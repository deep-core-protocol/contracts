// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {console} from "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {BaseBinTestHook} from "infinity-core/test/pool-bin/helpers/BaseBinTestHook.sol";

import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinFungibleToken} from "infinity-periphery/src/pool-bin/interfaces/IBinFungibleToken.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {IDeepCoreBinLPLocker, BinLock} from "../src/interfaces/IDeepCoreBinLPLocker.sol";
import {LockParams} from "../src/interfaces/IDeepCoreLPLocker.sol";

import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";

import {BinLockerFixture, BinTaxToken, BinPausableToken} from "./utils/BinLockerFixture.sol";

/// @dev A hook with a configurable registration bitmap. Only `beforeSwap` is ever implemented; the
/// burn-registering variants never reach a burn because the locker refuses them first.
contract BitmapHook is BaseBinTestHook {
    uint16 internal immutable bitmap;

    constructor(uint16 bitmap_) {
        bitmap = bitmap_;
    }

    function getHooksRegistrationBitmap() external view override returns (uint16) {
        return bitmap;
    }

    function beforeSwap(address, PoolKey calldata, bool, int128, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseBinTestHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

/// @dev A quote token that tries to re-enter the locker whenever it is transferred to `watch`.
contract ReentrantToken is MockERC20 {
    address public target;
    address public watch;
    bytes public payload;
    bytes4 public lastRevert;
    uint256 public attempts;
    bool public reentrySucceeded;

    constructor() MockERC20("Reenter", "RE", 18) {}

    function arm(address target_, address watch_, bytes calldata payload_) external {
        target = target_;
        watch = watch_;
        payload = payload_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (target != address(0) && (to == watch || msg.sender == watch)) {
            address t = target;
            target = address(0); // one attempt per arming
            attempts++;
            (bool success, bytes memory ret) = t.call(payload);
            if (success) reentrySucceeded = true;
            if (ret.length >= 4) lastRevert = bytes4(ret);
        }
        return ok;
    }
}

contract FakeBinPositionManager {
    address public vault;
    address public binPoolManager;

    constructor(address vault_, address binPoolManager_) {
        vault = vault_;
        binPoolManager = binPoolManager_;
    }
}

contract DeepCoreBinLPLockerTest is BinLockerFixture {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant BINS = 10;

    MockERC20 launch;
    MockERC20 quote;

    function setUp() public {
        _deployCore();
        (launch, quote) = _pair(true);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsImmutables() public view {
        assertEq(address(locker.positionManager()), address(binPm));
        assertEq(address(locker.binPoolManager()), address(binPoolManager));
        assertEq(locker.vault(), address(vault));
        assertEq(locker.protocolRecipient(), PROTOCOL);
        assertEq(locker.minProtocolBps(), MIN_PROTOCOL_BPS);
        assertEq(locker.maxProtocolBps(), MAX_PROTOCOL_BPS);
        assertEq(locker.maxIntegratorBps(), MAX_INTEGRATOR_BPS);
        assertEq(locker.maxBinsPerLock(), MAX_BINS);
        assertEq(locker.lockCount(), 0);
    }

    function test_constructor_rejectsBadArguments() public {
        vm.expectRevert(IDeepCoreBinLPLocker.ZeroAddress.selector);
        new DeepCoreBinLPLocker(IBinPositionManager(address(0)), PROTOCOL, 2_000, 5_000, 2_000, 64);
        vm.expectRevert(IDeepCoreBinLPLocker.ZeroAddress.selector);
        new DeepCoreBinLPLocker(binPm, address(0), 2_000, 5_000, 2_000, 64);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidBpsBounds.selector, 5_001, 5_000, 2_000));
        new DeepCoreBinLPLocker(binPm, PROTOCOL, 5_001, 5_000, 2_000, 64);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidBpsBounds.selector, 2_000, 10_001, 2_000));
        new DeepCoreBinLPLocker(binPm, PROTOCOL, 2_000, 10_001, 2_000, 64);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidBpsBounds.selector, 2_000, 5_000, 10_001));
        new DeepCoreBinLPLocker(binPm, PROTOCOL, 2_000, 5_000, 10_001, 64);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidMaxBinsPerLock.selector, 0));
        new DeepCoreBinLPLocker(binPm, PROTOCOL, 2_000, 5_000, 2_000, 0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidMaxBinsPerLock.selector, 257));
        new DeepCoreBinLPLocker(binPm, PROTOCOL, 2_000, 5_000, 2_000, 257);

        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(IDeepCoreBinLPLocker.ProtocolRecipientIsLocker.selector);
        new DeepCoreBinLPLocker(binPm, next, 2_000, 5_000, 2_000, 64);

        FakeBinPositionManager noVault = new FakeBinPositionManager(address(0), address(binPoolManager));
        vm.expectRevert(IDeepCoreBinLPLocker.PositionManagerHasNoVault.selector);
        new DeepCoreBinLPLocker(IBinPositionManager(address(noVault)), PROTOCOL, 2_000, 5_000, 2_000, 64);
        FakeBinPositionManager noManager = new FakeBinPositionManager(address(vault), address(0));
        vm.expectRevert(IDeepCoreBinLPLocker.PositionManagerHasNoPoolManager.selector);
        new DeepCoreBinLPLocker(IBinPositionManager(address(noManager)), PROTOCOL, 2_000, 5_000, 2_000, 64);
    }

    function test_noAdminSurface() public {
        (bool ok,) = address(locker).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner()");
        (ok,) = address(locker).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "pause()");
        (ok,) = address(locker).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok, "renounceOwnership()");
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    function test_lock_linearShape_pullsSharesAndRecordsPrincipal() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, BINS, SUPPLY);

        binPm.approveForAll(address(locker), true);
        vm.expectEmit(true, true, true, false, address(locker));
        emit IDeepCoreBinLPLocker.BinsLocked(
            1, leg.key.toId(), CREATOR, INTEGRATOR, 6_000, 2_000, 2_000, leg.binIds, leg.shares, new uint256[](0), address(this)
        );
        uint256 lockId = locker.lock(leg.key, leg.binIds, leg.shares, _defaultParams());

        assertEq(lockId, 1);
        assertEq(locker.lockCount(), 1);
        assertTrue(locker.isLocked(lockId));
        BinLock memory lk = locker.getLock(lockId);
        assertEq(lk.creator, CREATOR);
        assertEq(lk.integrator, INTEGRATOR);
        assertEq(lk.creatorBps, 6_000);
        assertEq(lk.integratorBps, 2_000);
        assertEq(lk.protocolBps, 2_000);
        assertEq(lk.binCount, BINS);
        assertEq(lk.lockedAt, block.timestamp);
        assertEq(PoolId.unwrap(lk.poolId), PoolId.unwrap(leg.key.toId()));
        assertEq(PoolId.unwrap(locker.getPoolKey(lockId).toId()), PoolId.unwrap(leg.key.toId()));

        (uint24[] memory ids, uint256[] memory shares, uint256[] memory principals) = locker.getLockedBins(lockId);
        for (uint256 i; i < BINS; ++i) {
            uint256 tid = _tokenId(leg.key, leg.binIds[i]);
            assertEq(ids[i], leg.binIds[i]);
            assertEq(shares[i], leg.shares[i]);
            assertEq(binPm.balanceOf(address(this), tid), 0, "creator keeps nothing");
            assertEq(binPm.balanceOf(address(locker), tid), leg.shares[i], "locker holds the shares");
            (uint128 rx, uint128 ry, uint256 binL, uint256 binS) = binPoolManager.getBin(lk.poolId, ids[i]);
            assertGt(rx, 0, "token-only bin holds launch token");
            assertEq(ry, 0, "token-only bin holds no quote");
            assertEq(principals[i], FullMath.mulDivRoundingUp(shares[i], binL, binS), "principal = ceil(s*L/S)");
        }
        _assertPrincipalIntact(lockId);
        uint256[] memory preview = locker.previewCollect(lockId);
        for (uint256 i; i < BINS; ++i) assertEq(preview[i], 0, "nothing to harvest at lock");
    }

    /// @dev A lock into bins whose share price already carries fees (L/S is not an integer): the recorded
    /// principal must round UP, and fees earned before the lock are principal, not harvestable.
    function test_lock_intoFeeBearingBins_principalRoundsUp_preLockFeesArePrincipal() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Flat, 4, SUPPLY);
        uint256 first = _lock(leg, _defaultParams());
        _buy(leg, 520_000 ether); // bins 0 and 1 fully bought: all quote, L/S > 1 from fees
        (uint24 active,,) = binPoolManager.getSlot0(leg.key.toId());
        assertGt(active, leg.binIds[1], "two bins crossed");

        int256[] memory deltaIds = new int256[](2);
        uint256[] memory distY = new uint256[](2);
        uint24[] memory ids = new uint24[](2);
        for (uint256 i; i < 2; ++i) {
            ids[i] = leg.binIds[i];
            deltaIds[i] = int256(uint256(ids[i])) - int256(uint256(active));
            distY[i] = 0.5e18;
        }
        IBinPositionManager.BinAddLiquidityParams memory p = IBinPositionManager.BinAddLiquidityParams({
            poolKey: leg.key,
            amount0: 0,
            amount1: 10_000 ether + 12_345,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            activeIdDesired: active,
            idSlippage: 0,
            deltaIds: deltaIds,
            distributionX: new uint256[](2),
            distributionY: distY,
            minLiquidities: new uint256[](2),
            to: address(this),
            hookData: ""
        });
        uint256[] memory shares = new uint256[](2);
        for (uint256 i; i < 2; ++i) shares[i] = binPm.balanceOf(address(this), _tokenId(leg.key, ids[i]));
        Plan memory plan = Planner.init();
        plan.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(p));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(leg.key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(leg.key.currency1));
        binPm.modifyLiquidities(plan.encode(), block.timestamp);
        for (uint256 i; i < 2; ++i) shares[i] = binPm.balanceOf(address(this), _tokenId(leg.key, ids[i])) - shares[i];

        uint256 second = locker.lock(leg.key, ids, shares, _params(8_000, 0, 2_000));
        (,, uint256[] memory principals) = locker.getLockedBins(second);
        for (uint256 i; i < 2; ++i) {
            (,, uint256 binL, uint256 binS) = binPoolManager.getBin(leg.key.toId(), ids[i]);
            assertGt(binL, binS, "share price carries fees");
            assertTrue(mulmod(shares[i], binL, binS) != 0, "non-integer value, so rounding is observable");
            assertEq(principals[i], FullMath.mulDivRoundingUp(shares[i], binL, binS), "principal rounds up");
        }
        uint256[] memory preview = locker.previewCollect(second);
        assertEq(preview[0] + preview[1], 0, "fees earned before the lock are not harvestable by it");
        assertGt(locker.previewCollect(first)[0], 0, "the earlier lock earned them");
    }

    function test_lock_everyShape_bothOrientations() public {
        for (uint256 o; o < 2; ++o) {
            for (uint8 s; s < 4; ++s) {
                (MockERC20 l, MockERC20 q) = _pair(o == 0);
                Leg memory leg = _launch(address(l), address(q), LP_FEE, Shape(s), 12, SUPPLY);
                assertEq(leg.launchIs0, o == 0);
                uint256 lockId = _lock(leg, _defaultParams());
                (uint24[] memory ids,,) = locker.getLockedBins(lockId);
                for (uint256 i = 1; i < ids.length; ++i) assertGt(ids[i], ids[i - 1], "ascending");
                if (Shape(s) == Shape.Stepped) assertGt(ids[ids.length - 1] - ids[0], 11, "stepped has gaps");
                _buy(leg, SUPPLY / 3);
                _assertPrincipalIntact(lockId);
            }
        }
    }

    function test_lock_revertsOnSplitOutsideBounds() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Flat, 4, SUPPLY);
        binPm.approveForAll(address(locker), true);

        // Protocol floor.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.ProtocolBpsOutOfRange.selector, 1_999, 2_000, 5_000));
        locker.lock(leg.key, leg.binIds, leg.shares, _params(8_001, 0, 1_999));
        // Protocol cap.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.ProtocolBpsOutOfRange.selector, 5_001, 2_000, 5_000));
        locker.lock(leg.key, leg.binIds, leg.shares, _params(4_999, 0, 5_001));
        // Integrator cap.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.IntegratorBpsTooHigh.selector, 2_001, 2_000));
        locker.lock(leg.key, leg.binIds, leg.shares, _params(5_999, 2_001, 2_000));
        // Sum.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.BpsDoNotSumToDenominator.selector, 9_999));
        locker.lock(leg.key, leg.binIds, leg.shares, _params(5_999, 2_000, 2_000));
        // Creator.
        LockParams memory p = _defaultParams();
        p.creator = address(0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidCreator.selector, address(0)));
        locker.lock(leg.key, leg.binIds, leg.shares, p);
        p.creator = address(locker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidCreator.selector, address(locker)));
        locker.lock(leg.key, leg.binIds, leg.shares, p);
        // Integrator must be set iff bps is set, and never the locker.
        p = _defaultParams();
        p.integrator = address(0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidIntegrator.selector, address(0), 2_000));
        locker.lock(leg.key, leg.binIds, leg.shares, p);
        p = _params(8_000, 0, 2_000);
        p.integrator = INTEGRATOR;
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidIntegrator.selector, INTEGRATOR, 0));
        locker.lock(leg.key, leg.binIds, leg.shares, p);
        p = _defaultParams();
        p.integrator = address(locker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidIntegrator.selector, address(locker), 2_000));
        locker.lock(leg.key, leg.binIds, leg.shares, p);

        // Exactly at the bounds is accepted.
        uint256 id1 = locker.lock(leg.key, _one(leg.binIds[0]), _oneU(leg.shares[0] / 2), _params(8_000, 0, 2_000));
        uint256 id2 = locker.lock(leg.key, _one(leg.binIds[1]), _oneU(leg.shares[1] / 2), _params(3_000, 2_000, 5_000));
        assertEq(locker.getLock(id1).protocolBps, 2_000);
        assertEq(locker.getLock(id2).protocolBps, 5_000);
    }

    function test_lock_revertsOnBadBins() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Flat, 4, SUPPLY);
        binPm.approveForAll(address(locker), true);
        LockParams memory p = _defaultParams();

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidBinCount.selector, 0, MAX_BINS));
        locker.lock(leg.key, new uint24[](0), new uint256[](0), p);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.LengthMismatch.selector, 4, 3));
        locker.lock(leg.key, leg.binIds, new uint256[](3), p);

        uint24[] memory tooMany = new uint24[](MAX_BINS + 1);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidBinCount.selector, MAX_BINS + 1, MAX_BINS));
        locker.lock(leg.key, tooMany, new uint256[](MAX_BINS + 1), p);

        uint24[] memory dup = new uint24[](2);
        (dup[0], dup[1]) = (leg.binIds[0], leg.binIds[0]);
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (1, 1);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.BinIdsNotStrictlyIncreasing.selector, 1));
        locker.lock(leg.key, dup, two, p);
        (dup[0], dup[1]) = (leg.binIds[1], leg.binIds[0]);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.BinIdsNotStrictlyIncreasing.selector, 1));
        locker.lock(leg.key, dup, two, p);

        uint256[] memory zeros = new uint256[](4);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.ZeroShares.selector, leg.binIds[0]));
        locker.lock(leg.key, leg.binIds, zeros, p);

        // More than the caller holds: the real share token refuses, nothing moves.
        uint256[] memory tooMuch = new uint256[](4);
        for (uint256 i; i < 4; ++i) tooMuch[i] = leg.shares[i] + 1;
        vm.expectRevert();
        locker.lock(leg.key, leg.binIds, tooMuch, p);
    }

    function test_lock_refusesForeignPoolManager() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Flat, 2, SUPPLY);
        binPm.approveForAll(address(locker), true);
        PoolKey memory k = leg.key;
        k.poolManager = IPoolManager(address(0x1234));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.PoolManagerMismatch.selector, address(0x1234)));
        locker.lock(k, leg.binIds, leg.shares, _defaultParams());
    }

    function test_lock_refusesBurnHooks_acceptsSwapHook() public {
        uint16[3] memory refused = [uint16(1 << 4), uint16(1 << 5), uint16((1 << 5) | (1 << 13))];
        binPm.approveForAll(address(locker), true);
        for (uint256 i; i < 3; ++i) {
            BitmapHook hook = new BitmapHook(refused[i]);
            (PoolKey memory key, bool is0) = _key(address(launch), address(quote), LP_FEE, IHooks(address(hook)), refused[i]);
            (uint24[] memory ids, uint256[] memory shares) = _mintShaped(key, is0, Shape.Flat, 2, SUPPLY, address(this));
            vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.HookInterceptsRemoval.selector, address(hook)));
            locker.lock(key, ids, shares, _defaultParams());
        }

        // A hook that only runs on swaps (BinLaunchGuardHook's shape: no burn bits) is accepted and collectable.
        uint16 swapOnly = 1 << 6;
        BitmapHook ok = new BitmapHook(swapOnly);
        Leg memory leg;
        (leg.key, leg.launchIs0) = _key(address(launch), address(quote), LP_FEE, IHooks(address(ok)), swapOnly);
        (leg.binIds, leg.shares) = _mintShaped(leg.key, leg.launchIs0, Shape.Linear, 4, SUPPLY, address(this));
        uint256 lockId = locker.lock(leg.key, leg.binIds, leg.shares, _defaultParams());
        _buy(leg, SUPPLY / 2);
        (uint256 a0, uint256 a1) = locker.collectFees(lockId);
        assertGt(a0 + a1, 0);
        _assertPrincipalIntact(lockId);
    }

    /// @dev The approval a holder grants the locker can only be spent by that holder, inside its own `lock`.
    function test_lock_pullsOnlyFromCaller_approvalIsNotUsableByOthers() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Flat, 3, SUPPLY);
        binPm.approveForAll(address(locker), true); // the victim's standing approval

        LockParams memory p = _defaultParams();
        p.creator = ATTACKER;
        vm.prank(ATTACKER);
        vm.expectRevert(); // BinFungibleToken_TransferExceedsBalance(ATTACKER, ...)
        locker.lock(leg.key, leg.binIds, leg.shares, p);

        for (uint256 i; i < 3; ++i) {
            assertEq(binPm.balanceOf(address(this), _tokenId(leg.key, leg.binIds[i])), leg.shares[i], "victim untouched");
        }
        assertEq(locker.lockCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PRINCIPAL: SALE PROCEEDS ARE NOT FEES
    //////////////////////////////////////////////////////////////*/

    /// @dev A ZERO-fee pool isolates price movement from fees. Buyers take most of the launch bins, so most
    /// principal is now quote tokens - and not one unit is harvestable.
    function test_zeroFeePool_buyThrough_nothingToCollect_bothOrientations() public {
        for (uint256 o; o < 2; ++o) {
            (MockERC20 l, MockERC20 q) = _pair(o == 0);
            Leg memory leg = _launch(address(l), address(q), 0, Shape.Linear, BINS, SUPPLY);
            uint256 lockId = _lock(leg, _defaultParams());

            _buy(leg, SUPPLY * 8 / 10);
            _sell(leg, SUPPLY / 10);
            _buy(leg, SUPPLY / 20);

            uint256 quoteInBins;
            for (uint256 i; i < BINS; ++i) {
                (uint128 rx, uint128 ry,,) = binPoolManager.getBin(leg.key.toId(), leg.binIds[i]);
                quoteInBins += leg.launchIs0 ? ry : rx;
            }
            assertGt(quoteInBins, SUPPLY / 2, "most principal converted to quote");

            _assertPrincipalIntact(lockId);
            // Core's swap rounding favours the bin by under one base unit per step, and that IS value above
            // principal, so a zero-fee pool may yield a few wei. It must never yield the proceeds.
            try locker.collectFees(lockId) returns (uint256 a0, uint256 a1) {
                assertLe(a0 + a1, 3 * BINS, "only rounding dust, never sale proceeds");
            } catch (bytes memory err) {
                assertEq(bytes4(err), IDeepCoreBinLPLocker.NothingToCollect.selector);
            }
            _assertPrincipalIntact(lockId);
        }
    }

    function test_buyThrough_feesCollected_onlyFeesLeave() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, BINS, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());

        uint256 quoteIn = 400_000 ether;
        _buy(leg, quoteIn);

        // Crossed bins now hold quote only.
        (uint128 rx0, uint128 ry0,,) = binPoolManager.getBin(leg.key.toId(), leg.binIds[0]);
        assertEq(rx0, 0, "first bin fully bought");
        assertGt(ry0, 0, "first bin is quote");
        _assertPrincipalIntact(lockId);

        uint256 lockerQuoteBefore = quote.balanceOf(address(locker));
        vm.prank(address(0xCAFE)); // anyone
        (uint256 a0, uint256 a1) = locker.collectFees(lockId);
        (uint256 launchOut, uint256 quoteOut) = leg.launchIs0 ? (a0, a1) : (a1, a0);
        assertEq(quote.balanceOf(address(locker)) - lockerQuoteBefore, quoteOut);

        // The LP fee on `quoteIn` at 0.3% is ~1_200 quote. Harvest (valued at ~1:1 bin prices, within the ~1%
        // spread of the crossed bins) must be that and nothing like the ~400_000 of sale proceeds.
        uint256 feeLow = quoteIn * LP_FEE / 1e6 * 98 / 100;
        uint256 feeHigh = quoteIn * LP_FEE / (1e6 - LP_FEE) * 102 / 100;
        assertGt(quoteOut + launchOut, feeLow, "fees harvested");
        assertLt(quoteOut + launchOut, feeHigh, "only fees harvested");

        // What remains is the principal plus rounding: under 4 wei of quote per bin.
        for (uint256 i; i < BINS; ++i) {
            (uint256 value, uint256 principal) = _value(lockId, i);
            assertGe(value, principal);
            assertLt(value - principal, 4 << 128, "harvest left fees behind");
        }
        // Core's floored payout of the first harvest raises the remaining shares' value by under one base unit
        // per token per bin, which a second harvest may realise. Dust, never principal.
        try locker.collectFees(lockId) returns (uint256 d0, uint256 d1) {
            assertLe(d0 + d1, 2 * BINS, "second harvest is rounding dust only");
        } catch (bytes memory err) {
            assertEq(bytes4(err), IDeepCoreBinLPLocker.NothingToCollect.selector);
        }
        _assertPrincipalIntact(lockId);
    }

    function test_split_isExact_dustToProtocol() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Exponential, BINS, SUPPLY);
        LockParams memory p = _params(6_667, 1_333, 2_000);
        uint256 lockId = _lock(leg, p);
        _buy(leg, 333_333 ether + 7);
        _sell(leg, 111_111 ether + 3);

        (uint256 a0, uint256 a1) = locker.collectFees(lockId);
        uint256[2] memory amts = [a0, a1];
        Currency[2] memory cs = [leg.key.currency0, leg.key.currency1];
        for (uint256 k; k < 2; ++k) {
            uint256 a = amts[k];
            assertGt(a, 0, "both currencies harvested");
            uint256 c = a * 6_667 / 10_000;
            uint256 i = a * 1_333 / 10_000;
            assertEq(locker.claimable(CREATOR, cs[k]), c, "creator floored");
            assertEq(locker.claimable(INTEGRATOR, cs[k]), i, "integrator floored");
            assertEq(locker.claimable(PROTOCOL, cs[k]), a - c - i, "protocol takes remainder");
            assertGe(locker.claimable(PROTOCOL, cs[k]), a * 2_000 / 10_000, "protocol never below its bps");
            assertLe(locker.claimable(PROTOCOL, cs[k]) - a * 2_000 / 10_000, 2, "at most 2 units of dust");
            assertEq(locker.totalOwed(cs[k]), a);
            assertEq(cs[k].balanceOf(address(locker)), a);
        }
    }

    function test_repeatedCollects_neverErodePrincipal() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Stepped, 16, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        (, uint256[] memory sharesPrev,) = locker.getLockedBins(lockId);

        for (uint256 r; r < 12; ++r) {
            _buy(leg, 37_000 ether + r);
            try locker.collectFees(lockId) {} catch {}
            _sell(leg, 21_000 ether + r);
            vm.prank(address(uint160(0x1000 + r)));
            try locker.collectFees(lockId) {} catch {}
            _assertPrincipalIntact(lockId);
            (, uint256[] memory sharesNow,) = locker.getLockedBins(lockId);
            for (uint256 i; i < sharesNow.length; ++i) assertLe(sharesNow[i], sharesPrev[i], "shares never rise");
            sharesPrev = sharesNow;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         PRINCIPAL IS UNREACHABLE
    //////////////////////////////////////////////////////////////*/

    function test_principal_cannotBeMovedOrBurnedByAnyone() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, 4, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 200_000 ether);

        uint256[] memory tids = new uint256[](4);
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            tids[i] = _tokenId(leg.key, leg.binIds[i]);
            ids[i] = leg.binIds[i];
        }

        address[3] memory actors = [ATTACKER, CREATOR, PROTOCOL];
        for (uint256 a; a < 3; ++a) {
            vm.startPrank(actors[a]);
            vm.expectRevert(
                abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, address(locker), actors[a])
            );
            binPm.batchTransferFrom(address(locker), actors[a], tids, leg.shares);

            Plan memory plan = Planner.init();
            plan.add(
                Actions.BIN_REMOVE_LIQUIDITY,
                abi.encode(
                    IBinPositionManager.BinRemoveLiquidityParams({
                        poolKey: leg.key,
                        amount0Min: 0,
                        amount1Min: 0,
                        ids: ids,
                        amounts: leg.shares,
                        from: address(locker),
                        hookData: ""
                    })
                )
            );
            plan.add(Actions.TAKE_PAIR, abi.encode(leg.key.currency0, leg.key.currency1, actors[a]));
            vm.expectRevert(
                abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, address(locker), actors[a])
            );
            binPm.modifyLiquidities(plan.encode(), block.timestamp);
            vm.stopPrank();
        }
        for (uint256 i; i < 4; ++i) assertEq(binPm.balanceOf(address(locker), tids[i]), leg.shares[i]);
        assertFalse(binPm.isApprovedForAll(address(locker), ATTACKER));
        _assertPrincipalIntact(lockId);
    }

    function test_poolManagerPaused_collectStillWorks() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, 4, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 300_000 ether);
        binPoolManager.pause();
        (uint256 a0, uint256 a1) = locker.collectFees(lockId);
        assertGt(a0 + a1, 0);
        _assertPrincipalIntact(lockId);
    }

    /*//////////////////////////////////////////////////////////////
                         SHARED BINS AND ORPHANS
    //////////////////////////////////////////////////////////////*/

    function test_twoLocksAndAThirdPartyInTheSameBins() public {
        Leg memory legA = _launch(address(launch), address(quote), LP_FEE, Shape.Flat, 6, SUPPLY);
        uint256 lockA = _lock(legA, _defaultParams());

        // Second lock in the same bins, different split.
        (uint24[] memory idsB, uint256[] memory sharesB) =
            _mintShaped(legA.key, legA.launchIs0, Shape.Flat, 6, SUPPLY / 3, address(this));
        Leg memory legB = Leg({key: legA.key, launchIs0: legA.launchIs0, binIds: idsB, shares: sharesB});
        LockParams memory pB = _params(5_000, 0, 5_000);
        uint256 lockB = _lock(legB, pB);

        // A third-party LP joins the same bins, trades happen, then it leaves entirely.
        address alice = address(0xA11CE);
        (uint24[] memory idsC, uint256[] memory sharesC) =
            _mintShaped(legA.key, legA.launchIs0, Shape.Flat, 6, SUPPLY / 2, alice);
        _buy(legA, 500_000 ether);
        _sell(legA, 120_000 ether);

        uint256[] memory idsCU = new uint256[](6);
        for (uint256 i; i < 6; ++i) idsCU[i] = idsC[i];
        vm.startPrank(alice);
        Plan memory plan = Planner.init();
        plan.add(
            Actions.BIN_REMOVE_LIQUIDITY,
            abi.encode(
                IBinPositionManager.BinRemoveLiquidityParams({
                    poolKey: legA.key,
                    amount0Min: 0,
                    amount1Min: 0,
                    ids: idsCU,
                    amounts: sharesC,
                    from: alice,
                    hookData: ""
                })
            )
        );
        plan.add(Actions.TAKE_PAIR, abi.encode(legA.key.currency0, legA.key.currency1, alice));
        binPm.modifyLiquidities(plan.encode(), block.timestamp);
        vm.stopPrank();

        _assertPrincipalIntact(lockA);
        _assertPrincipalIntact(lockB);
        locker.collectFees(lockA);
        locker.collectFees(lockB);
        _assertPrincipalIntact(lockA);
        _assertPrincipalIntact(lockB);

        (, uint256[] memory sA,) = locker.getLockedBins(lockA);
        (, uint256[] memory sB,) = locker.getLockedBins(lockB);
        for (uint256 i; i < 6; ++i) {
            assertEq(binPm.balanceOf(address(locker), _tokenId(legA.key, idsB[i])), sA[i] + sB[i], "balance == sum of locks");
        }
    }

    function test_orphanShares_areNeverBurnedOrMoved() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, 4, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());

        // A mistaken plain transfer into the locker, into the same bins.
        (uint24[] memory ids2, uint256[] memory orphan) =
            _mintShaped(leg.key, leg.launchIs0, Shape.Linear, 4, SUPPLY / 4, address(this));
        uint256[] memory tids = new uint256[](4);
        for (uint256 i; i < 4; ++i) tids[i] = _tokenId(leg.key, ids2[i]);
        binPm.batchTransferFrom(address(this), address(locker), tids, orphan);
        assertEq(locker.lockCount(), 1, "no record created");

        // Nobody can attach them: `lock` only pulls from the caller.
        vm.prank(ATTACKER);
        vm.expectRevert();
        locker.lock(leg.key, ids2, orphan, _params(8_000, 0, 2_000));

        _buy(leg, 300_000 ether);
        locker.collectFees(lockId);

        (, uint256[] memory s,) = locker.getLockedBins(lockId);
        for (uint256 i; i < 4; ++i) {
            assertEq(binPm.balanceOf(address(locker), tids[i]), s[i] + orphan[i], "orphans untouched by harvest");
        }
        _assertPrincipalIntact(lockId);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM & SKIM
    //////////////////////////////////////////////////////////////*/

    function test_claim_pullsToAnyAddress_andOnlyOnce() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, BINS, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 300_000 ether);
        locker.collectFees(lockId);

        Currency q = Currency.wrap(address(quote));
        uint256 owed = locker.claimable(CREATOR, q);
        assertGt(owed, 0);
        vm.prank(CREATOR);
        vm.expectRevert(IDeepCoreBinLPLocker.ZeroAddress.selector);
        locker.claim(q, address(0));

        vm.prank(CREATOR);
        assertEq(locker.claim(q, address(0xD00D)), owed);
        assertEq(quote.balanceOf(address(0xD00D)), owed);
        assertEq(locker.claimable(CREATOR, q), 0);

        vm.prank(CREATOR);
        vm.expectRevert(IDeepCoreBinLPLocker.NothingToClaim.selector);
        locker.claim(q, CREATOR);
        vm.prank(ATTACKER);
        vm.expectRevert(IDeepCoreBinLPLocker.NothingToClaim.selector);
        locker.claim(q, ATTACKER);

        vm.prank(PROTOCOL);
        locker.claim(q, PROTOCOL);
        vm.prank(INTEGRATOR);
        locker.claim(q, INTEGRATOR);
        assertEq(locker.totalOwed(q), 0);
    }

    function test_skim_creditsSurplusToProtocolOnly() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, 4, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 300_000 ether);
        locker.collectFees(lockId);
        Currency q = Currency.wrap(address(quote));

        vm.expectRevert(IDeepCoreBinLPLocker.NothingToSkim.selector);
        locker.skim(q);

        uint256 creatorBefore = locker.claimable(CREATOR, q);
        uint256 protocolBefore = locker.claimable(PROTOCOL, q);
        quote.transfer(address(locker), 5 ether);
        vm.prank(ATTACKER);
        assertEq(locker.skim(q), 5 ether);
        assertEq(locker.claimable(PROTOCOL, q), protocolBefore + 5 ether);
        assertEq(locker.claimable(CREATOR, q), creatorBefore);
        assertEq(locker.totalOwed(q), quote.balanceOf(address(locker)));
    }

    /*//////////////////////////////////////////////////////////////
                             CREATOR ROTATION
    //////////////////////////////////////////////////////////////*/

    function test_creatorRotation_twoStep_andUnauthorized() public {
        Leg memory leg = _launch(address(launch), address(quote), LP_FEE, Shape.Linear, 4, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NotLocked.selector, 99));
        locker.transferCreator(99, ATTACKER);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NotCreator.selector, lockId, ATTACKER));
        locker.transferCreator(lockId, ATTACKER);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.InvalidCreator.selector, address(locker)));
        locker.transferCreator(lockId, address(locker));

        address next = address(0x2EC7);
        vm.prank(CREATOR);
        locker.transferCreator(lockId, next);
        assertEq(locker.pendingCreator(lockId), next);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NotPendingCreator.selector, lockId, ATTACKER));
        locker.acceptCreator(lockId);

        _buy(leg, 200_000 ether);
        locker.collectFees(lockId); // credited to the old creator
        Currency q = Currency.wrap(address(quote));
        uint256 oldCredit = locker.claimable(CREATOR, q);
        assertGt(oldCredit, 0);

        vm.prank(next);
        locker.acceptCreator(lockId);
        assertEq(locker.getLock(lockId).creator, next);
        assertEq(locker.pendingCreator(lockId), address(0));

        _buy(leg, 200_000 ether);
        locker.collectFees(lockId);
        assertEq(locker.claimable(CREATOR, q), oldCredit, "old credit stays with the old creator");
        assertGt(locker.claimable(next, q), 0, "new collections credit the new creator");
    }

    function test_unauthorized_collectOnMissingLock_andNativeFromStranger() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NotLocked.selector, 0));
        locker.collectFees(0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NotLocked.selector, 1));
        locker.collectFees(1);

        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = address(locker).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(ret), IDeepCoreBinLPLocker.UnexpectedNativeSender.selector);
    }

    /*//////////////////////////////////////////////////////////////
                               TOKENS
    //////////////////////////////////////////////////////////////*/

    function test_nativeQuote_launchIsCurrency1() public {
        Leg memory leg;
        (leg.key, leg.launchIs0) = _key(address(launch), address(0), LP_FEE, IHooks(address(0)), 0);
        assertFalse(leg.launchIs0);
        assertTrue(leg.key.currency0.isNative());
        (leg.binIds, leg.shares) = _mintShaped(leg.key, false, Shape.Linear, BINS, SUPPLY, address(this));
        uint256 lockId = _lock(leg, _defaultParams());

        vm.deal(address(this), 1_000_000 ether);
        _buy(leg, 300_000 ether);
        _assertPrincipalIntact(lockId);
        (uint256 a0,) = locker.collectFees(lockId);
        assertGt(a0, 0, "native fees");
        assertEq(address(locker).balance, a0);

        uint256 owed = locker.claimable(CREATOR, CurrencyLibrary.NATIVE);
        vm.prank(CREATOR);
        locker.claim(CurrencyLibrary.NATIVE, CREATOR);
        assertEq(CREATOR.balance, owed);
    }

    function test_pausedQuote_collectRevertsThenRecovers_claimWaits() public {
        BinPausableToken stock = new BinPausableToken();
        _fund(address(stock));
        Leg memory leg = _launch(address(launch), address(stock), LP_FEE, Shape.Linear, BINS, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 300_000 ether);

        uint256[] memory previewBefore = locker.previewCollect(lockId);
        stock.pause(true);
        vm.expectRevert();
        locker.collectFees(lockId);
        // Nothing consumed by the failed attempt.
        uint256[] memory previewAfter = locker.previewCollect(lockId);
        for (uint256 i; i < BINS; ++i) assertEq(previewAfter[i], previewBefore[i]);

        stock.pause(false);
        locker.collectFees(lockId);
        Currency s = Currency.wrap(address(stock));
        uint256 owed = locker.claimable(CREATOR, s);
        assertGt(owed, 0);

        stock.pause(true);
        vm.prank(CREATOR);
        vm.expectRevert();
        locker.claim(s, CREATOR);
        assertEq(locker.claimable(CREATOR, s), owed, "credit survives a failed claim");

        stock.pause(false);
        stock.setBlocked(CREATOR, true);
        vm.prank(CREATOR);
        locker.claim(s, address(0xFEED)); // a blocked party redirects
        assertEq(stock.balanceOf(address(0xFEED)), owed);
    }

    function test_feeOnTransferQuote_creditsWhatArrived() public {
        BinTaxToken tax = new BinTaxToken(address(vault));
        _fund(address(tax));
        Leg memory leg = _launch(address(launch), address(tax), LP_FEE, Shape.Linear, BINS, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 300_000 ether);

        uint256 before = tax.balanceOf(address(locker));
        (uint256 a0, uint256 a1) = locker.collectFees(lockId);
        uint256 credited = leg.launchIs0 ? a1 : a0;
        assertEq(tax.balanceOf(address(locker)) - before, credited, "credit == balance delta");
        Currency t = Currency.wrap(address(tax));
        assertEq(locker.totalOwed(t), tax.balanceOf(address(locker)), "solvent, no phantom credit");
        assertEq(
            locker.claimable(CREATOR, t) + locker.claimable(INTEGRATOR, t) + locker.claimable(PROTOCOL, t), credited
        );
        vm.expectRevert(IDeepCoreBinLPLocker.NothingToSkim.selector);
        locker.skim(t);
    }

    function test_reentrancy_maliciousQuoteCannotReenter() public {
        ReentrantToken evil = new ReentrantToken();
        _fund(address(evil));
        Leg memory leg = _launch(address(launch), address(evil), LP_FEE, Shape.Linear, BINS, SUPPLY);
        uint256 lockId = _lock(leg, _defaultParams());
        _buy(leg, 300_000 ether);
        Currency e = Currency.wrap(address(evil));

        bytes[4] memory payloads = [
            abi.encodeCall(IDeepCoreBinLPLocker.collectFees, (lockId)),
            abi.encodeCall(IDeepCoreBinLPLocker.claim, (e, address(evil))),
            abi.encodeCall(IDeepCoreBinLPLocker.skim, (e)),
            abi.encodeCall(IDeepCoreBinLPLocker.lock, (leg.key, leg.binIds, leg.shares, _defaultParams()))
        ];
        for (uint256 k; k < 4; ++k) {
            // Arm: re-enter when the Vault pays the locker during the harvest.
            evil.arm(address(locker), address(locker), payloads[k]);
            uint256 attemptsBefore = evil.attempts();
            try locker.collectFees(lockId) {} catch {}
            if (evil.attempts() > attemptsBefore) {
                assertFalse(evil.reentrySucceeded(), "re-entered during collect");
                assertEq(evil.lastRevert(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            }
            _buy(leg, 50_000 ether);
        }

        // Re-enter from a claim payout.
        uint256 owed = locker.claimable(CREATOR, e);
        assertGt(owed, 0);
        evil.arm(address(locker), address(locker), abi.encodeCall(IDeepCoreBinLPLocker.claim, (e, CREATOR)));
        vm.prank(CREATOR);
        locker.claim(e, address(0xABCD));
        assertFalse(evil.reentrySucceeded());
        assertEq(evil.lastRevert(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(locker.totalOwed(e), evil.balanceOf(address(locker)));
        _assertPrincipalIntact(lockId);
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    function test_gas_lockCollectClaim_10_and_64_bins() public {
        uint256[2] memory sizes = [uint256(10), uint256(64)];
        for (uint256 z; z < 2; ++z) {
            (MockERC20 l, MockERC20 q) = _pair(true);
            Leg memory leg = _launch(address(l), address(q), LP_FEE, Shape.Linear, sizes[z], SUPPLY);
            binPm.approveForAll(address(locker), true);

            uint256 g = gasleft();
            uint256 lockId = locker.lock(leg.key, leg.binIds, leg.shares, _defaultParams());
            uint256 lockGas = g - gasleft();

            // Cross every bin so every bin has a fee to harvest (worst case): buy until the pool is empty.
            _buyOut(leg);
            g = gasleft();
            locker.collectFees(lockId);
            uint256 collectGas = g - gasleft();

            vm.prank(CREATOR);
            g = gasleft();
            locker.claim(Currency.wrap(address(q)), CREATOR);
            uint256 claimGas = g - gasleft();

            console.log("bins", sizes[z]);
            console.log("  lock gas   ", lockGas);
            console.log("  collect gas", collectGas);
            console.log("  claim gas  ", claimGas);
            _assertPrincipalIntact(lockId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _buyOut(Leg memory leg) internal {
        for (uint256 step = 200_000 ether; step >= 1 ether; step /= 4) {
            while (true) {
                try swapper.swap(
                    leg.key,
                    !leg.launchIs0,
                    -int128(int256(step)),
                    BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                    ""
                ) {} catch {
                    break;
                }
            }
        }
    }

    function _one(uint24 v) internal pure returns (uint24[] memory a) {
        a = new uint24[](1);
        a[0] = v;
    }

    function _oneU(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }
}
