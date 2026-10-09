// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

import {IDeepCoreLPLocker, LockParams} from "../src/interfaces/IDeepCoreLPLocker.sol";

import {LockerFixture} from "./utils/LockerFixture.sol";

contract DeepCoreLPLockerFuzzTest is LockerFixture {
    using CurrencyLibrary for Currency;

    uint256 constant D = 10_000;

    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey key;

    function setUp() public {
        _deployCore();
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 1e36);
        tokenB.mint(address(this), 1e36);
        _approveAll(address(tokenA));
        _approveAll(address(tokenB));
        key = _initPool(address(tokenA), address(tokenB));
    }

    /*//////////////////////////////////////////////////////////////
                               SPLIT MATH
    //////////////////////////////////////////////////////////////*/

    /// @dev For every amount and every valid split: nothing lost, nothing created, creator and integrator
    /// exactly floored, and ALL dust lands on the protocol - at most 2 units of it.
    function testFuzz_split_exactAndDustToProtocol(uint256 amount, uint16 creatorBps, uint16 integratorBps) public view {
        creatorBps = uint16(bound(creatorBps, 0, D));
        integratorBps = uint16(bound(integratorBps, 0, D - creatorBps));
        uint256 protocolBps = D - creatorBps - integratorBps;

        (uint256 c, uint256 i, uint256 p) = locker.splitAmount(amount, creatorBps, integratorBps);

        assertEq(c + i + p, amount, "sum is exact");
        assertEq(c, _mulDivDown(amount, creatorBps, D), "creator floored");
        assertEq(i, _mulDivDown(amount, integratorBps, D), "integrator floored");
        uint256 protocolFloor = _mulDivDown(amount, protocolBps, D);
        assertGe(p, protocolFloor, "protocol never below its bps");
        assertLe(p - protocolFloor, 2, "dust bounded by two units");
    }

    /// @dev Full-width amounts: FullMath must not overflow where `amount * bps` would.
    function testFuzz_split_noOverflowAtFullWidth(uint256 amount, uint16 creatorBps) public view {
        amount = bound(amount, type(uint256).max / D, type(uint256).max);
        creatorBps = uint16(bound(creatorBps, 0, D));
        (uint256 c, uint256 i, uint256 p) = locker.splitAmount(amount, creatorBps, 0);
        assertEq(i, 0);
        assertEq(c + p, amount);
    }

    function testFuzz_split_rejectsOverDenominator(uint16 creatorBps, uint16 integratorBps) public {
        vm.assume(uint256(creatorBps) + integratorBps > D);
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLPLocker.BpsDoNotSumToDenominator.selector, uint256(creatorBps) + integratorBps)
        );
        locker.splitAmount(1 ether, creatorBps, integratorBps);
    }

    /// @dev Repeated tiny collections cannot round the protocol floor away: dust goes TO the protocol.
    function testFuzz_split_manySmallCollectionsNeverShortProtocol(uint8 n, uint16 creatorBps) public view {
        creatorBps = uint16(bound(creatorBps, 0, D - MIN_PROTOCOL_BPS));
        uint256 protocolBps = D - creatorBps;
        uint256 total;
        uint256 protocolTotal;
        for (uint256 k = 1; k <= uint256(n) + 1; ++k) {
            uint256 amount = k * 7 + 3; // tiny, awkward amounts
            (,, uint256 p) = locker.splitAmount(amount, creatorBps, 0);
            total += amount;
            protocolTotal += p;
        }
        assertGe(protocolTotal, _mulDivDown(total, protocolBps, D));
    }

    /*//////////////////////////////////////////////////////////////
                         LOCK-TIME VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The locker accepts a lock IFF the declared split is inside every bound. Real position manager.
    function testFuzz_lock_acceptsExactlyTheValidSplits(
        uint16 creatorBps,
        uint16 integratorBps,
        uint16 protocolBps,
        bool sumToDenominator
    ) public {
        // Concentrated around the bounds, where a missing check would hide; `sumToDenominator == false`
        // still explores the full width via creatorBps.
        integratorBps = uint16(bound(integratorBps, 0, MAX_INTEGRATOR_BPS + 500));
        protocolBps = uint16(bound(protocolBps, 0, MAX_PROTOCOL_BPS + 1_000));
        // Half the runs make the parts sum exactly, so the bounds checks are exercised in isolation
        // rather than hidden behind the (far more likely) sum mismatch.
        if (sumToDenominator && uint256(integratorBps) + protocolBps <= D) {
            creatorBps = uint16(D - integratorBps - protocolBps);
        } else {
            creatorBps = uint16(bound(creatorBps, 0, D + 10));
        }

        uint256 tokenId = _mint(key, -600, 600, 1 ether);
        LockParams memory p = _params(creatorBps, integratorBps, protocolBps);

        bool valid = protocolBps >= MIN_PROTOCOL_BPS && protocolBps <= MAX_PROTOCOL_BPS
            && integratorBps <= MAX_INTEGRATOR_BPS && uint256(creatorBps) + integratorBps + protocolBps == D;

        // A low-level call, not `vm.expectRevert`: this package sets `allow_internal_expect_revert`, under
        // which a pending expectation can be satisfied by a LATER revert (such as a failing assertion) and
        // silently pass. That exact false pass hid a removed bounds check during mutation testing.
        (bool accepted,) = address(posm).call(
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,bytes)", address(this), address(locker), tokenId, abi.encode(p)
            )
        );
        assertEq(accepted, valid, "accepted iff valid");

        assertEq(locker.isLocked(tokenId), valid);
        assertEq(posm.ownerOf(tokenId), valid ? address(locker) : address(this));
        if (valid) {
            assertEq(locker.getLock(tokenId).protocolBps, protocolBps);
            assertEq(locker.getLock(tokenId).integratorBps, integratorBps);
        }
    }

    /// @dev End-to-end on the real pool: whatever arrives is credited in full, dust to protocol.
    function testFuzz_collect_creditsExactlyWhatArrived(uint96 swapAmount, uint16 creatorBps, uint16 integratorBps)
        public
    {
        integratorBps = uint16(bound(integratorBps, 0, MAX_INTEGRATOR_BPS));
        creatorBps = uint16(bound(creatorBps, D - MAX_PROTOCOL_BPS - integratorBps, D - MIN_PROTOCOL_BPS - integratorBps));
        uint16 protocolBps = uint16(D - creatorBps - integratorBps);
        swapAmount = uint96(bound(swapAmount, 1, 50 ether));

        uint256 tokenId = _mintFullRange(key);
        _lock(tokenId, _params(creatorBps, integratorBps, protocolBps));
        _trade(key, swapAmount);

        uint256 before0 = key.currency0.balanceOf(address(locker));
        (uint256 a0,) = locker.collectFees(tokenId);
        assertEq(key.currency0.balanceOf(address(locker)) - before0, a0);

        uint256 c = locker.claimable(CREATOR, key.currency0);
        uint256 i = locker.claimable(INTEGRATOR, key.currency0);
        uint256 pr = locker.claimable(PROTOCOL, key.currency0);
        assertEq(c + i + pr, a0);
        assertEq(c, a0 * creatorBps / D);
        assertEq(i, a0 * integratorBps / D);
        assertGe(pr, a0 * protocolBps / D);
        assertEq(posm.getPositionLiquidity(tokenId), LIQUIDITY);
    }

    function _mulDivDown(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        // a * b can overflow for a near 2^256; split to stay exact.
        return (a / d) * b + ((a % d) * b) / d;
    }
}
