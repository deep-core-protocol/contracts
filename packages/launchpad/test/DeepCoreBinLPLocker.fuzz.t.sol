// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {PriceHelper} from "infinity-core/src/pool-bin/libraries/PriceHelper.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {IDeepCoreBinLPLocker} from "../src/interfaces/IDeepCoreBinLPLocker.sol";

import {BinLockerFixture} from "./utils/BinLockerFixture.sol";

contract FakeClPositionManager {
    address public vault = address(0xBEEF);
}

contract DeepCoreBinLPLockerFuzzTest is BinLockerFixture {
    uint256 internal constant SUPPLY = 1_000_000 ether;

    DeepCoreLPLocker clLocker;

    function setUp() public {
        _deployCore();
        // The CL locker's constructor only reads `vault()`, so a stub is enough to compare pure split math.
        clLocker = new DeepCoreLPLocker(
            ICLPositionManager(address(new FakeClPositionManager())), PROTOCOL, 2_000, 5_000, 2_000
        );
    }

    /*//////////////////////////////////////////////////////////////
                    THE PRINCIPAL GUARD, IN ISOLATION
    //////////////////////////////////////////////////////////////*/

    /// @dev For ANY bin state (not only states core can reach) and any principal the shares currently cover:
    ///   1. the burn never exceeds `shares - 1`;
    ///   2. after core's floored payout, the remaining shares are still worth >= principal;
    ///   3. the burn is MAXIMAL: keeping one share fewer would have crossed the principal (fees are not left
    ///      behind, beyond the one-share granularity);
    ///   4. a non-zero burn always pays out at least one unit, so core never reverts `ZeroAmountsOut`.
    function testFuzz_harvestableShares_neverCrossesPrincipal(
        uint256 rxSeed,
        uint256 rySeed,
        uint256 idSeed,
        uint256 supplySeed,
        uint256 sharesSeed,
        uint256 principalSeed
    ) public view {
        uint24 id = uint24(bound(idSeed, ACTIVE_ID - 2_000, ACTIVE_ID + 2_000));
        uint256 price = PriceHelper.getPriceFromId(id, BIN_STEP);
        uint128 rx = uint128(bound(rxSeed, 0, 2 ** 100));
        uint128 ry = uint128(bound(rySeed, 0, 2 ** 100));
        uint256 binL = price * rx + (uint256(ry) << 128);
        vm.assume(binL > 0);
        uint256 binS = bound(supplySeed, 1_001, 2 ** 232);
        uint256 shares = bound(sharesSeed, 1, binS);
        uint256 valueNow = FullMath.mulDiv(shares, binL, binS);
        vm.assume(valueNow > 0);
        uint256 principal = bound(principalSeed, 1, valueNow);

        uint256 burn = locker.harvestableShares(shares, principal, rx, ry, binL, binS);
        assertLt(burn, shares, "never burns every share");
        if (burn == 0) return;

        uint256 outX = FullMath.mulDiv(burn, rx, binS);
        uint256 outY = FullMath.mulDiv(burn, ry, binS);
        assertGt(outX + outY, 0, "a burn always pays out");

        uint256 rxAfter = rx - outX;
        uint256 ryAfter = ry - outY;
        uint256 binLAfter = price * rxAfter + (ryAfter << 128);
        uint256 remaining = shares - burn;
        assertGe(FullMath.mulDiv(remaining, binLAfter, binS - burn), principal, "principal crossed");

        // Maximality against the pre-burn price per share.
        assertLt(FullMath.mulDiv(remaining - 1, binL, binS), principal, "left harvestable fees behind");
    }

    /// @dev Bit-for-bit the same split as the committed CL locker.
    function testFuzz_split_matchesCLLocker(uint256 amount, uint16 creatorBps, uint16 integratorBps) public view {
        creatorBps = uint16(bound(creatorBps, 0, 10_000));
        integratorBps = uint16(bound(integratorBps, 0, 10_000 - creatorBps));
        (uint256 c, uint256 i, uint256 p) = locker.splitAmount(amount, creatorBps, integratorBps);
        (uint256 c2, uint256 i2, uint256 p2) = clLocker.splitAmount(amount, creatorBps, integratorBps);
        assertEq(c, c2);
        assertEq(i, i2);
        assertEq(p, p2);
        assertEq(c + i + p, amount);
    }

    /*//////////////////////////////////////////////////////////////
                  PER-BIN ACCOUNTING AGAINST THE REAL POOL
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: legacy.fuzz.runs = 64
    function testFuzz_realPool_randomShapeAndTrades(
        uint8 shapeSeed,
        uint8 binSeed,
        bool launchIs0,
        uint24 feeSeed,
        uint256[8] memory amounts,
        uint8 opsSeed
    ) public {
        Shape shape = Shape(shapeSeed % 4);
        uint256 n = bound(binSeed, 1, 24);
        uint24 fee = uint24(bound(feeSeed, 0, 20_000));
        (MockERC20 l, MockERC20 q) = _pair(launchIs0);
        Leg memory leg = _launch(address(l), address(q), fee, shape, n, SUPPLY);
        uint256 lockId = _lock(leg, _params(6_000, 2_000, 2_000));

        (, uint256[] memory prevShares, uint256[] memory principals) = locker.getLockedBins(lockId);
        uint256 collected;

        for (uint256 k; k < 8; ++k) {
            uint256 op = (uint256(opsSeed) >> k) & 1;
            uint256 amt = bound(amounts[k], 1e6, SUPPLY / 3);
            bool swapForY = op == 0 ? !leg.launchIs0 : leg.launchIs0; // 0 = buy, 1 = sell
            try swapper.swap(
                leg.key,
                swapForY,
                -int128(int256(amt)),
                BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                ""
            ) {} catch {}

            if (k % 3 == 2) {
                try locker.collectFees(lockId) returns (uint256 a0, uint256 a1) {
                    collected += a0 + a1;
                } catch (bytes memory err) {
                    assertEq(bytes4(err), IDeepCoreBinLPLocker.NothingToCollect.selector, "collect only fails when empty");
                }
            }

            (, uint256[] memory sharesNow, uint256[] memory principalsNow) = locker.getLockedBins(lockId);
            for (uint256 i; i < n; ++i) {
                assertLe(sharesNow[i], prevShares[i], "shares only fall");
                assertGt(sharesNow[i], 0, "a bin is never emptied");
                assertEq(principalsNow[i], principals[i], "principal is written once");
                assertEq(
                    binPm.balanceOf(address(locker), _tokenId(leg.key, leg.binIds[i])), sharesNow[i], "custody == record"
                );
            }
            prevShares = sharesNow;
            _assertPrincipalIntact(lockId);
        }
        if (fee == 0) assertLe(collected, 16 * (n + 1), "a zero-fee pool yields rounding dust at most");
    }
}
