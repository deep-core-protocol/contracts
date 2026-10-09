// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {DeepCorePositionLock} from "../../src/lock/DeepCorePositionLock.sol";
import {DeepCoreFeeGate} from "../../src/fees/DeepCoreFeeGate.sol";
import {LockerFixture} from "../utils/LockerFixture.sol";

contract DeepCorePositionLockTest is LockerFixture {
    using PoolIdLibrary for PoolKey;

    address constant SAFE = address(0x5AFE);
    address constant OWNER = address(0x0E);
    address constant NEW_OWNER = address(0x0F);
    address constant STRANGER = address(0xBAD2);
    uint256 constant FEE = 0.075 ether;
    uint256 constant MAX_FEE = 0.75 ether;
    uint32 constant NOTICE = 7 days;

    DeepCorePositionLock plock;
    MockERC20 tokenA;
    MockERC20 tokenB;
    PoolKey key;
    uint256 tokenId;

    function setUp() public {
        _deployCore();
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), 1e30);
        tokenB.mint(address(this), 1e30);
        _approveAll(address(tokenA));
        _approveAll(address(tokenB));
        key = _initPool(address(tokenA), address(tokenB));
        tokenId = _mintFullRange(key);
        plock = new DeepCorePositionLock(posm, SAFE, SAFE, FEE, MAX_FEE, NOTICE);
        vm.deal(address(this), 100_000 ether);
    }

    function _lockIt(uint48 unlockAt) internal {
        IERC721(address(posm)).approve(address(plock), tokenId);
        plock.lock{value: FEE}(tokenId, unlockAt, OWNER);
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    function test_LOCK_takesTheNftChargesTheFeeRefundsTheRest() public {
        IERC721(address(posm)).approve(address(plock), tokenId);
        uint256 before = address(this).balance;
        uint48 unlockAt = uint48(block.timestamp + 30 days);
        plock.lock{value: 1 ether}(tokenId, unlockAt, OWNER);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(plock));
        assertEq(before - address(this).balance, FEE, "only the fee was kept");
        assertEq(plock.protocolFeesOwed(), FEE);
        DeepCorePositionLock.PositionLock memory l = plock.getLock(tokenId);
        assertEq(l.owner, OWNER);
        assertEq(l.unlockAt, unlockAt);
        assertEq(Currency.unwrap(l.currency0), Currency.unwrap(key.currency0));
        assertTrue(plock.isLocked(tokenId));
        assertEq(plock.lockCount(), 1);
        assertEq(plock.poolLockCount(key.toId()), 1);
        assertEq(plock.poolLockIds(key.toId(), 0, 10)[0], tokenId);
    }

    function test_LOCK_refusals() public {
        IERC721(address(posm)).approve(address(plock), tokenId);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.InvalidOwner.selector, address(0)));
        plock.lock{value: FEE}(tokenId, uint48(block.timestamp + 1), address(0));
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.InvalidUnlock.selector, uint48(block.timestamp)));
        plock.lock{value: FEE}(tokenId, uint48(block.timestamp), OWNER);
        uint48 tooFar = uint48(block.timestamp + plock.MAX_LOCK_SECONDS() + 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.InvalidUnlock.selector, tooFar));
        plock.lock{value: FEE}(tokenId, tooFar, OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.InsufficientFee.selector, FEE, FEE - 1));
        plock.lock{value: FEE - 1}(tokenId, uint48(block.timestamp + 1 days), OWNER);
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotPositionOwner.selector, tokenId, STRANGER));
        plock.lock{value: FEE}(tokenId, uint48(block.timestamp + 1 days), STRANGER);
    }

    function test_LOCK_emptyPositionIsRefused() public {
        Plan memory plan = Planner.init();
        plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(LIQUIDITY), uint128(0), uint128(0), bytes("")));
        plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, address(this)));
        posm.modifyLiquidities(plan.encode(), block.timestamp);
        IERC721(address(posm)).approve(address(plock), tokenId);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.EmptyPosition.selector, tokenId));
        plock.lock{value: FEE}(tokenId, uint48(block.timestamp + 1 days), OWNER);
    }

    /*//////////////////////////////////////////////////////////////
                         THE NO-EARLY-WITHDRAW GUARANTEE
    //////////////////////////////////////////////////////////////*/

    function test_GUARANTEE_nobodyTakesLiquidityOrTheNftBeforeUnlock() public {
        _lockIt(uint48(block.timestamp + 30 days));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.StillLocked.selector, tokenId, uint48(block.timestamp + 30 days)));
        plock.withdraw(tokenId, OWNER);

        // The lock owner, a stranger and the Safe cannot decrease the position directly: the lock owns it.
        Plan memory plan = Planner.init();
        plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(1), uint128(0), uint128(0), bytes("")));
        plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, OWNER));
        bytes memory encoded = plan.encode();
        for (uint256 i; i < 3; ++i) {
            address who = [OWNER, STRANGER, SAFE][i];
            vm.prank(who);
            vm.expectRevert();
            posm.modifyLiquidities(encoded, block.timestamp);
        }
        // The Safe's rescue refuses a live lock.
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.PositionIsLocked.selector, tokenId));
        plock.rescuePosition(tokenId, SAFE);
        (,,, uint128 liquidity,,,) = posm.positions(tokenId);
        assertEq(liquidity, LIQUIDITY, "not a unit of liquidity moved");
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(plock));
    }

    function test_GUARANTEE_extendOnlyLater_onlyTheOwner() public {
        uint48 unlockAt = uint48(block.timestamp + 30 days);
        _lockIt(unlockAt);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotLockOwner.selector, tokenId, STRANGER));
        plock.extend(tokenId, unlockAt + 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotLater.selector, unlockAt, unlockAt - 1));
        plock.extend(tokenId, unlockAt - 1);
        vm.prank(OWNER);
        plock.extend(tokenId, unlockAt + 60 days);
        assertEq(plock.getLock(tokenId).unlockAt, unlockAt + 60 days);
    }

    /*//////////////////////////////////////////////////////////////
                               FEES FLOW
    //////////////////////////////////////////////////////////////*/

    function test_FEES_collectPaysTheLockOwnerDirectly_holdsNothing() public {
        _lockIt(uint48(block.timestamp + 30 days));
        _trade(key, 10 ether);
        uint256 a0 = tokenA.balanceOf(OWNER);
        uint256 b0 = tokenB.balanceOf(OWNER);
        vm.prank(STRANGER);
        plock.collectFees(tokenId);
        assertGt(tokenA.balanceOf(OWNER) - a0, 0, "fees reached the lock owner");
        assertGt(tokenB.balanceOf(OWNER) - b0, 0);
        assertEq(tokenA.balanceOf(address(plock)), 0, "nothing rests in the lock");
        assertEq(tokenB.balanceOf(address(plock)), 0);
        (,,, uint128 liquidity,,,) = posm.positions(tokenId);
        assertEq(liquidity, LIQUIDITY);
    }

    function test_FEES_nativePoolPaysNativeToTheLockOwner() public {
        PoolKey memory nk = _initPool(address(0), address(tokenA));
        uint256 id = _mint(nk, -60_000, 60_000, LIQUIDITY);
        IERC721(address(posm)).approve(address(plock), id);
        plock.lock{value: FEE}(id, uint48(block.timestamp + 1 days), OWNER);
        _trade(nk, 1 ether);
        uint256 n0 = OWNER.balance;
        plock.collectFees(id);
        assertGt(OWNER.balance - n0, 0);
        assertEq(address(plock).balance, FEE, "only the fee stays");
    }

    /*//////////////////////////////////////////////////////////////
                         WITHDRAW, ROTATE, RELOCK
    //////////////////////////////////////////////////////////////*/

    function test_WITHDRAW_afterUnlockToAnyAddress_thenRelockKeepsListsUnique() public {
        uint48 unlockAt = uint48(block.timestamp + 1 days);
        _lockIt(unlockAt);
        vm.warp(unlockAt);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotLockOwner.selector, tokenId, STRANGER));
        plock.withdraw(tokenId, STRANGER);
        vm.prank(OWNER);
        vm.expectRevert(DeepCoreFeeGate.ZeroAddress.selector);
        plock.withdraw(tokenId, address(0));
        vm.prank(OWNER);
        plock.withdraw(tokenId, address(this));
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(this));
        assertFalse(plock.isLocked(tokenId));
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotLocked.selector, tokenId));
        plock.collectFees(tokenId);

        _lockIt(uint48(block.timestamp + 2 days));
        assertEq(plock.lockCount(), 1, "the id is listed once");
        assertTrue(plock.isLocked(tokenId));
    }

    function test_ROTATE_twoStep() public {
        _lockIt(uint48(block.timestamp + 1 days));
        vm.prank(OWNER);
        plock.transferLockOwner(tokenId, NEW_OWNER);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotPendingOwner.selector, tokenId, STRANGER));
        plock.acceptLockOwner(tokenId);
        vm.prank(NEW_OWNER);
        plock.acceptLockOwner(tokenId);
        assertEq(plock.getLock(tokenId).owner, NEW_OWNER);
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePositionLock.NotLockOwner.selector, tokenId, OWNER));
        plock.withdraw(tokenId, OWNER);
        vm.prank(NEW_OWNER);
        plock.withdraw(tokenId, NEW_OWNER);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), NEW_OWNER);
    }

    /*//////////////////////////////////////////////////////////////
                         MISDIRECTION AND THE SAFE
    //////////////////////////////////////////////////////////////*/

    function test_MISDIRECTION_safeTransferRevertsPlainTransferIsRescuable() public {
        vm.expectRevert();
        IERC721(address(posm)).safeTransferFrom(address(this), address(plock), tokenId);
        IERC721(address(posm)).transferFrom(address(this), address(plock), tokenId);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        plock.rescuePosition(tokenId, STRANGER);
        vm.prank(SAFE);
        plock.rescuePosition(tokenId, address(this));
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(this));

        tokenA.transfer(address(plock), 5);
        vm.prank(SAFE);
        plock.rescueERC20(address(tokenA), OWNER);
        assertEq(tokenA.balanceOf(OWNER), 5);
    }

    function test_FEEGATE_flushPaysTheRecipient_renounceReverts() public {
        _lockIt(uint48(block.timestamp + 1 days));
        vm.deal(address(plock), address(plock).balance + 7); // forced in
        vm.prank(STRANGER);
        assertEq(plock.flushProtocolFees(), FEE + 7);
        assertEq(SAFE.balance, FEE + 7);
        vm.expectRevert(DeepCoreFeeGate.NothingToFlush.selector);
        plock.flushProtocolFees();
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreFeeGate.RenounceDisabled.selector);
        plock.renounceOwnership();
    }

    function test_FEEGATE_setFeeNoticeCancel() public {
        vm.startPrank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.FeeAboveCap.selector, MAX_FEE + 1, MAX_FEE));
        plock.setFee(MAX_FEE + 1);
        plock.setFee(0.05 ether);
        assertEq(plock.feeWei(), 0.05 ether);
        plock.setFee(0.1 ether);
        assertEq(plock.feeWei(), 0.05 ether);
        (uint256 p, uint64 at) = plock.pendingFee();
        assertEq(p, 0.1 ether);
        assertEq(at, block.timestamp + NOTICE);
        plock.cancelPendingFee();
        vm.expectRevert(DeepCoreFeeGate.NoPendingFee.selector);
        plock.cancelPendingFee();
        plock.setFee(0.1 ether);
        vm.warp(block.timestamp + NOTICE);
        assertEq(plock.feeWei(), 0.1 ether);
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        plock.setFee(0);
    }
}
