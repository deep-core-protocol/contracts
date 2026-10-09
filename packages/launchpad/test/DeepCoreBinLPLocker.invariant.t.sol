// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";

import {BinPositionManager} from "infinity-periphery/src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {LockParams} from "../src/interfaces/IDeepCoreLPLocker.sol";

import {BinLockerFixture} from "./utils/BinLockerFixture.sol";

/// @dev Drives the Bin locker with a hostile world: buys and sells through the launch bins, permissionless
/// collections from anyone, claims to arbitrary addresses, creator rotations, currency donations plus skims,
/// a third-party LP joining and leaving the locked bins, orphan share transfers into the locker, and direct
/// attacks on the locked shares. Ghosts are measured from BALANCES, not from the locker's return values.
contract BinLockerHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    DeepCoreBinLPLocker public immutable locker;
    BinPositionManager public immutable binPm;
    BinPoolManager public immutable binPoolManager;
    BinSwapHelper public immutable swapper;

    struct LegRef {
        PoolKey key;
        bool launchIs0;
        uint24[] binIds;
    }

    LegRef[] internal _legs;
    uint256[] public lockIds;
    mapping(uint256 lockId => uint256 legIndex) public legOf;
    Currency[] public currencies;
    address[] public parties;
    mapping(address => bool) internal isParty;

    mapping(Currency => uint256) public ghostCollected;
    mapping(Currency => uint256) public ghostClaimed;
    mapping(Currency => uint256) public ghostSkimmed;
    /// @dev Last share counts observed by `collect`, the only action allowed to change them.
    mapping(uint256 lockId => mapping(uint256 index => uint256)) public ghostShares;
    mapping(uint256 tokenId => uint256) public ghostOrphans;

    bool public breach;
    bool public sharesRose;
    uint256 public collects;

    constructor(DeepCoreBinLPLocker locker_, BinPositionManager binPm_, BinPoolManager bpm_, BinSwapHelper swapper_) {
        locker = locker_;
        binPm = binPm_;
        binPoolManager = bpm_;
        swapper = swapper_;
    }

    function registerLeg(PoolKey memory key, bool launchIs0, uint24[] memory binIds) external returns (uint256 idx) {
        idx = _legs.length;
        _legs.push();
        LegRef storage l = _legs[idx];
        l.key = key;
        l.launchIs0 = launchIs0;
        for (uint256 i; i < binIds.length; ++i) l.binIds.push(binIds[i]);
        _addCurrency(key.currency0);
        _addCurrency(key.currency1);
    }

    function registerLock(uint256 lockId, uint256 legIndex, address[] memory ps) external {
        lockIds.push(lockId);
        legOf[lockId] = legIndex;
        (, uint256[] memory shares,) = locker.getLockedBins(lockId);
        for (uint256 i; i < shares.length; ++i) ghostShares[lockId][i] = shares[i];
        for (uint256 i; i < ps.length; ++i) {
            if (!isParty[ps[i]]) {
                isParty[ps[i]] = true;
                parties.push(ps[i]);
            }
        }
    }

    function _addCurrency(Currency c) internal {
        for (uint256 j; j < currencies.length; ++j) if (currencies[j] == c) return;
        currencies.push(c);
        address t = Currency.unwrap(c);
        MockERC20(t).mint(address(this), 1e36);
        MockERC20(t).approve(address(swapper), type(uint256).max);
        IAllowanceTransfer p2 = binPm.permit2();
        MockERC20(t).approve(address(p2), type(uint256).max);
        p2.approve(t, address(binPm), type(uint160).max, type(uint48).max);
    }

    function legCount() external view returns (uint256) {
        return _legs.length;
    }

    function legKey(uint256 i) external view returns (PoolKey memory) {
        return _legs[i].key;
    }

    function legBins(uint256 i) external view returns (uint24[] memory) {
        return _legs[i].binIds;
    }

    function lockCount() external view returns (uint256) {
        return lockIds.length;
    }

    function currencyCount() external view returns (uint256) {
        return currencies.length;
    }

    function partyCount() external view returns (uint256) {
        return parties.length;
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function trade(uint256 legSeed, bool buy, uint256 amount) external {
        LegRef storage l = _legs[legSeed % _legs.length];
        amount = bound(amount, 1e9, 150_000 ether);
        bool swapForY = buy ? !l.launchIs0 : l.launchIs0;
        try swapper.swap(
            l.key,
            swapForY,
            -int128(int256(amount)),
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        ) {} catch {}
    }

    function collect(uint256 lockSeed, uint256 callerSeed) external {
        uint256 lockId = lockIds[lockSeed % lockIds.length];
        PoolKey memory key = _legs[legOf[lockId]].key;
        uint256 b0 = key.currency0.balanceOf(address(locker));
        uint256 b1 = key.currency1.balanceOf(address(locker));
        vm.prank(address(uint160(bound(callerSeed, 1, type(uint160).max))));
        try locker.collectFees(lockId) {
            collects++;
        } catch {}
        ghostCollected[key.currency0] += key.currency0.balanceOf(address(locker)) - b0;
        ghostCollected[key.currency1] += key.currency1.balanceOf(address(locker)) - b1;

        (, uint256[] memory shares,) = locker.getLockedBins(lockId);
        for (uint256 i; i < shares.length; ++i) {
            if (shares[i] > ghostShares[lockId][i]) sharesRose = true;
            ghostShares[lockId][i] = shares[i];
        }
    }

    function claim(uint256 partySeed, uint256 currencySeed, uint256 toSeed) external {
        address party = parties[partySeed % parties.length];
        Currency c = currencies[currencySeed % currencies.length];
        address to = address(uint160(bound(toSeed, 1, type(uint160).max)));
        if (to == address(locker) || to == address(binPm) || to == address(this)) to = address(0xBEEF);
        if (locker.claimable(party, c) == 0) return;
        uint256 before = c.balanceOf(address(locker));
        vm.prank(party);
        locker.claim(c, to);
        ghostClaimed[c] += before - c.balanceOf(address(locker));
    }

    function rotateCreator(uint256 lockSeed, uint256 partySeed) external {
        uint256 lockId = lockIds[lockSeed % lockIds.length];
        address next = parties[partySeed % parties.length];
        address current = locker.getLock(lockId).creator;
        vm.prank(current);
        locker.transferCreator(lockId, next);
        vm.prank(next);
        locker.acceptCreator(lockId);
    }

    function donateAndSkim(uint256 currencySeed, uint256 amount) external {
        Currency c = currencies[currencySeed % currencies.length];
        amount = bound(amount, 1, 1 ether);
        MockERC20(Currency.unwrap(c)).transfer(address(locker), amount);
        ghostSkimmed[c] += locker.skim(c);
    }

    /// @dev A third party adds liquidity to a locked leg's bins (whichever side of the active bin each is on).
    function lpJoin(uint256 legSeed, uint256 amount) external {
        LegRef storage l = _legs[legSeed % _legs.length];
        amount = bound(amount, 1 ether, 100_000 ether);
        (uint24 active,,) = binPoolManager.getSlot0(l.key.toId());
        uint256 n = l.binIds.length;
        uint256 nX;
        uint256 nY;
        for (uint256 i; i < n; ++i) {
            if (l.binIds[i] > active) nX++;
            else if (l.binIds[i] < active) nY++;
        }
        uint256 m = nX + nY;
        if (m == 0) return;
        int256[] memory deltaIds = new int256[](m);
        uint256[] memory dx = new uint256[](m);
        uint256[] memory dy = new uint256[](m);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            if (l.binIds[i] == active) continue;
            deltaIds[j] = int256(uint256(l.binIds[i])) - int256(uint256(active));
            if (l.binIds[i] > active) dx[j] = 1e18 / nX;
            else dy[j] = 1e18 / nY;
            j++;
        }
        IBinPositionManager.BinAddLiquidityParams memory p = IBinPositionManager.BinAddLiquidityParams({
            poolKey: l.key,
            amount0: nX == 0 ? 0 : uint128(amount),
            amount1: nY == 0 ? 0 : uint128(amount),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            activeIdDesired: active,
            idSlippage: 0,
            deltaIds: deltaIds,
            distributionX: dx,
            distributionY: dy,
            minLiquidities: new uint256[](m),
            to: address(this),
            hookData: ""
        });
        Plan memory plan = Planner.init();
        plan.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(p));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(l.key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(l.key.currency1));
        try binPm.modifyLiquidities(plan.encode(), block.timestamp) {} catch {}
    }

    /// @dev The third party removes everything it holds in a leg's bins.
    function lpLeave(uint256 legSeed) external {
        LegRef storage l = _legs[legSeed % _legs.length];
        uint256 n = l.binIds.length;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amts = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            uint256 bal = binPm.balanceOf(address(this), _tid(l.key, l.binIds[i]));
            if (bal == 0) continue;
            ids[m] = l.binIds[i];
            amts[m] = bal;
            m++;
        }
        if (m == 0) return;
        assembly ("memory-safe") {
            mstore(ids, m)
            mstore(amts, m)
        }
        Plan memory plan = Planner.init();
        plan.add(
            Actions.BIN_REMOVE_LIQUIDITY,
            abi.encode(
                IBinPositionManager.BinRemoveLiquidityParams({
                    poolKey: l.key,
                    amount0Min: 0,
                    amount1Min: 0,
                    ids: ids,
                    amounts: amts,
                    from: address(this),
                    hookData: ""
                })
            )
        );
        plan.add(Actions.TAKE_PAIR, abi.encode(l.key.currency0, l.key.currency1, address(this)));
        try binPm.modifyLiquidities(plan.encode(), block.timestamp) {} catch {}
    }

    /// @dev A mistaken plain transfer of shares into the locker.
    function orphan(uint256 legSeed, uint256 binSeed, uint256 fractionSeed) external {
        LegRef storage l = _legs[legSeed % _legs.length];
        uint24 binId = l.binIds[binSeed % l.binIds.length];
        uint256 tid = _tid(l.key, binId);
        uint256 bal = binPm.balanceOf(address(this), tid);
        if (bal == 0) return;
        uint256 amt = bound(fractionSeed, 1, bal);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        (ids[0], amts[0]) = (tid, amt);
        binPm.batchTransferFrom(address(this), address(locker), ids, amts);
        ghostOrphans[tid] += amt;
    }

    /// @dev Every route to move, burn or re-attribute locked shares. Any success flips `breach`.
    function attack(uint256 lockSeed, uint8 mode) external {
        uint256 lockId = lockIds[lockSeed % lockIds.length];
        LegRef storage l = _legs[legOf[lockId]];
        address attacker = locker.getLock(lockId).creator; // the most privileged non-locker actor
        (, uint256[] memory shares,) = locker.getLockedBins(lockId);
        uint256 n = shares.length;
        uint256[] memory tids = new uint256[](n);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            tids[i] = _tid(l.key, l.binIds[i]);
            ids[i] = l.binIds[i];
        }
        mode = mode % 3;

        vm.startPrank(attacker);
        if (mode == 0) {
            try binPm.batchTransferFrom(address(locker), attacker, tids, shares) {
                breach = true;
            } catch {}
        } else if (mode == 1) {
            Plan memory plan = Planner.init();
            plan.add(
                Actions.BIN_REMOVE_LIQUIDITY,
                abi.encode(
                    IBinPositionManager.BinRemoveLiquidityParams({
                        poolKey: l.key,
                        amount0Min: 0,
                        amount1Min: 0,
                        ids: ids,
                        amounts: shares,
                        from: address(locker),
                        hookData: ""
                    })
                )
            );
            plan.add(Actions.TAKE_PAIR, abi.encode(l.key.currency0, l.key.currency1, attacker));
            try binPm.modifyLiquidities(plan.encode(), block.timestamp) {
                breach = true;
            } catch {}
        } else {
            // Re-lock the same bins under a split that names the attacker: pulls from the attacker only.
            LockParams memory p =
                LockParams({creator: attacker, creatorBps: 8_000, integrator: address(0), integratorBps: 0, protocolBps: 2_000});
            try locker.lock(l.key, l.binIds, shares, p) {
                breach = true;
            } catch {}
        }
        vm.stopPrank();
    }

    function _tid(PoolKey memory key, uint24 binId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), uint256(binId))));
    }
}

contract DeepCoreBinLPLockerInvariantTest is BinLockerFixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SUPPLY = 1_000_000 ether;

    BinLockerHandler handler;

    address constant CREATOR_2 = address(0xC0002);
    address constant INTEGRATOR_2 = address(0x10002);
    address constant SPARE = address(0x5BA4E);

    function setUp() public {
        _deployCore();
        handler = new BinLockerHandler(locker, binPm, binPoolManager, swapper);

        address[] memory ps = new address[](6);
        (ps[0], ps[1], ps[2], ps[3], ps[4], ps[5]) = (CREATOR, CREATOR_2, INTEGRATOR, INTEGRATOR_2, PROTOCOL, SPARE);

        // Leg A: launch token is currency0, linear shape, TWO locks in the same bins with different splits.
        (MockERC20 launchA, MockERC20 quote) = _pair(true);
        Leg memory a = _launch(address(launchA), address(quote), LP_FEE, Shape.Linear, 8, SUPPLY);
        uint256 legA = handler.registerLeg(a.key, a.launchIs0, a.binIds);
        handler.registerLock(_lock(a, _defaultParams()), legA, ps);
        (uint24[] memory ids2, uint256[] memory shares2) =
            _mintShaped(a.key, a.launchIs0, Shape.Linear, 8, SUPPLY / 4, address(this));
        LockParams memory p2 = _params(5_000, 0, 5_000);
        p2.creator = CREATOR_2;
        handler.registerLock(_lock(Leg({key: a.key, launchIs0: a.launchIs0, binIds: ids2, shares: shares2}), p2), legA, ps);

        // Leg B: a launch token that sorts as currency1, sharing leg A's quote, stepped shape (gaps).
        MockERC20 launchB;
        do {
            launchB = new MockERC20("LB", "LB", 18);
        } while (address(launchB) < address(quote));
        _fund(address(launchB));
        Leg memory b = _launch(address(launchB), address(quote), 10_000, Shape.Stepped, 10, SUPPLY);
        assertFalse(b.launchIs0);
        uint256 legB = handler.registerLeg(b.key, b.launchIs0, b.binIds);
        LockParams memory p3 = _params(4_500, 1_500, 4_000);
        p3.integrator = INTEGRATOR_2;
        handler.registerLock(_lock(b, p3), legB, ps);

        // Seed fees in both legs so the very first `collect` of any run has something to harvest.
        _buy(a, 200_000 ether);
        _buy(b, 200_000 ether);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = BinLockerHandler.trade.selector;
        selectors[1] = BinLockerHandler.collect.selector;
        selectors[2] = BinLockerHandler.claim.selector;
        selectors[3] = BinLockerHandler.rotateCreator.selector;
        selectors[4] = BinLockerHandler.donateAndSkim.selector;
        selectors[5] = BinLockerHandler.lpJoin.selector;
        selectors[6] = BinLockerHandler.lpLeave.selector;
        selectors[7] = BinLockerHandler.orphan.selector;
        selectors[8] = BinLockerHandler.attack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Guards against a vacuous pass: fees must actually have been harvested and paid out.
    function afterInvariant() public view {
        uint256 collected;
        for (uint256 k; k < handler.currencyCount(); ++k) collected += handler.ghostCollected(handler.currencies(k));
        assertGt(handler.collects(), 0, "run never collected");
        assertGt(collected, 0, "run never harvested value");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 100
    /// forge-config: legacy.invariant.runs = 32
    /// forge-config: legacy.invariant.depth = 100
    function invariant_principalNeverCrossed() public view {
        for (uint256 k; k < handler.lockCount(); ++k) _assertPrincipalIntact(handler.lockIds(k));
        assertFalse(handler.breach(), "an attack on locked shares succeeded");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 100
    /// forge-config: legacy.invariant.runs = 32
    /// forge-config: legacy.invariant.depth = 100
    function invariant_lockedSharesOnlyFallThroughCollect() public view {
        assertFalse(handler.sharesRose(), "a lock's shares rose");
        for (uint256 k; k < handler.lockCount(); ++k) {
            uint256 lockId = handler.lockIds(k);
            (, uint256[] memory shares,) = locker.getLockedBins(lockId);
            for (uint256 i; i < shares.length; ++i) {
                assertEq(shares[i], handler.ghostShares(lockId, i), "shares changed outside collectFees");
                assertGt(shares[i], 0, "bin emptied");
            }
        }
    }

    /// @dev The locker's share balance per bin is exactly the sum of its locks plus orphans: nothing left, and
    /// orphans were never burned.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 100
    /// forge-config: legacy.invariant.runs = 32
    /// forge-config: legacy.invariant.depth = 100
    function invariant_custodyEqualsRecordsPlusOrphans() public view {
        for (uint256 g; g < handler.legCount(); ++g) {
            PoolKey memory key = handler.legKey(g);
            uint24[] memory bins = handler.legBins(g);
            for (uint256 i; i < bins.length; ++i) {
                uint256 tid = _tokenId(key, bins[i]);
                uint256 recorded;
                for (uint256 k; k < handler.lockCount(); ++k) {
                    uint256 lockId = handler.lockIds(k);
                    if (PoolId.unwrap(locker.getLock(lockId).poolId) != PoolId.unwrap(key.toId())) continue;
                    (uint24[] memory ids, uint256[] memory shares,) = locker.getLockedBins(lockId);
                    for (uint256 j; j < ids.length; ++j) if (ids[j] == bins[i]) recorded += shares[j];
                }
                assertEq(binPm.balanceOf(address(locker), tid), recorded + handler.ghostOrphans(tid), "custody");
            }
        }
    }

    /// @dev sum(claimable) + claimed == collected + skimmed, per currency, from balance-measured ghosts.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 100
    /// forge-config: legacy.invariant.runs = 32
    /// forge-config: legacy.invariant.depth = 100
    function invariant_accountingConservesEveryUnit() public view {
        for (uint256 k; k < handler.currencyCount(); ++k) {
            Currency c = handler.currencies(k);
            uint256 sumClaimable;
            for (uint256 j; j < handler.partyCount(); ++j) sumClaimable += locker.claimable(handler.parties(j), c);
            assertEq(
                sumClaimable + handler.ghostClaimed(c),
                handler.ghostCollected(c) + handler.ghostSkimmed(c),
                "claimable + claimed == collected + skimmed"
            );
            assertEq(locker.totalOwed(c), sumClaimable, "totalOwed is the sum of claimable");
            assertGe(c.balanceOf(address(locker)), locker.totalOwed(c), "solvent");
        }
    }
}
