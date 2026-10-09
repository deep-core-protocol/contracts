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

import {ILockedLaunchOracle} from "./interfaces/ILockedLaunchOracle.sol";

/// @title DeepCoreProtocolFeeControllerV4
/// @notice Locked launch pools of EVERY kit in a fixed set, and pools of every hook on a Safe-kept
/// zero-fee list, are born paying ZERO core protocol fee, automatically. Every other pool pays exactly
/// what `DeepCoreProtocolFeeControllerV2` says.
///
/// @dev `DeepCoreProtocolFeeControllerV3` with two changes of substance: it asks a fixed, immutable SET of
/// oracles instead of one, and a pool is a locked launch when ANY of them answers exactly `true`; and
/// it zeroes the pools of listed hooks (see ZERO-FEE HOOKS below).
///
///     protocolFeeForPool(key) = isZeroFeeHook(key.hooks)
///                               || (any launchOracle_i).isLockedLaunch(key.toId()) == true
///                                   ? 0
///                                   : policy.protocolFeeForPool(key)
///
/// WHY IT EXISTS. A hook address is part of pool identity, so new launch guards mean a new kit beside
/// the first one, and the first kit and its pools stay for good. A pool manager has ONE controller, and
/// V3 names ONE kit. Bound to the new kit, V3 would stop recognising the first kit's pools: they would
/// keep the zero they were born with only until the owner's `setPoolProtocolFee` stamped a fee on
/// them, which is the power acceptance finding B (2026-09-18) took away. V4 recognises both kits, so
/// the refusal survives the second kit (owner decision, 2026-09-28).
///
/// WHAT IT DOES NOT CHANGE FROM V3. Everything else, deliberately:
///   - `policy` is still the live V2, called and never copied; all fee configuration, the kill switch
///     and the guardian stay there (design of record: `packages/fees/docs/controller-v3.md`);
///   - the oracle call is V3's, byte for byte: same selector, same stipend, at most 32 bytes copied,
///     and only `success && returndatasize == 32 && word == 1` counts as a yes;
///   - the V2 call is still NOT caught: if the policy ever failed, pool creation fails with it;
///   - `collect`, `sweep`, `setPoolProtocolFee`, `syncPoolToPolicy`, `setTreasury`, `accrued` and
///     `rescueERC20` are V3's; ownership is `Ownable2Step` with `renounceOwnership` reverting;
///   - no `receive`, no `fallback`, no `delegatecall`, no `selfdestruct`, and it custodies nothing.
///
/// TRUST. Each oracle can only ever LOWER a pool's fee to zero; none can raise one, and none can
/// affect a pool another oracle vouches for except by also vouching for it. So adding a kit to the set
/// can waive revenue on that kit's pools and nothing else - bounded to revenue, never user funds.
/// "That kit's pools" is the kit's promise (`ILockedLaunchOracle`, requirement 1), not something this
/// contract can check: an oracle is asked about every pool that would pay, so a kit that vouched for
/// pools it did not create would zero those too, and the owner could not charge them here. That is
/// the whole of the damage one wrong entry can do, and it is why every entry must be a DeepCore kit. The
/// set is fixed at construction: the oracles are immutables, there is no setter, no owner path and no
/// storage slot behind them. Changing the set is a new controller, installed through Custody (48 h,
/// public), exactly as replacing V3's single kit was. Every oracle must be a DeepCore kit itself, never an
/// adapter with a setter: an adapter would turn an immutable trust anchor into a mutable one.
///
/// HOT PATH AND GAS. Core staticcalls `protocolFeeForPool` inside every pool creation and reverts
/// pool creation if it reverts. The order is V3's: `policy` first, and zero is returned without asking
/// anyone when it says zero. Otherwise the oracles are asked in their constructor order, stopping at
/// the first `true`. What makes several oracles safe where one was:
///   - THE GAS FLOOR HOLDS PER CALL. `gasleft()` is checked against `LAUNCH_ORACLE_MIN_GASLEFT`
///     immediately before EACH oracle call, not once for the sequence. So every oracle that is asked
///     receives its whole stipend, whatever the oracles before it burned: EIP-150 can never hand a
///     later oracle less than `LAUNCH_ORACLE_GAS`. A floor checked once would let a caller pick a gas
///     limit at which an early oracle spends its stipend and the one that vouches is starved into a
///     failure, which reads as "not a locked launch" and charges the pool for life;
///   - so each answer is a function of state and never of the caller's gas limit, and so is the
///     result. A caller choosing a gas limit can make the call REVERT (`InsufficientGasForLaunchCheck`,
///     or plain out-of-gas after the last answer), which fails its own pool creation. It cannot make
///     an oracle be skipped, and it cannot get a non-zero fee resolved for a pool an oracle vouches for;
///   - the answers do not depend on the order either: asking stops at the first `true`, and every
///     oracle before it answered what it would have answered in any position. Order costs gas only;
///   - a broken oracle (reverting, burning its stipend, returning garbage) loses ITS zero rule and
///     costs every pool creation at most its stipend. It never blocks pool creation and never
///     silences the oracles after it;
///   - worst case the hot path spends `MAX_LAUNCH_ORACLES * (LAUNCH_ORACLE_GAS + a cold account
///     access)` on oracles, about 210k gas with four that all burn their stipend. An honest kit
///     answers from one storage read, about 5k each.
///
/// NO `launchOracle()` GETTER, ON PURPOSE. The first kit's library (`LaunchLegs._assertBornAtZero`)
/// calls `launchOracle()` on the installed controller and reverts a launch if the answer is the kit
/// itself while the pool's fee is not zero. That selector means "the one address whose word zeroes a
/// pool", and a set has no such address: whatever single oracle V4 named, that kit would be treated as
/// bound and every other kit in the set as unbound, and any reader of V3's getter would conclude the
/// other kits' pools are not covered. So V4 does not answer that selector at all. A kit's bounded
/// staticcall fails, and the kit treats V4 as a controller that is not bound to it alone - which is
/// the truth. The set is read through `launchOracles()`, `launchOracleCount()` and `isLaunchOracle()`.
///
/// ZERO-FEE HOOKS (owner decision, 2026-09-29). Pools on a DeepCore hook that already pays the protocol
/// its own share of each swap (the dynamic-fee hooks) must not pay the core fee on top. V2 has no
/// per-hook rule: every dynamic-fee pool pays its `DYNAMIC_FEE_PIPS`. So V4 keeps a list of hooks
/// whose pools are born at zero, read from `poolKey.hooks` in the hot path:
///   - the Safe ADDS a hook at once (`addZeroFeeHook`): it only lowers fees, and delay never sits on
///     privilege reduction;
///   - the Safe REMOVES one only after `ZERO_FEE_HOOK_REMOVAL_NOTICE` (`scheduleZeroFeeHookRemoval`,
///     cancellable while pending): removal raises the fee on NEW pools, so it is announced first;
///   - while a hook is listed, `setPoolProtocolFee` refuses a non-zero fee on its pools;
///   - core stores a pool's fee at initialization, so the list prices NEW pools. A pool created before
///     its hook was listed keeps what it was born with until the owner's `syncPoolToPolicy`.
///   - the CONSTRUCTOR may list a hook that has no code yet: its mined CREATE3 address, deployed by a
///     later step. That is how a hook's pools can never be opened before the list covers them: the hook
///     is deployed only once this controller is installed (the deploy scripts refuse otherwise). Only the
///     deployer bound into the salt can ever put code there; `addZeroFeeHook` still refuses no code.
///     Consequence, stated: that deployer could put a DIFFERENT contract at a listed address and have the
///     core fee waived on its pools. That reaches protocol revenue only, never user funds, and the release
///     scripts deploy only the real hooks there (D1/D2 read the hook back after deploying).
/// Trust: the list can only ever waive the core fee on pools of a listed hook, which is revenue and
/// never user funds; the launch-oracle set stays immutable and is not affected by it. The zero
/// address can never be listed, so hookless pools always pay what V2 says. The list lets a new
/// DeepCore hook get its zero with one Safe transaction instead of a new controller.
///
/// OWNERSHIP: the governance Safe (CLAUDE.md ownership table, `DeepCoreProtocolFeeController` owner).
/// No guardian here: V2's guardian still zeroes every non-launch pool through `policy`, and a
/// launch pool is already zero. `renounceOwnership` reverts.
contract DeepCoreProtocolFeeControllerV4 is IProtocolFeeController, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    /// @notice The most oracles one controller can name. Bounds the hot path's worst-case gas.
    uint256 public constant MAX_LAUNCH_ORACLES = 4;

    /// @notice Gas forwarded to each `isLockedLaunch` call. A plain storage read needs ~2.5k.
    uint256 public constant LAUNCH_ORACLE_GAS = 50_000;

    /// @notice Minimum `gasleft()` before EACH oracle call: the stipend, the 1/64 EIP-150 retains, and
    /// headroom for a cold account access. Below it the call could receive less than the stipend.
    uint256 public constant LAUNCH_ORACLE_MIN_GASLEFT = LAUNCH_ORACLE_GAS + LAUNCH_ORACLE_GAS / 63 + 5_000;

    /// @notice The live `DeepCoreProtocolFeeControllerV2`. Source of every non-launch fee.
    IProtocolFeeController public immutable policy;

    /// @notice How many oracles are configured, 1 to `MAX_LAUNCH_ORACLES`.
    uint256 public immutable launchOracleCount;

    /// @notice The configured oracles, in the order they are asked. Each is a DeepCore kit deployment and
    /// the only addresses whose answer can zero a pool. Slots past `launchOracleCount` are zero.
    /// @dev Immutables, not an array: the hot path reads them from code, with no SLOAD, and nothing
    /// can ever change them.
    address public immutable launchOracle0;
    address public immutable launchOracle1;
    address public immutable launchOracle2;
    address public immutable launchOracle3;

    /// @notice The shortest removal notice any deployment may carry.
    uint32 public constant MIN_ZERO_FEE_HOOK_REMOVAL_NOTICE = 1 days;

    /// @notice The longest removal notice any deployment may carry, so a typo cannot freeze the list.
    uint32 public constant MAX_ZERO_FEE_HOOK_REMOVAL_NOTICE = 90 days;

    /// @notice How long a scheduled removal waits before the hook's new pools pay the core fee again.
    uint32 public immutable ZERO_FEE_HOOK_REMOVAL_NOTICE;

    /// @notice Where the permissionless `sweep` pays. Owner-settable, never zero.
    address public treasury;

    /// @dev `listed` with `removalAt == 0` is listed; `removalAt` in the future is listed with a removal
    /// pending; `removalAt` reached is no longer listed (the removal applies itself, with no transaction).
    struct ZeroFeeHook {
        bool listed;
        uint40 removalAt;
    }

    mapping(address hook => ZeroFeeHook) private _zeroFeeHooks;

    event ZeroFeeHookAdded(address indexed hook);
    event ZeroFeeHookRemovalScheduled(address indexed hook, uint40 removalAt);
    event ZeroFeeHookRemovalCancelled(address indexed hook);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolFeesCollected(
        address indexed poolManager, Currency indexed currency, address indexed recipient, uint256 amount
    );

    error ZeroAddress();
    /// @notice A constructor dependency, `policy` or the named oracle, is not a contract.
    error NoCode(address account);
    /// @notice The oracle list is empty. A controller with nobody to ask is V2 with extra steps.
    error NoLaunchOracles();
    error TooManyLaunchOracles(uint256 count, uint256 maximum);
    /// @notice The oracle at `index` is the zero address.
    error ZeroLaunchOracle(uint256 index);
    /// @notice `policy` and every oracle must be different contracts.
    error InvalidDependencies(address policy, address launchOracle);
    /// @notice The same oracle is listed twice. Harmless to the rule, and almost always a list in which
    /// the kit that was meant to be there is missing - so it is refused rather than deployed.
    error DuplicateLaunchOracle(address launchOracle);
    /// @notice The oracle did not answer `isLockedLaunch(0)` with exactly one ABI-encoded `false`.
    error OracleDoesNotImplementInterface(address launchOracle);
    /// @notice Not enough gas to give an oracle its full stipend, so its answer could not be trusted.
    error InsufficientGasForLaunchCheck(uint256 available, uint256 required);
    error ZeroRecipient();
    error RenounceDisabled();
    /// @notice Nothing has accrued in this currency. A revert, so a simulating keeper pays nothing.
    error NothingToCollect(address poolManager, Currency currency);
    /// @dev A locked launch pool is born at 0 and stays there (CLAUDE.md "Kit fees": no double-dip);
    /// the only fee the owner may stamp on one is 0. Acceptance finding B, 2026-09-18.
    error LockedLaunchPoolKeepsZeroFee(PoolId poolId);
    error NothingToRescue(address token);
    error RescueToZero();
    /// @notice The removal notice is outside `MIN_..` to `MAX_ZERO_FEE_HOOK_REMOVAL_NOTICE`.
    error InvalidRemovalNotice(uint256 notice);
    /// @notice The hook is already listed with no removal pending.
    error AlreadyZeroFeeHook(address hook);
    /// @notice The hook is not listed, or its removal is already pending or done.
    error NotZeroFeeHook(address hook);
    /// @notice There is no pending removal to cancel (none scheduled, or it has already applied).
    error NoPendingRemoval(address hook);
    /// @notice The hook cannot be listed: it is the policy or a launch oracle.
    error InvalidZeroFeeHook(address hook);
    /// @dev A pool of a listed hook may only ever be set to 0 while the hook stays listed.
    error ZeroFeeHookPoolKeepsZeroFee(PoolId poolId, address hook);

    /// @param owner_ The governance Safe.
    /// @param policy_ The live `DeepCoreProtocolFeeControllerV2`.
    /// @param launchOracles_ The DeepCore kit deployments, 1 to `MAX_LAUNCH_ORACLES`, in the order they
    /// will be asked. Never an adapter with a setter.
    /// @param zeroFeeHooks_ Hooks listed from the start (may be empty); the Safe can add more later.
    /// @param zeroFeeHookRemovalNotice_ Seconds a removal waits, within the MIN/MAX constants.
    constructor(
        address owner_,
        IProtocolFeeController policy_,
        address[] memory launchOracles_,
        address[] memory zeroFeeHooks_,
        uint32 zeroFeeHookRemovalNotice_
    ) Ownable(owner_) {
        if (address(policy_) == address(0)) revert ZeroAddress();
        if (address(policy_).code.length == 0) revert NoCode(address(policy_));

        uint256 count = launchOracles_.length;
        if (count == 0) revert NoLaunchOracles();
        if (count > MAX_LAUNCH_ORACLES) revert TooManyLaunchOracles(count, MAX_LAUNCH_ORACLES);

        for (uint256 i; i < count; ++i) {
            address oracle = launchOracles_[i];
            if (oracle == address(0)) revert ZeroLaunchOracle(i);
            if (oracle.code.length == 0) revert NoCode(oracle);
            if (oracle == address(policy_)) revert InvalidDependencies(address(policy_), oracle);
            for (uint256 j; j < i; ++j) {
                if (launchOracles_[j] == oracle) revert DuplicateLaunchOracle(oracle);
            }

            /* Catches a mistyped address (the v1 kit, the registry, the locker) at deploy time instead
               of as a zero rule that silently never fires. No real pool has id 0. Per oracle: one
               good kit in the list must not carry a wrong address in with it. */
            (bool ok, uint256 word) = _askOracle(oracle, bytes32(0));
            if (!ok || word != 0) revert OracleDoesNotImplementInterface(oracle);
        }

        policy = policy_;
        launchOracleCount = count;
        launchOracle0 = launchOracles_[0];
        launchOracle1 = count > 1 ? launchOracles_[1] : address(0);
        launchOracle2 = count > 2 ? launchOracles_[2] : address(0);
        launchOracle3 = count > 3 ? launchOracles_[3] : address(0);

        if (
            zeroFeeHookRemovalNotice_ < MIN_ZERO_FEE_HOOK_REMOVAL_NOTICE
                || zeroFeeHookRemovalNotice_ > MAX_ZERO_FEE_HOOK_REMOVAL_NOTICE
        ) revert InvalidRemovalNotice(zeroFeeHookRemovalNotice_);
        ZERO_FEE_HOOK_REMOVAL_NOTICE = zeroFeeHookRemovalNotice_;

        treasury = owner_;
        emit TreasuryUpdated(address(0), owner_);

        /* The same checks `addZeroFeeHook` makes, against the arguments: immutables cannot be read by a
           function called during construction. */
        for (uint256 i; i < zeroFeeHooks_.length; ++i) {
            address hook = zeroFeeHooks_[i];
            if (hook == address(policy_)) revert InvalidZeroFeeHook(hook);
            for (uint256 j; j < count; ++j) {
                if (launchOracles_[j] == hook) revert InvalidZeroFeeHook(hook);
            }
            _listZeroFeeHook(hook);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    HOT PATH - CALLED DURING POOL INIT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolFeeController
    function protocolFeeForPool(PoolKey memory poolKey) external view override returns (uint24) {
        return _resolve(poolKey);
    }

    /// @notice Whether ANY configured oracle currently vouches for `poolId` as a locked launch.
    /// @dev Same predicate as the hot path, including the gas floor before each oracle call.
    function isLockedLaunchPool(PoolId poolId) external view returns (bool) {
        return _isLockedLaunch(PoolId.unwrap(poolId));
    }

    function _resolve(PoolKey memory poolKey) private view returns (uint24) {
        uint24 fee = policy.protocolFeeForPool(poolKey);
        /* Every branch below returns zero when V2 already says zero, so skip the lookups. */
        if (fee == 0) return 0;
        /* One storage read, before the oracle calls it can save. */
        if (_isZeroFeeHook(address(poolKey.hooks))) return 0;
        if (_isLockedLaunch(PoolId.unwrap(poolKey.toId()))) return 0;
        return fee;
    }

    /// @dev Listed, and no removal has reached its time. The zero address is never listed.
    function _isZeroFeeHook(address hook) private view returns (bool) {
        ZeroFeeHook memory z = _zeroFeeHooks[hook];
        return z.listed && (z.removalAt == 0 || block.timestamp < z.removalAt);
    }

    /// @dev Asks the oracles in order and stops at the first that vouches. Every oracle that is asked
    /// is asked with its full stipend (`_vouches`), so which oracle answers first changes the gas
    /// spent and never the result.
    function _isLockedLaunch(bytes32 poolId) private view returns (bool) {
        uint256 count = launchOracleCount;
        for (uint256 i; i < count; ++i) {
            if (_vouches(_launchOracleAt(i), poolId)) return true;
        }
        return false;
    }

    /// @dev One oracle's answer, behind its own gas floor. The floor is checked HERE, before every
    /// call, because the gas an earlier oracle burned is gone by the time a later one is asked: a
    /// floor checked once at the top would cover the first call only.
    function _vouches(address oracle, bytes32 poolId) private view returns (bool) {
        uint256 available = gasleft();
        if (available < LAUNCH_ORACLE_MIN_GASLEFT) {
            revert InsufficientGasForLaunchCheck(available, LAUNCH_ORACLE_MIN_GASLEFT);
        }
        (bool ok, uint256 word) = _askOracle(oracle, poolId);
        /* ABI `bool` is exactly 0 or 1. Anything else is a malformed answer, and a malformed answer
           must never be the one that waives revenue. */
        return ok && word == 1;
    }

    /// @dev `ok` is true only when the call succeeded AND returned exactly 32 bytes. At most 32 bytes
    /// are copied, so a hostile return cannot bill this call for memory expansion.
    function _askOracle(address oracle, bytes32 poolId) private view returns (bool ok, uint256 word) {
        bytes4 selector = ILockedLaunchOracle.isLockedLaunch.selector;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, poolId)
            ok := staticcall(LAUNCH_ORACLE_GAS, oracle, 0x00, 0x24, 0x00, 0x20)
            word := mload(0x00)
            ok := and(ok, eq(returndatasize(), 0x20))
        }
    }

    /// @dev `index` is always below `launchOracleCount`, so this never returns an unused zero slot.
    function _launchOracleAt(uint256 index) private view returns (address) {
        if (index == 0) return launchOracle0;
        if (index == 1) return launchOracle1;
        if (index == 2) return launchOracle2;
        return launchOracle3;
    }

    /*//////////////////////////////////////////////////////////////
                         THE ORACLE SET - READ ONLY
    //////////////////////////////////////////////////////////////*/

    /// @notice The configured oracles, in the order they are asked.
    /// @dev There is deliberately no `launchOracle()`: see the contract header.
    function launchOracles() external view returns (address[] memory oracles) {
        uint256 count = launchOracleCount;
        oracles = new address[](count);
        for (uint256 i; i < count; ++i) {
            oracles[i] = _launchOracleAt(i);
        }
    }

    /// @notice Whether `candidate` is one of the configured oracles. The zero address never is, even
    /// though the unused slots hold it.
    function isLaunchOracle(address candidate) external view returns (bool) {
        return _isLaunchOracle(candidate);
    }

    /*//////////////////////////////////////////////////////////////
                           ZERO-FEE HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether NEW pools on `hook` are born at zero core fee right now.
    function isZeroFeeHook(address hook) external view returns (bool) {
        return _isZeroFeeHook(hook);
    }

    /// @notice The raw entry: whether it was listed and when a scheduled removal applies (0 = none).
    function zeroFeeHook(address hook) external view returns (bool listed, uint40 removalAt) {
        ZeroFeeHook memory z = _zeroFeeHooks[hook];
        return (z.listed, z.removalAt);
    }

    /// @notice List `hook`: its new pools are born at zero, at once. Also cancels a pending removal,
    /// and re-lists a hook whose removal has applied. Owner only.
    function addZeroFeeHook(address hook) external onlyOwner {
        if (hook == address(policy) || _isLaunchOracle(hook)) revert InvalidZeroFeeHook(hook);
        /* A typo fails here, not as a zero rule that never fires. Only the constructor may name a hook
           that does not exist yet (see ZERO-FEE HOOKS). */
        if (hook == address(0)) revert ZeroAddress();
        if (hook.code.length == 0) revert NoCode(hook);
        _listZeroFeeHook(hook);
    }

    /// @notice Announce the removal of `hook`: after `ZERO_FEE_HOOK_REMOVAL_NOTICE` its new pools pay
    /// the core fee again, with no further transaction. Owner only.
    function scheduleZeroFeeHookRemoval(address hook) external onlyOwner {
        ZeroFeeHook storage z = _zeroFeeHooks[hook];
        if (!z.listed || z.removalAt != 0) revert NotZeroFeeHook(hook);
        uint40 removalAt = uint40(block.timestamp) + ZERO_FEE_HOOK_REMOVAL_NOTICE;
        z.removalAt = removalAt;
        emit ZeroFeeHookRemovalScheduled(hook, removalAt);
    }

    /// @notice Cancel a removal that has not applied yet. Owner only.
    function cancelZeroFeeHookRemoval(address hook) external onlyOwner {
        ZeroFeeHook storage z = _zeroFeeHooks[hook];
        if (!z.listed || z.removalAt == 0 || block.timestamp >= z.removalAt) revert NoPendingRemoval(hook);
        z.removalAt = 0;
        emit ZeroFeeHookRemovalCancelled(hook);
    }

    /// @dev Storage only (callable from the constructor). No code check here: the constructor may list a
    /// hook's mined CREATE3 address before the hook is deployed; `addZeroFeeHook` checks code itself.
    function _listZeroFeeHook(address hook) private {
        if (hook == address(0)) revert ZeroAddress();
        ZeroFeeHook storage z = _zeroFeeHooks[hook];
        if (z.listed && z.removalAt == 0) revert AlreadyZeroFeeHook(hook);
        z.listed = true;
        z.removalAt = 0;
        emit ZeroFeeHookAdded(hook);
    }

    function _isLaunchOracle(address candidate) private view returns (bool) {
        if (candidate == address(0)) return false;
        return candidate == launchOracle0 || candidate == launchOracle1 || candidate == launchOracle2
            || candidate == launchOracle3;
    }

    /*//////////////////////////////////////////////////////////////
          CONTROLLER-GATED CORE CALLS - WHAT V2 LOSES ON THE SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw accrued protocol fees, including everything accrued under an earlier controller.
    /// @dev Core checks the caller at collection time, so balances banked under V2 or V3 are
    /// collectable here. `amount == 0` means the whole balance. Owner only.
    function collect(address poolManager, Currency currency, uint256 amount, address recipient)
        external
        onlyOwner
        returns (uint256 amountCollected)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        amountCollected = IProtocolFees(poolManager).collectProtocolFees(recipient, currency, amount);
        emit ProtocolFeesCollected(poolManager, currency, recipient, amountCollected);
    }

    /// @notice Sweep accrued fees to `treasury`. Permissionless: there is no recipient argument.
    /// @dev Reverts on an empty balance so a keeper that simulates first never pays for nothing.
    function sweep(address poolManager, Currency currency) external returns (uint256 amountCollected) {
        address to = treasury;
        if (IProtocolFees(poolManager).protocolFeesAccrued(currency) == 0) {
            revert NothingToCollect(poolManager, currency);
        }
        amountCollected = IProtocolFees(poolManager).collectProtocolFees(to, currency, 0);
        emit ProtocolFeesCollected(poolManager, currency, to, amountCollected);
    }

    /// @notice Reprice a pool that already exists. Core validates `newProtocolFee` against its cap.
    /// @dev A pool ANY configured oracle vouches for (a locked launch) may only ever be set to 0: the
    /// zero fee is the rule that kit's creators were promised at launch, and the owner's escape hatch
    /// must not be able to break it for the first kit's pools any more than for the newest kit's.
    /// A non-zero fee on such a pool reverts; 0 always goes through (it is what `syncPoolToPolicy`
    /// would resolve anyway). The predicate reads a failed oracle call as "not a launch", so the
    /// refusal holds because the set is immutable, constructor-probed and gas-floored per call.
    function setPoolProtocolFee(address poolManager, PoolKey calldata key, uint24 newProtocolFee)
        external
        onlyOwner
    {
        if (newProtocolFee != 0) {
            if (_isZeroFeeHook(address(key.hooks))) revert ZeroFeeHookPoolKeepsZeroFee(key.toId(), address(key.hooks));
            if (_isLockedLaunch(PoolId.unwrap(key.toId()))) revert LockedLaunchPoolKeepsZeroFee(key.toId());
        }
        IProtocolFees(poolManager).setProtocolFee(key, newProtocolFee);
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`. Owner only.
    /// @dev This controller custodies nothing by design - `collect`/`sweep` pay the recipient straight
    /// from the pool manager - so any balance here is misdirected value (acceptance finding A,
    /// 2026-09-18). Native cannot reach it: no receive, no fallback, no payable function.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Push this controller's current answer onto an existing pool.
    /// @dev Resolves 0 for a pool any oracle vouches for, so it also fixes launch pools stamped under
    /// an earlier controller that did not know their kit. Owner only and per pool, as in V2.
    function syncPoolToPolicy(address poolManager, PoolKey calldata key)
        external
        onlyOwner
        returns (uint24 applied)
    {
        applied = _resolve(key);
        IProtocolFees(poolManager).setProtocolFee(key, applied);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroRecipient();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function accrued(address poolManager, Currency currency) external view returns (uint256) {
        return IProtocolFees(poolManager).protocolFeesAccrued(currency);
    }

    /// @notice Disabled. An unowned controller can never collect again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
