// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {KitV2Fixture} from "../kitv2/KitV2Fixture.sol";
import {DeepCorePad} from "../../src/pad/DeepCorePad.sol";
import {IDeepCorePad} from "../../src/pad/IDeepCorePad.sol";
import {DeepCorePadFactory} from "../../src/pad/DeepCorePadFactory.sol";
import {ILaunchpadKitV2, TenantConfig} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";
import {BinShape} from "../../src/libraries/BinLaunchShapes.sol";

/// @dev Forces native into a contract that has no receive: the only way value gets there besides createPad.
contract Forcer {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev A recipient that refuses native: what a flush into a broken Safe looks like.
contract Refuser {
    receive() external payable {
        revert("no");
    }
}

/// @dev A creator contract that re-enters the padFactory from its refund.
contract Reenterer {
    uint256 internal _saltNonce;

    /// @dev A fresh user salt per create: one creator may run several pads on one chain, each at its own salt.
    function _salt() internal returns (bytes32) {
        return keccak256(abi.encode("pad-test-salt", ++_saltNonce));
    }

    DeepCorePadFactory internal immutable factory;
    bytes internal reentry;

    constructor(DeepCorePadFactory f) {
        factory = f;
    }

    function create(bytes memory reentry_, string memory name_, TenantConfig memory c) external payable returns (address) {
        reentry = reentry_;
        address[] memory none;
        return factory.createPad{value: msg.value}(_salt(), name_, "", c, none);
    }

    receive() external payable {
        if (reentry.length != 0) {
            bytes memory call = reentry;
            reentry = "";
            (bool ok, bytes memory ret) = address(factory).call(call);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// @notice The site fee on `DeepCorePadFactory`: the kit's launch-fee mechanism, copied. Every function at least
/// twice (happy path and refusal), the funds path, and what the owner can and cannot do.
contract DeepCorePadFactoryFeeTest is KitV2Fixture {
    uint256 internal _saltNonce;

    /// @dev A fresh user salt per create: one creator may run several pads on one chain, each at its own salt.
    function _salt() internal returns (bytes32) {
        return keccak256(abi.encode("pad-test-salt", ++_saltNonce));
    }

    address internal constant PAD_OWNER = address(0x9AD0);
    address internal constant PAD_WALLET = address(0x9A11);
    address internal constant STRANGER = address(0x57A1);

    uint256 internal constant FEE = 0.003 ether;
    uint256 internal constant CAP = 0.03 ether;
    uint32 internal constant PAD_NOTICE = 7 days;

    DeepCorePadFactory internal padFactory;
    address[] internal noQuotes;

    function setUp() public {
        _deployAll();
        padFactory = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, FEE, CAP, PAD_NOTICE);
        vm.deal(PAD_OWNER, 100 ether);
        vm.deal(STRANGER, 100 ether);
        vm.deal(safe, 0);
    }

    function _config() internal pure returns (TenantConfig memory c) {
        c.integrator = PAD_WALLET;
        c.integratorBps = 500;
        c.integratorLaunchFeeWei = 0.001 ether;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch)) | uint8(1 << uint8(Preset.Custom));
        c.allowedBinShapes = uint8(1 << uint8(BinShape.Linear));
        c.active = true;
    }

    function _create(address who, uint256 value) internal returns (address pad) {
        vm.prank(who);
        pad = padFactory.createPad{value: value}(_salt(), "Pad", "", _config(), noQuotes);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_CTOR_immutablesOwnerAndBirthEvent() public {
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PadFeeChanged(0, FEE);
        DeepCorePadFactory f = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, FEE, CAP, PAD_NOTICE);
        assertEq(f.owner(), safe);
        assertEq(f.pendingOwner(), address(0));
        assertEq(f.protocolFeeRecipient(), safe);
        assertEq(f.padFeeWei(), FEE);
        assertEq(f.maxPadFeeWei(), CAP);
        assertEq(f.padFeeNoticeSeconds(), PAD_NOTICE);
        assertEq(f.protocolFeesOwed(), 0);
        (uint256 pw, uint64 pa) = f.pendingPadFee();
        assertEq(pw, 0);
        assertEq(pa, 0);
        assertEq(f.MIN_FEE_NOTICE_SECONDS(), kit.MIN_FEE_NOTICE_SECONDS(), "same bounds as the kit");
        assertEq(f.MAX_FEE_NOTICE_SECONDS(), kit.MAX_FEE_NOTICE_SECONDS());
    }

    function test_CTOR_refusals() public {
        ILaunchpadKitV2 k = ILaunchpadKitV2(address(kit));
        vm.expectRevert(DeepCorePadFactory.ZeroAddress.selector);
        new DeepCorePadFactory(k, safe, address(0), FEE, CAP, PAD_NOTICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DeepCorePadFactory(k, address(0), safe, FEE, CAP, PAD_NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InvalidNotice.selector, uint32(1 days - 1)));
        new DeepCorePadFactory(k, safe, safe, FEE, CAP, 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InvalidNotice.selector, uint32(30 days + 1)));
        new DeepCorePadFactory(k, safe, safe, FEE, CAP, 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.PadFeeAboveCap.selector, CAP + 1, CAP));
        new DeepCorePadFactory(k, safe, safe, CAP + 1, CAP, PAD_NOTICE);
        // Zero initial fee and both notice bounds are fine.
        DeepCorePadFactory free = new DeepCorePadFactory(k, safe, safe, 0, CAP, 1 days);
        assertEq(free.padFeeWei(), 0);
        new DeepCorePadFactory(k, safe, safe, CAP, CAP, 30 days);
    }

    /*//////////////////////////////////////////////////////////////
                           CREATE: PAY THE FEE
    //////////////////////////////////////////////////////////////*/

    function test_CREATE_underpaidIsRefused() public {
        vm.prank(PAD_OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InsufficientPadFee.selector, FEE, FEE - 1));
        padFactory.createPad{value: FEE - 1}(_salt(), "Pad", "", _config(), noQuotes);
        vm.prank(PAD_OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InsufficientPadFee.selector, FEE, 0));
        padFactory.createPad(_salt(), "Pad", "", _config(), noQuotes);
        assertEq(padFactory.padCount(), 0);
        assertEq(padFactory.protocolFeesOwed(), 0);
        assertEq(address(padFactory).balance, 0);
    }

    function test_CREATE_exactFeeIsCreditedNotPushed() public {
        uint256 before = PAD_OWNER.balance;
        vm.expectEmit(false, true, false, true);
        emit DeepCorePadFactory.PadFeePaid(address(0), PAD_OWNER, FEE);
        address pad = _create(PAD_OWNER, FEE);
        assertEq(DeepCorePad(pad).owner(), PAD_OWNER);
        assertEq(PAD_OWNER.balance, before - FEE);
        assertEq(padFactory.protocolFeesOwed(), FEE, "credited");
        assertEq(address(padFactory).balance, FEE, "held until flushed");
        assertEq(safe.balance, 0, "never pushed inside createPad");
        assertEq(pad.balance, 0, "the pad holds nothing");
    }

    function test_CREATE_overpaidIsRefundedInTheSameCall() public {
        uint256 before = PAD_OWNER.balance;
        _create(PAD_OWNER, FEE + 1 ether);
        assertEq(PAD_OWNER.balance, before - FEE, "surplus came back");
        assertEq(padFactory.protocolFeesOwed(), FEE);
        assertEq(address(padFactory).balance, FEE);
    }

    function test_CREATE_zeroFeeFactoryCreditsNothingAndEmitsNoFeeEvent() public {
        DeepCorePadFactory free = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, 0, CAP, PAD_NOTICE);
        vm.recordLogs();
        vm.prank(PAD_OWNER);
        free.createPad(_salt(), "Free", "", _config(), noQuotes);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != DeepCorePadFactory.PadFeePaid.selector, "no PadFeePaid at fee 0");
        }
        assertEq(free.protocolFeesOwed(), 0);
        // Overpaying a free padFactory is refunded too.
        uint256 before = PAD_OWNER.balance;
        vm.prank(PAD_OWNER);
        free.createPad{value: 1 ether}(_salt(), "Free2", "", _config(), noQuotes);
        assertEq(PAD_OWNER.balance, before);
    }

    function test_CREATE_reenteringFromTheRefundRevertsTheWholeCreate() public {
        Reenterer r = new Reenterer(padFactory);
        vm.deal(address(r), 1 ether);
        bytes memory again = abi.encodeCall(DeepCorePadFactory.flushProtocolFees, ());
        vm.expectRevert(
            abi.encodeWithSelector(DeepCorePadFactory.NativeTransferFailed.selector, address(r), 1)
        );
        r.create{value: FEE + 1}(again, "Re", _config());
        assertEq(padFactory.padCount(), 0, "nothing half-done");
        assertEq(padFactory.protocolFeesOwed(), 0);
        // The same contract with no re-entry, exact fee, is a plain creator.
        r.create{value: FEE}("", "Plain", _config());
        assertEq(padFactory.padCount(), 1);
    }

    function testFuzz_CREATE_valueAccounting(uint256 feeWei, uint256 sent) public {
        feeWei = bound(feeWei, 0, CAP);
        sent = bound(sent, 0, 50 ether);
        DeepCorePadFactory f = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, feeWei, CAP, PAD_NOTICE);
        uint256 before = PAD_OWNER.balance;
        vm.prank(PAD_OWNER);
        if (sent < feeWei) {
            vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InsufficientPadFee.selector, feeWei, sent));
            f.createPad{value: sent}(_salt(), "F", "", _config(), noQuotes);
            return;
        }
        f.createPad{value: sent}(_salt(), "F", "", _config(), noQuotes);
        assertEq(PAD_OWNER.balance, before - feeWei, "paid exactly the fee");
        assertEq(f.protocolFeesOwed(), feeWei);
        assertEq(address(f).balance, feeWei);
    }

    /*//////////////////////////////////////////////////////////////
                                 FLUSH
    //////////////////////////////////////////////////////////////*/

    function test_FLUSH_isPermissionlessAndPaysOnlyTheSafe() public {
        _create(PAD_OWNER, FEE);
        _create(STRANGER, FEE);
        assertEq(padFactory.protocolFeesOwed(), 2 * FEE);
        vm.prank(STRANGER);
        vm.expectEmit(true, false, false, true);
        emit DeepCorePadFactory.ProtocolFeesFlushed(safe, 2 * FEE, 2 * FEE);
        uint256 amount = padFactory.flushProtocolFees();
        assertEq(amount, 2 * FEE);
        assertEq(safe.balance, 2 * FEE, "the Safe, not the caller");
        assertEq(STRANGER.balance, 100 ether - FEE, "the caller got nothing");
        assertEq(padFactory.protocolFeesOwed(), 0);
        assertEq(address(padFactory).balance, 0);
        // A second flush with nothing to move reverts: the keeper reads first.
        vm.expectRevert(DeepCorePadFactory.NothingToFlush.selector);
        padFactory.flushProtocolFees();
    }

    function test_FLUSH_sweepsForcedNativeTooSoNothingIsEverStuck() public {
        new Forcer{value: 0.5 ether}(payable(address(padFactory)));
        assertEq(address(padFactory).balance, 0.5 ether);
        assertEq(padFactory.protocolFeesOwed(), 0, "nobody credited it");
        _create(PAD_OWNER, FEE);
        vm.expectEmit(true, false, false, true);
        emit DeepCorePadFactory.ProtocolFeesFlushed(safe, 0.5 ether + FEE, FEE);
        assertEq(padFactory.flushProtocolFees(), 0.5 ether + FEE);
        assertEq(address(padFactory).balance, 0);
        assertEq(safe.balance, 0.5 ether + FEE);
    }

    function test_FLUSH_aRecipientThatRefusesRevertsAndKeepsTheCredit() public {
        Refuser bad = new Refuser();
        DeepCorePadFactory f = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, address(bad), FEE, CAP, PAD_NOTICE);
        vm.prank(PAD_OWNER);
        f.createPad{value: FEE}(_salt(), "P", "", _config(), noQuotes);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.NativeTransferFailed.selector, address(bad), FEE));
        f.flushProtocolFees();
        assertEq(f.protocolFeesOwed(), FEE, "credit intact; the create itself was never blocked by the recipient");
    }

    /*//////////////////////////////////////////////////////////////
                          SET FEE: DECREASE / INCREASE
    //////////////////////////////////////////////////////////////*/

    function test_FEE_decreaseAppliesImmediately() public {
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PadFeeChanged(FEE, FEE / 2);
        padFactory.setPadFee(FEE / 2);
        assertEq(padFactory.padFeeWei(), FEE / 2);
        vm.prank(PAD_OWNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InsufficientPadFee.selector, FEE / 2, FEE / 2 - 1));
        padFactory.createPad{value: FEE / 2 - 1}(_salt(), "P", "", _config(), noQuotes);
        _create(PAD_OWNER, FEE / 2);
        assertEq(padFactory.protocolFeesOwed(), FEE / 2);
        // To zero is a decrease too: the fee can be switched off at once.
        vm.prank(safe);
        padFactory.setPadFee(0);
        assertEq(padFactory.padFeeWei(), 0);
        _create(STRANGER, 0);
    }

    function test_FEE_increaseIsScheduledThenMaterialisesByItself() public {
        uint64 t0 = uint64(block.timestamp);
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PadFeeIncreaseScheduled(FEE, 2 * FEE, t0 + PAD_NOTICE);
        padFactory.setPadFee(2 * FEE);
        assertEq(padFactory.padFeeWei(), FEE, "not yet");
        (uint256 pw, uint64 pa) = padFactory.pendingPadFee();
        assertEq(pw, 2 * FEE);
        assertEq(pa, t0 + PAD_NOTICE);

        // One second before: the old fee, and the old fee only (a create at the new value is refunded).
        vm.warp(t0 + PAD_NOTICE - 1);
        uint256 before = PAD_OWNER.balance;
        _create(PAD_OWNER, 2 * FEE);
        assertEq(PAD_OWNER.balance, before - FEE, "paid the fee in force, refunded the rest");
        assertEq(padFactory.protocolFeesOwed(), FEE);

        // At effectiveAt: the new fee, with no transaction from anyone.
        vm.warp(t0 + PAD_NOTICE);
        assertEq(padFactory.padFeeWei(), 2 * FEE);
        (pw, pa) = padFactory.pendingPadFee();
        assertEq(pw, 0, "no longer pending");
        assertEq(pa, 0);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InsufficientPadFee.selector, 2 * FEE, FEE));
        padFactory.createPad{value: FEE}(_salt(), "P", "", _config(), noQuotes);
        _create(STRANGER, 2 * FEE);
        assertEq(padFactory.protocolFeesOwed(), 3 * FEE);

        // The next owner call materialises it into storage with the same event a decrease emits, before
        // doing its own work (here: a no-op "set to the same value").
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PadFeeChanged(FEE, 2 * FEE);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PadFeeChanged(2 * FEE, 2 * FEE);
        padFactory.setPadFee(2 * FEE);
        assertEq(padFactory.padFeeWei(), 2 * FEE);
        vm.prank(safe);
        vm.expectRevert(DeepCorePadFactory.NoPendingPadFee.selector);
        padFactory.cancelPendingPadFee();
    }

    function test_FEE_aNewIncreaseRestartsTheNoticeAndADecreaseCancelsIt() public {
        uint64 t0 = uint64(block.timestamp);
        vm.prank(safe);
        padFactory.setPadFee(2 * FEE);
        vm.warp(t0 + PAD_NOTICE - 10);
        // A second announcement replaces the first and waits the full notice again.
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        // vm.getBlockTimestamp, not block.timestamp: via-IR treats TIMESTAMP as invariant within one call and
        // would reuse the pre-warp read.
        emit DeepCorePadFactory.PadFeeIncreaseScheduled(FEE, 3 * FEE, uint64(vm.getBlockTimestamp()) + PAD_NOTICE);
        padFactory.setPadFee(3 * FEE);
        vm.warp(t0 + PAD_NOTICE);
        assertEq(padFactory.padFeeWei(), FEE, "the first announcement no longer lands");
        (uint256 pw, uint64 pa) = padFactory.pendingPadFee();
        assertEq(pw, 3 * FEE);
        assertEq(pa, t0 + PAD_NOTICE - 10 + PAD_NOTICE);
        // A decrease (or equal) clears the pending increase and applies at once.
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PendingPadFeeCancelled(3 * FEE, pa);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PadFeeChanged(FEE, FEE);
        padFactory.setPadFee(FEE);
        (pw, pa) = padFactory.pendingPadFee();
        assertEq(pw, 0);
        assertEq(pa, 0);
        vm.warp(t0 + 3 * PAD_NOTICE);
        assertEq(padFactory.padFeeWei(), FEE, "nothing lands later");
    }

    function test_FEE_cancelPendingWorksOnceAndOnlyWhilePending() public {
        vm.prank(safe);
        vm.expectRevert(DeepCorePadFactory.NoPendingPadFee.selector);
        padFactory.cancelPendingPadFee();

        uint64 t0 = uint64(block.timestamp);
        vm.prank(safe);
        padFactory.setPadFee(CAP);
        vm.prank(safe);
        vm.expectEmit(false, false, false, true);
        emit DeepCorePadFactory.PendingPadFeeCancelled(CAP, t0 + PAD_NOTICE);
        padFactory.cancelPendingPadFee();
        vm.warp(t0 + PAD_NOTICE);
        assertEq(padFactory.padFeeWei(), FEE, "cancelled increase never lands");

        // An increase that already took effect is the fee; there is nothing to cancel.
        vm.prank(safe);
        padFactory.setPadFee(CAP);
        vm.warp(vm.getBlockTimestamp() + PAD_NOTICE);
        assertEq(padFactory.padFeeWei(), CAP);
        vm.prank(safe);
        vm.expectRevert(DeepCorePadFactory.NoPendingPadFee.selector);
        padFactory.cancelPendingPadFee();
        assertEq(padFactory.padFeeWei(), CAP, "and it stays the fee");
    }

    function test_FEE_capIsImmutableAndEnforced() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.PadFeeAboveCap.selector, CAP + 1, CAP));
        padFactory.setPadFee(CAP + 1);
        vm.prank(safe);
        padFactory.setPadFee(CAP); // exactly the cap is allowed
        (uint256 pw,) = padFactory.pendingPadFee();
        assertEq(pw, CAP);
    }

    function testFuzz_FEE_neverAboveCapNeverEarly(uint256 newFee, uint256 dt) public {
        newFee = bound(newFee, 0, CAP);
        dt = bound(dt, 0, 2 * PAD_NOTICE);
        uint64 t0 = uint64(block.timestamp);
        vm.prank(safe);
        padFactory.setPadFee(newFee);
        vm.warp(t0 + dt);
        uint256 inForce = padFactory.padFeeWei();
        assertLe(inForce, CAP);
        if (newFee <= FEE) assertEq(inForce, newFee, "decrease: immediate");
        else if (dt < PAD_NOTICE) assertEq(inForce, FEE, "increase: not before the notice");
        else assertEq(inForce, newFee, "increase: after the notice");
    }

    /*//////////////////////////////////////////////////////////////
                        THE OWNER: WHAT IT CANNOT DO
    //////////////////////////////////////////////////////////////*/

    function test_OWNER_strangerRefusedOnEveryOwnerFunction() public {
        MockERC20 stray = new MockERC20("S", "S", 18);
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        padFactory.setPadFee(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        padFactory.cancelPendingPadFee();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        padFactory.rescueERC20(address(stray), STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        padFactory.transferOwnership(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        padFactory.acceptOwnership();
        vm.stopPrank();
    }

    function test_OWNER_renounceRevertsForEveryone() public {
        vm.prank(safe);
        vm.expectRevert(DeepCorePadFactory.RenounceDisabled.selector);
        padFactory.renounceOwnership();
        vm.prank(STRANGER);
        vm.expectRevert(DeepCorePadFactory.RenounceDisabled.selector);
        padFactory.renounceOwnership();
        assertEq(padFactory.owner(), safe);
    }

    function test_OWNER_twoStepTransfer() public {
        vm.prank(safe);
        padFactory.transferOwnership(STRANGER);
        assertEq(padFactory.owner(), safe, "not yet");
        assertEq(padFactory.pendingOwner(), STRANGER);
        vm.prank(PAD_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, PAD_OWNER));
        padFactory.acceptOwnership();
        vm.prank(STRANGER);
        padFactory.acceptOwnership();
        assertEq(padFactory.owner(), STRANGER);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        padFactory.setPadFee(0);
    }

    /// @notice The reason the old padFactory had no owner was "an owner could only gate who may run a
    /// launchpad". This owner cannot: no allowlist, no pause, and it pays the same fee.
    function test_OWNER_cannotGateWhoCreatesAndPaysLikeAnyone() public {
        vm.deal(safe, 1 ether);
        // The owner pays the fee - there is no owner branch in createPad.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.InsufficientPadFee.selector, FEE, 0));
        padFactory.createPad(_salt(), "Own", "", _config(), noQuotes);
        _create(safe, FEE);
        // The worst the owner can do to a creator is the cap, after the notice - and a stranger still creates.
        vm.prank(safe);
        padFactory.setPadFee(CAP);
        vm.warp(vm.getBlockTimestamp() + PAD_NOTICE);
        _create(STRANGER, CAP);
        assertEq(padFactory.padCount(), 2);
    }

    function test_OWNER_cannotTouchAPadOrItsTerms() public {
        DeepCorePad pad = DeepCorePad(_create(PAD_OWNER, FEE));
        vm.startPrank(safe);
        vm.expectRevert(IDeepCorePad.NotOwner.selector);
        pad.configure(_config());
        vm.expectRevert(IDeepCorePad.NotOwner.selector);
        pad.setMetadata("x", "");
        vm.expectRevert(IDeepCorePad.NotOwner.selector);
        pad.setQuote(address(quote), true);
        vm.expectRevert(IDeepCorePad.NotOwner.selector);
        pad.transferOwnership(safe);
        vm.expectRevert(IDeepCorePad.NotOwner.selector);
        pad.rescueNative(safe);
        vm.expectRevert(IDeepCorePad.NotOwner.selector);
        pad.initialize(safe, "x", "", _config(), noQuotes);
        // The padFactory owner writing the kit writes ITS OWN tenant slot, never the pad's.
        kit.setTenantConfig(_config());
        vm.stopPrank();
        assertEq(kit.tenantConfig(address(pad)).integratorBps, 500);
        assertEq(pad.owner(), PAD_OWNER);
        // And the padFactory itself cannot re-initialize the pad.
        vm.prank(address(padFactory));
        vm.expectRevert(IDeepCorePad.AlreadyInitialized.selector);
        pad.initialize(safe, "x", "", _config(), noQuotes);
    }

    /*//////////////////////////////////////////////////////////////
                             FUNDS PATH
    //////////////////////////////////////////////////////////////*/

    function test_FUNDS_noReceiveNoFallback() public {
        vm.prank(PAD_OWNER);
        (bool ok,) = address(padFactory).call{value: 1}("");
        assertFalse(ok, "no receive");
        vm.prank(PAD_OWNER);
        (ok,) = address(padFactory).call{value: 1}(hex"deadbeef");
        assertFalse(ok, "no fallback");
        vm.prank(PAD_OWNER);
        (ok,) = address(padFactory).call("");
        assertFalse(ok, "no fallback even without value");
        assertEq(address(padFactory).balance, 0);
    }

    function test_FUNDS_rescueERC20MovesOnlyMisdirectedTokens() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.NothingToRescue.selector, address(stray)));
        padFactory.rescueERC20(address(stray), safe);
        stray.mint(address(padFactory), 5 ether);
        vm.prank(safe);
        vm.expectRevert(DeepCorePadFactory.ZeroAddress.selector);
        padFactory.rescueERC20(address(stray), address(0));
        vm.prank(safe);
        vm.expectEmit(true, true, false, true);
        emit DeepCorePadFactory.ERC20Rescued(address(stray), PAD_WALLET, 5 ether);
        padFactory.rescueERC20(address(stray), PAD_WALLET);
        assertEq(stray.balanceOf(PAD_WALLET), 5 ether);
        assertEq(stray.balanceOf(address(padFactory)), 0);
    }

    function test_FUNDS_directoryUnchangedByTheFee() public {
        address a = _create(PAD_OWNER, FEE);
        address b = _create(STRANGER, FEE + 1);
        assertEq(padFactory.padCount(), 2);
        assertEq(padFactory.padAt(0), a);
        assertEq(padFactory.padAt(1), b);
        assertTrue(padFactory.isPad(a) && padFactory.isPad(b));
        address[] memory page = padFactory.pads(0, 5);
        assertEq(page.length, 2);
        assertEq(page[1], b);
    }
}
