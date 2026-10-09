// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreMultisend} from "../../src/drop/DeepCoreMultisend.sol";
import {DeepCoreDropFactory} from "../../src/drop/DeepCoreDropFactory.sol";
import {DeepCoreMerkleDrop} from "../../src/drop/DeepCoreMerkleDrop.sol";
import {DeepCoreFeeGate} from "../../src/fees/DeepCoreFeeGate.sol";

contract Refuser {
    receive() external payable {
        revert("no");
    }
}

contract ContractAccount {
    function claim(DeepCoreMerkleDrop d, uint256 i, uint256 amount, bytes32[] calldata proof) external {
        d.claim(i, address(this), amount, proof);
    }
}

contract DeepCoreMultisendTest is Test {
    address constant SAFE = address(0x5AFE);
    uint256 constant FEE = 0.075 ether;
    DeepCoreMultisend ms;
    MockERC20 token;

    function setUp() public {
        ms = new DeepCoreMultisend(SAFE, SAFE, FEE, 0.75 ether, 7 days);
        token = new MockERC20("T", "T", 18);
        token.mint(address(this), 1e30);
        token.approve(address(ms), type(uint256).max);
        vm.deal(address(this), 1_000 ether);
    }

    receive() external payable {}

    function _three() internal pure returns (address[] memory r, uint256[] memory a) {
        r = new address[](3);
        a = new uint256[](3);
        (r[0], r[1], r[2]) = (address(0xA1), address(0xA2), address(0xA3));
        (a[0], a[1], a[2]) = (1 ether, 2 ether, 3 ether);
    }

    function test_NATIVE_paysEveryoneChargesOnceRefundsTheRest() public {
        (address[] memory r, uint256[] memory a) = _three();
        uint256 before = address(this).balance;
        ms.multisendNative{value: 6 ether + FEE + 1 ether}(r, a);
        assertEq(address(0xA1).balance, 1 ether);
        assertEq(address(0xA3).balance, 3 ether);
        assertEq(before - address(this).balance, 6 ether + FEE);
        assertEq(address(ms).balance, FEE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMultisend.NativeValueTooLow.selector, 6 ether, 5 ether));
        ms.multisendNative{value: 5 ether}(r, a);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.InsufficientFee.selector, FEE, 1));
        ms.multisendNative{value: 6 ether + 1}(r, a);
    }

    function test_TOKEN_straightFromSenderNoCustody() public {
        (address[] memory r, uint256[] memory a) = _three();
        ms.multisendToken{value: FEE}(address(token), r, a);
        assertEq(token.balanceOf(address(0xA2)), 2 ether);
        assertEq(token.balanceOf(address(ms)), 0);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.InsufficientFee.selector, FEE, 0));
        ms.multisendToken(address(token), r, a);
    }

    function test_ATOMIC_oneRefusalRevertsTheWholeSend() public {
        (address[] memory r, uint256[] memory a) = _three();
        r[1] = address(new Refuser());
        vm.expectRevert();
        ms.multisendNative{value: 6 ether + FEE}(r, a);
        assertEq(address(0xA1).balance, 0, "nothing was half-sent");
    }

    function test_INPUT_refusals() public {
        (address[] memory r, uint256[] memory a) = _three();
        vm.expectRevert(DeepCoreMultisend.NoRecipients.selector);
        ms.multisendToken{value: FEE}(address(token), new address[](0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMultisend.LengthMismatch.selector, 3, 2));
        ms.multisendToken{value: FEE}(address(token), r, new uint256[](2));
        r[2] = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMultisend.ZeroRecipient.selector, 2));
        ms.multisendToken{value: FEE}(address(token), r, a);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMultisend.TooManyRecipients.selector, 1001));
        ms.multisendToken{value: FEE}(address(token), new address[](1001), new uint256[](1001));
    }

    function test_FLUSH_andRescue() public {
        (address[] memory r, uint256[] memory a) = _three();
        ms.multisendToken{value: FEE}(address(token), r, a);
        ms.flushProtocolFees();
        assertEq(SAFE.balance, FEE);
        token.transfer(address(ms), 9);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        ms.rescueERC20(address(token), address(0xBAD));
        vm.prank(SAFE);
        ms.rescueERC20(address(token), SAFE);
        assertEq(token.balanceOf(SAFE), 9);
    }
}

contract DeepCoreMerkleDropTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant CREATOR = address(0xC4EA);
    address constant STRANGER = address(0xBAD);
    uint256 constant FEE = 0.075 ether;
    Currency constant NATIVE = Currency.wrap(address(0));

    DeepCoreDropFactory factory;
    MockERC20 token;
    ContractAccount cacct;

    address[4] accounts;
    uint256[4] amounts;
    bytes32[4] leaves;
    bytes32 root;

    function _leaf(uint256 i, address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(i, a, amt))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        uint256 other = i < 2 ? 1 : 0;
        p[1] = _pair(leaves[other * 2], leaves[other * 2 + 1]);
    }

    function setUp() public {
        factory = new DeepCoreDropFactory(SAFE, SAFE, FEE, 0.75 ether, 7 days);
        token = new MockERC20("T", "T", 18);
        token.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        token.approve(address(factory), type(uint256).max);
        vm.deal(CREATOR, 1_000 ether);
        cacct = new ContractAccount();
        accounts = [address(0xA1), address(0xA2), address(cacct), address(0xA4)];
        amounts = [uint256(10 ether), 20 ether, 30 ether, 40 ether];
        for (uint256 i; i < 4; ++i) leaves[i] = _leaf(i, accounts[i], amounts[i]);
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }

    function _create(Currency c, uint256 value) internal returns (DeepCoreMerkleDrop d) {
        vm.prank(CREATOR);
        d = DeepCoreMerkleDrop(payable(factory.createDrop{value: value}(c, 100 ether, root, uint64(block.timestamp + 30 days), "ipfs://drop")));
    }

    function test_CREATE_fundsTheCloneChargesTheFee() public {
        DeepCoreMerkleDrop d = _create(Currency.wrap(address(token)), FEE + 1 ether);
        assertEq(token.balanceOf(address(d)), 100 ether);
        assertEq(d.totalAmount(), 100 ether);
        assertEq(d.creator(), CREATOR);
        assertEq(address(factory).balance, FEE, "only the fee stays, surplus refunded");
        assertTrue(factory.isDrop(address(d)));
        assertEq(factory.dropCount(), 1);
        assertEq(factory.dropsOf(CREATOR, 0, 5)[0], address(d));
    }

    function test_CREATE_refusals() public {
        vm.startPrank(CREATOR);
        Currency t = Currency.wrap(address(token));
        vm.expectRevert(DeepCoreDropFactory.ZeroAmount.selector);
        factory.createDrop{value: FEE}(t, 0, root, uint64(block.timestamp + 2 days), "");
        vm.expectRevert(DeepCoreDropFactory.ZeroRoot.selector);
        factory.createDrop{value: FEE}(t, 1, bytes32(0), uint64(block.timestamp + 2 days), "");
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDropFactory.InvalidExpiry.selector, uint64(block.timestamp + 1 hours)));
        factory.createDrop{value: FEE}(t, 1, root, uint64(block.timestamp + 1 hours), "");
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.InsufficientFee.selector, FEE, 0));
        factory.createDrop(t, 1, root, uint64(block.timestamp + 2 days), "");
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDropFactory.NativeValueTooLow.selector, 100 ether, 1 ether));
        factory.createDrop{value: 1 ether}(NATIVE, 100 ether, root, uint64(block.timestamp + 2 days), "");
        vm.stopPrank();
    }

    function test_CLAIM_paysTheAccountOnceWithAValidProof() public {
        DeepCoreMerkleDrop d = _create(Currency.wrap(address(token)), FEE);
        vm.prank(STRANGER); // gas-sponsored claim for an EOA
        d.claim(1, accounts[1], amounts[1], _proof(1));
        assertEq(token.balanceOf(accounts[1]), 20 ether);
        assertEq(token.balanceOf(STRANGER), 0);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMerkleDrop.AlreadyClaimed.selector, 1));
        d.claim(1, accounts[1], amounts[1], _proof(1));
        vm.expectRevert(DeepCoreMerkleDrop.InvalidProof.selector);
        d.claim(0, accounts[0], amounts[0] + 1, _proof(0));
        vm.expectRevert(DeepCoreMerkleDrop.InvalidProof.selector);
        d.claim(0, STRANGER, amounts[0], _proof(0));
        assertTrue(d.isClaimed(1));
        assertFalse(d.isClaimed(0));
    }

    function test_CLAIM_contractAccountMustClaimItself() public {
        DeepCoreMerkleDrop d = _create(Currency.wrap(address(token)), FEE);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMerkleDrop.ContractAccountMustClaimItself.selector, address(cacct), STRANGER));
        d.claim(2, address(cacct), amounts[2], _proof(2));
        cacct.claim(d, 2, amounts[2], _proof(2));
        assertEq(token.balanceOf(address(cacct)), 30 ether);
    }

    function test_NATIVE_dropAndSweepAfterExpiry() public {
        DeepCoreMerkleDrop d = _create(NATIVE, 100 ether + FEE);
        assertEq(address(d).balance, 100 ether);
        d.claim(0, accounts[0], amounts[0], _proof(0));
        assertEq(accounts[0].balance, 10 ether);
        uint64 expiry = d.expiresAt();
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMerkleDrop.NotExpired.selector, expiry));
        d.sweep(CREATOR);
        vm.deal(STRANGER, 1);
        vm.prank(STRANGER);
        (bool accepted, bytes memory reason) = address(d).call{value: 1}("");
        assertFalse(accepted, "native from anyone but the factory is refused");
        assertEq(bytes4(reason), DeepCoreMerkleDrop.OnlyFactory.selector);
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMerkleDrop.Expired.selector, expiry));
        d.claim(3, accounts[3], amounts[3], _proof(3));
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMerkleDrop.NotCreator.selector, STRANGER));
        d.sweep(STRANGER);
        uint256 c0 = CREATOR.balance;
        vm.prank(CREATOR);
        assertEq(d.sweep(CREATOR), 90 ether);
        assertEq(CREATOR.balance - c0, 90 ether);
        vm.prank(CREATOR);
        vm.expectRevert(DeepCoreMerkleDrop.NothingToSweep.selector);
        d.sweep(CREATOR);
    }

    function test_RESCUE_otherTokenOnly_initializeOnce() public {
        DeepCoreMerkleDrop d = _create(Currency.wrap(address(token)), FEE);
        MockERC20 other = new MockERC20("O", "O", 18);
        other.mint(address(d), 5);
        vm.prank(CREATOR);
        vm.expectRevert(DeepCoreMerkleDrop.IsDropCurrency.selector);
        d.rescueOtherToken(address(token), CREATOR);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreMerkleDrop.NotCreator.selector, STRANGER));
        d.rescueOtherToken(address(other), STRANGER);
        vm.prank(CREATOR);
        d.rescueOtherToken(address(other), CREATOR);
        assertEq(other.balanceOf(CREATOR), 5);
        vm.prank(address(factory));
        vm.expectRevert(DeepCoreMerkleDrop.AlreadyInitialized.selector);
        d.initialize(STRANGER, NATIVE, 1, root, 1, "");
        vm.expectRevert(DeepCoreMerkleDrop.OnlyFactory.selector);
        d.initialize(STRANGER, NATIVE, 1, root, 1, "");
    }

    function test_FLUSH_leavesNoDropFunds() public {
        _create(NATIVE, 100 ether + FEE);
        factory.flushProtocolFees();
        assertEq(SAFE.balance, FEE);
        assertEq(address(factory).balance, 0);
    }
}
