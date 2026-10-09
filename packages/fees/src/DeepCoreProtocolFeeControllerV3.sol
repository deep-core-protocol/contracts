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

/// @title DeepCoreProtocolFeeControllerV3
/// @notice Kit launch pools whose liquidity is locked are born paying ZERO core protocol fee,
/// automatically. Every other pool pays exactly what `DeepCoreProtocolFeeControllerV2` says.
///
/// @dev Design of record: `packages/fees/docs/controller-v3.md`. The short version:
///
///     protocolFeeForPool(key) = launchOracle.isLockedLaunch(key.toId()) == true ? 0 : policy.protocolFeeForPool(key)
///
/// COMPOSED OVER THE LIVE V2, NOT A COPY OF IT. `policy` is the deployed V2 instance. Every piece of
/// fee configuration - split ratio, tier and dynamic fees, per-pool overrides, the kill switch and
/// the guardian - stays on V2, under V2's already-tested setters and caps. Nothing is migrated, so
/// nothing can be migrated wrongly. V3 adds only the zero rule and re-provides the four functions
/// core gates on `msg.sender == protocolFeeController`, which V2 loses the moment V3 is installed.
///
/// THE ORACLE IS THE KIT. `launchOracle` must be the LaunchpadKit v2 deployment itself, immutable
/// here. Its word at `initialize` is a promise about the rest of the same transaction ("this pool's
/// position will be in the locker, or this call reverts"), and it is the only party that can make
/// that promise before the pool exists. Neither the launch registry nor the locker can: both
/// records require an initialized pool, and core reads the fee inside `initialize`.
///
/// HOT PATH. Core staticcalls `protocolFeeForPool` inside every pool creation and reverts pool
/// creation if it reverts. So:
///   - the oracle call is gas-capped, copies at most 32 bytes, and treats ANY failure as "not a
///     locked launch" - a broken kit loses the zero rule, never pool creation;
///   - it cannot be gas-starved into a wrong answer: below `LAUNCH_ORACLE_MIN_GASLEFT` it reverts
///     rather than letting EIP-150 hand the kit less than its stipend;
///   - the V2 call is NOT caught. V2 never reverts on any input; if it did, falling back to zero
///     would give whoever caused the failure a zero-fee pool for life. Failing closed is correct.
///   - the oracle can only ever LOWER a pool's fee to zero. It can never raise one.
///
/// OWNERSHIP: the governance Safe (CLAUDE.md ownership table, `DeepCoreProtocolFeeController` owner).
/// No guardian here: V2's guardian still zeroes every non-launch pool through `policy`, and a
/// launch pool is already zero. `renounceOwnership` reverts.
contract DeepCoreProtocolFeeControllerV3 is IProtocolFeeController, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    /// @notice Gas forwarded to `launchOracle.isLockedLaunch`. A plain storage read needs ~2.5k.
    uint256 public constant LAUNCH_ORACLE_GAS = 50_000;

    /// @notice Minimum `gasleft()` before the oracle call: the stipend, the 1/64 EIP-150 retains, and
    /// headroom for a cold account access. Below it the call could receive less than the stipend.
    uint256 public constant LAUNCH_ORACLE_MIN_GASLEFT = LAUNCH_ORACLE_GAS + LAUNCH_ORACLE_GAS / 63 + 5_000;

    /// @notice The live `DeepCoreProtocolFeeControllerV2`. Source of every non-launch fee.
    IProtocolFeeController public immutable policy;

    /// @notice The LaunchpadKit v2 deployment. The only address whose answer can zero a pool.
    address public immutable launchOracle;

    /// @notice Where the permissionless `sweep` pays. Owner-settable, never zero.
    address public treasury;

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolFeesCollected(
        address indexed poolManager, Currency indexed currency, address indexed recipient, uint256 amount
    );

    error ZeroAddress();
    /// @notice A constructor dependency is not a contract.
    error NoCode(address account);
    /// @notice `policy` and `launchOracle` must be different contracts.
    error InvalidDependencies(address policy, address launchOracle);
    /// @notice The oracle did not answer `isLockedLaunch(0)` with exactly one ABI-encoded `false`.
    error OracleDoesNotImplementInterface(address launchOracle);
    /// @notice Not enough gas to give the oracle its full stipend, so its answer could not be trusted.
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

    /// @param owner_ The governance Safe.
    /// @param policy_ The live `DeepCoreProtocolFeeControllerV2`.
    /// @param launchOracle_ The LaunchpadKit v2 deployment. Never an adapter with a setter.
    constructor(address owner_, IProtocolFeeController policy_, address launchOracle_) Ownable(owner_) {
        if (address(policy_) == address(0) || launchOracle_ == address(0)) revert ZeroAddress();
        if (address(policy_).code.length == 0) revert NoCode(address(policy_));
        if (launchOracle_.code.length == 0) revert NoCode(launchOracle_);
        if (address(policy_) == launchOracle_) revert InvalidDependencies(address(policy_), launchOracle_);

        policy = policy_;
        launchOracle = launchOracle_;

        /* Catches a mistyped address (the v1 kit, the registry, the locker) at deploy time instead
           of as a zero rule that silently never fires. No real pool has id 0. */
        (bool ok, uint256 word) = _askOracle(launchOracle_, bytes32(0));
        if (!ok || word != 0) revert OracleDoesNotImplementInterface(launchOracle_);

        treasury = owner_;
        emit TreasuryUpdated(address(0), owner_);
    }

    /*//////////////////////////////////////////////////////////////
                    HOT PATH - CALLED DURING POOL INIT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolFeeController
    function protocolFeeForPool(PoolKey memory poolKey) external view override returns (uint24) {
        return _resolve(poolKey);
    }

    /// @notice Whether `launchOracle` currently vouches for `poolId` as a locked launch.
    /// @dev Same predicate as the hot path, including the gas floor.
    function isLockedLaunchPool(PoolId poolId) external view returns (bool) {
        return _isLockedLaunch(PoolId.unwrap(poolId));
    }

    function _resolve(PoolKey memory poolKey) private view returns (uint24) {
        uint24 fee = policy.protocolFeeForPool(poolKey);
        /* Both branches below return zero when V2 already says zero, so skip the oracle call. */
        if (fee == 0) return 0;
        if (_isLockedLaunch(PoolId.unwrap(poolKey.toId()))) return 0;
        return fee;
    }

    function _isLockedLaunch(bytes32 poolId) private view returns (bool) {
        uint256 available = gasleft();
        if (available < LAUNCH_ORACLE_MIN_GASLEFT) {
            revert InsufficientGasForLaunchCheck(available, LAUNCH_ORACLE_MIN_GASLEFT);
        }
        (bool ok, uint256 word) = _askOracle(launchOracle, poolId);
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

    /*//////////////////////////////////////////////////////////////
          CONTROLLER-GATED CORE CALLS - WHAT V2 LOSES ON THE SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw accrued protocol fees, including everything accrued while V2 was installed.
    /// @dev Core checks the caller at collection time, so balances banked under V2 are collectable
    /// here. `amount == 0` means the whole balance. Owner only.
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
    /// @dev A kit-flagged (locked launch) pool may only ever be set to 0: the zero fee is the rule the
    /// kit's creators were promised at launch, and the owner's escape hatch must not be able to break it.
    /// A non-zero fee on such a pool reverts; 0 always goes through (it is what `syncPoolToPolicy` would
    /// resolve anyway).
    function setPoolProtocolFee(address poolManager, PoolKey calldata key, uint24 newProtocolFee)
        external
        onlyOwner
    {
        if (newProtocolFee != 0 && _isLockedLaunch(PoolId.unwrap(key.toId()))) {
            revert LockedLaunchPoolKeepsZeroFee(key.toId());
        }
        IProtocolFees(poolManager).setProtocolFee(key, newProtocolFee);
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`. Owner only.
    /// @dev This controller custodies nothing by design - `collect`/`sweep` pay the recipient straight
    /// from the pool manager - so any balance here is misdirected value with, until now, no path out
    /// (acceptance finding A, 2026-09-18). Native cannot reach it: no receive, no fallback.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Push this controller's current answer onto an existing pool.
    /// @dev Resolves 0 for a kit-flagged pool, so it also fixes launch pools created before V3 was
    /// installed. Owner only and per pool, as in V2.
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
