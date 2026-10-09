// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreSplit} from "../../src/split/DeepCoreSplit.sol";
import {DeepCoreSplitFactory} from "../../src/split/DeepCoreSplitFactory.sol";

/// @dev A source shaped like a DeepCore locker: pays the caller's credit to `to`.
contract MockClaimSource {
    mapping(address => mapping(Currency => uint256)) public credit;

    function fund(address account, Currency currency, uint256 amount) external payable {
        credit[account][currency] += amount;
    }

    function claim(Currency currency, address to) external returns (uint256 amount) {
        amount = credit[msg.sender][currency];
        require(amount != 0, "NothingToClaim");
        credit[msg.sender][currency] = 0;
        if (currency.isNative()) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native");
        } else {
            MockERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    function claimFees(address to) external returns (uint256 amount) {
        amount = credit[msg.sender][Currency.wrap(address(0))];
        require(amount != 0, "NothingToClaim");
        credit[msg.sender][Currency.wrap(address(0))] = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "native");
    }

    uint256 public accepted;

    function acceptCreator(uint256 lockId) external {
        accepted = lockId;
    }
}

/// @dev A "source" that tries to re-enter the split while it is being collected from.
contract ReenteringSource {
    function claim(Currency currency, address) external returns (uint256) {
        DeepCoreSplit(payable(msg.sender)).release(0, currency);
        return 0;
    }
}

/// @dev A payee whose `receive` burns every unit of gas it is given.
contract GasBurner {
    receive() external payable {
        uint256 i;
        while (true) {
            unchecked {
                ++i;
            }
        }
    }
}

/// @dev A payee that refuses native currency.
contract NativeRefuser {
    receive() external payable {
        revert("no");
    }

    function releaseTo(DeepCoreSplit split, Currency currency, address to) external returns (uint256) {
        return split.releaseTo(currency, to);
    }
}

/// @dev A token that can blacklist a recipient.
contract BlacklistToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Black", "BLK", 18) {}

    function block_(address a) external {
        blocked[a] = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }
}

contract DeepCoreSplitTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant CREATOR = address(0xC4EA);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);
    address constant STRANGER = address(0xBAD);

    uint256 constant FEE = 0.001 ether;
    uint256 constant MAX_FEE = 0.01 ether;
    uint16 constant SHARE = 100; // 1%
    uint16 constant MAX_SHARE = 300;
    uint32 constant NOTICE = 7 days;

    Currency constant NATIVE = Currency.wrap(address(0));

    DeepCoreSplitFactory factory;
    MockERC20 token;
    Currency tok;

    function setUp() public {
        factory = new DeepCoreSplitFactory(SAFE, SAFE, FEE, MAX_FEE, SHARE, MAX_SHARE, NOTICE);
        token = new MockERC20("Quote", "QTE", 18);
        tok = Currency.wrap(address(token));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _three() internal pure returns (address[] memory p, uint96[] memory w, string[] memory l) {
        p = new address[](3);
        w = new uint96[](3);
        l = new string[](3);
        (p[0], p[1], p[2]) = (ALICE, BOB, CAROL);
        (w[0], w[1], w[2]) = (5_000, 3_000, 2_000);
        (l[0], l[1], l[2]) = ("alice", "bob", "");
    }

    function _create(address[] memory p, uint96[] memory w, string[] memory l) internal returns (DeepCoreSplit s) {
        vm.deal(CREATOR, CREATOR.balance + FEE);
        vm.prank(CREATOR);
        s = DeepCoreSplit(payable(factory.createSplit{value: FEE}("Team", p, w, l, 500)));
    }

    function _split() internal returns (DeepCoreSplit) {
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        return _create(p, w, l);
    }

    function _pay(DeepCoreSplit s, uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(s).call{value: amount}("");
        assertTrue(ok);
    }

    /*//////////////////////////////////////////////////////////////
                               FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_FACTORY_constructorRefusesBadArguments() public {
        vm.expectRevert(DeepCoreSplitFactory.ZeroAddress.selector);
        new DeepCoreSplitFactory(SAFE, address(0), 0, 1, 0, 1, NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.InvalidNotice.selector, uint32(1 days - 1)));
        new DeepCoreSplitFactory(SAFE, SAFE, 0, 1, 0, 1, 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.InvalidNotice.selector, uint32(30 days + 1)));
        new DeepCoreSplitFactory(SAFE, SAFE, 0, 1, 0, 1, 30 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.SplitFeeAboveCap.selector, 2, 1));
        new DeepCoreSplitFactory(SAFE, SAFE, 2, 1, 0, 1, NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.ProtocolShareAboveCap.selector, uint16(501), uint16(500)));
        new DeepCoreSplitFactory(SAFE, SAFE, 0, 1, 0, 501, NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.ProtocolShareAboveCap.selector, uint16(11), uint16(10)));
        new DeepCoreSplitFactory(SAFE, SAFE, 0, 1, 11, 10, NOTICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DeepCoreSplitFactory(address(0), SAFE, 0, 1, 0, 1, NOTICE);
    }

    function test_FACTORY_createListsTheSplitAndFreezesTheShare() public {
        DeepCoreSplit s = _split();
        assertEq(factory.splitCount(), 1);
        assertEq(factory.splitAt(0), address(s));
        assertTrue(factory.isSplit(address(s)));
        assertEq(s.protocolShareBps(), SHARE);
        assertEq(s.name(), "Team");
        assertEq(s.totalWeight(), 10_000);
        assertEq(s.payeeCount(), 3);
        (bool isPayee, uint256 slot) = s.slotOf(BOB);
        assertTrue(isPayee);
        assertEq(slot, 1);
        assertEq(factory.protocolFeesOwed(), FEE);
        address[] memory page = factory.splits(0, 10);
        assertEq(page.length, 1);
        assertEq(factory.splits(5, 10).length, 0);

        // A later change never reaches an existing split.
        vm.prank(SAFE);
        factory.setProtocolShare(0);
        assertEq(s.protocolShareBps(), SHARE);
        assertEq(_split().protocolShareBps(), 0);
    }

    function test_FACTORY_feeIsRequiredAndSurplusRefunded() public {
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.InsufficientSplitFee.selector, FEE, FEE - 1));
        factory.createSplit{value: FEE - 1}("Team", p, w, l, 500);

        vm.prank(CREATOR);
        factory.createSplit{value: 1 ether}("Team", p, w, l, 500);
        assertEq(CREATOR.balance, 1 ether - FEE, "surplus refunded");
        assertEq(address(factory).balance, FEE);
    }

    function test_FACTORY_feeLeversFollowTheNoticeRules() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        factory.setSplitFee(0);

        vm.startPrank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.SplitFeeAboveCap.selector, MAX_FEE + 1, MAX_FEE));
        factory.setSplitFee(MAX_FEE + 1);

        factory.setSplitFee(0.0005 ether); // decrease: now
        assertEq(factory.splitFeeWei(), 0.0005 ether);

        factory.setSplitFee(0.002 ether); // increase: after notice
        assertEq(factory.splitFeeWei(), 0.0005 ether);
        (uint256 pendingFee, uint64 at) = factory.pendingSplitFee();
        assertEq(pendingFee, 0.002 ether);
        assertEq(at, block.timestamp + NOTICE);

        vm.warp(block.timestamp + NOTICE - 1);
        factory.setSplitFee(0.003 ether); // restarts the notice
        vm.warp(block.timestamp + 2);
        assertEq(factory.splitFeeWei(), 0.0005 ether, "the restarted notice has not elapsed");
        factory.cancelPendingSplitFee();
        (pendingFee,) = factory.pendingSplitFee();
        assertEq(pendingFee, 0);
        vm.expectRevert(DeepCoreSplitFactory.NoPendingChange.selector);
        factory.cancelPendingSplitFee();

        factory.setSplitFee(0.004 ether);
        vm.warp(block.timestamp + NOTICE);
        assertEq(factory.splitFeeWei(), 0.004 ether, "applies by itself");
        vm.expectRevert(DeepCoreSplitFactory.NoPendingChange.selector);
        factory.cancelPendingSplitFee(); // materialised, nothing left to cancel
        assertEq(factory.splitFeeWei(), 0.004 ether);
        vm.stopPrank();
    }

    function test_FACTORY_protocolShareFollowsTheNoticeRules() public {
        vm.startPrank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.ProtocolShareAboveCap.selector, MAX_SHARE + 1, MAX_SHARE));
        factory.setProtocolShare(MAX_SHARE + 1);
        factory.setProtocolShare(50);
        assertEq(factory.protocolShareBps(), 50);
        factory.setProtocolShare(200);
        assertEq(factory.protocolShareBps(), 50);
        (uint16 bps, uint64 at) = factory.pendingProtocolShare();
        assertEq(bps, 200);
        assertEq(at, block.timestamp + NOTICE);
        factory.setProtocolShare(20); // a decrease cancels the pending increase
        (bps,) = factory.pendingProtocolShare();
        assertEq(bps, 0);
        assertEq(factory.protocolShareBps(), 20);
        factory.setProtocolShare(200);
        factory.cancelPendingProtocolShare();
        factory.setProtocolShare(200);
        vm.warp(block.timestamp + NOTICE);
        assertEq(factory.protocolShareBps(), 200);
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        factory.cancelPendingProtocolShare();
    }

    /// @dev An increase that lands between the creator's preview and its block is refused, not accepted silently.
    function test_FACTORY_creatorBoundsTheProtocolShare() public {
        vm.prank(SAFE);
        factory.setProtocolShare(200);
        vm.warp(block.timestamp + NOTICE); // the increase took effect by itself
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.ProtocolShareAboveLimit.selector, uint16(200), uint16(100)));
        factory.createSplit{value: FEE}("Team", p, w, l, 100);
        vm.prank(CREATOR);
        DeepCoreSplit s = DeepCoreSplit(payable(factory.createSplit{value: FEE}("Team", p, w, l, 200)));
        assertEq(s.protocolShareBps(), 200);
    }

    function test_FACTORY_flushPaysOnlyTheRecipient_includingForcedNative() public {
        vm.expectRevert(DeepCoreSplitFactory.NothingToFlush.selector);
        factory.flushProtocolFees();
        _split();
        vm.deal(address(factory), address(factory).balance + 3); // as if selfdestructed in
        vm.prank(STRANGER);
        uint256 amount = factory.flushProtocolFees();
        assertEq(amount, FEE + 3);
        assertEq(SAFE.balance, FEE + 3);
        assertEq(factory.protocolFeesOwed(), 0);
        assertEq(STRANGER.balance, 0);
    }

    function test_FACTORY_renounceRevertsAndRescueIsOwnerOnly() public {
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreSplitFactory.RenounceDisabled.selector);
        factory.renounceOwnership();

        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.NothingToRescue.selector, address(token)));
        factory.rescueERC20(address(token), CAROL);
        token.mint(address(factory), 7);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        factory.rescueERC20(address(token), STRANGER);
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreSplitFactory.ZeroAddress.selector);
        factory.rescueERC20(address(token), address(0));
        vm.prank(SAFE);
        factory.rescueERC20(address(token), CAROL);
        assertEq(token.balanceOf(CAROL), 7);
    }

    function test_FACTORY_ownerCannotGateCreationAndPaysLikeAnyone() public {
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        vm.deal(SAFE, 1 ether);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplitFactory.InsufficientSplitFee.selector, FEE, 0));
        factory.createSplit("Safe", p, w, l, 500);
        vm.prank(STRANGER);
        vm.deal(STRANGER, FEE);
        factory.createSplit{value: FEE}("Anyone", p, w, l, 500);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_INIT_refusesBadSplits() public {
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        vm.deal(CREATOR, 10 ether);
        vm.startPrank(CREATOR);

        vm.expectRevert(DeepCoreSplit.InvalidName.selector);
        factory.createSplit{value: FEE}("", p, w, l, 500);
        vm.expectRevert(DeepCoreSplit.InvalidName.selector);
        factory.createSplit{value: FEE}(string(new bytes(65)), p, w, l, 500);

        vm.expectRevert(DeepCoreSplit.NoPayees.selector);
        factory.createSplit{value: FEE}("T", new address[](0), new uint96[](0), new string[](0), 500);

        vm.expectRevert(DeepCoreSplit.LengthMismatch.selector);
        factory.createSplit{value: FEE}("T", p, new uint96[](2), l, 500);

        uint96[] memory w0 = new uint96[](3);
        (w0[0], w0[1]) = (1, 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.ZeroWeight.selector, 2));
        factory.createSplit{value: FEE}("T", p, w0, l, 500);

        address[] memory dup = new address[](3);
        (dup[0], dup[1], dup[2]) = (ALICE, BOB, ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.DuplicatePayee.selector, ALICE));
        factory.createSplit{value: FEE}("T", dup, w, l, 500);

        address[] memory zero = new address[](3);
        (zero[0], zero[1]) = (ALICE, BOB);
        vm.expectRevert(DeepCoreSplit.ZeroAddress.selector);
        factory.createSplit{value: FEE}("T", zero, w, l, 500);

        string[] memory longLabel = new string[](3);
        longLabel[1] = string(new bytes(33));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.InvalidLabel.selector, 1));
        factory.createSplit{value: FEE}("T", p, w, longLabel, 500);

        address[] memory many = new address[](101);
        uint96[] memory manyW = new uint96[](101);
        for (uint256 i; i < 101; ++i) {
            many[i] = address(uint160(0x1000 + i));
            manyW[i] = 1;
        }
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.TooManyPayees.selector, 101));
        factory.createSplit{value: FEE}("T", many, manyW, new string[](101), 500);

        // The clone's own address, predicted from the factory's nonce.
        address next = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        address[] memory selfPay = new address[](3);
        (selfPay[0], selfPay[1], selfPay[2]) = (ALICE, next, CAROL);
        vm.expectRevert(DeepCoreSplit.SelfPayee.selector);
        factory.createSplit{value: FEE}("T", selfPay, w, l, 500);
        vm.stopPrank();
    }

    function test_INIT_onlyTheFactory_once_andNeverTheImplementation() public {
        DeepCoreSplit s = _split();
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        vm.expectRevert(DeepCoreSplit.OnlyFactory.selector);
        s.initialize(STRANGER, "X", p, w, l, 0);
        vm.prank(address(factory));
        vm.expectRevert(DeepCoreSplit.AlreadyInitialized.selector);
        s.initialize(STRANGER, "X", p, w, l, 0);

        DeepCoreSplit impl = factory.IMPLEMENTATION();
        vm.prank(address(factory));
        vm.expectRevert(DeepCoreSplit.AlreadyInitialized.selector);
        impl.initialize(STRANGER, "X", p, w, l, 0);
        assertEq(impl.PROTOCOL_RECIPIENT(), SAFE);
        assertEq(s.PROTOCOL_RECIPIENT(), SAFE);
        assertEq(s.FACTORY(), address(factory));
    }

    function test_INIT_shareAboveTheSplitsOwnCapIsRefused() public {
        (address[] memory p, uint96[] memory w, string[] memory l) = _three();
        DeepCoreSplitFactory f = new DeepCoreSplitFactory(SAFE, SAFE, 0, 0, 0, 500, NOTICE);
        vm.prank(SAFE);
        f.setProtocolShare(500);
        vm.warp(block.timestamp + NOTICE);
        DeepCoreSplit s = DeepCoreSplit(payable(f.createSplit("T", p, w, l, 500)));
        assertEq(s.protocolShareBps(), 500);
        // A clone initialized by a factory that skipped its own cap is still refused by the split.
        DeepCoreSplit impl = new DeepCoreSplit(address(this), SAFE);
        DeepCoreSplit clone = DeepCoreSplit(payable(Clones.clone(address(impl))));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.ProtocolShareTooHigh.selector, uint16(501)));
        clone.initialize(CREATOR, "T", p, w, l, 501);
        clone.initialize(CREATOR, "T", p, w, l, 500);
        assertEq(clone.protocolShareBps(), 500);
    }

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_SPLIT_nativeIsSharedAfterTheProtocolShare() public {
        DeepCoreSplit s = _split();
        _pay(s, 100 ether);
        // 1% to the protocol, 99 split 50/30/20.
        assertEq(s.protocolReleasable(NATIVE), 1 ether);
        assertEq(s.releasable(0, NATIVE), 49.5 ether);
        assertEq(s.releasable(1, NATIVE), 29.7 ether);
        assertEq(s.releasable(2, NATIVE), 19.8 ether);

        vm.prank(STRANGER);
        s.release(1, NATIVE); // anyone may trigger; the payee is paid
        assertEq(BOB.balance, 29.7 ether);
        assertEq(STRANGER.balance, 0);
        vm.expectRevert(DeepCoreSplit.NothingToRelease.selector);
        s.release(1, NATIVE);

        _pay(s, 10 ether); // later inflow is counted with everything before
        assertEq(s.releasable(1, NATIVE), 2.97 ether);
        assertEq(s.totalReceived(NATIVE), 110 ether);

        vm.prank(STRANGER);
        s.releaseProtocol(NATIVE);
        assertEq(SAFE.balance, 1.1 ether);
        s.releaseAll(NATIVE);
        assertEq(ALICE.balance, 54.45 ether);
        assertEq(BOB.balance, 32.67 ether);
        assertEq(CAROL.balance, 21.78 ether);
        assertEq(address(s).balance, 0);
        vm.expectRevert(DeepCoreSplit.NothingToRelease.selector);
        s.releaseAll(NATIVE);
        vm.expectRevert(DeepCoreSplit.NothingToRelease.selector);
        s.releaseProtocol(NATIVE);
    }

    function test_SPLIT_erc20DirectTransferIsShared() public {
        DeepCoreSplit s = _split();
        token.mint(address(s), 1_000);
        s.releaseAll(tok);
        assertEq(token.balanceOf(SAFE), 10);
        assertEq(token.balanceOf(ALICE), 495);
        assertEq(token.balanceOf(BOB), 297);
        assertEq(token.balanceOf(CAROL), 198);
        assertEq(token.balanceOf(address(s)), 0);
    }

    function test_SPLIT_releaseToIsThePayeesOwnAndGoesWhereItSays() public {
        DeepCoreSplit s = _split();
        token.mint(address(s), 1_000_000);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPayee.selector, STRANGER));
        s.releaseTo(tok, STRANGER);
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreSplit.ZeroAddress.selector);
        s.releaseTo(tok, address(0));
        vm.prank(ALICE);
        s.releaseTo(tok, CAROL);
        assertEq(token.balanceOf(CAROL), 495_000);
        assertEq(s.releasable(0, tok), 0);
        assertEq(s.releasable(2, tok), 198_000, "Carol's own share untouched");
    }

    function test_SPLIT_releaseAllSkipsABadPayeeWhoKeepsTheShare() public {
        NativeRefuser refuser = new NativeRefuser();
        address[] memory p = new address[](2);
        uint96[] memory w = new uint96[](2);
        (p[0], p[1]) = (address(refuser), ALICE);
        (w[0], w[1]) = (1, 1);
        DeepCoreSplit s = _create(p, w, new string[](2));
        _pay(s, 2 ether);

        s.releaseAll(NATIVE); // Alice and the protocol are paid; the refuser is skipped
        assertEq(ALICE.balance, 0.99 ether);
        assertEq(SAFE.balance, 0.02 ether);
        assertEq(s.releasable(0, NATIVE), 0.99 ether, "kept");

        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.TransferFailed.selector, NATIVE, address(refuser), 0.99 ether));
        s.release(0, NATIVE);
        refuser.releaseTo(s, NATIVE, CAROL);
        assertEq(CAROL.balance, 0.99 ether);
        assertEq(address(s).balance, 0);
    }

    /// Audit C-3: with all gas forwarded, one gas-burning payee kept 63/64 of the batch's gas and the
    /// payees after it could not be paid, so `releaseAll` reverted every time.
    function test_FIX_releaseAllCapsGasPerNativePayee_aGasBurnerIsSkipped() public {
        GasBurner burner = new GasBurner();
        address[] memory p = new address[](2);
        uint96[] memory w = new uint96[](2);
        (p[0], p[1]) = (address(burner), ALICE);
        (w[0], w[1]) = (1, 1);
        DeepCoreSplit s = _create(p, w, new string[](2));
        _pay(s, 2 ether);

        s.releaseAll{gas: 1_000_000}(NATIVE);
        assertEq(ALICE.balance, 0.99 ether, "Alice is paid although the payee before her burned its whole stipend");
        assertEq(SAFE.balance, 0.02 ether, "and so is the protocol");
        assertEq(s.releasable(0, NATIVE), 0.99 ether, "the burner keeps its share");
        assertEq(address(burner).balance, 0);
    }

    function test_SPLIT_blacklistedPayeeIsSkippedForThatTokenOnly() public {
        BlacklistToken bl = new BlacklistToken();
        DeepCoreSplit s = _split();
        bl.block_(BOB);
        bl.mint(address(s), 10_000);
        s.releaseAll(Currency.wrap(address(bl)));
        assertEq(bl.balanceOf(ALICE), 4_950);
        assertEq(bl.balanceOf(BOB), 0);
        assertEq(s.releasable(1, Currency.wrap(address(bl))), 2_970);
        vm.prank(BOB);
        s.releaseTo(Currency.wrap(address(bl)), CAROL);
        assertEq(bl.balanceOf(CAROL), 1_980 + 2_970);
    }

    function test_SPLIT_releaseAllRevertsWhenNothingCouldBePaid() public {
        NativeRefuser refuser = new NativeRefuser();
        address[] memory p = new address[](1);
        uint96[] memory w = new uint96[](1);
        p[0] = address(refuser);
        w[0] = 1;
        vm.prank(SAFE);
        factory.setProtocolShare(0);
        DeepCoreSplit s = _create(p, w, new string[](1));
        _pay(s, 1 ether);
        vm.expectRevert(DeepCoreSplit.NothingToRelease.selector);
        s.releaseAll(NATIVE);
        assertEq(s.releasable(0, NATIVE), 1 ether);
    }

    function test_SPLIT_zeroProtocolShareMeansNothingForTheProtocol() public {
        vm.prank(SAFE);
        factory.setProtocolShare(0);
        DeepCoreSplit s = _split();
        _pay(s, 1 ether);
        assertEq(s.protocolReleasable(NATIVE), 0);
        vm.expectRevert(DeepCoreSplit.NothingToRelease.selector);
        s.releaseProtocol(NATIVE);
        s.releaseAll(NATIVE);
        assertEq(ALICE.balance + BOB.balance + CAROL.balance, 1 ether);
    }

    function test_SPLIT_releaseOfAnUnknownSlotReverts() public {
        DeepCoreSplit s = _split();
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NoSuchSlot.selector, 3));
        s.release(3, NATIVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NoSuchSlot.selector, 3));
        s.releasable(3, NATIVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NoSuchSlot.selector, 3));
        s.slotAt(3);
    }

    /*//////////////////////////////////////////////////////////////
                               ROTATION
    //////////////////////////////////////////////////////////////*/

    function test_ROTATE_twoStepMovesTheSlotAndItsUnreleasedMoney() public {
        DeepCoreSplit s = _split();
        _pay(s, 10 ether);
        address newBob = address(0xB0B2);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPayee.selector, STRANGER));
        s.transferPayee(newBob);

        vm.prank(BOB);
        s.transferPayee(newBob);
        assertEq(s.pendingPayee(1), newBob);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPendingPayee.selector, STRANGER));
        s.acceptPayee(1);

        vm.prank(newBob);
        s.acceptPayee(1);
        (address payee, uint96 weight) = s.slotAt(1);
        assertEq(payee, newBob);
        assertEq(weight, 3_000);
        (bool was,) = s.slotOf(BOB);
        assertFalse(was);
        assertEq(s.pendingPayee(1), address(0));

        s.release(1, NATIVE);
        assertEq(newBob.balance, 2.97 ether);
        assertEq(BOB.balance, 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPayee.selector, BOB));
        s.releaseTo(NATIVE, BOB);
    }

    function test_ROTATE_cannotMergeSlots_canWithdrawTheOffer_neverToSelf() public {
        DeepCoreSplit s = _split();
        vm.prank(BOB);
        s.transferPayee(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.DuplicatePayee.selector, ALICE));
        s.acceptPayee(1);

        vm.prank(BOB);
        s.transferPayee(address(0));
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPendingPayee.selector, address(0)));
        s.acceptPayee(1);

        vm.prank(BOB);
        vm.expectRevert(DeepCoreSplit.SelfPayee.selector);
        s.transferPayee(address(s));

        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NoSuchSlot.selector, 9));
        s.acceptPayee(9);
    }

    /*//////////////////////////////////////////////////////////////
                                COLLECT
    //////////////////////////////////////////////////////////////*/

    function test_COLLECT_pullsFromASourceAndKitFees() public {
        DeepCoreSplit s = _split();
        MockClaimSource src = new MockClaimSource();
        token.mint(address(src), 500);
        src.fund(address(s), tok, 500);
        vm.deal(address(src), 3 ether);
        src.fund(address(s), NATIVE, 3 ether);

        vm.prank(STRANGER);
        assertEq(s.collect(address(src), tok), 500);
        assertEq(token.balanceOf(address(s)), 500);
        vm.expectRevert(bytes("NothingToClaim"));
        s.collect(address(src), tok);

        assertEq(s.collectKitFees(address(src)), 3 ether);
        assertEq(s.totalReceived(NATIVE), 3 ether);
    }

    function test_COLLECT_aSourceCannotReenterARelease() public {
        DeepCoreSplit s = _split();
        _pay(s, 1 ether);
        ReenteringSource evil = new ReenteringSource();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        s.collect(address(evil), NATIVE);
        assertEq(address(s).balance, 1 ether);
    }

    function test_COLLECT_acceptCreatorIsForPayeesOnly() public {
        DeepCoreSplit s = _split();
        MockClaimSource locker = new MockClaimSource();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPayee.selector, STRANGER));
        s.acceptCreator(address(locker), 7);
        vm.prank(CAROL);
        s.acceptCreator(address(locker), 7);
        assertEq(locker.accepted(), 7);
    }

    function test_MULTICALL_collectThenReleaseAllInOneTransaction() public {
        DeepCoreSplit s = _split();
        MockClaimSource src = new MockClaimSource();
        token.mint(address(src), 10_000);
        src.fund(address(s), tok, 10_000);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(DeepCoreSplit.collect, (address(src), tok));
        calls[1] = abi.encodeCall(DeepCoreSplit.releaseAll, (tok));
        s.multicall(calls);
        assertEq(token.balanceOf(ALICE), 4_950);
        assertEq(token.balanceOf(SAFE), 100);
        assertEq(token.balanceOf(address(s)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Random weights, inflows and release order: nobody is ever paid more than its entitlement, the books
    /// always balance, and after a final `releaseAll` at most one unit per party is left behind.
    function testFuzz_SPLIT_solventAndBoundedDust(uint96[4] memory rawW, uint128[6] memory inflows, uint8 order, uint16 share)
        public
    {
        share = uint16(bound(share, 0, MAX_SHARE));
        DeepCoreSplitFactory f = new DeepCoreSplitFactory(SAFE, SAFE, 0, 0, share, MAX_SHARE, NOTICE);
        address[] memory p = new address[](4);
        uint96[] memory w = new uint96[](4);
        for (uint256 i; i < 4; ++i) {
            p[i] = address(uint160(0xF000 + i));
            w[i] = uint96(bound(rawW[i], 1, type(uint64).max));
        }
        DeepCoreSplit s = DeepCoreSplit(payable(f.createSplit("F", p, w, new string[](4), 500)));

        uint256 total;
        for (uint256 k; k < inflows.length; ++k) {
            uint256 amount = uint256(inflows[k]) % 1e30;
            token.mint(address(s), amount);
            total += amount;
            uint256 slot = (uint256(order) + k) % 4;
            if (s.releasable(slot, tok) != 0) s.release(slot, tok);
            if (k % 3 == 2 && s.protocolReleasable(tok) != 0) s.releaseProtocol(tok);
            assertEq(token.balanceOf(address(s)) + s.totalReleased(tok), total, "books balance");
        }
        if (total != 0) {
            try s.releaseAll(tok) {} catch {}
        }
        assertLe(token.balanceOf(address(s)), 5, "at most one unit per party is left");
        uint256 paid = token.balanceOf(SAFE);
        for (uint256 i; i < 4; ++i) {
            uint256 got = token.balanceOf(p[i]);
            paid += got;
            uint256 fair = total * (10_000 - share) * w[i] / (10_000 * s.totalWeight());
            assertLe(got, fair, "never above the entitlement");
        }
        assertEq(paid + token.balanceOf(address(s)), total);
    }
}
