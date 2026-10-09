// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {IDeepCoreLPLocker, LockParams, Lock} from "../src/interfaces/IDeepCoreLPLocker.sol";

import {LockerFixture} from "./utils/LockerFixture.sol";

/// @dev A subscriber that accepts everything, so a test can attach one before transfer.
contract NoopSubscriber {
    function notifySubscribe(uint256, bytes memory) external {}
    function notifyUnsubscribe(uint256) external {}
    function notifyModifyLiquidity(uint256, int256, int256) external {}
    function notifyBurn(uint256, address, uint256, uint256, int256) external {}
}

/// @dev Hooks that register a remove-liquidity callback. Both are otherwise inert.
contract BeforeRemoveHook is BaseCLHook {
    constructor(ICLPoolManager pm) BaseCLHook(pm) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_REMOVE_LIQUIDITY;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return ICLHooks.beforeRemoveLiquidity.selector;
    }
}

contract AfterRemoveHook is BaseCLHook {
    constructor(ICLPoolManager pm) BaseCLHook(pm) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return AFTER_REMOVE_LIQUIDITY;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal pure override returns (bytes4, BalanceDelta) {
        return (ICLHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}

contract DeepCoreLPLockerTest is LockerFixture {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey key;

    function setUp() public {
        _deployCore();
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 1e30);
        tokenB.mint(address(this), 1e30);
        _approveAll(address(tokenA));
        _approveAll(address(tokenB));
        key = _initPool(address(tokenA), address(tokenB));
    }

    function _lockedPosition() internal returns (uint256 tokenId) {
        tokenId = _mintFullRange(key);
        _lock(tokenId, _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_storesImmutables() public view {
        assertEq(address(locker.positionManager()), address(posm));
        assertEq(locker.vault(), address(vault));
        assertEq(locker.protocolRecipient(), PROTOCOL);
        assertEq(locker.minProtocolBps(), MIN_PROTOCOL_BPS);
        assertEq(locker.maxProtocolBps(), MAX_PROTOCOL_BPS);
        assertEq(locker.maxIntegratorBps(), MAX_INTEGRATOR_BPS);
        assertEq(locker.lockCount(), 0);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(IDeepCoreLPLocker.ZeroAddress.selector);
        new DeepCoreLPLocker(ICLPositionManager(address(0)), PROTOCOL, 0, 0, 0);
        vm.expectRevert(IDeepCoreLPLocker.ZeroAddress.selector);
        new DeepCoreLPLocker(posm, address(0), 0, 0, 0);
    }

    function test_constructor_rejectsBadBounds() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidBpsBounds.selector, 5001, 5000, 0));
        new DeepCoreLPLocker(posm, PROTOCOL, 5001, 5000, 0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidBpsBounds.selector, 0, 10_001, 0));
        new DeepCoreLPLocker(posm, PROTOCOL, 0, 10_001, 0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidBpsBounds.selector, 0, 0, 10_001));
        new DeepCoreLPLocker(posm, PROTOCOL, 0, 0, 10_001);
    }

    function test_constructor_rejectsPositionManagerWithoutVault() public {
        // An EOA answers no `vault()`.
        try new DeepCoreLPLocker(ICLPositionManager(address(0x1234)), PROTOCOL, 0, 0, 0) returns (DeepCoreLPLocker) {
            revert("constructed against a position manager with no code");
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    function test_lock_recordsEverythingAndTakesCustody() public {
        uint256 tokenId = _mintFullRange(key);
        LockParams memory p = _defaultParams();

        vm.expectEmit(true, true, true, true, address(locker));
        emit IDeepCoreLPLocker.PositionLocked(
            tokenId, key.toId(), CREATOR, INTEGRATOR, 6_000, 2_000, 2_000, LIQUIDITY, address(this), address(this)
        );
        _lock(tokenId, p);

        assertEq(posm.ownerOf(tokenId), address(locker));
        assertTrue(locker.isLocked(tokenId));
        assertEq(locker.lockCount(), 1);
        Lock memory l = locker.getLock(tokenId);
        assertEq(l.creator, CREATOR);
        assertEq(l.integrator, INTEGRATOR);
        assertEq(l.creatorBps, 6_000);
        assertEq(l.integratorBps, 2_000);
        assertEq(l.protocolBps, 2_000);
        assertEq(l.lockedAt, block.timestamp);
        assertEq(Currency.unwrap(l.currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(l.currency1), Currency.unwrap(key.currency1));
        assertEq(PoolId.unwrap(l.poolId), PoolId.unwrap(key.toId()));
    }

    function test_lock_acceptsZeroIntegratorWithZeroAddress() public {
        uint256 tokenId = _mintFullRange(key);
        _lock(tokenId, _params(8_000, 0, 2_000));
        assertEq(locker.getLock(tokenId).integrator, address(0));
        assertEq(locker.getLock(tokenId).integratorBps, 0);
    }

    function test_lock_acceptsProtocolExactlyAtFloor() public {
        uint256 tokenId = _mintFullRange(key);
        _lock(tokenId, _params(6_000, 2_000, 2_000));
        assertEq(locker.getLock(tokenId).protocolBps, 2_000);
    }

    function test_lock_acceptsProtocolExactlyAtCap() public {
        uint256 tokenId = _mintFullRange(key);
        _lock(tokenId, _params(5_000, 0, 5_000));
        assertEq(locker.getLock(tokenId).protocolBps, 5_000);
    }

    /// @dev Integrator at its cap with protocol at its cap leaves exactly 3000 for the creator. One more
    /// creator bp pushes the parts past 10000 and must revert.
    function test_lock_integratorAtCapWithProtocolAtCap() public {
        uint256 over = _mintFullRange(key);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.BpsDoNotSumToDenominator.selector, 10_001));
        _lock(over, _params(3_001, 2_000, 5_000));

        _lock(over, _params(3_000, 2_000, 5_000));
        assertEq(locker.getLock(over).creatorBps, 3_000);
    }

    function test_lock_onlyPositionManagerMayCallReceiver() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotPositionManager.selector, ATTACKER));
        locker.onERC721Received(ATTACKER, ATTACKER, 1, abi.encode(_defaultParams()));
    }

    /// @dev The forged-receiver attack: even with a real, existing position id, a direct call is refused,
    /// so nobody can attach a record to a position they do not own.
    function test_lock_cannotAttachRecordToAnOrphanPosition() public {
        uint256 tokenId = _mintFullRange(key);
        // Plain transferFrom: no callback, no record. The position is now orphaned in the locker.
        posm.transferFrom(address(this), address(locker), tokenId);
        assertFalse(locker.isLocked(tokenId));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotPositionManager.selector, ATTACKER));
        locker.onERC721Received(ATTACKER, ATTACKER, tokenId, abi.encode(_defaultParams()));

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotLocked.selector, tokenId));
        locker.collectFees(tokenId);
    }

    function test_lock_rejectsMalformedData() public {
        uint256 tokenId = _mintFullRange(key);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidLockData.selector, 0));
        posm.safeTransferFrom(address(this), address(locker), tokenId, "");
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidLockData.selector, 0));
        posm.safeTransferFrom(address(this), address(locker), tokenId);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidLockData.selector, 192));
        posm.safeTransferFrom(address(this), address(locker), tokenId, abi.encode(_defaultParams(), uint256(1)));
        assertEq(posm.ownerOf(tokenId), address(this));
    }

    function test_lock_rejectsInvalidCreator() public {
        uint256 tokenId = _mintFullRange(key);
        LockParams memory p = _defaultParams();
        p.creator = address(0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidCreator.selector, address(0)));
        _lock(tokenId, p);
        p.creator = address(locker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidCreator.selector, address(locker)));
        _lock(tokenId, p);
    }

    function test_lock_rejectsInconsistentIntegrator() public {
        uint256 tokenId = _mintFullRange(key);
        LockParams memory p = _defaultParams();
        p.integrator = address(0); // bps 1000 but no address
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidIntegrator.selector, address(0), 2_000));
        _lock(tokenId, p);

        p = _params(8_000, 0, 2_000);
        p.integrator = INTEGRATOR; // address but no bps
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidIntegrator.selector, INTEGRATOR, 0));
        _lock(tokenId, p);

        p = _defaultParams();
        p.integrator = address(locker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidIntegrator.selector, address(locker), 2_000));
        _lock(tokenId, p);
    }

    function test_lock_rejectsProtocolBelowFloor() public {
        uint256 tokenId = _mintFullRange(key);
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLPLocker.ProtocolBpsOutOfRange.selector, 1_999, MIN_PROTOCOL_BPS, MAX_PROTOCOL_BPS)
        );
        _lock(tokenId, _params(8_001, 0, 1_999));
    }

    function test_lock_rejectsProtocolAboveCap() public {
        uint256 tokenId = _mintFullRange(key);
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLPLocker.ProtocolBpsOutOfRange.selector, 5_001, MIN_PROTOCOL_BPS, MAX_PROTOCOL_BPS)
        );
        _lock(tokenId, _params(4_999, 0, 5_001));
    }

    function test_lock_rejectsIntegratorAboveCap() public {
        uint256 tokenId = _mintFullRange(key);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.IntegratorBpsTooHigh.selector, 2_001, MAX_INTEGRATOR_BPS));
        _lock(tokenId, _params(5_999, 2_001, 2_000));
    }

    function test_lock_rejectsBpsNotSummingToDenominator() public {
        uint256 tokenId = _mintFullRange(key);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.BpsDoNotSumToDenominator.selector, 9_999));
        _lock(tokenId, _params(5_999, 2_000, 2_000));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.BpsDoNotSumToDenominator.selector, 10_001));
        _lock(tokenId, _params(6_001, 2_000, 2_000));
    }

    function test_lock_rejectsEmptyPosition() public {
        uint256 tokenId = _mintFullRange(key);
        Plan memory plan = Planner.init();
        plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(LIQUIDITY), uint128(0), uint128(0), bytes("")));
        plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, address(this)));
        posm.modifyLiquidities(plan.encode(), block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.EmptyPosition.selector, tokenId));
        _lock(tokenId, _defaultParams());
    }

    /// @dev A subscriber set by the previous owner is removed by the position manager on transfer, so the
    /// locker never inherits one.
    function test_lock_subscriberIsClearedByTransfer() public {
        uint256 tokenId = _mintFullRange(key);
        NoopSubscriber sub = new NoopSubscriber();
        posm.subscribe(tokenId, address(sub), "");
        assertEq(address(posm.subscriber(tokenId)), address(sub));
        _lock(tokenId, _defaultParams());
        assertEq(address(posm.subscriber(tokenId)), address(0));
    }

    /// @dev A hook that runs on removal runs on every collection, so it could brick or skim them forever.
    function test_lock_rejectsPoolsWhoseHookInterceptsRemoval() public {
        BaseCLHook[2] memory hooks = [BaseCLHook(new BeforeRemoveHook(poolManager)), BaseCLHook(new AfterRemoveHook(poolManager))];
        for (uint256 i; i < 2; ++i) {
            PoolKey memory hooked = key;
            hooked.hooks = IHooks(address(hooks[i]));
            hooked.parameters = bytes32(uint256(hooks[i].getHooksRegistrationBitmap())).setTickSpacing(TICK_SPACING);
            poolManager.initialize(hooked, SQRT_RATIO_1_1);
            uint256 tokenId = _mintFullRange(hooked);
            vm.expectRevert(
                abi.encodeWithSelector(IDeepCoreLPLocker.HookInterceptsRemoval.selector, tokenId, address(hooks[i]))
            );
            _lock(tokenId, _defaultParams());
            assertEq(posm.ownerOf(tokenId), address(this));
        }
    }

    function test_lock_approvalsDoNotSurviveTheTransfer() public {
        uint256 tokenId = _mintFullRange(key);
        posm.approve(ATTACKER, tokenId);
        _lock(tokenId, _defaultParams());
        assertEq(posm.getApproved(tokenId), address(0));

        vm.prank(ATTACKER);
        vm.expectRevert("WRONG_FROM");
        posm.transferFrom(address(this), ATTACKER, tokenId);
        vm.prank(ATTACKER);
        vm.expectRevert("NOT_AUTHORIZED");
        posm.transferFrom(address(locker), ATTACKER, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                COLLECT
    //////////////////////////////////////////////////////////////*/

    function test_collect_creditsTheSplitWithDustToProtocol() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 3.333333333333333337 ether);

        uint256 b0 = key.currency0.balanceOf(address(locker));
        uint256 b1 = key.currency1.balanceOf(address(locker));
        vm.prank(ATTACKER); // permissionless
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(key.currency0.balanceOf(address(locker)) - b0, a0);
        assertEq(key.currency1.balanceOf(address(locker)) - b1, a1);

        _assertSplit(key.currency0, a0);
        _assertSplit(key.currency1, a1);
        assertEq(locker.totalOwed(key.currency0), a0);
        assertEq(locker.totalOwed(key.currency1), a1);
        // The attacker who paid for the collection got nothing.
        assertEq(locker.claimable(ATTACKER, key.currency0), 0);
    }

    function _assertSplit(Currency c, uint256 amount) internal view {
        uint256 creator = amount * 6_000 / 10_000;
        uint256 integrator = amount * 2_000 / 10_000;
        assertEq(locker.claimable(CREATOR, c), creator, "creator floored");
        assertEq(locker.claimable(INTEGRATOR, c), integrator, "integrator floored");
        assertEq(locker.claimable(PROTOCOL, c), amount - creator - integrator, "protocol takes dust");
        assertGe(locker.claimable(PROTOCOL, c), amount * 2_000 / 10_000);
    }

    function test_collect_withNoFeesIsANoop() public {
        uint256 tokenId = _lockedPosition();
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        assertEq(a0 + a1, 0);
        assertEq(locker.totalOwed(key.currency0), 0);
    }

    function test_collect_neverChangesLiquidity() public {
        uint256 tokenId = _lockedPosition();
        for (uint256 i; i < 5; ++i) {
            _trade(key, 1 ether);
            locker.collectFees(tokenId);
            assertEq(posm.getPositionLiquidity(tokenId), LIQUIDITY);
            assertEq(posm.ownerOf(tokenId), address(locker));
        }
    }

    function test_collect_revertsForUnknownPosition() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotLocked.selector, 42));
        locker.collectFees(42);
    }

    /// @dev Core forbids ADDING liquidity while paused and permits removal; a zero-delta decrease is a
    /// removal, so fees stay collectable through a pool-manager pause.
    function test_collect_worksWhilePoolManagerPaused() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 1 ether);
        poolManager.pause();
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        assertGt(a0 + a1, 0);
    }

    function test_collect_isolatesLocksFromEachOther() public {
        uint256 first = _lockedPosition();
        uint256 second = _mintFullRange(key);
        address otherCreator = address(0xC2);
        LockParams memory p = _params(5_000, 0, 5_000);
        p.creator = otherCreator;
        _lock(second, p);

        _trade(key, 2 ether);
        (uint256 a0,) = locker.collectFees(first);
        (uint256 b0,) = locker.collectFees(second);
        // Identical liquidity and range, so identical fees, split differently.
        assertEq(a0, b0);
        assertEq(locker.claimable(otherCreator, key.currency0), b0 * 5_000 / 10_000);
        assertEq(locker.claimable(CREATOR, key.currency0), a0 * 6_000 / 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_claim_paysEachPartyAndZeroes() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 1 ether);
        (uint256 a0,) = locker.collectFees(tokenId);

        address[3] memory parties = [CREATOR, INTEGRATOR, PROTOCOL];
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            uint256 owed = locker.claimable(parties[i], key.currency0);
            vm.expectEmit(true, true, true, true, address(locker));
            emit IDeepCoreLPLocker.Claimed(parties[i], key.currency0, parties[i], owed);
            vm.prank(parties[i]);
            assertEq(locker.claim(key.currency0, parties[i]), owed);
            assertEq(key.currency0.balanceOf(parties[i]), owed);
            assertEq(locker.claimable(parties[i], key.currency0), 0);
            paid += owed;
        }
        assertEq(paid, a0);
        assertEq(locker.totalOwed(key.currency0), 0);
        assertEq(key.currency0.balanceOf(address(locker)), 0);
    }

    function test_claim_toAnotherAddress() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 1 ether);
        locker.collectFees(tokenId);
        uint256 owed = locker.claimable(CREATOR, key.currency1);
        vm.prank(CREATOR);
        locker.claim(key.currency1, address(0xF00D));
        assertEq(key.currency1.balanceOf(address(0xF00D)), owed);
    }

    function test_claim_rejectsNothingAndZeroRecipient() public {
        vm.prank(ATTACKER);
        vm.expectRevert(IDeepCoreLPLocker.NothingToClaim.selector);
        locker.claim(key.currency0, ATTACKER);
        vm.prank(CREATOR);
        vm.expectRevert(IDeepCoreLPLocker.ZeroAddress.selector);
        locker.claim(key.currency0, address(0));
    }

    /// @dev Unauthorized access: nobody can claim another party's balance, whatever `to` they pass.
    function test_claim_attackerCannotTakeOthersCredit() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 1 ether);
        locker.collectFees(tokenId);
        vm.prank(ATTACKER);
        vm.expectRevert(IDeepCoreLPLocker.NothingToClaim.selector);
        locker.claim(key.currency0, ATTACKER);
        assertGt(locker.claimable(CREATOR, key.currency0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            CREATOR ROTATION
    //////////////////////////////////////////////////////////////*/

    function test_rotation_twoStepMovesFutureCreditOnly() public {
        uint256 tokenId = _lockedPosition();
        address next = address(0xE11);
        _trade(key, 1 ether);
        locker.collectFees(tokenId);
        uint256 oldCredit = locker.claimable(CREATOR, key.currency0);

        vm.prank(CREATOR);
        locker.transferCreator(tokenId, next);
        assertEq(locker.pendingCreator(tokenId), next);
        assertEq(locker.getLock(tokenId).creator, CREATOR, "not moved until accepted");

        vm.prank(next);
        locker.acceptCreator(tokenId);
        assertEq(locker.getLock(tokenId).creator, next);
        assertEq(locker.pendingCreator(tokenId), address(0));

        _trade(key, 1 ether);
        locker.collectFees(tokenId);
        assertEq(locker.claimable(CREATOR, key.currency0), oldCredit, "old credit stays with old creator");
        assertGt(locker.claimable(next, key.currency0), 0);
        // Split is unchanged by rotation.
        assertEq(locker.getLock(tokenId).creatorBps, 6_000);
    }

    function test_rotation_unauthorized() public {
        uint256 tokenId = _lockedPosition();
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotCreator.selector, tokenId, ATTACKER));
        locker.transferCreator(tokenId, ATTACKER);

        vm.prank(INTEGRATOR);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotCreator.selector, tokenId, INTEGRATOR));
        locker.transferCreator(tokenId, INTEGRATOR);

        vm.prank(PROTOCOL);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotCreator.selector, tokenId, PROTOCOL));
        locker.transferCreator(tokenId, PROTOCOL);

        vm.prank(CREATOR);
        locker.transferCreator(tokenId, address(0xE11));
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotPendingCreator.selector, tokenId, ATTACKER));
        locker.acceptCreator(tokenId);

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotLocked.selector, 999));
        locker.transferCreator(999, ATTACKER);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotPendingCreator.selector, 999, address(this)));
        locker.acceptCreator(999);
    }

    function test_rotation_cancelAndRejectLocker() public {
        uint256 tokenId = _lockedPosition();
        vm.startPrank(CREATOR);
        locker.transferCreator(tokenId, address(0xE11));
        locker.transferCreator(tokenId, address(0));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.InvalidCreator.selector, address(locker)));
        locker.transferCreator(tokenId, address(locker));
        vm.stopPrank();

        vm.prank(address(0xE11));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotPendingCreator.selector, tokenId, address(0xE11)));
        locker.acceptCreator(tokenId);
        // A zero pending can never be "accepted" by address(0).
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLPLocker.NotPendingCreator.selector, tokenId, address(0)));
        locker.acceptCreator(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                  SKIM
    //////////////////////////////////////////////////////////////*/

    function test_skim_creditsOnlySurplusToProtocol() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 1 ether);
        (uint256 a0,) = locker.collectFees(tokenId);

        MockERC20(Currency.unwrap(key.currency0)).transfer(address(locker), 5 ether);
        uint256 protocolBefore = locker.claimable(PROTOCOL, key.currency0);
        vm.prank(ATTACKER);
        assertEq(locker.skim(key.currency0), 5 ether);
        assertEq(locker.claimable(PROTOCOL, key.currency0), protocolBefore + 5 ether);
        assertEq(locker.totalOwed(key.currency0), a0 + 5 ether);
        assertEq(locker.claimable(ATTACKER, key.currency0), 0);

        vm.expectRevert(IDeepCoreLPLocker.NothingToSkim.selector);
        locker.skim(key.currency0);
    }

    function test_skim_nothingWhenInsolvent() public {
        vm.expectRevert(IDeepCoreLPLocker.NothingToSkim.selector);
        locker.skim(key.currency1);
    }

    /*//////////////////////////////////////////////////////////////
                                 NATIVE
    //////////////////////////////////////////////////////////////*/

    function test_native_refusedFromAnyoneButVault() public {
        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = address(locker).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IDeepCoreLPLocker.UnexpectedNativeSender.selector, ATTACKER));
    }

    function test_native_quotePoolCollectsAndClaims() public {
        vm.deal(address(this), 100_000 ether);
        PoolKey memory nativeKey = _key(CurrencyLibrary.NATIVE, Currency.wrap(address(tokenB)));
        poolManager.initialize(nativeKey, SQRT_RATIO_1_1);
        uint256 tokenId = _mint(nativeKey, -60_000, 60_000, LIQUIDITY);
        _lock(tokenId, _defaultParams());

        _trade(nativeKey, 1 ether);
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(address(locker).balance, a0);

        uint256 owed = locker.claimable(CREATOR, CurrencyLibrary.NATIVE);
        vm.prank(CREATOR);
        locker.claim(CurrencyLibrary.NATIVE, CREATOR);
        assertEq(CREATOR.balance, owed);

        // Forced native (no call) is surplus, and only protocol can receive it.
        vm.deal(address(locker), address(locker).balance + 3 ether);
        assertEq(locker.skim(CurrencyLibrary.NATIVE), 3 ether);
    }

    /// @dev A recipient that reverts on receipt can only fail its own claim.
    function test_native_revertingRecipientBlocksOnlyItself() public {
        vm.deal(address(this), 100_000 ether);
        PoolKey memory nativeKey = _key(CurrencyLibrary.NATIVE, Currency.wrap(address(tokenB)));
        poolManager.initialize(nativeKey, SQRT_RATIO_1_1);
        uint256 tokenId = _mint(nativeKey, -60_000, 60_000, LIQUIDITY);
        LockParams memory p = _defaultParams();
        p.creator = address(new RevertingReceiver());
        _lock(tokenId, p);

        _trade(nativeKey, 1 ether);
        locker.collectFees(tokenId);

        vm.prank(p.creator);
        (bool ok,) = address(locker).call(abi.encodeCall(DeepCoreLPLocker.claim, (CurrencyLibrary.NATIVE, p.creator)));
        assertFalse(ok, "reverting recipient's claim must fail");

        uint256 owed = locker.claimable(PROTOCOL, CurrencyLibrary.NATIVE);
        vm.prank(PROTOCOL);
        locker.claim(CurrencyLibrary.NATIVE, PROTOCOL);
        assertEq(PROTOCOL.balance, owed);
        assertGt(locker.claimable(p.creator, CurrencyLibrary.NATIVE), 0, "credit survives the failed claim");
    }

    /*//////////////////////////////////////////////////////////////
                    THE NO-WITHDRAW GUARANTEE, BY ATTEMPT
    //////////////////////////////////////////////////////////////*/

    /// @dev Every route the position manager offers to move or shrink a position, tried by an attacker
    /// and by the lock's own creator. None may succeed.
    function test_noWithdraw_everyPositionManagerRouteReverts() public {
        uint256 tokenId = _lockedPosition();
        _trade(key, 1 ether);
        address[2] memory callers = [ATTACKER, CREATOR];

        for (uint256 i; i < 2; ++i) {
            vm.startPrank(callers[i]);

            vm.expectRevert("NOT_AUTHORIZED");
            posm.transferFrom(address(locker), callers[i], tokenId);

            vm.expectRevert("NOT_AUTHORIZED");
            posm.safeTransferFrom(address(locker), callers[i], tokenId);

            // Low-level calls: `allow_internal_expect_revert` lets a bare `vm.expectRevert()` be satisfied
            // by a later, unrelated revert.
            (bool ok,) = address(posm).call(abi.encodeWithSignature("approve(address,uint256)", callers[i], tokenId));
            assertFalse(ok, "approve");

            (ok,) = address(posm).call(
                abi.encodeWithSignature("subscribe(uint256,address,bytes)", tokenId, address(0x5B), bytes(""))
            );
            assertFalse(ok, "subscribe");

            Plan memory dec = Planner.init();
            dec.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(1), uint128(0), uint128(0), bytes("")));
            dec.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, callers[i]));
            vm.expectRevert(abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, callers[i]));
            posm.modifyLiquidities(dec.encode(), block.timestamp);

            // Even a ZERO decrease by a stranger is refused: fees can only be taken through the locker.
            Plan memory poke = Planner.init();
            poke.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")));
            poke.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, callers[i]));
            vm.expectRevert(abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, callers[i]));
            posm.modifyLiquidities(poke.encode(), block.timestamp);

            Plan memory burn = Planner.init();
            burn.add(Actions.CL_BURN_POSITION, abi.encode(tokenId, uint128(0), uint128(0), bytes("")));
            vm.expectRevert(abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, callers[i]));
            posm.modifyLiquidities(burn.encode(), block.timestamp);

            // Increasing would also sweep accrued fees to the caller, so it must be refused too.
            Plan memory inc = Planner.init();
            inc.add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenId, uint256(1), type(uint128).max, type(uint128).max, bytes(""))
            );
            vm.expectRevert(abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, callers[i]));
            posm.modifyLiquidities(inc.encode(), block.timestamp);

            vm.stopPrank();
        }

        // ERC-721 permit: the owner is a contract, so the position manager asks the locker for an
        // ERC-1271 answer. The locker has no `isValidSignature`, so every signature fails.
        vm.prank(ATTACKER);
        (bool permitted,) = address(posm).call(
            abi.encodeWithSignature(
                "permit(address,uint256,uint256,uint256,bytes)", ATTACKER, tokenId, block.timestamp + 1, 0, new bytes(65)
            )
        );
        assertFalse(permitted, "permit");
        vm.prank(ATTACKER);
        (permitted,) = address(posm).call(
            abi.encodeWithSignature(
                "permitForAll(address,address,bool,uint256,uint256,bytes)",
                address(locker),
                ATTACKER,
                true,
                block.timestamp + 1,
                0,
                new bytes(65)
            )
        );
        assertFalse(permitted, "permitForAll");

        assertEq(posm.ownerOf(tokenId), address(locker));
        assertEq(posm.getPositionLiquidity(tokenId), LIQUIDITY);
        assertEq(posm.getApproved(tokenId), address(0));
        assertFalse(posm.isApprovedForAll(address(locker), ATTACKER));
    }

    /*//////////////////////////////////////////////////////////////
                              GAS REFERENCE
    //////////////////////////////////////////////////////////////*/

    /// @dev Gas reference for the report. Measured around the external call only.
    function test_gas_lockCollectClaim() public {
        uint256 tokenId = _mintFullRange(key);
        bytes memory data = abi.encode(_defaultParams());
        uint256 g = gasleft();
        posm.safeTransferFrom(address(this), address(locker), tokenId, data);
        emit log_named_uint("lock (safeTransferFrom incl. onERC721Received)", g - gasleft());

        _trade(key, 1 ether);
        vm.prank(ATTACKER);
        g = gasleft();
        locker.collectFees(tokenId);
        emit log_named_uint("collectFees, first (cold claimable slots, both currencies)", g - gasleft());

        _trade(key, 1 ether);
        g = gasleft();
        locker.collectFees(tokenId);
        emit log_named_uint("collectFees, repeat (warm-nonzero claimable slots)", g - gasleft());

        vm.prank(CREATOR);
        g = gasleft();
        locker.claim(key.currency0, CREATOR);
        emit log_named_uint("claim (ERC-20)", g - gasleft());
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }
}
