// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

/// @notice The one setter of `DeepCoreDynamicFeeHook` / `DeepCoreDexHook` the gate may call, plus the
/// tuner-role calls the gate makes on its own behalf.
interface IDynamicFeeTunable {
    function tune(PoolKey calldata key, uint24 baseFee, uint24 volSlope, uint24 sameSecondSlope) external;
    function acceptTuner(PoolId id) external;
    function revokeTuner(PoolId id) external;
}

/// @notice The one setter of `ManualPriceBandOracle` the gate may call, and the view it seeds from.
interface IReferencePublishable {
    function setReferencePrice(PoolId poolId, uint160 sqrtPriceX96) external;
    function publisherBoundsFor(PoolId poolId)
        external
        view
        returns (uint160 anchor, uint64 earliestUpdate, uint256 maxDeviationBps);
}

/// @title DeepCoreTunerGate
/// @notice The on-chain limits in front of an automated agent's hot key. Design of record:
/// `docs/products/agent-managed-deepcores.md`. The agent can be replaced; these limits cannot be
/// argued with.
///
/// ############################## WHAT THE AGENT CAN REACH ##############################
///
/// Exactly two typed entry points, each calling exactly ONE function on its target. There is no
/// generic call, no delegatecall, no approval, no transfer:
///   tuneFee(hook, key, ...)            -> hook.tune(key, ...)          (the gate is the pool's tuner)
///   publishReference(oracle, id, p)    -> oracle.setReferencePrice(id, p)  (the gate is a publisher)
/// Each is refused unless the OWNER enabled that (target, pool) with a policy, and each is bounded
/// by the gate's policy (tighter than, never looser than, the target's own bounds) AND by the target.
///
/// Fee policy: the three values inside the policy's ranges; at most once per `minInterval`
/// (>= 1 hour); the hook then applies its own bounds, its step against its own anchor and its own
/// interval. Reference policy: one update per `minInterval` (>= 1 hour), at most `maxDeviationBps`
/// in PRICE terms away from BOTH the oracle's anchor (which survives a clear) and the gate's own
/// anchor (its last write, never the agent's input), so the oracle's zero-default interval is never
/// relied on and the agent can neither undo another party's move nor ride it.
///
/// ############################## WHAT A STOLEN AGENT KEY CAN DO ##############################
///
/// It cannot take anyone's tokens: no contract it can reach transfers on its word. It CAN, inside
/// the limits, set a pool's fee anywhere in the policy's range (one change per interval) and walk a
/// price-band reference (one bounded step per interval). Both can cost LPs or traders money through
/// worse trading conditions until it is stopped, which the guardian or the owner does in one
/// transaction, at once.
///
/// ############################## ROLES ##############################
///
///   owner (Safe; Ownable2Step; renounce reverts): PROPOSE an agent, a policy (enabling or
///     loosening), an unpause — each applies only after a notice and within 3 days of falling due;
///     TIGHTEN or disable a policy, revoke, pause, set the guardian, accept or drop the tuner role
///     on a hook — at once. Cannot exceed a target's own bounds, cannot move funds.
///   guardian (Ops): revoke the agent, pause, drop the tuner role on a hook. Nothing else.
///   agent: the two entry points inside policy; resign.
///   anyone: apply a proposal that is due; sweep misdirected value to the immutable recipient.
///
/// Reduction is immediate and escalation waits, and a reduction voids the escalations queued
/// before it: a pause voids pending unpauses, a revocation voids pending agent appointments, a
/// tightening voids pending policies for that target and pool.
///
/// ############################## FUNDS ##############################
///
/// The gate is never owed anything. No `receive`, no `fallback`. ERC-20 sent by mistake and native
/// forced in leave through `sweep`, permissionless, to the immutable `protocolRecipient`.
contract DeepCoreTunerGate is Ownable2Step, ReentrancyGuard {
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct FeePolicy {
        bool enabled;
        uint24 minBaseFee;
        uint24 maxBaseFee;
        uint24 maxVolSlope;
        uint24 maxSameSecondSlope;
        uint32 minInterval; // >= MIN_INTERVAL_FLOOR
    }

    struct RefPolicy {
        bool enabled;
        uint16 maxDeviationBps; // <= MAX_DEVIATION_CEILING_BPS, in PRICE terms
        uint32 minInterval; // >= MIN_INTERVAL_FLOOR
    }

    struct FeeState {
        FeePolicy policy;
        uint40 lastAt;
        uint32 epoch; // bumped by every tightening: voids proposals queued before it
    }

    struct RefState {
        RefPolicy policy;
        uint160 anchor; // the gate's own anchor; 0 until the first publication through the gate
        uint40 lastAt;
        uint32 epoch;
    }

    enum Kind {
        None,
        Agent,
        FeePolicy,
        RefPolicy,
        Unpause
    }

    struct Proposal {
        Kind kind;
        uint40 effectiveAt;
        uint32 epoch; // the epoch it must still match when applied
        address target; // agent (Agent) or hook/oracle (policies)
        PoolId poolId;
        bytes policy; // abi-encoded FeePolicy or RefPolicy
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS AND IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint32 public constant MIN_INTERVAL_FLOOR = 3_600;
    uint32 public constant MIN_NOTICE_SECONDS = 86_400;
    uint16 public constant HARD_MAX_DEVIATION_BPS = 1_000;
    uint32 public constant PROPOSAL_TTL_SECONDS = 3 days;
    uint256 internal constant BPS = 10_000;
    uint256 private constant RATIO_SCALE = 1e9;
    uint256 private constant RATIO_CLAMP = 4 * RATIO_SCALE;

    uint32 public immutable AGENT_NOTICE_SECONDS;
    uint32 public immutable POLICY_NOTICE_SECONDS;
    uint16 public immutable MAX_DEVIATION_CEILING_BPS;
    /// @notice The only address a swept unit can reach (the Safe).
    address public immutable protocolRecipient;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public agent;
    address public guardian;
    bool public paused;
    uint32 public agentEpoch;
    uint32 public pauseEpoch;
    uint256 public proposalNonce;

    mapping(address hook => mapping(PoolId => FeeState)) private _fee;
    mapping(address oracle => mapping(PoolId => RefState)) private _ref;
    mapping(bytes32 id => Proposal) private _proposals;

    /*//////////////////////////////////////////////////////////////
                             ERRORS AND EVENTS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidDeployment(uint8 reason);
    error NotAgent();
    error NotGuardianOrOwner();
    error GatePaused();
    error NotPaused();
    error TargetNotEnabled(address target, PoolId poolId);
    error KeyMismatch();
    error TooSoon(uint40 earliest);
    error OutOfPolicy(uint8 field, uint256 value);
    error DeviationTooLarge(uint256 deviationBps, uint256 maxBps);
    error NoAnchor();
    error PriceOutOfRange(uint160 sqrtPriceX96);
    error NotATightening(uint8 field);
    error InvalidPolicy(uint8 reason);
    error NoSuchProposal(bytes32 id);
    error ProposalNotDue(uint40 effectiveAt);
    error ProposalExpired(uint40 expiredAt);
    error ProposalVoided(bytes32 id);
    error InvalidAgent(address agent);
    error NothingToSweep(Currency currency);
    error RenounceDisabled();

    event AgentProposed(bytes32 indexed id, address indexed agent, uint40 effectiveAt);
    event AgentAppointed(address indexed agent);
    event AgentRevoked(address indexed agent, address indexed by);
    event AgentResigned(address indexed agent);
    event Paused(address indexed by);
    event UnpauseProposed(bytes32 indexed id, uint40 effectiveAt);
    event Unpaused();
    event GuardianSet(address indexed previous, address indexed guardian);
    event FeePolicyProposed(bytes32 indexed id, address indexed hook, PoolId indexed poolId, FeePolicy policy, uint40 effectiveAt);
    event RefPolicyProposed(bytes32 indexed id, address indexed oracle, PoolId indexed poolId, RefPolicy policy, uint40 effectiveAt);
    event FeePolicySet(address indexed hook, PoolId indexed poolId, FeePolicy policy);
    event RefPolicySet(address indexed oracle, PoolId indexed poolId, RefPolicy policy);
    event ProposalCancelled(bytes32 indexed id);
    event FeeTuned(address indexed hook, PoolId indexed poolId, uint24 baseFee, uint24 volSlope, uint24 sameSecondSlope);
    event ReferencePublished(address indexed oracle, PoolId indexed poolId, uint160 sqrtPriceX96, uint256 deviationBps);
    event TunerAccepted(address indexed hook, PoolId indexed poolId);
    event TunerDropped(address indexed hook, PoolId indexed poolId, address indexed by);
    event Swept(Currency indexed currency, address indexed recipient, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param owner_ The Safe (a tenant's own multisig for a tenant's gate).
    /// @param guardian_ Ops: may only revoke and pause. May be zero (owner alone then).
    /// @dev Reasons: 1 a notice under one day; 2 the deviation ceiling zero or above 1,000 bps.
    constructor(
        address owner_,
        address guardian_,
        address protocolRecipient_,
        uint32 agentNoticeSeconds_,
        uint32 policyNoticeSeconds_,
        uint16 maxDeviationCeilingBps_
    ) Ownable(owner_) {
        if (protocolRecipient_ == address(0)) revert ZeroAddress();
        if (agentNoticeSeconds_ < MIN_NOTICE_SECONDS || policyNoticeSeconds_ < MIN_NOTICE_SECONDS) {
            revert InvalidDeployment(1);
        }
        if (maxDeviationCeilingBps_ == 0 || maxDeviationCeilingBps_ > HARD_MAX_DEVIATION_BPS) revert InvalidDeployment(2);
        AGENT_NOTICE_SECONDS = agentNoticeSeconds_;
        POLICY_NOTICE_SECONDS = policyNoticeSeconds_;
        MAX_DEVIATION_CEILING_BPS = maxDeviationCeilingBps_;
        protocolRecipient = protocolRecipient_;
        guardian = guardian_;
        emit GuardianSet(address(0), guardian_);
    }

    modifier onlyAgent() {
        if (agent == address(0) || msg.sender != agent) revert NotAgent();
        if (paused) revert GatePaused();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           THE AGENT'S TWO CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Move one pool's three fee parameters through the hook's bounded setter.
    function tuneFee(address hook, PoolKey calldata key, uint24 baseFee, uint24 volSlope, uint24 sameSecondSlope)
        external
        onlyAgent
        nonReentrant
    {
        if (address(key.hooks) != hook) revert KeyMismatch();
        PoolId id = key.toId();
        FeeState storage s = _fee[hook][id];
        FeePolicy memory p = s.policy;
        if (!p.enabled) revert TargetNotEnabled(hook, id);
        _checkInterval(s.lastAt, p.minInterval);
        if (baseFee < p.minBaseFee || baseFee > p.maxBaseFee) revert OutOfPolicy(1, baseFee);
        if (volSlope > p.maxVolSlope) revert OutOfPolicy(2, volSlope);
        if (sameSecondSlope > p.maxSameSecondSlope) revert OutOfPolicy(3, sameSecondSlope);
        // The hook applies its own bounds, its step against its own anchor and its own interval.
        IDynamicFeeTunable(hook).tune(key, baseFee, volSlope, sameSecondSlope);
        // Written only after the target accepted.
        s.lastAt = uint40(block.timestamp);
        emit FeeTuned(hook, id, baseFee, volSlope, sameSecondSlope);
    }

    /// @notice Publish one pool's price-band reference through the oracle's publisher setter.
    function publishReference(address oracle, PoolId poolId, uint160 sqrtPriceX96) external onlyAgent nonReentrant {
        RefState storage s = _ref[oracle][poolId];
        RefPolicy memory p = s.policy;
        if (!p.enabled) revert TargetNotEnabled(oracle, poolId);
        _checkInterval(s.lastAt, p.minInterval);
        // TickMath's representable range, restated (so a 0 can never mean "clear" through the gate).
        if (sqrtPriceX96 < 4_295_128_739 || sqrtPriceX96 > 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342) {
            revert PriceOutOfRange(sqrtPriceX96);
        }
        // Two anchors, both must hold. The ORACLE's anchor (its last accepted price, which survives a
        // clear) keeps the agent from undoing a move the oracle's owner or another bounded publisher
        // made; the GATE's own anchor (its last write, never the agent's input) keeps the agent from
        // riding someone else's walk further than its own policy allows. If they have drifted apart
        // the agent is stuck until the owner re-proposes the policy, which re-seeds the gate anchor.
        (uint160 oracleAnchor,,) = IReferencePublishable(oracle).publisherBoundsFor(poolId);
        if (oracleAnchor == 0) revert NoAnchor();
        uint256 deviation = priceDeviationBps(sqrtPriceX96, oracleAnchor);
        if (deviation > p.maxDeviationBps) revert DeviationTooLarge(deviation, p.maxDeviationBps);
        uint160 own = s.anchor;
        if (own != 0) {
            uint256 ownDeviation = priceDeviationBps(sqrtPriceX96, own);
            if (ownDeviation > p.maxDeviationBps) revert DeviationTooLarge(ownDeviation, p.maxDeviationBps);
        }
        IReferencePublishable(oracle).setReferencePrice(poolId, sqrtPriceX96);
        s.anchor = sqrtPriceX96;
        s.lastAt = uint40(block.timestamp);
        emit ReferencePublished(oracle, poolId, sqrtPriceX96, deviation);
    }

    /// @notice The agent steps down, at once.
    function resign() external {
        if (agent == address(0) || msg.sender != agent) revert NotAgent();
        agent = address(0);
        emit AgentResigned(msg.sender);
    }

    function _checkInterval(uint40 lastAt, uint32 minInterval) private view {
        if (lastAt != 0) {
            uint40 earliest = lastAt + minInterval;
            if (block.timestamp < earliest) revert TooSoon(earliest);
        }
    }

    /// @notice The distance between two sqrt prices in PRICE bps, symmetric (the larger over the
    /// smaller), the same measure `ManualPriceBandOracle` uses. Saturates above 16x.
    function priceDeviationBps(uint160 a, uint160 b) public pure returns (uint256) {
        uint256 hi = a >= b ? a : b;
        uint256 lo = a >= b ? b : a;
        uint256 sqrtRatio = (hi * RATIO_SCALE) / lo;
        if (sqrtRatio >= RATIO_CLAMP) return type(uint256).max;
        uint256 priceRatio = (sqrtRatio * sqrtRatio) / RATIO_SCALE;
        return ((priceRatio - RATIO_SCALE) * BPS) / RATIO_SCALE;
    }

    /*//////////////////////////////////////////////////////////////
                    REDUCTION: GUARDIAN OR OWNER, AT ONCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Remove the agent at once, and void every agent appointment queued before now.
    function revokeAgent() external onlyGuardianOrOwner {
        address a = agent;
        agent = address(0);
        ++agentEpoch;
        emit AgentRevoked(a, msg.sender);
    }

    /// @notice Stop both entry points at once, and void every unpause queued before now.
    function pause() external onlyGuardianOrOwner {
        paused = true;
        ++pauseEpoch;
        emit Paused(msg.sender);
    }

    /// @notice Give up the gate's tuner role on one pool (the hook lets its tuner revoke itself).
    function dropTuner(address hook, PoolId poolId) external onlyGuardianOrOwner {
        IDynamicFeeTunable(hook).revokeTuner(poolId);
        emit TunerDropped(hook, poolId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         REDUCTION: OWNER, AT ONCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Replace a fee policy with one no looser in any field (disabling is a tightening).
    function tightenFeePolicy(address hook, PoolId poolId, FeePolicy calldata p) external onlyOwner {
        FeeState storage s = _fee[hook][poolId];
        FeePolicy memory o = s.policy;
        if (p.enabled) {
            _validateFee(p);
            if (!o.enabled) revert NotATightening(0);
            if (p.minBaseFee < o.minBaseFee) revert NotATightening(1);
            if (p.maxBaseFee > o.maxBaseFee) revert NotATightening(2);
            if (p.maxVolSlope > o.maxVolSlope) revert NotATightening(3);
            if (p.maxSameSecondSlope > o.maxSameSecondSlope) revert NotATightening(4);
            if (p.minInterval < o.minInterval) revert NotATightening(5);
            s.policy = p;
        } else {
            delete s.policy;
        }
        ++s.epoch;
        emit FeePolicySet(hook, poolId, s.policy);
    }

    /// @notice Replace a reference policy with one no looser in any field (disabling is a tightening).
    function tightenRefPolicy(address oracle, PoolId poolId, RefPolicy calldata p) external onlyOwner {
        RefState storage s = _ref[oracle][poolId];
        RefPolicy memory o = s.policy;
        if (p.enabled) {
            _validateRef(p);
            if (!o.enabled) revert NotATightening(0);
            if (p.maxDeviationBps > o.maxDeviationBps) revert NotATightening(1);
            if (p.minInterval < o.minInterval) revert NotATightening(2);
            s.policy = p;
        } else {
            delete s.policy;
        }
        ++s.epoch;
        emit RefPolicySet(oracle, poolId, s.policy);
    }

    /// @notice Set the guardian. Its only powers are reductions, so this is immediate.
    function setGuardian(address guardian_) external onlyOwner {
        emit GuardianSet(guardian, guardian_);
        guardian = guardian_;
    }

    /// @notice Take the tuner role the pool's owner proposed for this gate on `hook`.
    function acceptTuner(address hook, PoolId poolId) external onlyOwner {
        IDynamicFeeTunable(hook).acceptTuner(poolId);
        emit TunerAccepted(hook, poolId);
    }

    /// @notice Disabled: an owner that could renounce would leave the agent unappointable, its
    /// policies frozen and every queued escalation unreachable.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                   ESCALATION: OWNER PROPOSES, NOTICE, APPLY
    //////////////////////////////////////////////////////////////*/

    function proposeAgent(address agent_) external onlyOwner returns (bytes32 id) {
        // The agent's hot key must not be a key that already holds a role here.
        if (agent_ == address(0) || agent_ == address(this) || agent_ == owner() || agent_ == guardian) {
            revert InvalidAgent(agent_);
        }
        uint40 at = uint40(block.timestamp) + AGENT_NOTICE_SECONDS;
        id = _store(Proposal(Kind.Agent, at, agentEpoch, agent_, PoolId.wrap(0), ""));
        emit AgentProposed(id, agent_, at);
    }

    /// @notice Enable or loosen (or set any valid) fee policy, after `POLICY_NOTICE_SECONDS`.
    function proposeFeePolicy(address hook, PoolId poolId, FeePolicy calldata p) external onlyOwner returns (bytes32 id) {
        if (hook == address(0)) revert ZeroAddress();
        if (!p.enabled) revert InvalidPolicy(0);
        _validateFee(p);
        uint40 at = uint40(block.timestamp) + POLICY_NOTICE_SECONDS;
        id = _store(Proposal(Kind.FeePolicy, at, _fee[hook][poolId].epoch, hook, poolId, abi.encode(p)));
        emit FeePolicyProposed(id, hook, poolId, p, at);
    }

    /// @notice Enable or loosen a reference policy, after `POLICY_NOTICE_SECONDS`. Applying it also
    /// re-seeds the gate's anchor from the oracle at the next publication.
    function proposeRefPolicy(address oracle, PoolId poolId, RefPolicy calldata p) external onlyOwner returns (bytes32 id) {
        if (oracle == address(0)) revert ZeroAddress();
        if (!p.enabled) revert InvalidPolicy(0);
        _validateRef(p);
        uint40 at = uint40(block.timestamp) + POLICY_NOTICE_SECONDS;
        id = _store(Proposal(Kind.RefPolicy, at, _ref[oracle][poolId].epoch, oracle, poolId, abi.encode(p)));
        emit RefPolicyProposed(id, oracle, poolId, p, at);
    }

    function proposeUnpause() external onlyOwner returns (bytes32 id) {
        if (!paused) revert NotPaused();
        uint40 at = uint40(block.timestamp) + POLICY_NOTICE_SECONDS;
        id = _store(Proposal(Kind.Unpause, at, pauseEpoch, address(0), PoolId.wrap(0), ""));
        emit UnpauseProposed(id, at);
    }

    function cancelProposal(bytes32 id) external onlyOwner {
        if (_proposals[id].kind == Kind.None) revert NoSuchProposal(id);
        delete _proposals[id];
        emit ProposalCancelled(id);
    }

    /// @notice Apply a proposal inside `[effectiveAt, effectiveAt + 3 days]`. Anyone may call: it
    /// has survived its notice in public. Refused if a reduction since voided it.
    function applyProposal(bytes32 id) external {
        Proposal memory p = _proposals[id];
        if (p.kind == Kind.None) revert NoSuchProposal(id);
        if (block.timestamp < p.effectiveAt) revert ProposalNotDue(p.effectiveAt);
        uint40 expiry = p.effectiveAt + PROPOSAL_TTL_SECONDS;
        if (block.timestamp > expiry) revert ProposalExpired(expiry);
        delete _proposals[id];
        if (p.kind == Kind.Agent) {
            if (p.epoch != agentEpoch) revert ProposalVoided(id);
            agent = p.target;
            emit AgentAppointed(p.target);
        } else if (p.kind == Kind.Unpause) {
            if (p.epoch != pauseEpoch) revert ProposalVoided(id);
            paused = false;
            emit Unpaused();
        } else if (p.kind == Kind.FeePolicy) {
            FeeState storage s = _fee[p.target][p.poolId];
            if (p.epoch != s.epoch) revert ProposalVoided(id);
            s.policy = abi.decode(p.policy, (FeePolicy));
            ++s.epoch;
            emit FeePolicySet(p.target, p.poolId, s.policy);
        } else {
            RefState storage s = _ref[p.target][p.poolId];
            if (p.epoch != s.epoch) revert ProposalVoided(id);
            s.policy = abi.decode(p.policy, (RefPolicy));
            s.anchor = 0;
            ++s.epoch;
            emit RefPolicySet(p.target, p.poolId, s.policy);
        }
    }

    function _store(Proposal memory p) private returns (bytes32 id) {
        id = keccak256(abi.encode(address(this), ++proposalNonce, p.kind, p.target, p.poolId, p.policy));
        _proposals[id] = p;
    }

    /// @dev Reasons: 1 min above max; 2 interval under the floor; 3 deviation zero or above the ceiling.
    function _validateFee(FeePolicy calldata p) private pure {
        if (p.minBaseFee > p.maxBaseFee) revert InvalidPolicy(1);
        if (p.minInterval < MIN_INTERVAL_FLOOR) revert InvalidPolicy(2);
    }

    function _validateRef(RefPolicy calldata p) private view {
        if (p.minInterval < MIN_INTERVAL_FLOOR) revert InvalidPolicy(2);
        if (p.maxDeviationBps == 0 || p.maxDeviationBps > MAX_DEVIATION_CEILING_BPS) revert InvalidPolicy(3);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay a misdirected balance to the immutable recipient. Permissionless.
    function sweep(Currency currency) external nonReentrant returns (uint256 amount) {
        amount = currency.balanceOfSelf();
        if (amount == 0) revert NothingToSweep(currency);
        emit Swept(currency, protocolRecipient, amount);
        currency.transfer(protocolRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function feePolicyOf(address hook, PoolId poolId) external view returns (FeeState memory) {
        return _fee[hook][poolId];
    }

    function refPolicyOf(address oracle, PoolId poolId) external view returns (RefState memory) {
        return _ref[oracle][poolId];
    }

    function proposalOf(bytes32 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    /// @notice When the agent may next act on this fee target (0 = now).
    function nextFeeTuneAt(address hook, PoolId poolId) external view returns (uint40) {
        FeeState storage s = _fee[hook][poolId];
        return s.lastAt == 0 ? 0 : s.lastAt + s.policy.minInterval;
    }

    /// @notice When the agent may next act on this reference target (0 = now).
    function nextPublishAt(address oracle, PoolId poolId) external view returns (uint40) {
        RefState storage s = _ref[oracle][poolId];
        return s.lastAt == 0 ? 0 : s.lastAt + s.policy.minInterval;
    }
}
