/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {BaseBinHook} from "../base/BaseBinHook.sol";
import {IBinHooks} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LiquidityConfigurations} from "infinity-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";

import {LaunchTaxModule} from "./LaunchTaxModule.sol";

/// @dev Imported, not redeclared: one declaration of the factory read for both launch guards, so a
/// kit that imports both hooks never sees two `ILaunchTokenOrigin`s. Interface only - no CL bytecode.
import {ILaunchTokenOrigin} from "./LaunchGuardHook.sol";

/// @title BinLaunchGuardHook
/// @notice Anti-sniper launch protection for DeepCoreProtocol BIN (liquidity-book) pools: a decaying
/// "sniper tax", ported from `LaunchGuardHook` (the CL version) with the three changes that the bin
/// pool type forces. Read those first — two of them change what the hook can promise.
///
/// @dev ############################ WHAT THIS HOOK ACTUALLY DOES ############################
///
/// It prices early buying instead of trying to identify early buyers. For `decaySeconds` seconds
/// after `startTime` the fee decays linearly from `initialFeeBips` down to `finalFeeBips`. A sniper
/// who buys in the first second pays the full launch tax; a normal buyer who arrives after the
/// window pays the normal fee.
///
/// ON A SWAP THE FEE IS TAKEN BY THIS CONTRACT, IN THE QUOTE CURRENCY (owner decision,
/// 2026-09-28), exactly as on `LaunchGuardHook`: the fee is a hook delta on whichever side of the
/// swap is the quote, split by the pool's fee split and paid by pull, and a share of it fixed at
/// deployment (`LP_SHARE_BPS`) is left to the pool as its LP fee, on buys only. `LaunchTaxModule`
/// carries the table of the four swap shapes, the share and the money path. ON A MINT the WHOLE
/// fee is still handed to core as the composition fee, which core charges as an LP fee in the
/// token added (see the mint note below): that route pays the pool's liquidity providers.
///
/// EVERY DURATION HERE IS `block.timestamp` SECONDS, exactly as in `LaunchGuardHook`, whose
/// contract-level "CLOCK" note applies here word for word: honest sequencer skew is bounded by
/// `MIN_DECAY_SECONDS`; a malicious Nitro sequencer can move the clock up to one hour forward and
/// is a trust assumption, not something a floor can defend.
///
/// This design is deliberate, and it follows from a hard constraint of the singleton architecture:
///
///   THE `sender` ARGUMENT OF EVERY HOOK CALLBACK IS THE LOCKER, NOT THE END USER.
///
///   `BinHooks.beforeSwap` invokes the hook with `msg.sender` of the `BinPoolManager.swap` call,
///   which is whoever locked the Vault - i.e. the router. (`BinHooks.beforeMint` does the same for
///   `BinPoolManager.mint`.) Every swap routed through a shared router arrives with the SAME
///   `sender`. A per-wallet buy cap keyed on `sender` would therefore be consumed by the first
///   buyer on behalf of everybody, and `hookData` cannot be trusted to name the real buyer because
///   anyone may bypass the router and lock the Vault directly with arbitrary `hookData`.
///
///   Consequence: NO identity-based protection is implementable at this layer. There are no
///   per-wallet caps, no allowlists, and no "one buy per address" rules in this hook, because
///   none of them could be enforced honestly. It is also why mints are TAXED rather than GATED
///   (see the mint note below): the hook cannot tell the launcher seeding liquidity apart from a
///   sniper extracting it, so it must charge both rather than block both.
///
/// ------------------------------ BIN-SPECIFIC: THE MINT HOLE ------------------------------
///
/// This is the difference that matters, and it has no CL analogue. On a bin pool, adding liquidity
/// to the ACTIVE bin at a ratio different from the bin's own ratio performs an IMPLICIT SWAP inside
/// core, charged at the "composition fee" (`BinHelper.getCompositionFeesAmount`). Mint lopsided,
/// then burn, and you have swapped.
///
/// The composition fee is taken from the pool's stored LP fee unless `beforeMint` returns an
/// override — and a dynamic-fee pool's stored LP fee is 0 until somebody calls
/// `updateDynamicLPFee`. So a bin launch hook that only registered `beforeSwap` (the exact shape of
/// the CL hook) would leave a FEE-FREE swap route straight through the launch tax, usable even
/// before `startTime`, when ordinary swaps revert.
///
/// This hook therefore registers `beforeMint` as well and returns the SAME decayed fee there. That
/// closes the free route. What it cannot do is close the route entirely: see "WHAT IT DOES NOT
/// PREVENT".
///
/// ---------------------------- BIN-SPECIFIC: THE 10% CEILING ----------------------------
///
/// Core validates a bin LP fee against `LPFeeLibrary.TEN_PERCENT_FEE` (100_000), not
/// `ONE_HUNDRED_PERCENT_FEE`. The CL hook opens at up to 50%; this one cannot exceed 10% however it
/// is configured. Since the fee on a SWAP became a hook delta, core's ceiling binds the MINT route
/// only (the composition fee is still an LP fee, and core would revert the mint with
/// `LPFeeTooLarge`). One schedule governs both routes on purpose: a swap fee above what the mint
/// route can charge would make the mint route the cheap way through the launch. A bin launch fee
/// is consequently a WEAKER deterrent than a CL one by construction.
///
/// ------------------------------- WHAT IT PREVENTS -------------------------------
///  * Free front-running of a launch. Buying in the first second of the window costs
///    `initialFeeBips` (up to 10%). A sniper cannot escape this with fresh wallets, contracts, or
///    private orderflow, because the tax is a function of time and the pool, not of the buyer.
///  * Trading before the launch opens. `beforeSwap` reverts for every swap before `startTime`.
///  * Escaping the tax through the mint/burn composition-swap route: it is charged the same
///    decayed fee, at every moment, including before `startTime`.
///  * A single oversized market buy during the window, if `maxBuyPerTx` is configured.
///  * A launch owner spiking the fee mid-launch. Configuration is frozen from `startTime` on, and
///    from the first swap if that comes first (a disabled schedule trades before its `startTime`).
///  * Silent misconfiguration: a non-dynamic-fee pool is rejected at `beforeInitialize`, because
///    core discards a `beforeSwap`/`beforeMint` fee on a static-fee pool without reverting.
///
/// ----------------------------- WHAT IT DOES NOT PREVENT -----------------------------
///  * Sybil accumulation. Splitting a buy across N wallets or N transactions in the same block is
///    NOT prevented and cannot be. `maxBuyPerTx` bounds one swap transaction, nothing more.
///  * A sniper who is simply willing to pay the tax — and on bin that tax is capped at 10%, so the
///    price of sniping is materially lower than on a CL launch.
///  * ACQUISITION BEFORE `startTime` VIA MINT+BURN. Swaps revert before the launch opens, but
///    mints must not (nobody could seed the pool otherwise, because `sender` is the router and the
///    launcher cannot be recognised). A sniper can therefore mint lopsided into the active bin and
///    burn, acquiring the launch token before trading opens, at the cost of `initialFeeBips`
///    charged as a composition fee. The tax is paid; the gate is bypassed. This is the residual
///    risk of the bin port and it is asserted in the test suite rather than papered over.
///  * `maxBuyPerTx` on the mint route. `beforeMint` receives `liquidityConfigs` and a packed
///    `amountIn`, not the size of the implicit swap that core will compute from the bin's live
///    reserves. The cap is a swap-path control only.
///  * Accumulation via a route that does not touch this pool (another pool, an OTC deal, a CEX).
///  * Anything about the token itself: transfer restrictions, mint authority, LP-token custody,
///    or a rug pull by the token deployer. This hook only governs ONE pool.
///  * Sells. `maxBuyPerTx` is one-directional by design; the decaying fee applies to both
///    directions, so early sells are taxed too, but there is no separate sell limit.
///  * A launch owner who opens trading late. `startTime` may be pushed back while nobody has traded,
///    but never past `openDeadline` (first claim + `MAX_START_DELAY_SECONDS`), so a launch opens
///    within 30 days of being claimed. Burns are NOT hooked, so LPs can always withdraw.
///  * A MALICIOUS SEQUENCER. See `LaunchGuardHook`'s "CLOCK" note.
///
/// ------------------------------ THE CREATOR TAX ------------------------------
/// Inherited from `LaunchTaxModule` exactly as on the CL guard: a buy rate and a sell rate taken
/// once per swap on the same quote amount as the fee, until a fixed expiry, split creator /
/// protocol / integrator with the protocol floor enforced here. It is NOT an LP fee, so core's 10%
/// Bin LP-fee ceiling does not apply to it; its own cap is `MAX_TAX_BPS` (10%).
///
/// THE MINT HOLE, AGAIN. A mint into the ACTIVE bin is an implicit swap, and a hook delta cannot
/// price it: `beforeMint` sees the intended amounts, not the swap core will derive from the bin's
/// live reserves. A seller could therefore mint launch token into the active bin, burn, and leave
/// with quote at the composition fee but without the sell tax. So WHILE A TAX IS LIVE, THIS HOOK
/// REFUSES ANY MINT THAT TOUCHES THE ACTIVE BIN (`TaxedActiveBinMintBlocked`). Every other bin
/// accepts only its own side of the pair (core's `verifyAmounts`), which is no swap at all, so
/// seeding and ordinary liquidity provision continue: the kit seeds bins at offsets >= 1, and the
/// Bin locker only ever burns. Once the tax expires the active bin opens to mints again.
/// #####################################################################################
contract BinLaunchGuardHook is BaseBinHook, LaunchTaxModule {
    using LPFeeLibrary for uint24;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool key does not name this contract as its hook
    error HookMismatch(address declared);

    /// @notice The pool key names a different pool manager than this hook serves
    error PoolManagerMismatch(address declared);

    /// @notice A fee returned from `beforeSwap`/`beforeMint` is silently ignored on a static-fee
    /// pool, so a launch on such a pool would provide no protection at all. Reject it at
    /// initialization.
    error PoolMustUseDynamicFee(uint24 fee);

    /// @notice No launch has been registered for this pool
    error LaunchNotConfigured(PoolId poolId);

    /// @notice Caller is not the registered launch owner of this pool
    error NotLaunchOwner(PoolId poolId, address caller);

    /// @notice Configuration is frozen from `startTime` onwards, or from the first swap if earlier
    error LaunchAlreadyStarted(PoolId poolId, uint256 startTime);

    /// @notice A swap was attempted before the launch opened
    error TradingNotOpen(PoolId poolId, uint256 startTime, uint256 currentTime);

    /// @notice `startTime` is in the past or more than `MAX_START_DELAY_SECONDS` ahead
    error InvalidStartTime(uint256 startTime, uint256 currentTime);
    /// @notice `startTime` is past the latest opening fixed when the launch was first claimed
    error StartTimeAfterOpenDeadline(PoolId poolId, uint256 startTime, uint256 openDeadline);

    /// @notice `decaySeconds` is outside [`MIN_DECAY_SECONDS`, `MAX_DECAY_SECONDS`]
    error InvalidDecaySeconds(uint32 decaySeconds);

    /// @notice The fee schedule is not a decay, or exceeds the caps this hook enforces
    error InvalidFeeSchedule(uint24 initialFeeBips, uint24 finalFeeBips);

    /// @notice A buy exceeded the configured per-transaction cap
    error BuyExceedsMaxPerTx(uint256 amountIn, uint128 maxBuyPerTx);

    /// @notice An exact-output buy was attempted while a per-transaction cap is active.
    /// @dev `beforeSwap` cannot know the input amount of an exact-output swap, so the cap cannot
    /// be enforced on one. Allowing it would be a one-line bypass of the cap, so it is rejected
    /// for the duration of the launch window instead.
    error ExactOutputBuyBlockedDuringLaunch();

    /// @notice A first claim named a non-native currency with no code. Same rule, same selector as
    /// `LaunchGuardHook.CurrencyHasNoCode`.
    error CurrencyHasNoCode(address currency);

    /// @notice `token` was created by the launch-token factory, so only its creator (or the claimer
    /// that creator appointed) may claim a launch pool for it. Same selector as the CL hook's.
    error LaunchPoolReserved(address token, address creator, address caller);

    /// @notice Only a factory token's creator may appoint its launch claimer.
    error NotTokenCreator(address token, address caller);

    /// @notice A mint named the active bin while a creator tax is live. See the contract-level note.
    error TaxedActiveBinMintBlocked(PoolId poolId, uint24 activeId);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted the first time an address registers a launch for a pool id
    event LaunchClaimed(PoolId indexed poolId, address indexed owner);

    /// @notice A factory token's creator appointed (or, with `address(0)`, revoked) a launch claimer.
    event LaunchClaimerSet(address indexed token, address indexed creator, address indexed claimer);

    /// @notice Emitted on every accepted configuration write (including the first)
    event LaunchConfigured(
        PoolId indexed poolId,
        address indexed owner,
        uint40 startTime,
        uint32 decaySeconds,
        uint24 initialFeeBips,
        uint24 finalFeeBips,
        uint128 maxBuyPerTx,
        bool launchTokenIsCurrency0,
        bool enabled
    );

    /// @notice Emitted once, on the first swap the guard lets through (at or after `startTime` for an
    /// enabled launch; the first swap at all for a disabled one)
    /// @param timestamp `block.timestamp` of that swap.
    event LaunchStarted(PoolId indexed poolId, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fees are in hundredths of a bip, matching core: 1_000_000 == 100%.
    uint24 public constant FEE_DENOMINATOR = LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE;

    /// @dev The flag that makes what `beforeSwap` hands core as the LP fee a decision rather than
    /// an absence: the pool's part of the fee on a buy, zero on a sell. `beforeMint` hands core the
    /// whole fee as the composition fee.
    uint24 internal constant LP_FEE_OVERRIDE = LPFeeLibrary.OVERRIDE_FEE_FLAG;

    /// @notice Hard cap on the opening fee. This is core's own bin ceiling (10%):
    /// `BinPool.mint` calls `removeOverrideAndValidate(LPFeeLibrary.TEN_PERCENT_FEE)` on the
    /// composition fee this hook returns, so anything above it would revert the mint. The swap fee
    /// is a hook delta and core does not bound it, but it follows the same schedule (see the
    /// contract note). The CL hook's 50% opening fee is unreachable here.
    uint24 public constant MAX_INITIAL_FEE = LPFeeLibrary.TEN_PERCENT_FEE; // 10%, core's bin max

    /// @notice Hard cap on the fee that remains once the window has elapsed. Bounds how bad a
    /// permanently hostile configuration can be, since config is immutable after `startTime`.
    uint24 public constant MAX_FINAL_FEE = 20_000; // 2%

    /// @notice ERC-6372 clock mode. Every duration and stored time here is `block.timestamp`.
    string public constant CLOCK_MODE = "mode=timestamp";

    /// @notice Shortest decay window a launch may configure. Same value and same justification as
    /// `LaunchGuardHook.MIN_DECAY_SECONDS`: whole-second resolution under 1.7%, honest sequencer
    /// skew absorbed, at least 4x finer than Nitro's ~15 s `block.number` resync. NOT a defence
    /// against a malicious sequencer's one-hour forward bound.
    uint32 public constant MIN_DECAY_SECONDS = 60;

    /// @notice Hard cap on the decay window, so a "launch tax" cannot be a permanent tax.
    uint32 public constant MAX_DECAY_SECONDS = 30 days;

    /// @notice Hard cap on how far ahead `startTime` may be set in any single write. No floor, for
    /// the reason given on `LaunchGuardHook.MAX_START_DELAY_SECONDS`.
    uint40 public constant MAX_START_DELAY_SECONDS = 30 days;

    /// @notice Design envelope: `MAX_DECAY_SECONDS >= MIN_LAUNCH_WINDOW_SECONDS` and
    /// `MAX_START_DELAY_SECONDS + MAX_DECAY_SECONDS <= MAX_LAUNCH_WINDOW_SECONDS`. Asserted in tests.
    uint256 public constant MIN_LAUNCH_WINDOW_SECONDS = 3 days;

    /// @notice See `MIN_LAUNCH_WINDOW_SECONDS`.
    uint256 public constant MAX_LAUNCH_WINDOW_SECONDS = 180 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @param owner The launch owner. `address(0)` means the pool id has never been claimed.
    /// @param startTime First `block.timestamp` at which swaps are permitted.
    /// @param decaySeconds Length of the decay window, in seconds, starting at `startTime`.
    /// @param enabled When false the hook applies no gate, no cap and no decay: its fee is
    ///        `finalFeeBips` from the first swap, taken in the quote on a swap and handed to core
    ///        as the composition fee on a mint. The mint override is still required: a
    ///        dynamic-fee pool's stored LP fee is 0 at initialization, so a hook that returns no
    ///        override lets a mint composition-swap through the pool for free.
    /// @param initialFeeBips Fee at `startTime`.
    /// @param finalFeeBips Fee at and after `startTime + decaySeconds`.
    /// @param maxBuyPerTx Per-transaction cap on the INPUT amount of a buy SWAP, denominated in the
    ///        quote currency (the currency that is not the launch token). 0 disables the cap. It
    ///        does not apply to the mint route.
    /// @param launchTokenIsCurrency0 Which side of the pool is the token being launched. Only used
    ///        to decide which swap direction is a "buy" for `maxBuyPerTx`. On bin, currency0 is X
    ///        and currency1 is Y, so `swapForY == true` is the analogue of CL's `zeroForOne`.
    /// @param launched Set on the first swap the guard lets through, so `LaunchStarted` fires once and
    ///        the configuration is frozen from then on even if `startTime` is still ahead.
    struct Launch {
        // ---- slot 0: 160 + 40 + 32 + 8 = 240 bits ----
        address owner;
        uint40 startTime;
        uint32 decaySeconds;
        bool enabled;
        // ---- slot 1: 24 + 24 + 128 + 8 + 8 = 192 bits ----
        uint24 initialFeeBips;
        uint24 finalFeeBips;
        uint128 maxBuyPerTx;
        bool launchTokenIsCurrency0;
        bool launched;
    }

    /// @notice Caller-supplied configuration. Mirrors `Launch` minus the fields the hook owns.
    struct LaunchConfig {
        uint40 startTime;
        uint32 decaySeconds;
        uint24 initialFeeBips;
        uint24 finalFeeBips;
        uint128 maxBuyPerTx;
        bool launchTokenIsCurrency0;
        bool enabled;
    }

    /// @notice Launch state per pool id
    mapping(PoolId poolId => Launch) internal _launches;

    /// @notice The latest `startTime` any configuration of the pool may carry: first claim time plus
    /// `MAX_START_DELAY_SECONDS`, written once. Its own mapping so `Launch` keeps its ABI.
    mapping(PoolId poolId => uint40) internal _openDeadline;

    /**
     * ############ POOL-ID RESERVATION (ported from LaunchGuardHook, 2026-09-14) ############
     *
     * Closes the open LOW: the CL guard reserved launch pools and this one did not, so a Bin launch
     * pool with a predictable id (kit v2 derives the token address from a CREATE2 salt, and the key
     * from that) could be claimed by a front-runner, making the kit's own `configureLaunch` revert
     * `NotLaunchOwner`. Denial, not theft - but a launchpad whose launches can be denied at will is
     * not one anybody can ship on.
     *
     * The same two rules as `LaunchGuardHook`, word for word, so a reviewer checks one argument:
     *
     *   1. NO CLAIM ON AN ADDRESS WITHOUT CODE. Before the kit's transaction the token does not exist,
     *      so nobody can claim; inside it, the kit claims first.
     *   2. A `LAUNCH_TOKEN_FACTORY` TOKEN BELONGS TO ITS CREATOR. The first claim must come from
     *      `deployerOf(token)` - the kit, for a kit-created token - or from the one claimer that
     *      creator appointed with `setLaunchClaimer`.
     *
     * No owner and no kit address is added: the factory's creator record has no setter and serves
     * every tenant kit on the shared factory. Pools on non-factory tokens behave as before, except
     * that rule 1 refuses a currency with no code, which could never be a working pool anyway.
     */
    ILaunchTokenOrigin public immutable LAUNCH_TOKEN_FACTORY;

    /// @notice The claimer a factory token's creator appointed. Zero means only the creator.
    mapping(address token => address claimer) public launchClaimerOf;

    /// @param _poolManager The Bin singleton this hook serves, forever.
    /// @param launchTokenFactory The `LaunchTokenFactory` whose tokens get reserved launch pools, or
    /// `address(0)` for a deployment with no factory (rule 1 still applies). Every duration bound is a
    /// constant in seconds, so no chain can be configured with the wrong clock.
    /// @param protocolRecipient_ Where the creator tax's protocol bucket is credited, forever (the
    /// governance Safe on mainnet). See `LaunchTaxModule`.
    constructor(
        IBinPoolManager _poolManager,
        ILaunchTokenOrigin launchTokenFactory,
        address protocolRecipient_,
        uint16 lpShareBps_
    ) BaseBinHook(_poolManager) LaunchTaxModule(_poolManager.vault(), protocolRecipient_, lpShareBps_) {
        LAUNCH_TOKEN_FACTORY = launchTokenFactory;
    }

    /// @notice Appoint (or revoke with `address(0)`) the one address besides you that may claim a
    /// launch pool for a factory token you created. Typically the kit you will launch through.
    function setLaunchClaimer(address token, address claimer) external {
        if (
            address(LAUNCH_TOKEN_FACTORY) == address(0) || msg.sender == address(0)
                || LAUNCH_TOKEN_FACTORY.deployerOf(token) != msg.sender
        ) revert NotTokenCreator(token, msg.sender);
        launchClaimerOf[token] = claimer;
        emit LaunchClaimerSet(token, msg.sender, claimer);
    }

    /// @inheritdoc IHooks
    /// @dev `beforeInitialize` rejects static-fee pools and pools with no fee split; `beforeSwap`
    /// gates trading and returns the pool's part of the fee; `beforeMint` returns the whole fee so the
    /// composition-swap route is charged the same rate (no returns-delta bit needed for a fee:
    /// `BinHooks` parses it unconditionally on a dynamic-fee pool). The two returns-delta bits are
    /// what let this contract take the fee and the tax in the quote currency: bit 10 when the quote
    /// is the specified side of the swap, bit 11 when it is the unspecified side. Bit 10 requires
    /// bit 6 and bit 11 requires bit 7, re-checked by `BaseBinHook._validatePermissions` at deploy
    /// time.
    ///
    /// bit 0 (beforeInitialize) | bit 2 (beforeMint) | bit 6 (beforeSwap) | bit 7 (afterSwap)
    /// | bit 10 (beforeSwapReturnsDelta) | bit 11 (afterSwapReturnsDelta) == 0x0CC5.
    function getHooksRegistrationBitmap() public pure virtual override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_MINT | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA
            | AFTER_SWAP_RETURNS_DELTA;
    }

    /// @notice ERC-6372 clock: the current `block.timestamp`, the unit every time here is in.
    function clock() external view returns (uint48) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION

        ACCESS-CONTROL MODEL
        --------------------
        A PoolKey is not owned by anybody: anyone may build a key naming this hook. So ownership
        cannot be derived from the key, and it cannot be derived from a callback's `sender` either
        (see the contract-level note). It is therefore established by explicit first-claim:

          1. The launcher calls `configureLaunch(key, cfg)`. If the pool id is unclaimed, the
             caller becomes its permanent launch owner.
          2. `beforeInitialize` REFUSES to let the pool be created unless a claim already exists.
             There is consequently no such thing as an initialized-but-unclaimed pool on this hook.
          3. Further writes require `msg.sender == owner` AND `block.timestamp < startTime` AND no
             swap has happened yet (`launched == false`). Once the launch opens - by the clock, or
             by the first swap of a disabled schedule, which has no gate - the configuration is
             immutable forever: a launch owner cannot raise the fee on, or close the pool to, buyers
             who have already committed.

        Ownership is deliberately non-transferable and non-renounceable: after `startTime` the
        owner has no powers at all, so there is nothing to transfer and nothing to renounce.
    //////////////////////////////////////////////////////////////*/

    /// @notice Register or update the launch parameters for `key`'s pool.
    /// @dev First caller for a given pool id claims it. Reverts after the launch has opened.
    function configureLaunch(PoolKey calldata key, LaunchConfig calldata cfg) external {
        if (address(key.hooks) != address(this)) revert HookMismatch(address(key.hooks));
        if (address(key.poolManager) != address(poolManager)) {
            revert PoolManagerMismatch(address(key.poolManager));
        }
        // Enforced here as well as in `beforeInitialize` so a launcher cannot burn gas building a
        // configuration for a pool that can never be initialized.
        if (!key.fee.isDynamicLPFee()) revert PoolMustUseDynamicFee(key.fee);

        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];

        address owner = l.owner;
        if (owner == address(0)) {
            _requireMayClaim(key.currency0);
            _requireMayClaim(key.currency1);
            l.owner = msg.sender;
            owner = msg.sender;
            _openDeadline[poolId] = uint40(block.timestamp) + MAX_START_DELAY_SECONDS;
            emit LaunchClaimed(poolId, msg.sender);
        } else {
            if (msg.sender != owner) revert NotLaunchOwner(poolId, msg.sender);
            // Config is frozen from the moment the CURRENT schedule opens trading, OR from the first
            // swap, whichever comes first. A disabled schedule (`enabled == false`) trades before its
            // `startTime`, so without the `launched` half an owner could sell into an open pool and
            // then close it, or impose the maximum fee, on everyone who bought (review 2026-09-18).
            uint256 currentStart = l.startTime;
            if (l.launched || block.timestamp >= currentStart) revert LaunchAlreadyStarted(poolId, currentStart);
        }

        _validateConfig(cfg);
        // L-1 (review 2026-09-18): each write may look 30 days ahead, so without this an owner could
        // re-push `startTime` before every open and postpone an untraded launch for ever.
        uint256 deadline = _openDeadline[poolId];
        if (cfg.startTime > deadline) revert StartTimeAfterOpenDeadline(poolId, cfg.startTime, deadline);

        l.startTime = cfg.startTime;
        l.decaySeconds = cfg.decaySeconds;
        l.enabled = cfg.enabled;
        l.initialFeeBips = cfg.initialFeeBips;
        l.finalFeeBips = cfg.finalFeeBips;
        l.maxBuyPerTx = cfg.maxBuyPerTx;
        l.launchTokenIsCurrency0 = cfg.launchTokenIsCurrency0;

        emit LaunchConfigured(
            poolId,
            owner,
            cfg.startTime,
            cfg.decaySeconds,
            cfg.initialFeeBips,
            cfg.finalFeeBips,
            cfg.maxBuyPerTx,
            cfg.launchTokenIsCurrency0,
            cfg.enabled
        );
    }

    /// @notice Write the fee split for `key`'s pool. Once: a second write reverts `FeeSplitAlreadySet`.
    /// @dev Launch owner only, and only until trading opens (the freeze `configureTax` applies). The
    /// pool cannot be initialized without it. Bounds and the protocol floor are validated in
    /// `LaunchTaxModule`.
    function configureFeeSplit(PoolKey calldata key, FeeSplit calldata cfg) external {
        _configureFeeSplit(_ownedUnfrozenPool(key), cfg);
    }

    /// @notice Write (or, with all-zero terms, clear) the creator tax for `key`'s pool.
    /// @dev Launch owner only, under the freeze `configureLaunch` applies: until trading opens or the
    /// first swap, whichever comes first (see `_launchOwnerAndFreeze` for the one-second difference). A pool must already be claimed (`configureLaunch`
    /// first). Bounds and the protocol floor are validated in `LaunchTaxModule`.
    function configureTax(PoolKey calldata key, TaxConfig calldata cfg) external {
        _configureTax(_ownedUnfrozenPool(key), cfg);
    }

    /// @dev The pool id of `key`, after checking that `key` is this hook's, that the caller is its
    /// launch owner and that its configuration is not frozen. Shared by the two writes above.
    function _ownedUnfrozenPool(PoolKey calldata key) internal view returns (PoolId poolId) {
        if (address(key.hooks) != address(this)) revert HookMismatch(address(key.hooks));
        if (address(key.poolManager) != address(poolManager)) {
            revert PoolManagerMismatch(address(key.poolManager));
        }
        poolId = key.toId();
        (address owner, bool frozen) = _launchOwnerAndFreeze(poolId);
        if (owner == address(0)) revert LaunchNotConfigured(poolId);
        if (msg.sender != owner) revert NotLaunchOwner(poolId, msg.sender);
        if (frozen) revert LaunchAlreadyStarted(poolId, _launches[poolId].startTime);
    }

    /// @inheritdoc LaunchTaxModule
    /// @dev `>` where `configureLaunch` uses `>=`: the tax may still be written in the very second trading
    /// opens as long as nobody has traded (`launched`), because a kit claims and configures the tax in ONE
    /// transaction and a launch that opens immediately (`startTime == now`) must be able to carry one. A
    /// trade in that second sets `launched` first, so no buyer ever sees a tax added after their trade.
    function _launchOwnerAndFreeze(PoolId poolId) internal view override returns (address owner, bool frozen) {
        Launch storage l = _launches[poolId];
        owner = l.owner;
        frozen = l.launched || block.timestamp > l.startTime;
    }

    /// @dev The two reservation rules, for one currency of a first claim. Identical to
    /// `LaunchGuardHook._requireMayClaim`; see `LAUNCH_TOKEN_FACTORY`.
    function _requireMayClaim(Currency currency) internal view {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return; // the native asset
        if (token.code.length == 0) revert CurrencyHasNoCode(token);
        if (address(LAUNCH_TOKEN_FACTORY) == address(0)) return;
        address creator = LAUNCH_TOKEN_FACTORY.deployerOf(token);
        if (creator == address(0) || msg.sender == creator) return;
        address claimer = launchClaimerOf[token];
        if (claimer != address(0) && msg.sender == claimer) return;
        revert LaunchPoolReserved(token, creator, msg.sender);
    }

    /// @dev All bounds that keep a hostile launch owner inside a survivable envelope.
    function _validateConfig(LaunchConfig calldata cfg) internal view {
        // `startTime` in the past would mean the config is born frozen, and (worse) would let an
        // owner open trading retroactively at whatever fee suits them. Require it to be now-or-later.
        if (cfg.startTime < block.timestamp || uint256(cfg.startTime) > block.timestamp + MAX_START_DELAY_SECONDS) {
            revert InvalidStartTime(cfg.startTime, block.timestamp);
        }
        // Applied whether or not the launch is `enabled`, as in `LaunchGuardHook`.
        if (cfg.decaySeconds < MIN_DECAY_SECONDS || cfg.decaySeconds > MAX_DECAY_SECONDS) {
            revert InvalidDecaySeconds(cfg.decaySeconds);
        }
        // Must be a decay, and must stay inside this hook's caps. `MAX_INITIAL_FEE` IS core's bin
        // ceiling, so a schedule that passes here can never make core revert with `LPFeeTooLarge`.
        if (
            cfg.initialFeeBips < cfg.finalFeeBips || cfg.initialFeeBips > MAX_INITIAL_FEE
                || cfg.finalFeeBips > MAX_FINAL_FEE
        ) {
            revert InvalidFeeSchedule(cfg.initialFeeBips, cfg.finalFeeBips);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Full launch record for a pool id
    function getLaunch(PoolId poolId) external view returns (Launch memory) {
        return _launches[poolId];
    }

    /// @notice The latest `startTime` the pool's configuration may ever carry (0 = never claimed)
    function openDeadline(PoolId poolId) external view returns (uint256) {
        return _openDeadline[poolId];
    }

    /// @notice Launch owner of a pool id, or `address(0)` if unclaimed
    function launchOwner(PoolId poolId) external view returns (address) {
        return _launches[poolId].owner;
    }

    /// @notice The trade fee, in hundredths of a bip, that a swap at `timestamp` would pay: both
    /// parts of it. `feePartsAt` says how much of it the pool charges and how much this contract takes.
    /// @dev Reverts for an unconfigured pool. Returns `finalFeeBips` when the launch is disabled,
    /// and for times before `startTime` returns `initialFeeBips` - a SWAP at such a time would
    /// revert, but a MINT would not, and it is charged exactly this value as its composition fee.
    function feeAt(PoolId poolId, uint256 timestamp) public view returns (uint24) {
        Launch storage l = _launches[poolId];
        if (l.owner == address(0)) revert LaunchNotConfigured(poolId);
        if (!l.enabled) return l.finalFeeBips;
        if (timestamp < l.startTime) return l.initialFeeBips;
        return _decayedFee(l.initialFeeBips, l.finalFeeBips, timestamp - l.startTime, l.decaySeconds);
    }

    /// @notice The trade fee a swap would pay now. See `feeAt`.
    function currentFee(PoolId poolId) external view returns (uint24) {
        return feeAt(poolId, block.timestamp);
    }

    /// @notice The parts of the trade fee a swap at `timestamp` would pay, in hundredths of a bip.
    /// @return buyLpPips What the pool charges a buy as its LP fee, on the quote it takes in.
    /// @return buyGuardPips What this contract takes from a buy, in the quote.
    /// @return sellGuardPips What this contract takes from a sell, in the quote: the whole fee.
    function feePartsAt(PoolId poolId, uint256 timestamp)
        public
        view
        returns (uint24 buyLpPips, uint24 buyGuardPips, uint24 sellGuardPips)
    {
        sellGuardPips = feeAt(poolId, timestamp);
        (buyLpPips, buyGuardPips) = _feeParts(sellGuardPips, true);
    }

    /// @notice The parts of the trade fee a swap would pay now. See `feePartsAt`.
    function currentFeeParts(PoolId poolId)
        external
        view
        returns (uint24 buyLpPips, uint24 buyGuardPips, uint24 sellGuardPips)
    {
        return feePartsAt(poolId, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                              DECAY MATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Linear decay from `initialFee` at `elapsed == 0` to `finalFee` at
    /// `elapsed >= decaySeconds`.
    ///
    /// @dev Rounding: the SUBTRACTED discount is floored, so the RATE rounds UP, away from the
    /// sniper. That is the safe direction for a protection mechanism. (The amount taken at that rate
    /// is floored in `_quoteTake`: the rounding wei of a trade stays with the trader.)
    ///
    /// Boundaries:
    ///   elapsed == 0                -> exactly `initialFee`
    ///   elapsed == decaySeconds-1   -> the last taxed second, strictly above `finalFee` whenever
    ///                                  the spread is at least `decaySeconds` (otherwise flooring
    ///                                  may have already reached `finalFee`, which is fine)
    ///   elapsed == decaySeconds     -> exactly `finalFee`; the window is half-open [start, start+n)
    ///   elapsed >  decaySeconds     -> `finalFee`
    ///
    /// Range: `finalFee <= result <= initialFee` for every input, so the value can never exceed
    /// `MAX_INITIAL_FEE` and therefore never exceeds what core accepts for a bin pool (100_000).
    ///
    /// Monotonicity: `spread * elapsed / decaySeconds` is non-decreasing in `elapsed` (integer
    /// division by a fixed positive denominator preserves order), so the result is non-increasing.
    ///
    /// Overflow: `spread <= 100_000` and `elapsed < decaySeconds <= 2_592_000` in the multiplying
    /// branch, so the product is below 2.6e11 - nowhere near uint256.
    function _decayedFee(uint24 initialFee, uint24 finalFee, uint256 elapsed, uint256 decaySeconds)
        internal
        pure
        returns (uint24)
    {
        if (elapsed >= decaySeconds) return finalFee;
        unchecked {
            // `initialFee >= finalFee` is enforced at configuration time.
            uint256 spread = uint256(initialFee) - uint256(finalFee);
            uint256 discount = (spread * elapsed) / decaySeconds;
            // discount <= spread, so this cannot underflow and the result stays in [finalFee, initialFee],
            // both of which are uint24 - the cast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint24(uint256(initialFee) - discount);
        }
    }

    /// @dev The fee of this second, without the override flag: what a swap is charged in the quote
    /// currency and, with the flag attached, what a mint is charged as its composition fee. One
    /// function so the explicit-swap and composition-swap routes can never diverge.
    function _feeNow(Launch storage l) internal view returns (uint24) {
        if (!l.enabled) return l.finalFeeBips;
        uint256 startTime = l.startTime;
        uint256 elapsed = block.timestamp < startTime ? 0 : block.timestamp - startTime;
        return _decayedFee(l.initialFeeBips, l.finalFeeBips, elapsed, l.decaySeconds);
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Rejects a pool that cannot actually enforce the launch tax, a pool nobody has claimed
    /// and a pool whose fee has nowhere to go. `sender` is intentionally ignored: it is the caller
    /// of `initialize`, which may be any periphery contract, and is not a trustworthy identity.
    /// `activeId` is likewise ignored - the starting price is the launcher's business, not the
    /// guard's.
    function _beforeInitialize(
        address,
        /* sender */
        PoolKey calldata key,
        uint24 /* activeId */
    )
        internal
        view
        virtual
        override
        returns (bytes4)
    {
        // On a static-fee pool `BinHooks.beforeSwap` and `BinHooks.beforeMint` DISCARD the fee this
        // hook returns, with no revert and no event. Launch protection there is protection in name
        // only.
        if (!key.fee.isDynamicLPFee()) revert PoolMustUseDynamicFee(key.fee);

        PoolId poolId = key.toId();
        if (_launches[poolId].owner == address(0)) revert LaunchNotConfigured(poolId);
        // A fee is taken from the first swap on, and the split is written once: a pool born without
        // it would collect into a pot nobody could ever be paid from.
        if (!_feeSplitSet(poolId)) revert FeeSplitNotConfigured(poolId);

        return IBinHooks.beforeInitialize.selector;
    }

    /// @dev `sender` is the Vault locker (the router), NOT the buyer. It is unused here, and that
    /// is the whole reason this hook taxes time rather than identity.
    ///
    /// On bin there is no `SwapParams` struct: `swapForY` and `amountSpecified` (int128) arrive
    /// flat. `swapForY == true` sells currency0 (X) for currency1 (Y).
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        bytes calldata /* hookData */
    )
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];

        // Unreachable via a pool this hook gated at initialization, but a pool could in principle
        // have been created by a manager this hook does not serve; fail closed either way.
        if (l.owner == address(0)) revert LaunchNotConfigured(poolId);

        bool tokenIs0 = l.launchTokenIsCurrency0;
        if (!l.enabled) {
            // A disabled launch trades from its first swap; that swap freezes its configuration
            // exactly as `startTime` freezes an enabled one (see `configureLaunch`).
            if (!l.launched) {
                l.launched = true;
                emit LaunchStarted(poolId, block.timestamp);
            }
        } else {
            uint256 startTime = l.startTime;
            if (block.timestamp < startTime) revert TradingNotOpen(poolId, startTime, block.timestamp);

            if (!l.launched) {
                l.launched = true;
                emit LaunchStarted(poolId, block.timestamp);
            }

            uint128 maxBuyPerTx = l.maxBuyPerTx;
            if (maxBuyPerTx != 0 && block.timestamp - startTime < l.decaySeconds) {
                // Checked against what the trader SENDS, before this contract's take: the cap is
                // on the buy, not on what is left of it after the fee.
                _enforceMaxBuy(swapForY, amountSpecified, tokenIs0, maxBuyPerTx);
            }
        }

        // The quote is the specified side of an exact-input buy and of an exact-output sell. Those
        // two are charged here, on the amount the trader named; the other two in `afterSwap`.
        bool isBuy = tokenIs0 ? !swapForY : swapForY;
        (uint24 lpPips, uint24 guardPips) = _feeParts(_feeNow(l), isBuy);
        if ((amountSpecified < 0) != isBuy) {
            return (IBinHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpPips | LP_FEE_OVERRIDE);
        }
        int128 taken =
            _takeInQuote(poolId, tokenIs0 ? key.currency1 : key.currency0, _abs(amountSpecified), guardPips, isBuy);
        return (IBinHooks.beforeSwap.selector, toBeforeSwapDelta(taken, 0), lpPips | LP_FEE_OVERRIDE);
    }

    /// @dev The bin-only callback, and the reason this hook is not a straight port of the CL one.
    ///
    /// A mint into the ACTIVE bin at a ratio other than the bin's own is an implicit swap, priced
    /// at the composition fee. Without this override that fee would be the pool's stored LP fee,
    /// which is 0 on a dynamic-fee pool - a free swap around the launch tax.
    ///
    /// It deliberately does NOT gate on `startTime`. Reverting here before the launch opens would
    /// make the pool unseedable, because `sender` is the router and the launcher cannot be
    /// distinguished from a sniper. Pre-launch mints are therefore charged `initialFeeBips`, the
    /// maximum rate on the schedule, rather than blocked. See "WHAT IT DOES NOT PREVENT".
    ///
    /// WHILE A CREATOR TAX IS LIVE the active bin is closed to mints altogether (contract-level
    /// note): a lopsided active-bin mint is a swap the tax cannot see. The loop is over the caller's
    /// own `liquidityConfigs`, so the caller pays for its length; a config core would reject
    /// (`LiquidityConfigurations__InvalidConfig`) is rejected here first, harmlessly.
    function _beforeMint(
        address, /* sender */
        PoolKey calldata key,
        IBinPoolManager.MintParams calldata params,
        bytes calldata /* hookData */
    )
        internal
        virtual
        override
        returns (bytes4, uint24)
    {
        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];
        if (l.owner == address(0)) revert LaunchNotConfigured(poolId);

        if (_taxLiveAt(poolId, block.timestamp)) {
            (uint24 activeId,,) = poolManager.getSlot0(poolId);
            uint256 n = params.liquidityConfigs.length;
            for (uint256 i; i < n; ++i) {
                (,, uint24 id) = LiquidityConfigurations.decodeParams(params.liquidityConfigs[i]);
                if (id == activeId) revert TaxedActiveBinMintBlocked(poolId, activeId);
            }
        }

        return (IBinHooks.beforeMint.selector, _feeNow(l) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Per-TRANSACTION cap. It bounds one swap. It does not and cannot bound a wallet, an
    /// entity, or a block: splitting a buy into several transactions defeats it entirely, and no
    /// hook at this layer can tell those transactions apart (see the contract-level note). It also
    /// does not bound the mint route at all.
    ///
    /// `amountSpecified < 0` is exact input in core's convention. For a buy, the input currency is
    /// the quote currency, which is the denomination of `maxBuyPerTx`. For an exact-OUTPUT buy the
    /// input amount is not known until the swap has been computed, so the cap cannot be checked;
    /// such a buy is rejected while the cap is live rather than waved through.
    function _enforceMaxBuy(bool swapForY, int128 amountSpecified, bool launchTokenIsCurrency0, uint128 maxBuyPerTx)
        internal
        pure
    {
        // swapForY sells currency0 (X) and receives currency1 (Y) - the analogue of zeroForOne.
        bool isBuy = launchTokenIsCurrency0 ? !swapForY : swapForY;
        if (!isBuy) return;

        if (amountSpecified > 0) revert ExactOutputBuyBlockedDuringLaunch();

        // `amountSpecified` is strictly negative here (core rejects 0 with `AmountSpecifiedIsZero`
        // before any hook runs), and the negation is CHECKED: the single pathological input,
        // `type(int128).min`, reverts rather than wrapping to a huge positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(uint128(-amountSpecified));
        if (amountIn > maxBuyPerTx) revert BuyExceedsMaxPerTx(amountIn, maxBuyPerTx);
    }

    /// @dev The fee and the tax of a swap whose quote is the unspecified side. `sender` is the Vault
    /// locker and `hookData` is attacker-controlled; neither is read. A buy is a swap INTO the
    /// launch token.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];
        bool tokenIs0 = l.launchTokenIsCurrency0;
        bool isBuy = tokenIs0 ? !swapForY : swapForY;
        // The mirror of `beforeSwap`: an exact-input sell and an exact-output buy have the quote on
        // the unspecified side, and are charged here on the amount the pool computed. The other two
        // were charged before the swap and take nothing now.
        if ((amountSpecified < 0) == isBuy) return (IBinHooks.afterSwap.selector, 0);
        (, uint24 guardPips) = _feeParts(_feeNow(l), isBuy);
        return (
            IBinHooks.afterSwap.selector,
            _takeInQuote(
                poolId,
                tokenIs0 ? key.currency1 : key.currency0,
                _abs(tokenIs0 ? delta.amount1() : delta.amount0()),
                guardPips,
                isBuy
            )
        );
    }
}
