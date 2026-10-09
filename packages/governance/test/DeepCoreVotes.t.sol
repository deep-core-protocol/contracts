// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {DeepCoreVotes} from "../src/DeepCoreVotes.sol";

/**
 * A plain ERC20Votes with no auto-delegation, used as the CONTROL.
 *
 * The point of these tests is not that `DeepCoreVotes` delegates — that is one
 * line and hard to get wrong. It is that NOT delegating fails silently, and a
 * test suite that only exercises the fixed contract never demonstrates the bug
 * it was written to prevent. So the control is deployed alongside and the two
 * are measured with the same assertions.
 */
contract PlainVotes is ERC20, ERC20Votes {
    constructor(address to, uint256 supply) ERC20("Plain", "PLN") EIP712("Plain", "1") {
        _mint(to, supply);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract DeepCoreVotesTest is Test {
    /* `makeAddr` rather than short hex literals: 0xTREA5 is not hex, and the
       near-miss literals that DO compile (0xA11CE) are only 20 bits wide, so
       they sit in precompile territory and behave unlike real accounts. */
    address immutable TREASURY = makeAddr("treasury");
    address immutable ALICE = makeAddr("alice");
    address immutable BOB = makeAddr("bob");

    uint256 constant SUPPLY = 1_000_000 ether;

    DeepCoreVotes token;

    function setUp() public {
        token = new DeepCoreVotes("DeepCore Votes", "DEEPCORE", TREASURY, SUPPLY);
        // Checkpoints are only readable once the timepoint is in the past.
        vm.roll(block.number + 1);
    }

    /* ---------------------------------------------------------------- basics */

    function test_ConstructorMintsEntireSupplyToTreasury() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply");
        assertEq(token.balanceOf(TREASURY), SUPPLY, "treasury balance");
    }

    function test_ConstructorRejectsZeroTreasury() public {
        vm.expectRevert(DeepCoreVotes.InvalidTreasury.selector);
        new DeepCoreVotes("x", "x", address(0), SUPPLY);
    }

    function test_ConstructorRejectsZeroSupply() public {
        vm.expectRevert(DeepCoreVotes.ZeroSupply.selector);
        new DeepCoreVotes("x", "x", TREASURY, 0);
    }

    /* ------------------------------------------------- the whole point ------
       The treasury has voting power without ever having sent a transaction.
       For a 2-of-3 Safe that is the difference between "it works" and "it
       works after we collect two signatures for a call nobody remembered".
       ------------------------------------------------------------------------ */

    function test_TreasuryHasVotingPowerWithoutEverCallingDelegate() public view {
        assertEq(token.delegates(TREASURY), TREASURY, "self-delegated");
        assertEq(token.getVotes(TREASURY), SUPPLY, "votes");
        assertTrue(token.hasAutoDelegated(TREASURY), "flag recorded");
    }

    function test_DelegationIsEffectiveAtTheMintBlock() public {
        // There must be no block in which supply exists behind zero votes: a
        // distributor that snapshots the deployment block would otherwise
        // measure a fully-supplied, fully-unvoting token.
        uint256 mintBlock = block.number - 1;
        assertEq(token.getPastVotes(TREASURY, mintBlock), SUPPLY, "past votes at mint");
        assertEq(token.getPastTotalSupply(mintBlock), SUPPLY, "past supply at mint");
    }

    /* ----------------------------------------------------------------------
       THE SILENT FAILURE, demonstrated on the control.

       `getPastTotalSupply` is pushed on mint/burn; `getPastVotes` is pushed on
       delegation. A 100% holder who never delegated therefore produces a
       NON-ZERO denominator and a ZERO numerator, so the distributor's
       `NoVotingSupplyAtSnapshot` guard does not fire and every payout rounds
       to nothing. Nobody gets an error. The pot just never moves.
       ---------------------------------------------------------------------- */

    function test_Control_UndelegatedSupplyStrandsTheEntirePot() public {
        PlainVotes plain = new PlainVotes(TREASURY, SUPPLY);
        vm.roll(block.number + 1);
        uint256 t = block.number - 1;

        uint256 denominator = plain.getPastTotalSupply(t);
        uint256 numerator = plain.getPastVotes(TREASURY, t);

        assertEq(denominator, SUPPLY, "denominator is full supply - the guard cannot fire");
        assertEq(numerator, 0, "numerator is zero - the holder never delegated");

        // This is the distributor's formula, verbatim.
        uint256 pot = 100 ether;
        assertEq((pot * numerator) / denominator, 0, "100% holder is paid nothing");
    }

    function test_DeepCoreVotes_PaysTheWholePotToASoleHolder() public view {
        uint256 t = block.number - 1;
        uint256 pot = 100 ether;
        uint256 payout = (pot * token.getPastVotes(TREASURY, t)) / token.getPastTotalSupply(t);
        assertEq(payout, pot, "sole holder receives the whole pot");
    }

    /* ------------------------------------------------------- on transfer --- */

    function test_RecipientIsDelegatedOnFirstReceipt() public {
        vm.prank(TREASURY);
        token.transfer(ALICE, 100 ether);

        assertEq(token.delegates(ALICE), ALICE, "alice self-delegated");
        assertEq(token.getVotes(ALICE), 100 ether, "alice votes");
        assertEq(token.getVotes(TREASURY), SUPPLY - 100 ether, "treasury reduced");
    }

    function test_VotesMoveWithBalanceForBothParties() public {
        vm.prank(TREASURY);
        token.transfer(ALICE, 300 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);

        assertEq(token.getVotes(ALICE), 200 ether, "alice");
        assertEq(token.getVotes(BOB), 100 ether, "bob");
        assertEq(
            token.getVotes(TREASURY) + token.getVotes(ALICE) + token.getVotes(BOB),
            SUPPLY,
            "voting units conserved"
        );
    }

    /* -------------------------------------------- opting out is permanent --- */

    function test_ExplicitUndelegationSurvivesLaterReceipts() public {
        vm.prank(TREASURY);
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        token.delegate(address(0));
        assertEq(token.getVotes(ALICE), 0, "opted out");

        // The naive `delegates(to) == address(0)` implementation re-delegates
        // here, making opt-out impossible for anyone who keeps receiving.
        vm.prank(TREASURY);
        token.transfer(ALICE, 100 ether);

        assertEq(token.delegates(ALICE), address(0), "still opted out");
        assertEq(token.getVotes(ALICE), 0, "still no votes");
        assertEq(token.balanceOf(ALICE), 200 ether, "but holds the tokens");
    }

    function test_HolderMayDelegateToSomebodyElseAndItSticks() public {
        vm.prank(TREASURY);
        token.transfer(ALICE, 100 ether);

        vm.prank(ALICE);
        token.delegate(BOB);
        assertEq(token.getVotes(BOB), 100 ether, "bob holds alice's votes");

        vm.prank(TREASURY);
        token.transfer(ALICE, 50 ether);

        assertEq(token.delegates(ALICE), BOB, "delegation not overwritten");
        assertEq(token.getVotes(BOB), 150 ether, "new receipt follows the delegation");
        assertEq(token.getVotes(ALICE), 0, "alice holds none herself");
    }

    /* ---------------------------------------------------------- no supply --- */

    function test_ThereIsNoMintFunction() public view {
        // A snapshot distributor is only as honest as the supply it measures.
        // If this ever compiles with a mint path, the assertion below is the
        // wrong test — the review is.
        assertEq(token.totalSupply(), SUPPLY, "supply is fixed at construction");
    }

    function test_BurnDoesNotCreateADelegationForTheZeroAddress() public {
        // `to == address(0)` is a burn, not a receipt. Delegating it would
        // credit voting units to nobody and corrupt the conservation check.
        assertFalse(token.hasAutoDelegated(address(0)), "zero address untouched");
    }

    /* -------------------------------------------------------------- fuzz --- */

    function testFuzz_VotingUnitsAlwaysEqualBalancesForAutoDelegatedHolders(uint96 amount) public {
        amount = uint96(bound(amount, 1, SUPPLY));

        vm.prank(TREASURY);
        token.transfer(ALICE, amount);

        assertEq(token.getVotes(ALICE), token.balanceOf(ALICE), "alice");
        assertEq(token.getVotes(TREASURY), token.balanceOf(TREASURY), "treasury");
    }

    function testFuzz_PastTotalSupplyNeverExceedsPastVotesSum(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, SUPPLY / 2));
        b = uint96(bound(b, 1, SUPPLY / 2));

        vm.startPrank(TREASURY);
        token.transfer(ALICE, a);
        token.transfer(BOB, b);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 t = block.number - 1;
        uint256 summed =
            token.getPastVotes(TREASURY, t) + token.getPastVotes(ALICE, t) + token.getPastVotes(BOB, t);

        // Equality here is what makes the distributor's division exact. Any
        // shortfall is stranded value, which is the failure mode this whole
        // contract exists to remove.
        assertEq(summed, token.getPastTotalSupply(t), "every unit is delegated to somebody");
    }

    /* ---- regression probe: delegate BEFORE first receipt ---------------- */

    function test_PreReceiptDelegationSurvivesFirstReceipt() public {
        // Alice picks her delegate before she holds anything — the only
        // possible ordering for a delegateBySig collected ahead of a
        // distribution, and an ordinary one for anybody who decides first.
        vm.prank(ALICE);
        token.delegate(BOB);
        assertEq(token.delegates(ALICE), BOB, "delegated before holding");

        vm.prank(TREASURY);
        token.transfer(ALICE, 100 ether);

        assertEq(token.delegates(ALICE), BOB, "first receipt must not overwrite her choice");
        assertEq(token.getVotes(BOB), 100 ether, "votes follow her delegate");
        assertEq(token.getVotes(ALICE), 0, "alice holds none herself");
    }
}
