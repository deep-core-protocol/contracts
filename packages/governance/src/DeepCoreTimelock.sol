/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DeepCoreTimelock
/// @notice The delay that sits between the governance multisig and any privileged protocol call.
///
/// @dev ####################### WHY THIS EXISTS RATHER THAN RAW OZ #######################
///
/// OpenZeppelin's `TimelockController` accepts `minDelay = 0` with no validation. A timelock
/// deployed that way looks correct on a block explorer, exposes the same interface, emits the
/// same events, and delays nothing. That is the single easiest way to ship governance theatre,
/// so this subclass refuses a delay below a floor chosen for the tier it protects.
///
/// ####################### WHY TWO TIMELOCKS, NOT ONE #######################
///
/// Delay should be proportional to how hard an action is to undo, and DeepCore has two very
/// different tiers:
///
///   CUSTODY tier — owns Vault and the pool managers.
///     `Vault.registerApp` is `onlyOwner` and IRREVERSIBLE: there is no unregister function
///     anywhere in the Vault or its interface. A registered app can move funds against the
///     Vault permanently. A mistake here cannot be walked back by governance at any speed, so
///     the only real defence is a window long enough for the public to notice and for users to
///     exit. Hence CUSTODY_MIN_DELAY.
///
///   POLICY tier — owns the protocol fee controller.
///     Fee changes are fully reversible and occasionally need to respond to market conditions.
///     A multi-day delay on a fee tweak buys nothing and creates pressure to hand someone an
///     emergency bypass, which is worse. Hence the shorter POLICY_MIN_DELAY.
///
/// These are separate contracts with separate owners, which is what makes two delays possible
/// at all — `Vault` has a single owner slot, so one timelock owning it means one delay for
/// everything it controls.
///
/// ####################### WHAT A TIMELOCK MUST NOT DELAY #######################
///
/// Delay belongs on privilege ESCALATION, never on privilege REDUCTION. If the only path to
/// switching protocol fees off runs through a two-day queue, then during an incident the
/// protocol keeps charging for two days. That is why `DeepCoreProtocolFeeController` carries a
/// separate guardian that can disable fees immediately but can never enable them, raise them,
/// or change any configuration. The guardian can only ever make the protocol take less.
///
/// Do not add powers to the guardian. Anything that can increase what the protocol takes, or
/// change who controls it, belongs behind this timelock.
///
/// ####################### ONE TIER IS DEPLOYED, NOT TWO #######################
///
/// The `Tier` enum and `POLICY_MIN_DELAY` below are retained, and a Policy timelock still
/// constructs correctly - but only the CUSTODY tier is deployed. Everything the ownership table
/// previously routed through a 6h Policy timelock is now held by the governance Safe directly.
///
/// The reasoning is about who governance is FOR. A delay between a multisig and a privileged call
/// is a check on the signers, and with a single operator there are no other signers to check. What
/// survives that reframing is (a) surviving a stolen key and (b) being a credible base for a
/// tenant who would otherwise fork. Both of those are about IRREVERSIBLE authority -
/// `Vault.registerApp` and pool-manager ownership - and neither is served by queueing a fee tweak
/// or a registry role grant, which are reversible, custody nothing, and cost agility to delay.
/// Reality had already drifted this way: `DEFAULT_ADMIN_ROLE` on the live registry is the Safe,
/// and the deployed Policy timelock holds nothing at all.
///
/// The type is kept whole because a second tier is a reasonable thing to want back the moment
/// there is a second signer. Deploying one is then a script change, not a contract change.
///
/// ####################### WHO CAN CANCEL #######################
///
/// `TimelockController` grants `CANCELLER_ROLE` to proposers and to nobody else. With the Safe as
/// sole proposer that means a 2-of-3 compromise which queues `updateDelay(0)` buys the public 48
/// hours of VISIBILITY with no party able to act on it - a delay that announces the attack and
/// then executes it. So the canceller is an explicit, separate constructor argument.
///
/// It is the right key to hold alone, for a reason that is structural rather than procedural: its
/// only power is REFUSAL. Losing it costs nothing that a redeploy of the role cannot restore, and
/// stealing it achieves nothing beyond griefing - a thief can veto honest operations and can never
/// cause one. That asymmetry is what makes a veto safe to hold on a hot key when the proposer is
/// not.
/// #####################################################################################
contract DeepCoreTimelock is TimelockController {
    /// @notice Minimum delay for the tier that owns the Vault and pool managers.
    /// @dev 48h. Sized so that `registerApp` — irreversible, and able to move Vault funds
    /// forever — cannot be executed inside a single news cycle.
    uint256 public constant CUSTODY_MIN_DELAY = 48 hours;

    /// @notice Minimum delay for the tier that owns fee policy.
    /// @dev 6h. Long enough to be observed and contested, short enough that nobody argues for
    /// an emergency bypass around it.
    uint256 public constant POLICY_MIN_DELAY = 6 hours;

    /// @notice Tier this timelock was deployed for.
    enum Tier {
        Custody,
        Policy
    }

    /// @notice The tier, fixed at deployment.
    Tier public immutable tier;

    /// @notice Delay is below the floor for the chosen tier
    error DelayBelowTierFloor(Tier tier, uint256 provided, uint256 required);

    /// @notice A timelock with no proposer can never do anything
    error NoProposers();

    /// @notice A timelock with no executor can never execute what it queues
    error NoExecutors();

    /// @notice A proposer entry is the zero address
    /// @dev Length alone was checked, which a `[address(0)]` array passes. `schedule` is gated on
    /// `onlyRole`, NOT `onlyRoleOrOpenRole`, so a zero proposer is a DEAD role rather than an open
    /// one: the timelock would look correctly configured, pass `NoProposers`, and be unable to
    /// queue anything for anybody. It also silently hands `CANCELLER_ROLE` to nobody, because OZ
    /// grants that to each proposer.
    error ZeroProposer();

    /// @notice The canceller is the zero address
    /// @dev Rejected for the same reason as `ZeroProposer`, and with a sharper consequence: a zero
    /// canceller reproduces exactly the hole this argument exists to close, while making the
    /// deployment look like it had been closed.
    error ZeroCanceller();

    /// @notice The canceller is also a proposer, so a compromised proposer can veto its own veto
    error CancellerMustNotBeAProposer(address canceller);

    /// @dev The OZ optional `admin` is hardcoded to address(0). An admin can grant and revoke
    /// roles directly, which is a permanent backdoor around every delay this contract enforces.
    /// It is not a constructor parameter because it should never be a deployment decision.
    /// @param tier_ Custody (Vault, pool managers) or Policy (retained; not deployed — see the
    /// contract header)
    /// @param minDelay Seconds of delay; must meet the floor for `tier_`
    /// @param proposers Addresses allowed to queue operations — the governance multisig
    /// @param executors Addresses allowed to execute a matured operation. Passing address(0)
    /// makes execution permissionless, which is usually correct: once an operation has survived
    /// its delay in public, anyone executing it is harmless, and it removes the multisig as a
    /// liveness dependency.
    /// @param canceller An address whose ONLY power is to cancel a queued operation, independent
    /// of the proposer set. Must be non-zero and must not be a proposer. OZ additionally grants
    /// `CANCELLER_ROLE` to every proposer; that is left alone, because a proposer cancelling its
    /// own mistake is useful and cancelling is never an escalation.
    constructor(
        Tier tier_,
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address canceller
    ) TimelockController(minDelay, proposers, executors, address(0)) {
        uint256 floor = tier_ == Tier.Custody ? CUSTODY_MIN_DELAY : POLICY_MIN_DELAY;
        if (minDelay < floor) revert DelayBelowTierFloor(tier_, minDelay, floor);
        if (proposers.length == 0) revert NoProposers();
        if (executors.length == 0) revert NoExecutors();
        if (canceller == address(0)) revert ZeroCanceller();

        for (uint256 i = 0; i < proposers.length; ++i) {
            if (proposers[i] == address(0)) revert ZeroProposer();
            if (proposers[i] == canceller) revert CancellerMustNotBeAProposer(canceller);
        }

        _grantRole(CANCELLER_ROLE, canceller);

        tier = tier_;
    }

    /// @notice The floor enforced for this timelock's tier.
    /*//////////////////////////////////////////////////////////////
                 THE ROLES THAT MAKE THE TIMELOCK A TIMELOCK (audit C, 2026-10-07)
    //////////////////////////////////////////////////////////////*/

    /// @notice A role whose loss would end governance is not renounceable, and its last holder cannot
    /// be revoked. Without this, OpenZeppelin lets the sole proposer call `renounceRole(PROPOSER_ROLE)`
    /// DIRECTLY — no 48 h queue, no canceller — and since the timelock is its own admin, nobody could
    /// ever grant a proposer again: no `registerApp`, no `unpausePoolManager`, forever. The same brick
    /// as the `renounceOwnership` hazard, one level up. `DeepCoreRegistry` already refuses the same
    /// on its admin role.
    error RoleIsNotRenounceable(bytes32 role);
    error LastHolderCannotBeRemoved(bytes32 role);

    /// @notice How many accounts hold PROPOSER_ROLE / EXECUTOR_ROLE (TimelockController's AccessControl
    /// is not enumerable, so the count is kept here, written only through `_grantRole`/`_revokeRole`).
    mapping(bytes32 role => uint256) public roleHolderCount;

    function _isLoadBearing(bytes32 role) internal pure returns (bool) {
        return role == PROPOSER_ROLE || role == EXECUTOR_ROLE || role == DEFAULT_ADMIN_ROLE;
    }

    /// @dev Refuses the load-bearing roles outright. The canceller may still renounce: its only power
    /// is refusal, and a replacement is one queued `grantRole` away.
    function renounceRole(bytes32 role, address callerConfirmation) public virtual override {
        if (_isLoadBearing(role)) revert RoleIsNotRenounceable(role);
        super.renounceRole(role, callerConfirmation);
    }

    function _grantRole(bytes32 role, address account) internal virtual override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && _isLoadBearing(role)) roleHolderCount[role] += 1;
    }

    /// @dev A queued `revokeRole` is allowed — rotating the Safe is legitimate governance — but never
    /// to zero holders: grant the successor first, revoke the predecessor after.
    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool revoked) {
        if (_isLoadBearing(role) && hasRole(role, account) && roleHolderCount[role] <= 1) {
            revert LastHolderCannotBeRemoved(role);
        }
        revoked = super._revokeRole(role, account);
        if (revoked && _isLoadBearing(role)) roleHolderCount[role] -= 1;
    }

    function minDelayFloor() public view returns (uint256) {
        return tier == Tier.Custody ? CUSTODY_MIN_DELAY : POLICY_MIN_DELAY;
    }

    /**
     * THE TIER FLOOR, RE-APPLIED ON EVERY READ.
     *
     * `TimelockController._schedule` calls `getMinDelay()` rather than reading its storage
     * directly, so overriding this is what makes the floor a property of the contract instead of a
     * one-off constructor check. Even if `_minDelay` were somehow driven below the floor, every
     * subsequent `schedule` would still demand the floor.
     *
     * `_minDelay` is `private` in OpenZeppelin, so this cannot be implemented by writing it back —
     * which is why the guard is a max() on the read AND a rejection on the write below, rather
     * than a single validated setter.
     */
    function getMinDelay() public view virtual override returns (uint256) {
        uint256 stored = super.getMinDelay();
        uint256 floor = minDelayFloor();
        return stored < floor ? floor : stored;
    }

    /**
     * `updateDelay(x)` BELOW THE TIER FLOOR IS REJECTED, at the only place it can originate.
     *
     * The hole this closes. OZ's `updateDelay` is `external virtual`, gated only on
     * `msg.sender == address(this)`, and re-validates nothing. The tier floor was checked once, in
     * the constructor. So a single queued operation targeting the timelock itself set
     * `_minDelay = 0`, after which every later operation — `Vault.registerApp` included — executed
     * in the block it was queued. The tier stopped existing, and with `CANCELLER_ROLE` held only
     * by the compromised proposer there was nobody to stop it.
     *
     * Why here and not in an override of `updateDelay`. Solidity cannot call an `external` base
     * function through `super`, and `_minDelay` is private, so an override could reject a bad
     * delay but could never apply a good one. `_execute` is the single choke point instead: the
     * timelock makes external calls from nowhere else, so a self-targeted `updateDelay` cannot
     * reach the base implementation without passing through this check. A below-floor update
     * therefore REVERTS the execution — loudly, with the operation left pending and cancellable —
     * rather than succeeding and emitting a `MinDelayChange` that a monitor would read as the tier
     * being gone.
     *
     * Raising the delay, or setting it to exactly the floor, is untouched and still works.
     */
    function _execute(address target, uint256 value, bytes calldata data) internal virtual override {
        // 4 selector bytes + one 32-byte word. Anything shorter cannot be a well-formed call to
        // `updateDelay` and is left to the target to reject.
        if (target == address(this) && data.length >= 36 && bytes4(data[:4]) == TimelockController.updateDelay.selector)
        {
            uint256 newDelay = uint256(bytes32(data[4:36]));
            uint256 floor = minDelayFloor();
            if (newDelay < floor) revert DelayBelowTierFloor(tier, newDelay, floor);
        }
        super._execute(target, value, data);
    }
}
