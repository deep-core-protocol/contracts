// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreTokenLock} from "../../src/lock/DeepCoreTokenLock.sol";
import {DeepCoreSplit} from "../../src/split/DeepCoreSplit.sol";
import {DeepCoreSplitFactory} from "../../src/split/DeepCoreSplitFactory.sol";

/// @notice `release(lockId)`: permissionless, pays only the lock's current beneficiary. It closes the integration
/// limit found 2026-09-19 - a `DeepCoreSplit` named as beneficiary could never be paid, because it has no call that
/// reaches `claim` - without giving anyone a way to send a lock's tokens anywhere else.
contract DeepCoreTokenLockReleaseTest is Test {
    address constant SAFE = address(0x5AFE);
    address constant BEN = address(0xBE4);
    address constant BEN2 = address(0xBE5);
    address constant STRANGER = address(0xBAD);
    address constant CREATOR = address(0xC4EA);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant FEE = 0.075 ether;
    uint256 constant SPLIT_FEE = 0.001 ether;

    DeepCoreTokenLock tl;
    DeepCoreSplitFactory factory;
    MockERC20 token;
    Currency tok;

    function setUp() public {
        tl = new DeepCoreTokenLock(SAFE, SAFE, FEE, 0.75 ether, 7 days);
        factory = new DeepCoreSplitFactory(SAFE, SAFE, SPLIT_FEE, 0.01 ether, 100, 300, 7 days);
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

    function test_RELEASE_anyonePaysTheBeneficiaryOnly() public {
        uint256 id = tl.lock{value: FEE}(tok, 1_000 ether, BEN, _t(0), _t(0), _t(100 days));
        vm.warp(block.timestamp + 25 days);

        vm.prank(STRANGER);
        uint256 paid = tl.release(id);
        assertEq(paid, 250 ether, "a quarter vested");
        assertEq(token.balanceOf(BEN), 250 ether, "paid to the beneficiary");
        assertEq(token.balanceOf(STRANGER), 0, "never to the caller");
        assertEq(tl.totalHeld(tok), 750 ether);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NothingToClaim.selector, id));
        tl.release(id);

        // `claim` still works alongside it, for what vests later.
        vm.warp(block.timestamp + 75 days);
        vm.prank(BEN);
        assertEq(tl.claim(id, BEN2), 750 ether);
        assertEq(tl.totalHeld(tok), 0);
    }

    /// @dev A contract that can `claim` to elsewhere but cannot move tokens it holds: a stranger must not be
    /// able to strand its tokens inside it. Only it may call `release` for itself.
    function test_RELEASE_aPlainContractBeneficiaryIsNotReleasedByAStranger() public {
        ClaimOnlyBeneficiary c = new ClaimOnlyBeneficiary();
        uint256 id = tl.lock{value: FEE}(tok, 1 ether, address(c), _t(1 days), _t(1 days), _t(1 days));
        vm.warp(block.timestamp + 1 days);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.ReleaseNotAllowed.selector, id, address(c)));
        tl.release(id);
        // A fake split (a factory that vouches for nobody) is refused the same way.
        FakeSplit f = new FakeSplit(address(new NoSplitFactory()));
        uint256 id2 = tl.lock{value: FEE}(tok, 1 ether, address(f), _t(1), _t(1), _t(1));
        vm.warp(block.timestamp + 1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.ReleaseNotAllowed.selector, id2, address(f)));
        tl.release(id2);
        // The contract itself keeps its route: claim to wherever it forwards.
        c.claimTo(tl, id, BEN2);
        assertEq(token.balanceOf(BEN2), 1 ether);
    }

    function test_RELEASE_refusals() public {
        uint256 id = tl.lock{value: FEE}(tok, 1 ether, BEN, _t(30 days), _t(30 days), _t(30 days));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NothingToClaim.selector, id));
        tl.release(id);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTokenLock.NoSuchLock.selector, id + 1));
        tl.release(id + 1);
    }

    /// @dev After a rotation it pays the NEW beneficiary, never the old one.
    function test_RELEASE_followsTheBeneficiaryAfterARotation() public {
        uint256 id = tl.lock{value: FEE}(tok, 1 ether, BEN, _t(1 days), _t(1 days), _t(1 days));
        vm.prank(BEN);
        tl.transferBeneficiary(id, BEN2);
        vm.prank(BEN2);
        tl.acceptBeneficiary(id);
        vm.warp(block.timestamp + 1 days);
        tl.release(id);
        assertEq(token.balanceOf(BEN2), 1 ether);
        assertEq(token.balanceOf(BEN), 0);
    }

    /// @dev The integration limit itself: a split named as beneficiary is paid, and splits to its payees.
    function test_RELEASE_aSplitBeneficiaryIsPaidAndSplitsIt() public {
        address[] memory p = new address[](2);
        uint96[] memory w = new uint96[](2);
        string[] memory l = new string[](2);
        (p[0], p[1]) = (ALICE, BOB);
        (w[0], w[1]) = (7_000, 3_000);
        vm.deal(CREATOR, SPLIT_FEE);
        vm.prank(CREATOR);
        DeepCoreSplit s = DeepCoreSplit(payable(factory.createSplit{value: SPLIT_FEE}("Team", p, w, l, 500)));

        uint256 id = tl.lock{value: FEE}(tok, 1_000 ether, address(s), _t(10 days), _t(10 days), _t(10 days));
        vm.warp(block.timestamp + 10 days);

        vm.prank(STRANGER);
        assertEq(tl.release(id), 1_000 ether);
        assertEq(token.balanceOf(address(s)), 1_000 ether, "the split holds the lock's tokens");

        vm.prank(STRANGER);
        s.releaseAll(tok);
        assertEq(token.balanceOf(SAFE), 10 ether, "1% protocol share");
        assertEq(token.balanceOf(ALICE), 693 ether, "70% of the rest");
        assertEq(token.balanceOf(BOB), 297 ether, "30% of the rest");
        assertEq(token.balanceOf(address(s)), 0, "nothing stranded");
        assertEq(tl.totalHeld(tok), 0);
    }
}

/// @dev Can call `claim(id, to)` but has no way to move an ERC-20 it holds.
contract ClaimOnlyBeneficiary {
    function claimTo(DeepCoreTokenLock tl, uint256 id, address to) external {
        tl.claim(id, to);
    }
}

contract NoSplitFactory {
    function isSplit(address) external pure returns (bool) {
        return false;
    }
}

contract FakeSplit {
    address public immutable FACTORY;

    constructor(address f) {
        FACTORY = f;
    }
}
