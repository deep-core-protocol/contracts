/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {BaseCLHook} from "../base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
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

import {LaunchTaxModule} from "./LaunchTaxModule.sol";

/// @notice The one read this hook makes of a launch-token factory: who created a token.
/// @dev Declared here rather than imported from `packages/launchpad`, which depends on this package.
/// `LaunchTokenFactory.deployerOf` satisfies it; a non-factory address returns zero.
interface ILaunchTokenOrigin {
    function deployerOf(address token) external view returns (address);
}

/// @title LaunchGuardHook
/// @notice Anti-sniper launch protection for DeepCoreProtocol CL pools: a decaying "sniper tax".
///
/// @dev ############################ WHAT THIS HOOK ACTUALLY DOES ############################
///
/// It prices early buying instead of trying to identify early buyers. For `decaySeconds` seconds
/// after `startTime` the fee decays linearly from `initialFeeBips` down to `finalFeeBips`. A sniper
/// who buys in the first second pays the full launch tax; a normal buyer who arrives after the
/// window pays the normal fee.
///
/// THE FEE IS TAKEN BY THIS CONTRACT, IN THE QUOTE CURRENCY (owner decision, 2026-09-28). It used
/// to be an LP fee override, which core charges on the input: a buy paid it in the quote and a sell
/// paid it in the launch token. Now the fee is a hook delta on whichever side of the swap is the
/// quote, split creator / protocol / integrator by the pool's fee split and paid by pull. A share
/// of it fixed at deployment (`LP_SHARE_BPS`) is left to the pool as its LP fee, on buys only, so
/// that it too is paid in the quote. `LaunchTaxModule` carries the table of the four swap shapes,
/// the share, the money path and the consequences; the short form is that everybody a pool this
/// guard runs pays is paid in one currency.
///
/// EVERY DURATION HERE IS `block.timestamp` SECONDS. It used to be `block.number` blocks, sized
/// through a per-chain `blockTimeCentis`, and on Arbitrum Nitro (Robinhood Chain, 4663) the EVM's
/// `block.number` is Ethereum's ~12 s block while the RPC reports ~0.1 s L2 blocks - the live
/// block-based deployment was built for the wrong one and runs every window ~120x long. There is
/// no block-time argument left to get wrong. See "CLOCK" below for what timestamps do and do not
/// promise on a sequencer chain.
///
/// This design is deliberate, and it follows from a hard constraint of the singleton architecture:
///
///   THE `sender` ARGUMENT OF EVERY HOOK CALLBACK IS THE LOCKER, NOT THE END USER.
///
///   `CLHooks.beforeSwap` invokes the hook with `msg.sender` of the `CLPoolManager.swap` call,
///   which is whoever locked the Vault - i.e. the router. Every swap routed through a shared
///   router arrives with the SAME `sender`. A per-wallet buy cap keyed on `sender` would therefore
///   be consumed by the first buyer on behalf of everybody, and `hookData` cannot be trusted to
///   name the real buyer because anyone may bypass the router and lock the Vault directly with
///   arbitrary `hookData`.
///
///   Consequence: NO identity-based protection is implementable at this layer. There are no
///   per-wallet caps, no allowlists, and no "one buy per address" rules in this hook, because
///   none of them could be enforced honestly.
///
/// ------------------------------- WHAT IT PREVENTS -------------------------------
///  * Free front-running of a launch. Buying in the first second of the window costs
///    `initialFeeBips`. A sniper cannot escape this with fresh wallets, contracts, or private
///    orderflow, because the tax is a function of time and the pool, not of the buyer.
///  * Trading before the launch opens. `beforeSwap` reverts for every swap before `startTime`,
///    so liquidity can be seeded and the pool initialized without anyone being able to buy first.
///  * A single oversized market buy during the window, if `maxBuyPerTx` is configured.
///  * A launch owner spiking the fee mid-launch. Configuration is frozen from `startTime` on, and
///    from the first swap if that comes first (a disabled schedule trades before its `startTime`).
///  * Silent misconfiguration: a non-dynamic-fee pool is rejected at `beforeInitialize`, because
///    core discards a `beforeSwap` fee on a static-fee pool without reverting.
///
/// ----------------------------- WHAT IT DOES NOT PREVENT -----------------------------
///  * Sybil accumulation. Splitting a buy across N wallets or N transactions in the same block is
///    NOT prevented and cannot be. `maxBuyPerTx` bounds one transaction, nothing more.
///  * A sniper who is simply willing to pay the tax. The tax is a price, not a prohibition.
///  * Accumulation via a route that does not touch this pool (another pool, an OTC deal, a CEX).
///  * Anything about the token itself: transfer restrictions, mint authority, LP-token custody,
///    or a rug pull by the token deployer. This hook only governs swaps against ONE pool.
///  * Sells. `maxBuyPerTx` is one-directional by design; the decaying fee applies to both
///    directions, so early sells are taxed too, but there is no separate sell limit.
///  * A launch owner who opens trading late. `startTime` may be pushed back while nobody has traded,
///    but never past `openDeadline` (first claim + `MAX_START_DELAY_SECONDS`), so a launch opens
///    within 30 days of being claimed. Liquidity operations are NOT hooked, so LPs can always withdraw.
///  * A MALICIOUS SEQUENCER. See "CLOCK".
///
/// ------------------------------ THE CREATOR TAX ------------------------------
/// Distinct from the fee above, and inherited from `LaunchTaxModule`: a per-pool buy rate and sell
/// rate, taken ONCE per swap on the same quote amount as the fee, until a fixed expiry, and split
/// creator / protocol / integrator (protocol floor 10%, enforced by this contract and not by any
/// kit). It is configured through `configureTax` by the same launch owner, under the same freeze:
/// writable until `startTime` or the first swap, immutable after. Fee and tax have separate pots
/// and separate splits on one pull-based ledger. Neither is charged on the other; see the module
/// header for the money path.
///
/// ---------------------------------- CLOCK ----------------------------------
/// `block.timestamp` is set by the block producer. On Ethereum L1 it is fixed per slot. On
/// Arbitrum Nitro the sequencer sets it from its own clock, and the protocol bounds it: never
/// below the previous block's timestamp, never more than 24 h behind real time, never more than
/// 1 h ahead (docs.arbitrum.io, "Block numbers and time"). Force-included transactions take the
/// parent-chain timestamp of their delayed-inbox message, so nobody but the sequencer can push
/// the clock forward. Consequences:
///  * An HONEST sequencer's clock is NTP-synchronised and whole-second; `MIN_DECAY_SECONDS`
///    bounds the relative error that leaves. A lagging or stalled clock only LENGTHENS a window.
///  * A MALICIOUS sequencer can jump the clock up to one hour forward in one block and so erase
///    any window shorter than that. No floor compatible with minutes-long presets defends
///    against it, and that same sequencer already orders every transaction. This is a trust
///    assumption on the chain operator, stated rather than hidden.
///  * A sequencer outage that spans the window erases it for everyone equally: the first block
///    after recovery carries the recovered timestamp. The old block-number clock had the same
///    property, since Nitro's `block.number` also resyncs to the parent chain on recovery.
/// #####################################################################################
contract LaunchGuardHook is BaseCLHook, LaunchTaxModule {
    using LPFeeLibrary for uint24;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool key does not name this contract as its hook
    error HookMismatch(address declared);

    /// @notice The pool key names a different pool manager than this hook serves
    error PoolManagerMismatch(address declared);

    /// @notice A fee returned from `beforeSwap` is silently ignored on a static-fee pool, so a
    /// launch on such a pool would provide no protection at all. Reject it at initialization.
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

    /// @notice A first claim named a non-native currency with no code. Launch pools are refused on
    /// addresses that do not hold a token YET, which is exactly what a front-runner squatting a
    /// predictable token address would claim.
    error CurrencyHasNoCode(address currency);

    /// @notice `token` was created by the launch-token factory, so only its creator (or the claimer
    /// that creator appointed) may claim a launch pool for it.
    error LaunchPoolReserved(address token, address creator, address caller);

    /// @notice Only a factory token's creator may appoint its launch claimer.
    error NotTokenCreator(address token, address caller);

    /// @notice An exact-output buy was attempted while a per-transaction cap is active.
    /// @dev `beforeSwap` cannot know the input amount of an exact-output swap, so the cap cannot
    /// be enforced on one. Allowing it would be a one-line bypass of the cap, so it is rejected
    /// for the duration of the launch window instead.
    error ExactOutputBuyBlockedDuringLaunch();

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
    /// an absence: the pool's part of the fee on a buy, zero on a sell. A dynamic-fee pool's stored
    /// fee is zero, and without the flag core would use that on every path.
    uint24 internal constant LP_FEE_OVERRIDE = LPFeeLibrary.OVERRIDE_FEE_FLAG;

    /// @notice Hard cap on the opening tax. Core would accept up to 100%, which is confiscation;
    /// this hook refuses to let a launch owner configure that.
    uint24 public constant MAX_INITIAL_FEE = 500_000; // 50%

    /// @notice Hard cap on the fee that remains once the window has elapsed. Bounds how bad a
    /// permanently hostile configuration can be, since config is immutable after `startTime`.
    uint24 public constant MAX_FINAL_FEE = 100_000; // 10%

    /// @notice ERC-6372 clock mode. Every duration and every stored time in this contract is
    /// `block.timestamp`. Off-chain readers call this to tell this hook apart from the retired
    /// block-numbered one, which does not implement it and reverts.
    string public constant CLOCK_MODE = "mode=timestamp";

    /// @notice Shortest decay window a launch may configure.
    ///
    /// @dev WHY 60 SECONDS, with the numbers:
    ///  * Resolution. `block.timestamp` is whole seconds, so a window of W seconds is exact to
    ///    within 1/W: at 60 s that is under 1.7%. (Many ~0.1 s Nitro blocks share one second.)
    ///  * Honest skew. The sequencer stamps blocks from an NTP-synchronised clock, monotonically,
    ///    so ordinary operation drifts by well under a second. A failover to a replica whose clock
    ///    is ahead by d seconds jumps the chain forward by d once; 60 s absorbs d = 6 s at 10%.
    ///  * Better than what it replaces. Nitro's `block.number` resyncs to Ethereum only "every 13
    ///    to 15 seconds (occasionally longer)" per Arbitrum's docs, so a block-denominated window
    ///    was never finer than ~15 s. 60 s of timestamp is at least four times that granularity.
    ///  * Below the owner's presets. The shortest (`Stealth`) is 120 s, so the floor constrains
    ///    only hand-built custom launches that would otherwise be measurement noise.
    ///  * NOT a defence against a malicious sequencer, which can move the clock up to 3 600 s
    ///    forward. No floor under an hour is; see the contract-level "CLOCK" note.
    uint32 public constant MIN_DECAY_SECONDS = 60;

    /// @notice Hard cap on the decay window, so a "launch tax" cannot be a permanent tax.
    uint32 public constant MAX_DECAY_SECONDS = 30 days;

    /// @notice Hard cap on how far ahead `startTime` may be set in any single write.
    /// @dev No FLOOR on the start delay, deliberately. A forward clock skew can only open trading
    /// earlier than scheduled; it cannot make trading open before the pool exists, and a start of
    /// "now" is already a legitimate launch that opens at the full `initialFeeBips`.
    uint40 public constant MAX_START_DELAY_SECONDS = 30 days;

    /// @notice The design envelope the two caps above must sit inside, kept as published
    /// constants so a reader can check the relationship without trusting this comment:
    /// `MIN_LAUNCH_WINDOW_SECONDS <= MAX_DECAY_SECONDS` (a three-day fair launch is possible) and
    /// `MAX_START_DELAY_SECONDS + MAX_DECAY_SECONDS <= MAX_LAUNCH_WINDOW_SECONDS` (the tax is gone
    /// within 60 days of any configuration write, well inside 180). Both asserted in tests.
    uint256 public constant MIN_LAUNCH_WINDOW_SECONDS = 3 days;

    /// @notice See `MIN_LAUNCH_WINDOW_SECONDS`. Past this a "launch tax" stops being a launch tax.
    uint256 public constant MAX_LAUNCH_WINDOW_SECONDS = 180 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @param owner The launch owner. `address(0)` means the pool id has never been claimed.
    /// @param startTime First `block.timestamp` at which swaps are permitted.
    /// @param decaySeconds Length of the decay window, in seconds, starting at `startTime`.
    /// @param enabled When false the hook applies no gate, no cap and no decay: its fee is
    ///        `finalFeeBips` from the first swap, taken in the quote like any other.
    /// @param initialFeeBips Fee at `startTime`.
    /// @param finalFeeBips Fee at and after `startTime + decaySeconds`.
    /// @param maxBuyPerTx Per-transaction cap on the INPUT amount of a buy, denominated in the
    ///        quote currency (the currency that is not the launch token). 0 disables the cap.
    /// @param launchTokenIsCurrency0 Which side of the pool is the token being launched. Only used
    ///        to decide which swap direction is a "buy" for `maxBuyPerTx`.
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
     * ############ POOL-ID RESERVATION (owner decision, 2026-09-14) ############
     *
     * A launch pool's id is predictable before its transaction lands: the kit derives the token
     * address from a CREATE2 salt and the key from that. First-claim ownership then let a
     * front-runner `configureLaunch` the pool first, so the kit's own claim reverted
     * `NotLaunchOwner` and the launch failed. Nothing was stolen; the launch was denied.
     *
     * Two rules close it, and neither needs an owner or a kit address in this contract:
     *
     *   1. NO CLAIM ON AN ADDRESS WITHOUT CODE. A kit that creates the token and the pool in one
     *      transaction (Kit v2) is unsquattable: before that transaction the token has no code, so
     *      nobody can claim; inside it, the kit claims first.
     *   2. A `LAUNCH_TOKEN_FACTORY` TOKEN BELONGS TO ITS CREATOR. For a token the factory made, the
     *      first claim must come from `deployerOf(token)` - the kit, for a kit-created token - or
     *      from the one claimer that creator appointed (`setLaunchClaimer`), which is how a person
     *      who minted a token directly hands the launch to a kit. This closes the window between a
     *      token existing and its launch.
     *
     * Why the factory's creator record rather than "the registered kit": it cannot be squatted, it
     * has no setter, it works for every tenant kit on the shared factory rather than one, and it
     * avoids a hook-kit circular deployment. Pools on any other token behave exactly as before,
     * except that rule 1 refuses a currency with no code, which cannot be a working pool anyway.
     */
    ILaunchTokenOrigin public immutable LAUNCH_TOKEN_FACTORY;

    /// @notice The claimer a factory token's creator appointed. Zero means only the creator.
    mapping(address token => address claimer) public launchClaimerOf;

    /// @param _poolManager The CL singleton this hook serves, forever.
    /// @param launchTokenFactory The `LaunchTokenFactory` whose tokens get reserved launch pools, or
    /// `address(0)` for a deployment with no factory (rule 1 still applies). Every duration bound is a
    /// constant in seconds, so no chain can be configured with the wrong clock.
    /// @param protocolRecipient_ Where the protocol bucket of the fee and of the creator tax is
    /// credited, forever (the governance Safe on mainnet). See `LaunchTaxModule`.
    /// @param lpShareBps_ The share of the trade fee left to the pool as its LP fee, on buys, for
    /// every pool this guard runs. At most `MAX_LP_SHARE_BPS`; zero leaves the pool nothing.
    constructor(
        ICLPoolManager _poolManager,
        ILaunchTokenOrigin launchTokenFactory,
        address protocolRecipient_,
        uint16 lpShareBps_
    ) BaseCLHook(_poolManager) LaunchTaxModule(_poolManager.vault(), protocolRecipient_, lpShareBps_) {
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
    /// gates trading and returns the pool's part of the fee. The two returns-delta bits are what let this
    /// contract take the fee and the tax in the quote currency: bit 10 when the quote is the
    /// specified side of the swap, bit 11 when it is the unspecified side. Bit 10 requires bit 6 and
    /// bit 11 requires bit 7, re-checked by `BaseCLHook._validatePermissions` at deploy time.
    ///
    /// bit 0 (beforeInitialize) | bit 6 (beforeSwap) | bit 7 (afterSwap)
    ///   | bit 10 (beforeSwapReturnsDelta) | bit 11 (afterSwapReturnsDelta) == 0x0CC1.
    function getHooksRegistrationBitmap() public pure virtual override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA;
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
    /// pool cannot be initialized without it, so the kit calls this right after its claim and a
    /// direct launcher does the same in the same transaction. Bounds and the protocol floor are
    /// validated in `LaunchTaxModule`.
    function configureFeeSplit(PoolKey calldata key, FeeSplit calldata cfg) external {
        _configureFeeSplit(_ownedUnfrozenPool(key), cfg);
    }

    /// @notice Write (or, with all-zero terms, clear) the creator tax for `key`'s pool.
    /// @dev Launch owner only, under the freeze `configureLaunch` applies: until trading opens or the
    /// first swap, whichever comes first (see `_launchOwnerAndFreeze` for the one-second difference). A pool must already be claimed (`configureLaunch`
    /// first), so the kit calls this right after its claim and a direct launcher does the same in
    /// the same transaction. Bounds and the protocol floor are validated in `LaunchTaxModule`.
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

    /// @dev The two reservation rules, for one currency of a first claim. See `LAUNCH_TOKEN_FACTORY`.
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
        // Applied whether or not the launch is `enabled`: a disabled config may be re-enabled by a
        // later write, and a single invariant is harder to get wrong than a conditional one.
        if (cfg.decaySeconds < MIN_DECAY_SECONDS || cfg.decaySeconds > MAX_DECAY_SECONDS) {
            revert InvalidDecaySeconds(cfg.decaySeconds);
        }
        // Must be a decay, and must stay inside this hook's caps (which are stricter than core's).
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
    /// and for times before `startTime` returns `initialFeeBips` - though such a swap would in
    /// fact revert, so treat that value as "the fee at the open".
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
    /// `MAX_INITIAL_FEE` and therefore never exceeds what core accepts (1_000_000).
    ///
    /// Monotonicity: `spread * elapsed / decaySeconds` is non-decreasing in `elapsed` (integer
    /// division by a fixed positive denominator preserves order), so the result is non-increasing.
    ///
    /// Overflow: `spread <= 500_000` and `elapsed < decaySeconds <= 2_592_000` in the multiplying
    /// branch, so the product is below 1.3e12 - nowhere near uint256.
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

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Rejects a pool that cannot actually enforce the launch tax, a pool nobody has claimed
    /// and a pool whose fee has nowhere to go. `sender` is intentionally ignored: it is the caller
    /// of `initialize`, which may be any periphery contract, and is not a trustworthy identity.
    function _beforeInitialize(address, /* sender */ PoolKey calldata key, uint160 /* sqrtPriceX96 */ )
        internal
        view
        virtual
        override
        returns (bytes4)
    {
        // On a static-fee pool `CLHooks.beforeSwap` DISCARDS the fee this hook returns, with no
        // revert and no event. Deploying launch protection there would be protection in name only.
        if (!key.fee.isDynamicLPFee()) revert PoolMustUseDynamicFee(key.fee);

        PoolId poolId = key.toId();
        if (_launches[poolId].owner == address(0)) revert LaunchNotConfigured(poolId);
        // A fee is taken from the first swap on, and the split is written once: a pool born without
        // it would collect into a pot nobody could ever be paid from.
        if (!_feeSplitSet(poolId)) revert FeeSplitNotConfigured(poolId);

        return ICLHooks.beforeInitialize.selector;
    }

    /// @dev `sender` is the Vault locker (the router), NOT the buyer. It is unused here, and that
    /// is the whole reason this hook taxes time rather than identity.
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
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
                _enforceMaxBuy(params, tokenIs0, maxBuyPerTx);
            }
        }

        // The quote is the specified side of an exact-input buy and of an exact-output sell. Those
        // two are charged here, on the amount the trader named; the other two in `afterSwap`.
        bool isBuy = tokenIs0 ? !params.zeroForOne : params.zeroForOne;
        (uint24 lpPips, uint24 guardPips) = _feeParts(_feeNow(l), isBuy);
        if ((params.amountSpecified < 0) != isBuy) {
            return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpPips | LP_FEE_OVERRIDE);
        }
        int128 taken = _takeInQuote(
            poolId, tokenIs0 ? key.currency1 : key.currency0, _absSpecified(params.amountSpecified), guardPips, isBuy
        );
        return (ICLHooks.beforeSwap.selector, toBeforeSwapDelta(taken, 0), lpPips | LP_FEE_OVERRIDE);
    }

    /// @dev The fee of this second: `finalFeeBips` on a disabled schedule, the decay otherwise. Only
    /// reached at or after `startTime` on an enabled one (`beforeSwap` reverts before it).
    function _feeNow(Launch storage l) internal view returns (uint24) {
        if (!l.enabled) return l.finalFeeBips;
        return _decayedFee(l.initialFeeBips, l.finalFeeBips, block.timestamp - l.startTime, l.decaySeconds);
    }

    /// @dev A swap charged in `beforeSwap` must have traded what it named: a CL swap that runs out of
    /// liquidity, or reaches its price limit, fills in part without reverting, and the take was made
    /// on the whole amount. Recomputed from the same inputs in the same second, so `taken` here is
    /// what `beforeSwap` took. Nothing was taken, nothing to check.
    /// @param quoteDelta The pool's own delta in the quote currency, before any hook delta.
    function _requireFilled(PoolId poolId, Launch storage l, int256 amountSpecified, int128 quoteDelta, bool isBuy)
        internal
        view
    {
        uint256 named = _absSpecified(amountSpecified);
        (, uint24 guardPips) = _feeParts(_feeNow(l), isBuy);
        (uint256 fee, uint256 tax) = _quoteTake(poolId, named, guardPips, isBuy);
        uint256 taken = fee + tax;
        if (taken == 0) return;
        // Exact input: the pool takes in what was named less the take. Exact output: it pays out
        // what was named plus the take.
        uint256 expected = amountSpecified < 0 ? named - taken : named + taken;
        uint256 traded = _abs(quoteDelta);
        if (traded != expected) revert SwapNotFilled(expected, traded);
    }

    /// @dev Core's `amountSpecified` is an `int256` that it has already bounded to `int128` by the
    /// time a swap settles; the magnitude is taken in 256 bits so no input can wrap.
    function _absSpecified(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified > 0 ? uint256(amountSpecified) : uint256(-amountSpecified);
    }

    /// @dev Per-TRANSACTION cap. It bounds one swap. It does not and cannot bound a wallet, an
    /// entity, or a block: splitting a buy into several transactions defeats it entirely, and no
    /// hook at this layer can tell those transactions apart (see the contract-level note).
    ///
    /// `amountSpecified < 0` is exact input in core's convention. For a buy, the input currency is
    /// the quote currency, which is the denomination of `maxBuyPerTx`. For an exact-OUTPUT buy the
    /// input amount is not known until the swap has been computed, so the cap cannot be checked;
    /// such a buy is rejected while the cap is live rather than waved through.
    function _enforceMaxBuy(
        ICLPoolManager.SwapParams calldata params,
        bool launchTokenIsCurrency0,
        uint128 maxBuyPerTx
    ) internal pure {
        // zeroForOne sells currency0 and receives currency1.
        bool isBuy = launchTokenIsCurrency0 ? !params.zeroForOne : params.zeroForOne;
        if (!isBuy) return;

        if (params.amountSpecified > 0) revert ExactOutputBuyBlockedDuringLaunch();

        // `amountSpecified` is strictly negative here, and the negation is CHECKED: the single
        // pathological input, `type(int256).min`, reverts rather than wrapping to a huge positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn > maxBuyPerTx) revert BuyExceedsMaxPerTx(amountIn, maxBuyPerTx);
    }

    /// @dev The fee and the tax of a swap whose quote is the unspecified side. `sender` is the Vault
    /// locker and `hookData` is attacker-controlled; neither is read. A buy is a swap INTO the
    /// launch token. `beforeSwap` already read this pool's launch record in this transaction, so
    /// that read is warm here.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];
        bool tokenIs0 = l.launchTokenIsCurrency0;
        bool isBuy = tokenIs0 ? !params.zeroForOne : params.zeroForOne;
        // The mirror of `beforeSwap`: an exact-input sell and an exact-output buy have the quote on
        // the unspecified side, and are charged here on the amount the pool computed. The other two
        // were charged before the swap, on the amount NAMED, and take nothing now; what they owe
        // this callback is proof that the pool traded that amount.
        if ((params.amountSpecified < 0) == isBuy) {
            _requireFilled(poolId, l, params.amountSpecified, tokenIs0 ? delta.amount1() : delta.amount0(), isBuy);
            return (ICLHooks.afterSwap.selector, 0);
        }
        (, uint24 guardPips) = _feeParts(_feeNow(l), isBuy);
        return (
            ICLHooks.afterSwap.selector,
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
