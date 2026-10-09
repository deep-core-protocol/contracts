/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * The snapshot token `SnapshotEpochDistributor` measures holders against.
 *
 * WHY AUTO-DELEGATION IS NOT A CONVENIENCE. In OpenZeppelin's `Votes`,
 * `_transferVotingUnits` pushes to `_totalCheckpoints` only when `from` or `to`
 * is the zero address — that is, on mint and burn. So `getPastTotalSupply`
 * tracks TOTAL SUPPLY, while `getPastVotes` tracks DELEGATED voting units.
 * The two are different quantities, and the gap between them is silent.
 *
 * Run that through the distributor's formula:
 *
 *     payout = pot * getPastVotes(account, t) / getPastTotalSupply(t)
 *
 * A treasury holding 100% of an UNDELEGATED supply gives
 * `getPastTotalSupply = supply` (non-zero, so `NoVotingSupplyAtSnapshot` never
 * fires) and `getPastVotes = 0` (so every `claim` reverts `NothingToClaim`).
 * The epoch does not fail. It quietly pays nobody, and the entire pot sits
 * until somebody calls `rollover`. There is no error to notice and no event
 * that says "these funds were forfeited by a configuration mistake".
 *
 * That failure is one forgotten transaction away on any token without this
 * override, and it is worse for a multisig than for an EOA: a Safe would have
 * to collect a threshold of signatures for `delegate()` before the first epoch
 * closed, for a call that does nothing a holder can see. So delegation happens
 * here, on first receipt, where it cannot be forgotten.
 *
 * A HOLDER'S OWN CHOICE ALWAYS WINS, WHENEVER THEY MAKE IT. `_hasAutoDelegated`
 * records that the one-time assignment has been SPENT — not that the account
 * currently delegates to itself — and it is spent by any delegation, automatic
 * or deliberate. That is why `_delegate` is overridden rather than only
 * `_update`: OpenZeppelin routes `delegate` and `delegateBySig` through
 * `_delegate` without passing through `_update` at all, so a flag maintained
 * only on receipt misses both.
 *
 * The ordering that exposes it is not exotic. Somebody picks a delegate before
 * they hold anything — which is the ONLY possible ordering for a
 * `delegateBySig` gathered ahead of a distribution — and their first receipt
 * then resets them to self, emitting `DelegateChanged` and `AutoDelegated` as
 * though that were intended. Their dividend quietly stops going where they
 * sent it, because `SnapshotEpochDistributor` pays on votes, not on balance.
 *
 * The same rule makes opting out permanent: `delegate(address(0))` spends the
 * assignment, so later receipts do not re-delegate. A holder who chooses to
 * hold no voting power forfeits their share of each epoch to the rollover,
 * which is their decision to make.
 *
 * Dusting is therefore not a grief. An unsolicited transfer spends the
 * automatic assignment, but the recipient can still call `delegate` freely
 * afterwards — the flag only ever suppresses a FUTURE automatic assignment,
 * never a person's instruction.
 *
 * FIXED SUPPLY. There is no `mint`, no owner, no role and no upgrade path.
 * Supply is minted once, in the constructor, and that is the whole of it.
 *
 * The alternative — an ownable mint behind the governance Safe — would put an
 * inflation key in the hands of the same address that receives distributions,
 * able to dilute every other holder's claim on every future epoch without
 * touching the distributor at all. A snapshot distributor is only as honest as
 * the supply it measures against, so the supply is not something anybody gets
 * to change.
 *
 * CLOCK. `clock()` is left at OpenZeppelin's default of `block.number`.
 * `SnapshotEpochDistributor`'s constructor probes ERC-6372 and records the
 * domain, so this contract does not need to agree with anything by convention
 * — but block numbers are the safer default on a chain whose timestamps are
 * proposer-influenced, and an epoch boundary is exactly the kind of thing
 * worth not letting a proposer nudge.
 */
contract DeepCoreVotes is ERC20, ERC20Votes {
    /// @dev Thrown when the constructor is handed no recipient or no supply —
    ///      either produces a token that can never satisfy a snapshot.
    error InvalidTreasury();
    error ZeroSupply();

    /// @notice Emitted once per account, the first time it receives tokens.
    /// @dev Distinct from `DelegateChanged` so an indexer can tell an automatic
    ///      assignment apart from a holder's own decision.
    event AutoDelegated(address indexed account);

    /// @dev True once an account's one-time automatic assignment has been
    ///      SPENT — by `_update` on first receipt, or by the holder's own
    ///      `delegate` / `delegateBySig`, whichever comes first. Never cleared,
    ///      and NOT a statement about who the account currently delegates to.
    mapping(address account => bool) private _hasAutoDelegated;

    /**
     * @param name_     Token name.
     * @param symbol_   Token symbol.
     * @param treasury  Receives the entire supply. Self-delegates on receipt.
     * @param supply    Total supply, in wei. Fixed forever.
     */
    constructor(string memory name_, string memory symbol_, address treasury, uint256 supply)
        ERC20(name_, symbol_)
        EIP712(name_, "1")
    {
        if (treasury == address(0)) revert InvalidTreasury();
        if (supply == 0) revert ZeroSupply();

        // `_mint` routes through `_update` below, so the treasury is delegated
        // before this constructor returns. There is no block in which the
        // supply exists with zero voting power behind it.
        _mint(treasury, supply);
    }

    /// @notice Whether `account` has already had its one-time self-delegation.
    /// @dev Exposed so the deploy script can assert the treasury was delegated
    ///      rather than trusting that `_mint` did what this contract claims.
    function hasAutoDelegated(address account) external view returns (bool) {
        return _hasAutoDelegated[account];
    }

    /**
     * @dev Delegation is applied AFTER `super._update`, so the balance is
     *      already credited when `_delegate` moves voting units. Delegating
     *      first would move zero units and leave the account with a delegate
     *      and no votes until its next transfer — the exact silent-zero bug
     *      this override exists to prevent.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);

        // Burns (`to == 0`) are not receipts and must not create a delegation.
        if (to != address(0) && !_hasAutoDelegated[to]) {
            // `_delegate` below sets the flag; setting it here too would be
            // redundant. The event is emitted here because only this path
            // knows the delegation was automatic rather than instructed.
            _delegate(to, to);
            emit AutoDelegated(to);
        }
    }

    /**
     * @dev Every delegation spends the one-time automatic assignment,
     *      including `delegate` and `delegateBySig`, which OpenZeppelin routes
     *      here WITHOUT going through `_update`. Tracking the flag only on
     *      receipt would let a first transfer overwrite a delegation the
     *      holder had already chosen — see the contract header.
     */
    function _delegate(address account, address delegatee) internal override {
        _hasAutoDelegated[account] = true;
        super._delegate(account, delegatee);
    }
}
