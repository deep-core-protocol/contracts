/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {DeepCoreMetadata} from "deepcore-registry/src/IDeepCoreRegistry.sol";

import {
    ILaunchpadKit,
    LaunchParams,
    LaunchResult,
    LaunchRecord,
    SeedParams,
    HookListingParams
} from "./interfaces/ILaunchpadKit.sol";
import {IHookRegistryListing} from "./interfaces/IHookRegistryListing.sol";
import {LaunchPresets, Preset, PresetParams} from "./libraries/LaunchPresets.sol";

/// @title LaunchpadKit
/// @notice Turns "launch a token on DeepCore with sniper protection" into one transaction.
///
/// @dev ############################ WHY THIS CONTRACT EXISTS ############################
///
/// Attaching `LaunchGuardHook` to a pool by hand means getting five separate things right, in
/// order, where four of them fail SILENTLY or CONFUSINGLY when you get them wrong:
///
///   1. `poolKey.fee` must be EXACTLY `0x800000`. `LPFeeLibrary.isDynamicLPFee` is an equality
///      test, not a bitmask. On a static-fee pool core parses the fee a hook returns from
///      `beforeSwap` and then DISCARDS it - no revert, no event. The pool looks guarded, the tax
///      never applies, and the first person to notice is the sniper. This kit does not accept a
///      fee argument at all: it hard-codes the dynamic-fee marker and asserts it.
///
///   2. `poolKey.parameters` bits 0-15 must equal the hook's own `getHooksRegistrationBitmap()`.
///      Core cross-checks them in `Hooks.validateHookConfig` and reverts with the undiagnosable
///      `HookConfigValidationError`. This kit reads the bitmap off the hook at DEPLOY time, pins
///      it, and builds every key from it.
///
///      (This is also the whole reason a kit like this can exist. On Uniswap v4 the permissions
///      live in the hook's ADDRESS, so a factory cannot compose a pool key without a CREATE2 salt
///      mined for that exact permission set. On DeepCore the permissions live in the pool key and are
///      cross-checked against the hook, so any hook works at any address and a plain factory is
///      all you need.)
///
///   3. `LaunchGuardHook.beforeInitialize` REVERTS unless the launch has already been configured,
///      so `configureLaunch` must happen BEFORE `initialize`. Do it the other way round and the
///      pool cannot be created.
///
///   4. The first caller of `configureLaunch` claims the pool id permanently. If a launchpad's
///      backend calls it from a hot wallet and then loses that key, the launch can never be
///      adjusted again. Here the KIT is the on-chain launch owner and it delegates to a recorded
///      operator, so the address that may reconfigure is an explicit parameter rather than an
///      accident of which key signed first.
///
///   5. `launchTokenIsCurrency0` has to agree with the address sort order, or `maxBuyPerTx` caps
///      SELLS instead of buys. This kit derives it; it is not a caller input.
///
/// ############################### WHAT IT DOES NOT DO ###############################
///
///   * It does not custody anything. Seed funds are pulled, spent, and refunded inside one call;
///     the kit holds no balance between transactions and has no withdrawal function, no owner and
///     no upgrade path.
///   * It does not make a launch safe. Read `LaunchPresets` - the hook prices early buying, it
///     does not police who buys. There is no per-wallet cap here because none is implementable.
///   * It does not cover bin pools. `BinLaunchGuardHook` needs `beforeMint` and a bin position
///     manager with a liquidity-shape encoding, and core caps a bin LP fee at 10%, so the presets
///     here do not carry over. A bin kit is a separate contract, not a flag on this one.
///   * It cannot seed a token that taxes EVERY transfer. `Vault._settle` credits
///     `balanceOfSelf() - reservesBefore`, so a token that shaves the payer-to-Vault transfer
///     always credits less than the debt and core rejects the lock with `CurrencyNotSettled`.
///     Such a token cannot provide liquidity to a DeepCore pool by ANY route, so there is nothing a
///     launchpad kit could do about it. A token that taxes the pull but exempts the liquidity path
///     - which is how real tax tokens are configured - works, because the amounts are measured on
///     arrival rather than assumed.
///   * It does not stop pool-id squatting. Anyone may call `LaunchGuardHook.configureLaunch` for
///     any key, including one naming your token, and claim it. If that happens `createLaunch`
///     reverts with the hook's `NotLaunchOwner` and the launch has to move to a different tick
///     spacing or a different hook deployment. That is a property of the hook's first-claim
///     ownership model, which this kit uses rather than replaces.
/// #####################################################################################
contract LaunchpadKit is ILaunchpadKit, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;
    using LPFeeLibrary for uint24;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The concentrated-liquidity singleton every pool this kit creates belongs to.
    ICLPoolManager public immutable clPoolManager;

    /// @notice The launch-guard hook every pool this kit creates is bound to.
    LaunchGuardHook public immutable hook;

    /// @notice Periphery position manager used to seed liquidity, so a launcher receives an
    /// ordinary position NFT they can manage with standard tooling rather than a bespoke receipt.
    ICLPositionManager public immutable positionManager;

    /// @notice Permit2 deployment the position manager pulls payment through.
    /// @dev On several DeepCore target chains this is NOT canonical Permit2. Read it off the position
    /// manager rather than assuming an address.
    IAllowanceTransfer public immutable permit2;

    /// @notice Optional hook registry. `address(0)` disables listing.
    IHookRegistryListing public immutable registry;

    /// @notice The bitmap this kit builds into every pool key.
    /// @dev Read from the hook at construction, not hard-coded, so a hook whose permissions differ
    /// from `beforeInitialize | beforeSwap` cannot be driven by this kit at all.
    uint16 public immutable hookBitmap;

    /// @notice `beforeInitialize` (bit 0) | `beforeSwap` (bit 6). What `LaunchGuardHook` reports.
    uint16 public constant EXPECTED_HOOK_BITMAP = 0x0041;

    /// @notice ERC-6372 clock mode of every time this kit writes: `block.timestamp` seconds. The
    /// hook it drives must report the same, checked at construction.
    string public constant CLOCK_MODE = "mode=timestamp";

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId poolId => LaunchRecord) private _records;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param _hook A deployed `LaunchGuardHook`. Its pool manager and bitmap are verified here so
    /// a mismatch is a deployment failure rather than a failed launch six months later.
    /// @param _registry May be `address(0)`, which disables the listing feature.
    /// @dev No block-time argument. Presets are seconds, the hook measures seconds, and there is
    /// nothing left for a deployer to declare about the chain's clock.
    constructor(
        ICLPoolManager _clPoolManager,
        LaunchGuardHook _hook,
        ICLPositionManager _positionManager,
        IAllowanceTransfer _permit2,
        IHookRegistryListing _registry
    ) {
        if (
            address(_clPoolManager) == address(0) || address(_hook) == address(0)
                || address(_positionManager) == address(0) || address(_permit2) == address(0)
        ) {
            revert ZeroAddress();
        }
        address hookManager = address(_hook.poolManager());
        if (hookManager != address(_clPoolManager)) {
            revert HookPoolManagerMismatch(address(_clPoolManager), hookManager);
        }

        uint16 bitmap = _hook.getHooksRegistrationBitmap();
        if (bitmap != EXPECTED_HOOK_BITMAP) revert UnexpectedHookBitmap(EXPECTED_HOOK_BITMAP, bitmap);

        // THE CLOCK GUARD. Every window this kit resolves is in seconds, and the hook must measure
        // them in seconds. The retired block-numbered `LaunchGuardHook` (0x8b4F…575c on Robinhood)
        // has no `CLOCK_MODE()`, and a kit wired to it would write "five minutes" as a block count
        // the hook reads as a timestamp - a start time in 1970, rejected, or worse, a window that
        // means something else entirely. Checked by CALL, with a named revert either way: verify,
        // never assume, same as the bitmap above.
        try _hook.CLOCK_MODE() returns (string memory mode) {
            if (keccak256(bytes(mode)) != keccak256(bytes(CLOCK_MODE))) revert HookClockMismatch(mode);
        } catch {
            revert HookClockMismatch("");
        }

        clPoolManager = _clPoolManager;
        hook = _hook;
        positionManager = _positionManager;
        permit2 = _permit2;
        registry = _registry;
        hookBitmap = bitmap;
    }

    /// @dev Native refunds arrive here from `Vault.take` (via the position manager's SWEEP) before
    /// being forwarded to the launcher inside the same call. Nothing is meant to rest here.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                              THE ONE CALL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKit
    function createLaunch(LaunchParams calldata p)
        external
        payable
        override
        nonReentrant
        returns (LaunchResult memory result)
    {
        (PoolKey memory key, PoolId poolId, bool launchTokenIsCurrency0) =
            _buildPoolKey(p.launchToken, p.quoteToken, p.tickSpacing);

        // Structural guarantee, not an opinion: a `beforeSwap` fee override is discarded without a
        // revert on a static-fee pool, so a launch on one would be protection in name only.
        assert(key.fee.isDynamicLPFee());

        if (_records[poolId].operator != address(0)) revert LaunchAlreadyExists(poolId);

        LaunchGuardHook.LaunchConfig memory cfg =
            _resolveConfig(p, launchTokenIsCurrency0);

        // ---- effects before any external call ----
        address operator = p.launchOperator == address(0) ? msg.sender : p.launchOperator;
        _records[poolId] =
            LaunchRecord({operator: operator, launchTokenIsCurrency0: launchTokenIsCurrency0, launchToken: p.launchToken});

        // ---- interactions ----
        // Order matters: `LaunchGuardHook.beforeInitialize` reverts on an unclaimed pool id, so
        // the configuration has to exist before the pool does.
        hook.configureLaunch(key, cfg);
        // The returned tick is redundant here: it is a pure function of `sqrtPriceX96`, which the
        // caller supplied, and the pool is brand new so there is nothing to reconcile it against.
        // forge-lint: disable-next-line(unused-return)
        clPoolManager.initialize(key, p.sqrtPriceX96);

        emit LaunchCreated(
            poolId,
            p.launchToken,
            operator,
            p.quoteToken,
            cfg.startTime,
            cfg.decaySeconds,
            cfg.initialFeeBips,
            cfg.finalFeeBips,
            cfg.maxBuyPerTx,
            launchTokenIsCurrency0,
            p.preset
        );

        result.key = key;
        result.poolId = poolId;
        result.startTime = cfg.startTime;
        result.decaySeconds = cfg.decaySeconds;
        result.launchTokenIsCurrency0 = launchTokenIsCurrency0;

        (result.positionTokenId, result.liquiditySeeded) = _seed(key, p.seed, launchTokenIsCurrency0);

        if (p.listing.register) _listHook(p.listing);
    }

    /*//////////////////////////////////////////////////////////////
                            RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Update a launch that has not opened yet.
    /// @dev The kit is the hook's registered launch owner, so this is the only route to
    /// `configureLaunch` for a pool the kit created. Every substantive restriction still lives in
    /// the hook: bounds on the fee schedule, and the hard freeze from `startTime` onwards. The
    /// kit adds exactly one rule of its own - `launchTokenIsCurrency0` is pinned to the value
    /// derived at creation, so an operator cannot flip `maxBuyPerTx` onto sells by accident.
    /// @param key The pool key returned by `createLaunch`. Self-authenticating: its hash is the id.
    function reconfigureLaunch(PoolKey calldata key, LaunchGuardHook.LaunchConfig calldata cfg) external nonReentrant {
        PoolId poolId = key.toId();
        LaunchRecord memory record = _records[poolId];
        if (record.operator == address(0)) revert UnknownLaunch(poolId);
        if (msg.sender != record.operator) revert NotLaunchOperator(poolId, msg.sender);

        LaunchGuardHook.LaunchConfig memory pinned = LaunchGuardHook.LaunchConfig({
            startTime: cfg.startTime,
            decaySeconds: cfg.decaySeconds,
            initialFeeBips: cfg.initialFeeBips,
            finalFeeBips: cfg.finalFeeBips,
            maxBuyPerTx: cfg.maxBuyPerTx,
            launchTokenIsCurrency0: record.launchTokenIsCurrency0,
            enabled: cfg.enabled
        });

        hook.configureLaunch(key, pinned);

        emit LaunchReconfigured(
            poolId,
            msg.sender,
            pinned.startTime,
            pinned.decaySeconds,
            pinned.initialFeeBips,
            pinned.finalFeeBips,
            pinned.maxBuyPerTx,
            pinned.enabled
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKit
    /// @notice Reproduces the exact key `createLaunch` would build, so an integrator can compute
    /// the pool id (and check whether it is already claimed) before sending a transaction.
    function computePoolKey(address launchToken, address quoteToken, int24 tickSpacing)
        external
        view
        override
        returns (PoolKey memory key, PoolId poolId, bool launchTokenIsCurrency0)
    {
        return _buildPoolKey(launchToken, quoteToken, tickSpacing);
    }

    /// @inheritdoc ILaunchpadKit
    function getLaunchRecord(PoolId poolId) external view override returns (LaunchRecord memory) {
        return _records[poolId];
    }

    /// @notice Preview the schedule a set of parameters resolves to, without sending anything.
    /// @dev Uses the CURRENT `block.timestamp`, so `startTime` shifts by however long the real
    /// transaction takes to land. That is deliberate; see `LaunchParams.startDelaySeconds`.
    function previewSchedule(LaunchParams calldata p)
        external
        view
        returns (LaunchGuardHook.LaunchConfig memory cfg)
    {
        (,, bool launchTokenIsCurrency0) = _buildPoolKey(p.launchToken, p.quoteToken, p.tickSpacing);
        return _resolveConfig(p, launchTokenIsCurrency0);
    }

    /*//////////////////////////////////////////////////////////////
                            KEY CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function _buildPoolKey(address launchToken, address quoteToken, int24 tickSpacing)
        private
        view
        returns (PoolKey memory key, PoolId poolId, bool launchTokenIsCurrency0)
    {
        if (launchToken == address(0)) revert LaunchTokenCannotBeNative();
        if (launchToken == quoteToken) revert IdenticalCurrencies(launchToken);
        if (launchToken.code.length == 0) revert LaunchTokenHasNoCode(launchToken);

        launchTokenIsCurrency0 = uint160(launchToken) < uint160(quoteToken);
        (address c0, address c1) =
            launchTokenIsCurrency0 ? (launchToken, quoteToken) : (quoteToken, launchToken);

        // Bits 0-15 carry the bitmap; `setTickSpacing` writes bits 16-39. Everything above stays
        // zero, which is what `CLPoolManager.initialize` checks.
        bytes32 parameters = bytes32(uint256(hookBitmap)).setTickSpacing(tickSpacing);

        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(hook)),
            poolManager: clPoolManager,
            // Never a caller input. A static fee here would silently disable the launch tax.
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: parameters
        });
        poolId = key.toId();
    }

    /*//////////////////////////////////////////////////////////////
                          SCHEDULE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function _resolveConfig(LaunchParams calldata p, bool launchTokenIsCurrency0)
        private
        view
        returns (LaunchGuardHook.LaunchConfig memory cfg)
    {
        uint24 initialFeeBips;
        uint24 finalFeeBips;
        uint32 decaySeconds;
        bool enabled;

        if (p.preset == Preset.Custom) {
            initialFeeBips = p.initialFeeBips;
            finalFeeBips = p.finalFeeBips;
            // Bounds (`MIN_DECAY_SECONDS`..`MAX_DECAY_SECONDS`) are the hook's, and it enforces them.
            decaySeconds = p.decaySeconds;
            enabled = p.enabled;
        } else {
            PresetParams memory pp = LaunchPresets.params(p.preset);
            if (pp.requiresMaxBuyPerTx && p.maxBuyPerTx == 0) revert MaxBuyRequiredByPreset(p.preset);
            initialFeeBips = pp.initialFeeBips;
            finalFeeBips = pp.finalFeeBips;
            enabled = pp.enabled;
            // Seconds in, seconds out. No conversion, so no rounding and no chain-clock assumption.
            decaySeconds = pp.windowSeconds;
        }

        // `LaunchGuardHook` rejects a start more than MAX_START_DELAY_SECONDS ahead; fail here with
        // a parameter-shaped error instead of the hook's absolute-time-shaped one.
        if (p.startDelaySeconds > hook.MAX_START_DELAY_SECONDS()) revert StartDelayTooLong(p.startDelaySeconds);
        uint256 startTime = block.timestamp + p.startDelaySeconds;

        cfg = LaunchGuardHook.LaunchConfig({
            // block.timestamp + at most 30 days is nowhere near uint40 (year 36812).
            // forge-lint: disable-next-line(unsafe-typecast)
            startTime: uint40(startTime),
            decaySeconds: decaySeconds,
            initialFeeBips: initialFeeBips,
            finalFeeBips: finalFeeBips,
            maxBuyPerTx: p.maxBuyPerTx,
            // Derived from the address sort, never supplied. Getting this backwards would apply
            // `maxBuyPerTx` to sells and leave buys uncapped.
            launchTokenIsCurrency0: launchTokenIsCurrency0,
            enabled: enabled
        });
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY SEEDING
    //////////////////////////////////////////////////////////////*/

    /// @dev Pulls the declared amounts, mints one position through the periphery position manager,
    /// and returns every unspent unit to `msg.sender` in the same call.
    ///
    /// Balance accounting is done as deltas against this contract's balance at entry, never as
    /// "whatever is here now". A stray balance sitting on the kit from a previous transaction
    /// therefore cannot be swept out by the next launcher.
    function _seed(PoolKey memory key, SeedParams calldata s, bool launchTokenIsCurrency0)
        private
        returns (uint256 tokenId, uint128 liquidity)
    {
        if (s.launchTokenAmount == 0 && s.quoteTokenAmount == 0) {
            if (msg.value != 0) revert UnexpectedNativeValue(msg.value);
            return (0, 0);
        }
        if (s.tickLower >= s.tickUpper) revert InvalidTickRange(s.tickLower, s.tickUpper);

        (uint128 amount0Desired, uint128 amount1Desired) = launchTokenIsCurrency0
            ? (s.launchTokenAmount, s.quoteTokenAmount)
            : (s.quoteTokenAmount, s.launchTokenAmount);

        // The native asset, if present, always sorts to currency0 (address(0) is the lowest).
        uint256 nativeAmount = key.currency0.isNative() ? amount0Desired : 0;
        if (msg.value != nativeAmount) revert NativeValueMismatch(nativeAmount, msg.value);

        uint256 before0 = key.currency0.balanceOfSelf() - msg.value;
        uint256 before1 = key.currency1.balanceOfSelf();

        // Fee-on-transfer tokens deliver less than they are asked for. Measure, do not assume:
        // seeding a taxed token with its nominal amount would revert inside the settle otherwise.
        uint128 have0 = key.currency0.isNative()
            ? amount0Desired
            : _pullExact(key.currency0, amount0Desired, before0);
        // currency1 can never be native: the zero address always sorts to currency0.
        uint128 have1 = _pullExact(key.currency1, amount1Desired, before1);

        // forge-lint: disable-next-line(unused-return)
        (uint160 sqrtPriceX96,,,) = clPoolManager.getSlot0(key.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(s.tickLower),
            TickMath.getSqrtRatioAtTick(s.tickUpper),
            have0,
            have1
        );
        if (liquidity == 0) revert SeedProducesNoLiquidity();

        // Native value is forwarded with the call rather than pulled through Permit2, and
        // `IERC20(address(0)).allowance` would revert on the empty return.
        if (have0 != 0 && !key.currency0.isNative()) _approvePosition(key.currency0);
        if (have1 != 0) _approvePosition(key.currency1);

        address recipient = s.positionRecipient == address(0) ? msg.sender : s.positionRecipient;
        tokenId = positionManager.nextTokenId();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_MINT_POSITION,
            // `have0`/`have1` are the amounts actually in hand, used as the position manager's
            // own `validateMaxIn` slippage bound, so that check cannot pass while the settle that
            // follows would fail for want of funds.
            abi.encode(key, s.tickLower, s.tickUpper, uint256(liquidity), have0, have1, recipient, bytes(""))
        );
        plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));
        if (nativeAmount != 0) {
            // The position manager settles native out of its OWN balance, which this call funds
            // with `msg.value`. Whatever the mint did not consume would otherwise be stranded
            // there, so it is swept back here and refunded below.
            //
            // Caveat, inherited from periphery's SWEEP action: it returns the position manager's
            // ENTIRE native balance, not just this call's residue. In a well-formed transaction
            // those are the same thing, because the position manager is not designed to hold
            // native value between calls.
            plan.add(Actions.SWEEP, abi.encode(key.currency0, address(this)));
        }

        uint256 deadline = s.deadline == 0 ? block.timestamp : s.deadline;
        positionManager.modifyLiquidities{value: nativeAmount}(plan.encode(), deadline);

        uint256 after0 = key.currency0.balanceOfSelf();
        uint256 after1 = key.currency1.balanceOfSelf();

        emit LaunchSeeded(
            key.toId(),
            tokenId,
            recipient,
            liquidity,
            (before0 + have0) - after0,
            (before1 + have1) - after1
        );

        _refund(key.currency0, before0, after0);
        _refund(key.currency1, before1, after1);
    }

    /// @dev Moves `amount` of an ERC-20 in and returns what actually arrived.
    function _pullExact(Currency currency, uint128 amount, uint256 balanceBefore) private returns (uint128 received) {
        if (amount == 0) return 0;
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        uint256 delta = currency.balanceOfSelf() - balanceBefore;
        // A fee-on-transfer token delivers less; a rebasing or inflationary one could deliver
        // more. Never count more than was asked for: it keeps the result inside the uint128 the
        // caller declared, and any surplus is refunded with everything else at the end.
        // The cast is unreachable when `delta > amount`, and `amount` is a uint128, so the
        // branch that casts has already established `delta <= type(uint128).max`.
        // forge-lint: disable-next-line(unsafe-typecast)
        received = delta > amount ? amount : uint128(delta);
    }

    /// @dev Grants the position manager an unbounded Permit2 allowance over this kit's balance.
    ///
    /// Safe despite being unbounded: Permit2 only lets the SPENDER move the OWNER's tokens, and
    /// the position manager only spends on behalf of whoever locked it - which for these calls is
    /// this contract. A third party calling `modifyLiquidities` is the payer of their own actions,
    /// never this kit. Combined with the kit holding no balance between transactions, there is
    /// nothing here for the allowance to leak.
    function _approvePosition(Currency currency) private {
        address token = Currency.unwrap(currency);
        if (IERC20(token).allowance(address(this), address(permit2)) != type(uint256).max) {
            // forceApprove handles the non-standard tokens that require a reset to zero first.
            IERC20(token).forceApprove(address(permit2), type(uint256).max);
        }
        // forge-lint: disable-next-line(unused-return)
        (uint160 allowed, uint48 expiration,) = permit2.allowance(address(this), token, address(positionManager));
        if (allowed != type(uint160).max || expiration != type(uint48).max) {
            permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

    function _refund(Currency currency, uint256 balanceBefore, uint256 balanceAfter) private {
        if (balanceAfter <= balanceBefore) return;
        unchecked {
            currency.transfer(msg.sender, balanceAfter - balanceBefore);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            REGISTRY LISTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Lists the hook once, then immediately hands stewardship to a human address. The kit
    /// deliberately does not keep the steward right: it has no governance and no owner, so a
    /// listing it stewarded could never be corrected.
    function _listHook(HookListingParams calldata listing) private {
        if (address(registry) == address(0)) revert RegistryNotConfigured();
        // A hook backs many launches. The second launch must not revert because the first listed it.
        if (registry.isRegistered(address(hook))) return;

        address steward = listing.steward == address(0) ? msg.sender : listing.steward;
        registry.register(address(hook), listing.metadata);
        registry.transferSteward(address(hook), steward);
        // forge-lint: disable-next-line(reentrancy-events)
        emit HookListed(address(hook), steward);
    }

    /// @notice List the hook in the registry on its own, outside a launch.
    /// @dev Same one-shot semantics as the in-launch path. Returns false if it was already listed.
    function listHook(DeepCoreMetadata calldata metadata, address steward) external nonReentrant returns (bool listed) {
        if (address(registry) == address(0)) revert RegistryNotConfigured();
        if (registry.isRegistered(address(hook))) return false;

        address to = steward == address(0) ? msg.sender : steward;
        registry.register(address(hook), metadata);
        registry.transferSteward(address(hook), to);
        // forge-lint: disable-next-line(reentrancy-events)
        emit HookListed(address(hook), to);
        return true;
    }
}
