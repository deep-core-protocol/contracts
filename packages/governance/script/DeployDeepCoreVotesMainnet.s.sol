// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {DeepCoreVotes} from "../src/DeepCoreVotes.sol";

/**
 * Deploys `DeepCoreVotes` and mints the entire supply to the governance Safe.
 *
 * WHAT THIS SCRIPT CANNOT UNDO, and therefore checks first. The supply is
 * fixed at construction and there is no mint, no owner and no upgrade path. A
 * wrong recipient or a wrong supply is not a misconfiguration to be corrected
 * later — it is a token that has to be abandoned and redeployed, along with
 * every distributor already pointed at it. So every parameter is asserted
 * before the broadcast and every consequence is read back after it.
 *
 * THE RECIPIENT MUST HAVE CODE. The treasury is a Safe. A typo in an address
 * almost always lands on an EOA or on nothing at all, and minting a fixed
 * supply to an address nobody controls is unrecoverable in the most literal
 * sense. `code.length > 0` will not catch every mistake, but it catches the
 * whole class of mistakes that look like a correct address.
 *
 * SUPPLY IS REQUIRED FROM THE ENVIRONMENT, deliberately without a default. A
 * default supply is a number nobody decided, and this one can never be changed.
 *
 * WHAT THIS SCRIPT DOES NOT DO. It does not deploy a distributor and it does
 * not touch `RevShareHook`. `SnapshotEpochDistributor` binds a PoolKey in its
 * own constructor, so it belongs to a pool, not to the token — see
 * `packages/hooks-revshare/script/DeploySnapshotDistributorMainnet.s.sol`.
 * Pointing a live pool at a distributor is a third, separate act that costs
 * `CONFIG_DELAY_BLOCKS` on an already-configured pool.
 *
 * Usage:
 *   VOTES_NAME="DeepCore Votes" VOTES_SYMBOL=DEEPCORE \
 *   VOTES_TREASURY=<governance Safe> \
 *   VOTES_SUPPLY=1000000000000000000000000 \
 *   forge script script/DeployDeepCoreVotesMainnet.s.sol --rpc-url $RPC --broadcast --slow
 */
contract DeployDeepCoreVotesMainnetScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory name_ = vm.envString("VOTES_NAME");
        string memory symbol_ = vm.envString("VOTES_SYMBOL");
        address treasury = vm.envAddress("VOTES_TREASURY");
        uint256 supply = vm.envUint("VOTES_SUPPLY");

        /* ---- assertions before anything irreversible happens ------------- */

        require(treasury != address(0), "VOTES_TREASURY not set");
        require(
            treasury.code.length > 0,
            "VOTES_TREASURY has no code - expected the governance Safe, not an EOA"
        );
        require(treasury != deployer, "VOTES_TREASURY must not be the deployer");
        require(supply > 0, "VOTES_SUPPLY not set");
        require(bytes(name_).length > 0 && bytes(symbol_).length > 0, "name/symbol not set");

        console.log("=== DeepCoreVotes ===");
        console.log("  deployer  ", deployer);
        console.log("  treasury  ", treasury);
        console.log("  supply    ", supply);
        console.log("");

        vm.startBroadcast(pk);
        DeepCoreVotes token = new DeepCoreVotes(name_, symbol_, treasury, supply);
        vm.stopBroadcast();

        /* ---- read back the deployed reality, not the intent -------------- */

        require(token.totalSupply() == supply, "supply mismatch");
        require(token.balanceOf(treasury) == supply, "treasury did not receive the supply");
        require(token.balanceOf(deployer) == 0, "deployer holds tokens - it must hold nothing");

        /* The whole reason this contract exists. If delegation did not happen
           in the constructor, every epoch measured against this token pays
           nobody and reverts nothing — see the header of DeepCoreVotes.sol. It is
           checked here because it is invisible on a block explorer: balance
           and supply would both look correct. */
        require(token.delegates(treasury) == treasury, "treasury is not self-delegated");
        require(token.getVotes(treasury) == supply, "treasury has no voting power");
        require(token.hasAutoDelegated(treasury), "one-time assignment not spent");

        console.log("DeepCoreVotes            ", address(token));
        console.log("  name                ", token.name());
        console.log("  symbol              ", token.symbol());
        console.log("  totalSupply         ", token.totalSupply());
        console.log("  treasury balance    ", token.balanceOf(treasury));
        console.log("  treasury votes      ", token.getVotes(treasury));
        console.log("  delegate            ", token.delegates(treasury));
        console.log("  clock mode          ", token.CLOCK_MODE());
        console.log("");
        console.log("Fixed supply. No mint, no owner, no upgrade path.");
        console.log("");
        /* Precise, because the imprecise version is misleading in both
           directions. The delegation IS effective at this block —
           test_DelegationIsEffectiveAtTheMintBlock asserts getPastVotes at the
           mint block equals the full supply. What cannot happen is READING it
           yet: OpenZeppelin's getPastVotes reverts unless the timepoint is
           strictly in the past. So the constraint is one block of latency on
           the read, not a window in which the numbers are wrong. */
        console.log("NEXT: getPastVotes reverts on a timepoint that is not strictly in the past,");
        console.log("so let one block pass before closing an epoch. The delegation itself is");
        console.log("already effective at this block - there is no window of zero voting power.");
    }
}
