/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

/// @title DeepCoreProtocolFeeControllerV2
/// @notice Decides the protocol fee for every DeepCoreProtocol pool, and is the only address that
/// can withdraw what those fees accrue.
///
/// @dev ####################### WHY V2 EXISTS: THE MONEY WAS UNREACHABLE #######################
///
/// `ProtocolFees.collectProtocolFees` is gated on `msg.sender == protocolFeeController`. V1
/// (`0x2a03E6E6900b9cF93CcC27e3A75a5a95FB4a154c`, live on Robinhood Chain) has twelve external
/// functions and NOT ONE of them calls it — no collect, no sweep, no fallback, no delegatecall.
/// Its deployed bytecode was verified byte-for-byte identical to its source, so this is a fact
/// about the deployment and not a stale reading.
///
/// The consequence: with V1 installed, every pip of protocol fee accrues into
/// `protocolFeesAccrued[currency]` on the pool manager, and the only address permitted to
/// withdraw it is a contract with no code path to do so. The fee was safe to turn on only in the
/// sense that a locked room is safe.
///
/// Nothing accrued under V1 is lost. The caller check is evaluated at COLLECTION time and
/// `protocolFeesAccrued` is ordinary storage on the manager, so installing this contract makes
/// every previously-stranded balance collectable. That is why the ordering of the migration does
/// not matter, and why V1 can be replaced at leisure rather than urgently.
///
/// ############################### THE FEE MODEL CHANGED TOO ################################
///
/// V1 charged a FLAT pip value with per-tier overrides. That is the wrong shape: a flat 0.1% is
/// eleven times the total fee of a 0.01% stable pool and a rounding error on a 1% exotic one, so
/// staying competitive meant hand-maintaining a tier table and hoping no pool opened at a tier
/// nobody had enumerated — such a pool silently fell through to the flat default.
///
/// V2 takes a SHARE of the total swap fee, the way `infinity-core`'s own controller does, so
/// every tier resolves proportionately and an unenumerated tier is impossible.
///
///     protocolFeeSplitRatio = 250000   // 25% of the total swap fee
///
/// PancakeSwap Infinity ships 33% (`ProtocolFeeController.sol:32`, `33 * 1e4`). DeepCore takes a
/// quarter where they take a third: about 32% fewer pips per swap, because the pip needed to
/// realise a share `s` of the total goes as `s / (1 - s)` rather than linearly in `s`.
///
/// What that means at the tiers that exist:
///
///     LP fee   protocol pips   protocol %   trader pays   protocol share
///     0.01%    33              0.0033%      0.0133%       24.81%
///     0.05%    166             0.0166%      0.0666%       24.92%
///     0.25%    832             0.0832%      0.3330%       24.98%
///     0.30%    999             0.0999%      0.3997%       24.99%
///     1.00%    3322            0.3322%      1.3289%       24.99%
///
/// Two properties worth keeping: 0.30% pools — the common case — land at 0.0999%, and the
/// trader's all-in cost stays under 0.4%. Pancake's 33% hits core's `MAX_PROTOCOL_FEE` cap at
/// roughly a 0.9% LP fee, after which their share silently decays (28.65% at 1%, 16.72% at 2%);
/// at 25% we stay under the cap through the 1% tier, so the share is constant and needs no
/// asterisk.
///
/// FEE SEMANTICS, unchanged from V1 and verified in `ProtocolFeeLibrary`: the protocol fee comes
/// off the swap INPUT first and the LP fee applies to the remainder, so it is ADDITIVE to what a
/// swapper pays and does NOT come out of LP earnings:
///
///     totalSwapCost = protocolFee + lpFee - (protocolFee * lpFee / 1_000_000)
///
/// ############################ THE HOT-PATH RULE, INHERITED ################################
///
/// `ProtocolFees._fetchProtocolFee` staticcalls `protocolFeeForPool` while a pool is being
/// INITIALIZED, forwarding all remaining gas and requiring exactly 32 bytes back. If it reverts,
/// returns the wrong size, or burns excessive gas, POOL CREATION FAILS and the protocol is
/// bricked for new pools until the controller is replaced.
///
/// So, as in V1 and for the same reason: `protocolFeeForPool` MUST NOT revert on any input.
/// Every branch returns a value, every division is guarded against a zero denominator, all
/// validation lives in the owner-only setters, and values are clamped on write rather than on
/// read. The split arithmetic below is the one piece V1 did not have, and it is exactly where a
/// division could be introduced carelessly — see `_splitDerivedFee`.
///
/// OWNERSHIP: this contract sets protocol revenue AND moves collected funds, which makes it
/// strictly more valuable than V1. It must be owned by the governance Safe. `Ownable2Step`, and
/// `renounceOwnership` reverts — an unowned controller cannot collect, and every future fee
/// would accrue into the same locked room this contract exists to open.
/// ###########################################################################################
contract DeepCoreProtocolFeeControllerV2 is IProtocolFeeController, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @notice Hard cap enforced by core (`ProtocolFeeLibrary.MAX_PROTOCOL_FEE`): 0.4%.
    uint16 public constant MAX_PROTOCOL_FEE = 4000;

    /// @notice Pips denominator, matching core. 1e6 == 100%.
    uint256 public constant ONE_HUNDRED_PERCENT_RATIO = 1e6;

    /// @notice Launch split: 25% of the total swap fee. See the header for the tier table.
    uint256 public constant DEFAULT_SPLIT_RATIO = 250_000;

    /// @notice Default protocol fee for DYNAMIC-fee pools, per direction, in pips.
    /// @dev 999 == what a 0.30% pool pays under a 25% split, and 0.30% is what every launch
    /// preset decays to. See `_dynamicFee` for why this must not be zero.
    uint16 public constant DYNAMIC_FEE_PIPS = 999;

    /// @notice Share of the TOTAL swap fee taken by the protocol, in hundredths of a bip.
    /// @dev The base case for every static-fee pool. Overrides below take precedence.
    uint256 public protocolFeeSplitRatio;

    /// @dev One storage slot: 1 + 2 + 2 = 5 bytes. Read with a single SLOAD.
    struct FeeConfig {
        bool isSet;
        uint16 zeroForOne;
        uint16 oneForZero;
    }

    /// @notice Per-pool override. Highest precedence.
    mapping(PoolId poolId => FeeConfig) private _poolFee;

    /// @notice Per-LP-fee-tier override, keyed by the static LP fee. Beats the split ratio.
    mapping(uint24 lpFeeTier => FeeConfig) private _tierFee;

    /**
     * @notice Applied to dynamic-fee pools, which have no static tier to derive a share from.
     *
     * @dev SET BY DEFAULT, AND THAT DEFAULT IS LOAD-BEARING. A dynamic pool's LP fee is chosen
     * per swap by its hook, so at `initialize` there is no total to take a percentage OF — the
     * share model simply has nothing to work with.
     *
     * An earlier draft left this unset and returned zero, on the reasoning that charging a number
     * we cannot derive is worse than charging nothing. That reasoning is sound and the conclusion
     * was still wrong, because of WHICH pools are dynamic here:
     *
     *     LaunchpadKit.sol:373        fee: LPFeeLibrary.DYNAMIC_FEE_FLAG
     *     LaunchGuardHook.sol:328     if (!key.fee.isDynamicLPFee()) revert PoolMustUseDynamicFee
     *
     * EVERY launchpad pool is dynamic-fee, by construction and by requirement. A zero default
     * therefore exempts the entire launchpad — the protocol's flagship integration path — from
     * the protocol fee, permanently for every pool created that way, since core stamps the fee at
     * `initialize` and never re-reads it.
     *
     * The default is `DYNAMIC_FEE_PIPS`: what a 0.30% pool pays under the split. That is the
     * honest analogue, because 0.30% is exactly what the launch presets DECAY TO —
     * `LaunchPresets.sol` sets `finalFeeBips: 3_000` for FairLaunch, Stealth and NoTax. A launch
     * pool is a 0.30% pool wearing a temporary anti-sniper surcharge, so it pays what a 0.30%
     * pool pays.
     *
     * Deliberately NOT a share of the elevated launch-window fee. That surcharge exists to
     * compensate LPs for being sniped; taking a quarter of it would mean the protocol profits
     * most from the launches that go worst for the people providing liquidity.
     *
     * For reference, infinity-core's controller defaults dynamic pools to a flat 300 pips
     * (`ProtocolFeeController.sol:39`). Ours is higher because theirs is a general-purpose
     * default and this one is sized to a specific, known population of pools.
     */
    FeeConfig private _dynamicFee;

    /// @notice Emergency switch: when true every pool reports a zero protocol fee.
    bool public feesDisabled;

    /**
     * @notice Where `sweep` sends collected fees. Owner-settable, never zero.
     *
     * @dev The whole reason `sweep` can be permissionless. The destination is STORED rather than
     * passed by the caller, so the function has no argument an attacker can point anywhere. Per
     * CLAUDE.md this is the governance Safe itself: "No separate treasury address exists or
     * should be introduced — a second address to secure, for no gain."
     */
    address public treasury;

    /// @notice Address that may switch fees OFF immediately, and do nothing else.
    /// @dev Delay belongs on privilege escalation, never on privilege reduction. It can only ever
    /// make the protocol take LESS. It CANNOT collect — see `collect`.
    address public guardian;

    event SplitRatioUpdated(uint256 previousRatio, uint256 newRatio);
    event PoolFeeUpdated(PoolId indexed poolId, bool isSet, uint16 zeroForOne, uint16 oneForZero);
    event TierFeeUpdated(uint24 indexed lpFeeTier, bool isSet, uint16 zeroForOne, uint16 oneForZero);
    event DynamicFeeUpdated(bool isSet, uint16 zeroForOne, uint16 oneForZero);
    event FeesDisabledSet(bool disabled);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event EmergencyFeesDisabled(address indexed caller);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolFeesCollected(
        address indexed poolManager, Currency indexed currency, address indexed recipient, uint256 amount
    );

    /// @notice A configured fee exceeds the 0.4% cap enforced by core.
    error FeeExceedsMaximum(uint16 fee, uint16 maximum);
    /// @notice A split ratio above 100% is not a share of anything.
    error InvalidSplitRatio(uint256 ratio);
    /// @notice Caller is neither the guardian nor the owner.
    error NotGuardianOrOwner();
    /// @notice Collecting to `address(0)` would burn the protocol's revenue.
    error ZeroRecipient();
    /// @notice `renounceOwnership` is disabled. See the header.
    error RenounceDisabled();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Nothing has accrued in this currency. A revert, so a simulation catches it free.
    error NothingToCollect(address poolManager, Currency currency);

    /// @param owner_ The governance Safe. Never an EOA on a live chain.
    /// @param guardian_ May disable fees instantly during an incident. May be `address(0)`.
    constructor(address owner_, address guardian_) Ownable(owner_) {
        guardian = guardian_;
        emit GuardianUpdated(address(0), guardian_);
        /* Defaults to the owner. A treasury left unset would make `sweep` revert on every call,
           which is a scheduled job that silently never works. */
        treasury = owner_;
        emit TreasuryUpdated(address(0), owner_);
        protocolFeeSplitRatio = DEFAULT_SPLIT_RATIO;
        emit SplitRatioUpdated(0, DEFAULT_SPLIT_RATIO);
        /* Set here rather than left to a later governance call: every launchpad pool is
           dynamic-fee, and a pool created before that call would be exempt for life. */
        _dynamicFee = FeeConfig({isSet: true, zeroForOne: DYNAMIC_FEE_PIPS, oneForZero: DYNAMIC_FEE_PIPS});
        emit DynamicFeeUpdated(true, DYNAMIC_FEE_PIPS, DYNAMIC_FEE_PIPS);
    }

    /*//////////////////////////////////////////////////////////////
                    HOT PATH - CALLED DURING POOL INIT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolFeeController
    /// @dev MUST NOT revert. Precedence: kill switch > per-pool > tier/dynamic > split ratio.
    function protocolFeeForPool(PoolKey memory poolKey) external view override returns (uint24) {
        if (feesDisabled) return 0;

        FeeConfig memory config = _poolFee[poolKey.toId()];
        if (config.isSet) return _pack(config);

        if (poolKey.fee.isDynamicLPFee()) {
            config = _dynamicFee;
            /* Set in the constructor, so this is the DYNAMIC_FEE_PIPS path in practice. It can
               be unset deliberately by governance, which then means zero — but it is never zero
               by omission. Every launchpad pool arrives here. See `_dynamicFee`. */
            return config.isSet ? _pack(config) : 0;
        }

        config = _tierFee[poolKey.fee];
        if (config.isSet) return _pack(config);

        uint16 derived = _splitDerivedFee(poolKey.fee);
        return uint24(derived) | (uint24(derived) << 12);
    }

    /// @notice The protocol fee a static-fee pool at `lpFee` would be given, in pips per direction.
    /// @dev Exposed so an integrator can quote the all-in cost of a pool BEFORE creating it,
    /// rather than discovering it from a receipt.
    function feeForLpFee(uint24 lpFee) external view returns (uint16) {
        return _splitDerivedFee(lpFee);
    }

    /**
     * @dev The share arithmetic, matching `infinity-core`'s controller so the two are comparable
     * line by line.
     *
     * Solving `p / (p + l - p*l/ONE) == ratio` for `p` gives:
     *
     *     p = l * ONE / (l + ONE*ONE/ratio - ONE)
     *
     * EVERY DIVISION HERE IS GUARDED, because this runs inside pool creation and a revert bricks
     * it. `ratio == 0` is special-cased before it can be a divisor. `denominator` cannot reach
     * zero for any accepted ratio — with `ratio <= ONE`, `ONE*ONE/ratio >= ONE`, so
     * `denominator >= lpFee`; the only way to zero is `lpFee == 0` together with `ratio == ONE`,
     * which is special-cased above it. The explicit check remains anyway: the cost is one JUMPI
     * and the alternative is a bricked protocol if a future edit weakens an invariant this
     * comment is the only record of.
     */
    function _splitDerivedFee(uint24 lpFee) private view returns (uint16) {
        uint256 ratio = protocolFeeSplitRatio;
        if (ratio == 0) return 0;
        if (ratio >= ONE_HUNDRED_PERCENT_RATIO) return MAX_PROTOCOL_FEE;

        uint256 l = uint256(lpFee);
        uint256 denominator = l + (ONE_HUNDRED_PERCENT_RATIO * ONE_HUNDRED_PERCENT_RATIO) / ratio
            - ONE_HUNDRED_PERCENT_RATIO;
        if (denominator == 0) return MAX_PROTOCOL_FEE;

        uint256 fee = (l * ONE_HUNDRED_PERCENT_RATIO) / denominator;
        return fee > MAX_PROTOCOL_FEE ? MAX_PROTOCOL_FEE : uint16(fee);
    }

    /// @dev Pack two directional fees into the uint24 layout core expects:
    /// low 12 bits = zeroForOne, upper 12 bits = oneForZero.
    function _pack(FeeConfig memory config) private pure returns (uint24) {
        return uint24(config.zeroForOne) | (uint24(config.oneForZero) << 12);
    }

    /*//////////////////////////////////////////////////////////////
                        COLLECTION - THE V1 GAP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw accrued protocol fees from a pool manager.
     *
     * @dev The function V1 did not have. `collectProtocolFees` on the manager admits only its
     * configured controller, so this contract is the sole route to funds that would otherwise sit
     * in `protocolFeesAccrued` forever.
     *
     * `poolManager` is an argument rather than immutable state because ONE controller serves both
     * the CL and Bin managers on this deployment, and a third could be added. The parameter is
     * harmless: the call only succeeds where this contract is the installed controller, so a
     * wrong address wastes gas and moves nothing.
     *
     * OWNER ONLY, AND DELIBERATELY NOT THE GUARDIAN. The guardian's whole security argument is
     * that it can only make the protocol take less; handing it a withdrawal would make a stolen
     * guardian key a theft rather than an inconvenience.
     *
     * @param poolManager The manager holding the accrued balance.
     * @param currency The token to withdraw.
     * @param amount Pass `0` to sweep the entire accrued balance — core reads that as "all".
     * @param recipient Where the funds go. The governance Safe, per the ownership table; there is
     * no separate treasury address and one should not be introduced.
     */
    function collect(address poolManager, Currency currency, uint256 amount, address recipient)
        external
        onlyOwner
        returns (uint256 amountCollected)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        amountCollected = IProtocolFees(poolManager).collectProtocolFees(recipient, currency, amount);
        emit ProtocolFeesCollected(poolManager, currency, recipient, amountCollected);
    }

    /**
     * @notice Reprice a pool that ALREADY EXISTS.
     *
     * @dev The third function of this shape, and the third gap of the same kind. Core stamps a
     * pool's protocol fee at `initialize` and never re-reads the controller, so everything in the
     * "GOVERNANCE" section below changes only what FUTURE pools are born with.
     * `ProtocolFees.setProtocolFee` is the sole route to an existing one — and, like
     * `collectProtocolFees`, it admits only the installed controller:
     *
     *     if (msg.sender != address(protocolFeeController)) revert InvalidCaller();
     *
     * V1 could not call it. Without this function V2 could not either, which would mean:
     *   - every pool created before V2 is installed stays at zero for the rest of its life;
     *   - a policy change could never reach a pool that already exists;
     *   - a pool mispriced by an error at creation could never be corrected.
     *
     * The pattern worth naming, since it has now bitten three times in one contract: core gates a
     * privileged call on `msg.sender == protocolFeeController`, and a controller without a
     * matching passthrough silently forfeits that power forever. Before adding a capability to
     * core's fee surface, grep `ProtocolFees.sol` for `InvalidCaller` and check this contract has
     * a route to every one of them.
     *
     * @param newProtocolFee PACKED, as core expects: low 12 bits zeroForOne, next 12 oneForZero.
     * Use `packFee`. Core validates it and reverts `ProtocolFeeTooLarge` on anything above the
     * cap, so a bad value costs gas rather than money.
     */
    function setPoolProtocolFee(address poolManager, PoolKey calldata key, uint24 newProtocolFee)
        external
        onlyOwner
    {
        IProtocolFees(poolManager).setProtocolFee(key, newProtocolFee);
    }

    /**
     * @notice Bring an existing pool up to whatever this controller's current policy says.
     *
     * @dev The bulk-fix path. After a split-ratio change, or after installing this controller
     * over one that charged nothing, the pools that already exist are the ones left behind — and
     * working out each one's correct fee by hand is how a pool ends up mispriced. This resolves
     * the same policy `protocolFeeForPool` would apply to a new pool with this key, and pushes it.
     *
     * Owner-only, and per-pool on purpose. A sweep over every pool at once would be a single
     * transaction that reprices the whole protocol, which is not a thing to make easy.
     */
    function syncPoolToPolicy(address poolManager, PoolKey calldata key)
        external
        onlyOwner
        returns (uint24 applied)
    {
        applied = this.protocolFeeForPool(key);
        IProtocolFees(poolManager).setProtocolFee(key, applied);
    }

    /// @notice Pack two directional fees the way core expects. Reverts above the cap, unlike the
    /// hot path, because this one is called by a human writing a Safe batch.
    function packFee(uint16 zeroForOne, uint16 oneForZero) external pure returns (uint24) {
        if (zeroForOne > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(zeroForOne, MAX_PROTOCOL_FEE);
        if (oneForZero > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(oneForZero, MAX_PROTOCOL_FEE);
        return uint24(zeroForOne) | (uint24(oneForZero) << 12);
    }

    /**
     * @notice Sweep accrued fees to the treasury. PERMISSIONLESS, on purpose.
     *
     * @dev This is the function a scheduled job calls. It follows the same security model as
     * `packages/keeper`, which CLAUDE.md states as: "All four are permissionless, and that is the
     * security model. A stolen keeper key buys an attacker nothing they could not already do from
     * any address."
     *
     * The same is true here, and it is a property of the SIGNATURE, not of a check. There is no
     * recipient argument: the destination is `treasury`, which only the owner can change. So the
     * worst a hostile caller achieves is paying gas to move DeepCore's revenue into DeepCore's Safe —
     * the thing that was going to happen anyway. That is why this needs no role, no allowlist and
     * no bot key with privileges.
     *
     * The alternative — automating the owner-only `collect` — would mean a scheduled process
     * holding Safe signer keys, collapsing 2-of-3 to 1-of-1 for a key that can also queue
     * `registerApp`. Not a trade worth making for a fee sweep.
     *
     * REVERTS WHEN THERE IS NOTHING TO COLLECT, and that is deliberate. `collectProtocolFees`
     * returns zero rather than reverting on an empty balance, which is the exact trap CLAUDE.md
     * records against `settleBeneficiaries`: a job that "does NOT revert when pointless... will
     * pay gas to do nothing forever". Making it a revert turns the check into a free read for any
     * caller that simulates first, which the keeper always does.
     */
    function sweep(address poolManager, Currency currency) external returns (uint256 amountCollected) {
        address to = treasury;
        uint256 pending = IProtocolFees(poolManager).protocolFeesAccrued(currency);
        if (pending == 0) revert NothingToCollect(poolManager, currency);

        amountCollected = IProtocolFees(poolManager).collectProtocolFees(to, currency, 0);
        emit ProtocolFeesCollected(poolManager, currency, to, amountCollected);
    }

    /// @notice Change where `sweep` sends fees. Owner-only; zero is refused.
    /// @dev Zero would not merely misroute — `collectFee` would transfer to `address(0)`, which
    /// for most ERC-20s burns the balance rather than reverting.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroRecipient();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice How much is waiting to be collected. A read, so anyone may call it.
    function accrued(address poolManager, Currency currency) external view returns (uint256) {
        return IProtocolFees(poolManager).protocolFeesAccrued(currency);
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE - VALIDATED
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the share of the total swap fee the protocol takes.
    /// @dev Only affects pools created AFTER this call — core stamps the protocol fee into the
    /// pool at `initialize`. Existing pools are moved with `setPoolFee` plus the manager's own
    /// `setProtocolFee`, one at a time and on purpose.
    function setProtocolFeeSplitRatio(uint256 newRatio) external onlyOwner {
        if (newRatio > ONE_HUNDRED_PERCENT_RATIO) revert InvalidSplitRatio(newRatio);
        emit SplitRatioUpdated(protocolFeeSplitRatio, newRatio);
        protocolFeeSplitRatio = newRatio;
    }

    /// @notice Override the fee for one pool. Highest precedence.
    function setPoolFee(PoolId poolId, bool isSet, uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        _validate(zeroForOne);
        _validate(oneForZero);
        _poolFee[poolId] = FeeConfig({isSet: isSet, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit PoolFeeUpdated(poolId, isSet, zeroForOne, oneForZero);
    }

    /// @notice Override the fee for every pool at one static LP-fee tier.
    function setTierFee(uint24 lpFeeTier, bool isSet, uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        _validate(zeroForOne);
        _validate(oneForZero);
        _tierFee[lpFeeTier] = FeeConfig({isSet: isSet, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit TierFeeUpdated(lpFeeTier, isSet, zeroForOne, oneForZero);
    }

    /// @notice Set the fee for dynamic-fee pools, which have no tier to derive a share from.
    function setDynamicFee(bool isSet, uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        _validate(zeroForOne);
        _validate(oneForZero);
        _dynamicFee = FeeConfig({isSet: isSet, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit DynamicFeeUpdated(isSet, zeroForOne, oneForZero);
    }

    /// @notice Turn all protocol fees off, or back on. Owner-only in both directions.
    function setFeesDisabled(bool disabled) external onlyOwner {
        feesDisabled = disabled;
        emit FeesDisabledSet(disabled);
    }

    /// @notice Switch every pool to a zero protocol fee immediately. One-way for the guardian.
    /// @dev Re-enabling is an escalation and stays owner-only. A compromised guardian costs the
    /// protocol revenue and nothing else — it cannot raise a fee, retarget one, collect, or
    /// change who controls this contract.
    function emergencyDisableFees() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        feesDisabled = true;
        emit FeesDisabledSet(true);
        emit EmergencyFeesDisabled(msg.sender);
    }

    /// @notice Appoint or remove the guardian.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Disabled. An unowned controller cannot collect, and every fee accrued afterwards
    /// would be permanently unreachable — the exact defect V2 exists to repair.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev This controller custodies nothing: `collect`/`sweep` pay straight from the pool manager, so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function _validate(uint16 fee) private pure {
        if (fee > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(fee, MAX_PROTOCOL_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function poolFee(PoolId poolId) external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _poolFee[poolId];
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }

    function tierFee(uint24 lpFeeTier) external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _tierFee[lpFeeTier];
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }

    function dynamicFee() external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _dynamicFee;
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }
}
