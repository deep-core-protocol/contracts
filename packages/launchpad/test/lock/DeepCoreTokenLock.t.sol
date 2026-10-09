// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreTokenLock} from "../../src/lock/DeepCoreTokenLock.sol";
import {DeepCoreFeeGate} from "../../src/fees/DeepCoreFeeGate.sol";
import {FeeOnTransferToken} from "../utils/LockerFixture.sol";

contract DeepCoreTokenLockTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant BEN = address(0xBE4);
    address constant BEN2 = address(0xBE5);
    address constant STRANGER = address(0xBAD);
    uint256 constant FEE = 0.075 ether;
    Currency constant NATIVE = Currency.wrap(address(0));

    DeepCoreTokenLock tl;
    MockERC20 token;
    Currency tok;

    function setUp() public {
        tl = new DeepCoreTokenLock(SAFE, SAFE, FEE, 0.75 ether, 7 days);
        token = new MockERC20("T", "T", 18);
        tok = Currency.wrap(address(token));
        token.mint(address(this), 1e30);
        token.approve(address(tl), type(uint256).max);
        vm.deal(address(this), 1_000 ether);
        vm.warp(1_800_000_000);
    }

    receive() external payable {}

    function _t(uint256 dt) internal view returns (uint48) {
        return uint48(block.timestamp + dt);
    }

    function test_LOCK_timeLockPaysEverythingAtEndAndNothingBefore() public {
        uint256 id = tl.lock{value: FEE}(tok, 1_000 ether, BEN, _t(30 days), _t(30 days), _t(30 days));
        assertEq(tl.totalHeld(tok), 1_000 ether);
        assertEq(tl.claimable(id), 0);
        vm.prank(BEN);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NothingToClaim.selector, id));
        tl.claim(id, BEN);
        vm.warp(block.timestamp + 30 days);
        vm.prank(BEN);
        assertEq(tl.claim(id, BEN2), 1_000 ether);
        assertEq(token.balanceOf(BEN2), 1_000 ether);
        assertEq(tl.totalHeld(tok), 0);
    }

    function test_VEST_cliffThenLinear() public {
        uint48 start = _t(0);
        uint256 id = tl.lock{value: FEE}(tok, 1_200 ether, BEN, start, _t(90 days), _t(360 days));
        vm.warp(start + 89 days);
        assertEq(tl.claimable(id), 0, "nothing before the cliff");
        vm.warp(start + 90 days);
        assertEq(tl.claimable(id), 300 ether, "the cliff releases a quarter at once");
        vm.prank(BEN);
        tl.claim(id, BEN);
        vm.warp(start + 180 days);
        assertEq(tl.claimable(id), 300 ether);
        vm.warp(start + 400 days);
        assertEq(tl.claimable(id), 900 ether);
        vm.prank(BEN);
        tl.claim(id, BEN);
        assertEq(token.balanceOf(BEN), 1_200 ether);
    }

    function test_LOCK_refusals() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.InvalidBeneficiary.selector, address(0)));
        tl.lock{value: FEE}(tok, 1, address(0), _t(1), _t(1), _t(1));
        vm.expectRevert(DeepCoreTokenLock.ZeroAmount.selector);
        tl.lock{value: FEE}(tok, 0, BEN, _t(1), _t(1), _t(1));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.InvalidSchedule.selector, _t(2), _t(1), _t(3)));
        tl.lock{value: FEE}(tok, 1, BEN, _t(2), _t(1), _t(3));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.InvalidSchedule.selector, _t(0), _t(0), _t(0)));
        tl.lock{value: FEE}(tok, 1, BEN, _t(0), _t(0), _t(0));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.InsufficientFee.selector, FEE, 0));
        tl.lock(tok, 1, BEN, _t(1), _t(1), _t(1));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NoSuchLock.selector, 7));
        tl.claimable(7);
    }

    function test_NATIVE_lockedNativeIsNeverFlushed() public {
        uint256 before = address(this).balance;
        uint256 id = tl.lock{value: 5 ether + FEE + 1 ether}(NATIVE, 5 ether, BEN, _t(10), _t(10), _t(10));
        assertEq(before - address(this).balance, 5 ether + FEE, "surplus refunded");
        vm.deal(address(tl), address(tl).balance + 3); // forced in
        vm.prank(STRANGER);
        assertEq(tl.flushProtocolFees(), FEE + 3, "only fee + forced native leave");
        assertEq(address(tl).balance, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NativeValueMismatch.selector, 5 ether, 1 ether));
        tl.lock{value: 1 ether}(NATIVE, 5 ether, BEN, _t(10), _t(10), _t(10));
        vm.warp(block.timestamp + 10);
        vm.prank(BEN);
        tl.claim(id, BEN);
        assertEq(BEN.balance, 5 ether);
    }

    function test_FOT_locksWhatArrived() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(address(0xdead));
        fot.mint(address(this), 1_000 ether);
        fot.approve(address(tl), type(uint256).max);
        // transferFrom in solmate does not take the fee; transfer does. Credit is the balance delta either way.
        uint256 id = tl.lock{value: FEE}(Currency.wrap(address(fot)), 100 ether, BEN, _t(1), _t(1), _t(1));
        assertEq(tl.getLock(id).amount, fot.balanceOf(address(tl)));
    }

    function test_BENEFICIARY_rotatesTwoStep() public {
        uint256 id = tl.lock{value: FEE}(tok, 10 ether, BEN, _t(1), _t(1), _t(1));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NotBeneficiary.selector, id, STRANGER));
        tl.transferBeneficiary(id, STRANGER);
        vm.prank(BEN);
        tl.transferBeneficiary(id, BEN2);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NotPendingBeneficiary.selector, id, STRANGER));
        tl.acceptBeneficiary(id);
        vm.prank(BEN2);
        tl.acceptBeneficiary(id);
        vm.warp(block.timestamp + 1);
        vm.prank(BEN);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NotBeneficiary.selector, id, BEN));
        tl.claim(id, BEN);
        vm.prank(BEN2);
        tl.claim(id, BEN2);
        assertEq(token.balanceOf(BEN2), 10 ether);
        assertEq(tl.beneficiaryLockIds(BEN2, 0, 5)[0], id);
    }

    function test_RESCUE_onlySurplusNeverALock() public {
        tl.lock{value: FEE}(tok, 10 ether, BEN, _t(1), _t(1), _t(1));
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NothingToRescue.selector, tok));
        tl.rescueSurplus(tok, SAFE);
        token.transfer(address(tl), 3 ether);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        tl.rescueSurplus(tok, STRANGER);
        vm.prank(SAFE);
        assertEq(tl.rescueSurplus(tok, SAFE), 3 ether);
        assertEq(token.balanceOf(address(tl)), 10 ether, "the lock is intact");
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NothingToRescue.selector, NATIVE));
        tl.rescueSurplus(NATIVE, SAFE);
    }

    /// @dev Random schedules and claim times: never more than the amount, never more than vested, all of it by end.
    function testFuzz_VEST_boundedAndComplete(uint96 amount, uint32 toCliff, uint32 toEnd, uint32[4] memory claimsAt) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        toCliff = uint32(bound(toCliff, 0, 3_650 days));
        toEnd = uint32(bound(toEnd, uint256(toCliff) + 1, 3_650 days + 1));
        uint48 start = _t(0);
        token.mint(address(this), amount);
        uint256 id = tl.lock{value: FEE}(tok, amount, BEN, start, start + toCliff, start + toEnd);
        uint256 got;
        uint256 at = start;
        for (uint256 i; i < 4; ++i) {
            // Time only moves forward on a chain: each claim is at or after the previous one.
            at += bound(claimsAt[i], 0, uint256(toEnd) / 2 + 1);
            vm.warp(at);
            uint256 c = tl.claimable(id);
            assertLe(got + c, tl.vestedAt(id, block.timestamp));
            if (c != 0) {
                vm.prank(BEN);
                got += tl.claim(id, BEN);
            }
        }
        if (at < start + toEnd) vm.warp(start + toEnd);
        uint256 rest = tl.claimable(id);
        if (rest != 0) {
            vm.prank(BEN);
            got += tl.claim(id, BEN);
        }
        assertEq(got, amount, "everything vests by end");
        assertEq(tl.totalHeld(tok), 0);
    }
}
