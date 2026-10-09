/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IRevShareHook} from "../interfaces/IRevShareHook.sol";
import {IEpochDistributor, EpochDistributorKind} from "../interfaces/IEpochDistributor.sol";

/// @title SnapshotEpochDistributor
/// @notice Route 3 for a token that CAN prove its own history: pay holders their exact pro-rata
/// share of an epoch's fees, computed on-chain from ERC-5805 checkpoints, with no root, no
/// off-chain job, and no trusted party anywhere in the flow.
///
/// @dev ############################ WHY THIS ONE IS TRUSTLESS ############################
///
/// `MerkleEpochDistributor` exists because a plain ERC20 cannot answer "who held this at block N".
/// An ERC20Votes / ERC-5805 token can: `getPastVotes(account, t)` and `getPastTotalSupply(t)` are
/// binary searches over checkpoints the token itself wrote. So `closeEpoch` records a timepoint,
/// and every claim derives its own amount:
///
///     payout = pot * getPastVotes(account, timepoint) / getPastTotalSupply(timepoint)
///
/// There is no admin function on this contract at all. Nobody posts anything, nobody can cancel
/// anything, and nobody can move an epoch's funds anywhere except to a holder who proves their own
/// balance. Prefer this variant whenever the token supports it.
///
/// ------------------------------- THE CATCH, STATED PLAINLY -------------------------------
///
/// THE NUMERATOR AND THE DENOMINATOR DO NOT MEASURE THE SAME THING, and that asymmetry is the
/// single most important fact about this contract:
///
///   * `getPastVotes(account, t)` counts DELEGATED VOTING UNITS. In OpenZeppelin's `ERC20Votes` a
///     holder who has never called `delegate` has `getPastVotes == 0` however large their balance.
///   * `getPastTotalSupply(t)` counts the token's TOTAL supply of voting units. `Votes` pushes to
///     `_totalCheckpoints` on mint and burn only - delegation never touches it - so undelegated
///     balances ARE in the denominator. OpenZeppelin says as much on the function itself: "this is
///     not necessarily the sum of all delegated votes".
///
/// So the numerators sum to the denominator only when every unit of supply is delegated, and are
/// strictly smaller otherwise. That direction is deliberate and must not be inverted: a denominator
/// that is always at least the sum of the numerators is what makes the epoch solvent BY
/// CONSTRUCTION, before the flooring and the escrow ceiling in `claim` are considered at all.
///
/// There is no on-chain fix. ERC-5805 exposes no total-delegated figure, and having the caller
/// supply the delegate set instead would let an incomplete list shrink the denominator, over-draw
/// the epoch and turn `claim` into a first-come-first-served race. Total supply is the only
/// denominator this contract can trust.
///
/// Consequences a deployment must own:
///   * Undelegated holders receive NOTHING, and their share is NOT redistributed to delegated
///     holders - nobody can claim it, so it sits in the epoch until `rollover` returns it to the
///     next one. No value is lost, but only `delegatedSupply / totalSupply` of each pot is paid
///     out per epoch and the rest churns. "All holders share the fees" is FALSE unless every
///     holder has self-delegated. Say "delegated holders" in the marketing copy, or - much better
///     - ship a token whose `_update` auto-delegates, which collapses the two figures into one.
///   * Watch this especially when the votes token is one of the pool's own currencies: the
///     liquidity parked in the Vault is undelegated supply sitting in the denominator.
///   * A token can be delegated to an address that cannot receive the payout currency. That
///     strands one holder's share until `rollover`, and affects nobody else - `claim` is pull.
///
/// ------------------------------- CLOCK HANDLING -------------------------------
///
/// The timepoint domain is the token's, not ours. ERC-6372 lets a token be block-numbered or
/// timestamped, and reading `getPastVotes` with the wrong domain silently returns garbage - a
/// timestamp is a far-future block number, which reverts, and a block number is a 1970 timestamp,
/// which returns the token's genesis state. So the constructor PROBES `clock()` and records the
/// answer instead of assuming, and falls back to `block.number` per ERC-6372's default only when
/// the token does not implement it. This is the "detect, don't assume" requirement, and it is the
/// single most likely thing to get silently wrong when integrating a new token.
/// ###############################################################################
contract SnapshotEpochDistributor is IEpochDistributor, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidHook();
    error InvalidPoolKey();
    error InvalidWindows();

    /// @notice The token does not implement the ERC-5805 read surface this contract needs.
    error TokenNotSnapshotCapable(address token);

    error EpochTooSoon(uint64 earliest);
    error NothingToDistribute();
    error NoVotingSupplyAtSnapshot(uint48 timepoint);
    error UnknownEpoch(uint256 epochId);
    error AlreadyClaimed(uint256 epochId, address account);
    error NothingToClaim(uint256 epochId, address account);
    error ClaimWindowClosed(uint256 epochId, uint64 expiresAt);
    error NotExpiredYet(uint256 epochId, uint64 expiresAt);
    error AlreadyRolledOver(uint256 epochId);
    error NativeNotAccepted();
    /// @notice `sweepSurplus` found nothing above the tracked escrow in either currency
    error NothingToSweep();

    /// @notice A claim for an account with code was submitted by someone other than that account.
    /// @dev See `claim`: a contract holder must claim for itself, so a holder that cannot is never
    /// paid into a dead end and its share rolls over instead.
    error ContractAccountMustClaimItself(address account, address caller);

    /// @notice `minEpochDuration` is below `MIN_EPOCH_DURATION_FLOOR`.
    error MinEpochDurationTooShort(uint64 provided, uint64 required);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shortest `minEpochDuration` this contract will accept at construction.
    ///
    /// @dev A floor against a DEGENERATE configuration, not a recommendation, and the one
    /// parameter that decides how cheap the snapshot-timing edge documented on `closeEpoch` is.
    /// `minEpochDuration` used to be validated not at all, so `0` was accepted - and a snapshot
    /// distributor with a zero cooldown can have its timepoint chosen by an attacker in EVERY
    /// block, for a holding period of one block each time. That parameter was load-bearing for a
    /// security property and enforced by nothing, which is the same shape as
    /// `ManualPriceBandOracle.minPublisherInterval` defaulting to zero. Pick days, not hours, on a
    /// thin token.
    uint64 public constant MIN_EPOCH_DURATION_FLOOR = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event EpochClosed(
        uint256 indexed epochId, uint48 timepoint, uint256 totalVotingSupply, uint256 amount0, uint256 amount1
    );
    event EpochClaimed(uint256 indexed epochId, address indexed account, uint256 amount0, uint256 amount1);
    event EpochRolledOver(uint256 indexed epochId, uint256 amount0, uint256 amount1);
    /// @notice Value found above the tracked escrow was moved into the next epoch's carry-over.
    event SurplusSwept(uint256 amount0, uint256 amount1);

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @param timepoint The token-clock timepoint holders are measured at.
    /// @param totalVotingSupply `getPastTotalSupply(timepoint)`, cached so a claim needs one fewer
    /// external call and so the denominator can never change under an epoch.
    struct Epoch {
        uint256 amount0;
        uint256 amount1;
        uint256 claimed0;
        uint256 claimed1;
        uint256 totalVotingSupply;
        uint48 timepoint;
        uint64 closedAt;
        uint64 expiresAt;
        bool rolledOver;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    IRevShareHook public immutable hook;

    /// @notice The ERC-5805 token whose holders are paid.
    IVotes public immutable token;

    /// @notice True when the token's clock is block-numbered, false when it is timestamped.
    bool public immutable clockIsBlockNumber;

    uint64 public immutable minEpochDuration;
    uint64 public immutable claimWindow;

    PoolKey internal _key;

    uint256 public epochCount;
    uint64 public lastCloseAt;

    uint256 public carryOver0;
    uint256 public carryOver1;

    /// @notice Everything this contract is meant to hold, per currency: every live epoch's unclaimed
    /// remainder plus the carry-over. Balance above it is surplus - see `sweepSurplus`.
    /// @dev Increments by exactly what `closeEpoch` pulls from the hook, decrements by exactly what
    /// `claim` pays; `rollover` moves value between an epoch and the carry-over and leaves it unchanged.
    uint256 public escrowed0;
    uint256 public escrowed1;

    mapping(uint256 epochId => Epoch) internal _epochs;
    mapping(uint256 epochId => mapping(address account => bool)) public claimed;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param token_ Must implement `getPastVotes` / `getPastTotalSupply`. Usually one of the
    /// pool's two currencies, but not required to be - a staked wrapper is a legitimate choice.
    constructor(
        IRevShareHook hook_,
        PoolKey memory key_,
        IVotes token_,
        uint64 minEpochDuration_,
        uint64 claimWindow_
    ) {
        if (address(hook_) == address(0)) revert InvalidHook();
        if (address(key_.hooks) != address(hook_)) revert InvalidPoolKey();
        if (claimWindow_ == 0) revert InvalidWindows();
        if (minEpochDuration_ < MIN_EPOCH_DURATION_FLOOR) {
            revert MinEpochDurationTooShort(minEpochDuration_, MIN_EPOCH_DURATION_FLOOR);
        }

        hook = hook_;
        _key = key_;
        token = token_;
        minEpochDuration = minEpochDuration_;
        claimWindow = claimWindow_;

        // The cooldown clock starts at deployment, not at the first close. `closeEpoch` used to
        // exempt epoch 0 entirely (`epochCount != 0 && ...`) because with `lastCloseAt == 0` the
        // comparison was against a 1970 timestamp and could never bite - which meant the very
        // first snapshot, the one nobody is watching for yet, was the one with no cooldown at all.
        lastCloseAt = uint64(block.timestamp);

        // DETECT, DO NOT ASSUME. ERC-6372 says a token without `clock()` is block-numbered.
        bool isBlockNumber = true;
        try IERC6372(address(token_)).clock() returns (uint48 clockValue) {
            // A clock within a block of `block.number` is a block clock; one within a block of
            // `block.timestamp` is a timestamp clock. On any live chain these two are separated by
            // orders of magnitude, so the test is unambiguous.
            isBlockNumber = _near(clockValue, block.number);
            if (!isBlockNumber && !_near(clockValue, block.timestamp)) {
                revert TokenNotSnapshotCapable(address(token_));
            }
        } catch {
            isBlockNumber = true;
        }
        clockIsBlockNumber = isBlockNumber;

        // Probe the read surface itself, so a token that is simply not an ERC20Votes fails here
        // rather than at the first `closeEpoch` with a pot already pulled out of the hook.
        uint256 probe = isBlockNumber ? block.number : block.timestamp;
        if (probe == 0) revert TokenNotSnapshotCapable(address(token_));
        try token_.getPastTotalSupply(probe - 1) returns (uint256) {}
        catch {
            revert TokenNotSnapshotCapable(address(token_));
        }
    }

    /// @notice Accepts native currency pulled from the hook. See `MerkleEpochDistributor`.
    receive() external payable {
        if (msg.sender != address(hook)) revert NativeNotAccepted();
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEpochDistributor
    /// @dev The `Epoch` returned by `getEpoch` below is nine all-static fields, and so is the
    /// merkle distributor's. Decoding one with the other's ABI therefore SUCCEEDS and hands back
    /// this contract's `totalVotingSupply` as a merkle root, or a root as a voting supply. This is
    /// the call that stops that happening; there is nothing further down this file that will.
    function kind() external pure returns (bytes32) {
        return EpochDistributorKind.SNAPSHOT;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function poolId() public view returns (PoolId) {
        return _key.toId();
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        return _epochs[epochId];
    }

    /// @notice The token clock's current value, in whichever domain the token uses.
    function clock() public view returns (uint48) {
        return clockIsBlockNumber ? uint48(block.number) : uint48(block.timestamp);
    }

    /// @notice What `account` would receive from `epochId`, ignoring whether it has claimed.
    function claimableAmounts(uint256 epochId, address account)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        Epoch storage epoch = _epochs[epochId];
        uint256 votes = token.getPastVotes(account, epoch.timepoint);
        if (votes == 0) return (0, 0);
        amount0 = Math.mulDiv(epoch.amount0, votes, epoch.totalVotingSupply);
        amount1 = Math.mulDiv(epoch.amount1, votes, epoch.totalVotingSupply);
    }

    /*//////////////////////////////////////////////////////////////
                                 EPOCHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Close the current epoch, snapshotting the token's voting supply one tick back.
    ///
    /// @dev Permissionless and admin-free. `timepoint = clock() - 1` because ERC-5805 rejects a
    /// lookup at or after the current timepoint: the current block is still mutable.
    ///
    /// ################## THE ATTACKER CHOOSES THE SNAPSHOT MOMENT ##################
    ///
    /// This function is permissionless AND it is what fixes the timepoint, so the two facts
    /// compose into a real, un-removable edge, stated here rather than left for a reader to find:
    ///
    ///   1. Wait until `lastCloseAt + minEpochDuration` has passed and the pot is worth taking -
    ///      it is a public number, `RevShareHook.pendingDistributorShare`.
    ///   2. Buy a large position in block N.
    ///   3. Call `closeEpoch()` in block N+1. `timepoint == N`, which captures step 2.
    ///   4. Claim, then sell.
    ///
    /// It CANNOT be done in one transaction: closing in block N snapshots N-1, before the buy, so
    /// the position must survive a block boundary and no flash loan reaches it. One block of price
    /// risk plus the round trip's own slippage is the entire cost, which is thin on an illiquid
    /// token and is the honest statement of the risk. `DeepCoreVotes` makes it cheaper still, on
    /// purpose: it auto-delegates on first receipt, so a buyer has voting units in the same block
    /// they have tokens, with no delegation lag to sit through.
    ///
    /// WHAT IT IS WORTH, AND WHY THIS DESIGN WAS KEPT. A sniper holding share `s` of supply takes
    /// `s` of one epoch. Doing it every epoch takes `s` of ALL fees - exactly what an honest holder
    /// of `s` receives for holding continuously. The theft is not of quantity, it is of RISK: the
    /// sniper is paid a continuous holder's dividend for one block of exposure per epoch, and
    /// honest holders are diluted by however much snipers hold at each close.
    ///
    /// THE ALTERNATIVE THAT LOOKS BETTER AND IS NOT. Recording the NEXT epoch's timepoint at the
    /// PREVIOUS close would fix the eligible set before the fees it will be paid accrue. It was
    /// rejected on three counts, and the first is the one that settles it:
    ///
    ///   * IT DOES NOT CHANGE THE ATTACKER'S EXPOSURE. The close that records the next timepoint is
    ///     itself permissionless, so the same buy-in-N, close-in-N+1 sequence lands the attacker in
    ///     the pre-recorded set - and, once recorded, they may SELL IMMEDIATELY and still claim an
    ///     epoch that closes a full `minEpochDuration` later. One block of exposure, as now. What
    ///     changes is that they must bet on a future pot instead of seeing the present one, which
    ///     lowers expected value but does not remove the attack.
    ///   * IT SEALS THE SET. Today a large honest buyer before the close dilutes a sniper. Under a
    ///     pre-recorded timepoint nobody can dilute anybody, and a mid-epoch buyer earns nothing
    ///     for a whole epoch.
    ///   * IT CREATES A PERMANENT LIVENESS HAZARD. The recorded timepoint is in the past and cannot
    ///     be moved. If voting supply was zero at that timepoint, `NoVotingSupplyAtSnapshot` fires
    ///     on every future `closeEpoch` and the distributor is bricked with no escape hatch -
    ///     trading a bounded economic edge for an unbounded availability failure.
    ///
    /// SO THE MITIGATION IS `minEpochDuration`, AND IT IS NOW ENFORCED RATHER THAN ADVISED. It caps
    /// how often the trick can be repeated, and it is the only lever that does. It was previously
    /// unvalidated - `0` was accepted, and the first close was exempt from it outright - so the one
    /// parameter carrying a security property was guaranteed by a comment. See
    /// `MIN_EPOCH_DURATION_FLOOR`, and set days rather than hours on a thin token.
    function closeEpoch() external nonReentrant returns (uint256 epochId) {
        // `lastCloseAt` is seeded at construction, so the first close waits exactly like every
        // other one. There is no first-epoch exemption.
        uint64 earliest = lastCloseAt + minEpochDuration;
        if (block.timestamp < earliest) revert EpochTooSoon(earliest);

        uint48 timepoint = clock() - 1;
        // Total supply of voting units at the snapshot, NOT the delegated subset - see the notes at
        // the top of this file. It is an upper bound on the sum of every holder's `getPastVotes`,
        // which is what keeps the epoch solvent whatever the token's delegation state.
        uint256 supply = token.getPastTotalSupply(timepoint);
        // No supply at all, so there is no denominator and no honest way to split the pot.
        // Reverting leaves the value in the hook, where a later epoch can still distribute it.
        // Note this does NOT catch "supply exists but nobody delegated": that case closes an epoch
        // nobody can claim, which costs nothing because `rollover` returns the pot intact.
        if (supply == 0) revert NoVotingSupplyAtSnapshot(timepoint);

        // Carry-over is consumed before the external pull; see `MerkleEpochDistributor`.
        uint256 amount0 = carryOver0;
        uint256 amount1 = carryOver1;
        carryOver0 = 0;
        carryOver1 = 0;

        uint256 pulled0 = hook.pullDistributorShare(_key, _key.currency0);
        uint256 pulled1 = hook.pullDistributorShare(_key, _key.currency1);
        amount0 += pulled0;
        amount1 += pulled1;
        escrowed0 += pulled0;
        escrowed1 += pulled1;
        if (amount0 == 0 && amount1 == 0) revert NothingToDistribute();

        epochId = epochCount;
        epochCount = epochId + 1;
        lastCloseAt = uint64(block.timestamp);

        Epoch storage epoch = _epochs[epochId];
        epoch.amount0 = amount0;
        epoch.amount1 = amount1;
        epoch.totalVotingSupply = supply;
        epoch.timepoint = timepoint;
        epoch.closedAt = uint64(block.timestamp);
        epoch.expiresAt = uint64(block.timestamp) + claimWindow;

        emit EpochClosed(epochId, timepoint, supply, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim `account`'s pro-rata share of `epochId`. `account` is always the one paid.
    ///
    /// @dev ############ WHO MAY SUBMIT, AND WHY IT IS NOT "ANYONE" ############
    ///
    /// This used to be callable by anyone for any `account`. Paired with `DeepCoreVotes`, which
    /// auto-delegates to EVERY first receiver including contracts, that let a stranger claim the
    /// share of an address that can never spend it - the Vault (which holds every pool's
    /// liquidity, often the largest holder), `RevShareHook` after `redeem`, this distributor itself,
    /// a router - and so move real holder money into a permanent dead end, every epoch, for gas.
    /// Left unclaimed, that same share would have reached real holders through `rollover`.
    ///
    /// The rule is deliberately about CODE rather than a list of known sinks, because the set of
    /// contracts that ever received the token is open-ended:
    ///   * an account WITH code must submit its own claim (`msg.sender == account`). A contract
    ///     that can claim can also use the payout; one that cannot claim is never paid and its
    ///     share rolls over. Smart-contract wallets (Safes, EIP-7702 delegated EOAs) call it
    ///     themselves.
    ///   * an account WITHOUT code may still be claimed for by anyone - a claim bot or a gas
    ///     sponsor - because a key holder can always move what it receives. Payout stays
    ///     hard-wired to `account`, so a sponsor can never redirect it.
    /// Residual: a counterfactual address (code deployed later) can be claimed for while empty.
    /// Whoever controls that address chose to hold votes there.
    ///
    /// Rounding floors both amounts, so the sum of all claims is never more than the pot and
    /// the epoch cannot be over-drawn even before the escrow ceiling below. The floor remainder is
    /// picked up by `rollover`.
    function claim(uint256 epochId, address account) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (msg.sender != account && account.code.length != 0) {
            revert ContractAccountMustClaimItself(account, msg.sender);
        }
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        Epoch storage epoch = _epochs[epochId];

        if (block.timestamp >= epoch.expiresAt) revert ClaimWindowClosed(epochId, epoch.expiresAt);
        if (claimed[epochId][account]) revert AlreadyClaimed(epochId, account);

        uint256 votes = token.getPastVotes(account, epoch.timepoint);
        if (votes == 0) revert NothingToClaim(epochId, account);

        amount0 = Math.mulDiv(epoch.amount0, votes, epoch.totalVotingSupply);
        amount1 = Math.mulDiv(epoch.amount1, votes, epoch.totalVotingSupply);
        if (amount0 == 0 && amount1 == 0) revert NothingToClaim(epochId, account);

        // ---- effects ----
        claimed[epochId][account] = true;
        uint256 newClaimed0 = epoch.claimed0 + amount0;
        uint256 newClaimed1 = epoch.claimed1 + amount1;
        // Belt and braces on top of the flooring above: an epoch can never pay out more than it
        // escrowed, whatever the token's checkpoints say.
        if (newClaimed0 > epoch.amount0) {
            amount0 = epoch.amount0 - epoch.claimed0;
            newClaimed0 = epoch.amount0;
        }
        if (newClaimed1 > epoch.amount1) {
            amount1 = epoch.amount1 - epoch.claimed1;
            newClaimed1 = epoch.amount1;
        }
        epoch.claimed0 = newClaimed0;
        epoch.claimed1 = newClaimed1;
        escrowed0 -= amount0;
        escrowed1 -= amount1;

        // ---- interactions ----
        if (amount0 != 0) _key.currency0.transfer(account, amount0);
        if (amount1 != 0) _key.currency1.transfer(account, amount1);

        emit EpochClaimed(epochId, account, amount0, amount1);
    }

    /// @notice Return an expired epoch's unclaimed remainder to the next epoch's holders.
    function rollover(uint256 epochId) external nonReentrant {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        Epoch storage epoch = _epochs[epochId];
        if (epoch.rolledOver) revert AlreadyRolledOver(epochId);
        if (block.timestamp < epoch.expiresAt) revert NotExpiredYet(epochId, epoch.expiresAt);

        uint256 remainder0 = epoch.amount0 - epoch.claimed0;
        uint256 remainder1 = epoch.amount1 - epoch.claimed1;

        epoch.rolledOver = true;
        epoch.amount0 = epoch.claimed0;
        epoch.amount1 = epoch.claimed1;

        carryOver0 += remainder0;
        carryOver1 += remainder1;

        emit EpochRolledOver(epochId, remainder0, remainder1);
    }

    /// @notice Move anything this contract holds ABOVE its tracked escrow into the next epoch's
    /// carry-over, so a token sent here by mistake reaches holders instead of staying stuck.
    ///
    /// @dev Permissionless and admin-free like `closeEpoch` and `rollover`: there is no owner to pay
    /// and no recipient to choose, the surplus simply becomes holder money at the next close. It can
    /// never touch escrowed value - `escrowed0/1` is exactly what every live epoch and the carry-over
    /// are owed, and only the balance above it moves. Native can only exceed the escrow if it was
    /// forced in (`receive` refuses everyone but the hook). Acceptance finding L-1, 2026-09-18.
    function sweepSurplus() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 held0 = _key.currency0.balanceOfSelf();
        uint256 held1 = _key.currency1.balanceOfSelf();
        amount0 = held0 > escrowed0 ? held0 - escrowed0 : 0;
        amount1 = held1 > escrowed1 ? held1 - escrowed1 : 0;
        if (amount0 == 0 && amount1 == 0) revert NothingToSweep();

        carryOver0 += amount0;
        carryOver1 += amount1;
        escrowed0 += amount0;
        escrowed1 += amount1;

        emit SurplusSwept(amount0, amount1);
    }

    /// @dev True when `a` and `b` are within one unit of each other. Used only to tell a block
    /// clock from a timestamp clock, which differ by many orders of magnitude on any real chain.
    function _near(uint256 a, uint256 b) private pure returns (bool) {
        return a > b ? a - b <= 1 : b - a <= 1;
    }
}
