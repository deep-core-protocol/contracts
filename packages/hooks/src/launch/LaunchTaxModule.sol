/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";

/// @title LaunchTaxModule
/// @notice Everything a launch guard charges, shared by `LaunchGuardHook` (CL) and
/// `BinLaunchGuardHook` (Bin), and ALL OF IT IN THE POOL'S QUOTE CURRENCY:
///
///   * the TRADE FEE: the guard's own fee schedule (the decaying opening fee, then the final fee
///     forever), split three ways by a per-pool split written once;
///   * the CREATOR TAX: an optional per-pool buy rate and sell rate until a fixed expiry, split
///     three ways by its own per-pool split.
///
/// Both are taken as a hook delta on whichever side of the swap is the quote currency, and paid by
/// pull.
///
/// @dev ##################### QUOTE AT THE SOURCE (owner decision, 2026-09-28) #####################
///
/// An AMM charges its LP fee on the INPUT, so a sell paid its fee in the launch token, and the
/// creator tax was taken on the unspecified side, so a buy paid it in the launch token. Creator,
/// protocol and integrator each ended up holding a mix that had to be sold to be spent. Selling it
/// into the launch's own pool costs the fee again, can be sandwiched (a launch token has no price
/// oracle) and shows on the chart as the platform selling.
///
/// So nothing is sold. The guard takes the fee itself, in the quote currency, on every swap:
///
///   swap                 quote is         taken in      base of the fee
///   buy,  exact input    specified (in)   beforeSwap    the quote the trader sends
///   sell, exact input    unspecified      afterSwap     the quote the pool pays out
///   buy,  exact output   unspecified      afterSwap     the quote the pool asks for
///   sell, exact output   specified (out)  beforeSwap    the quote the trader asked for
///
/// The pool sees the same tokens either way: on a sell of X tokens, X reach the pool whether 1% of
/// them is taken first and sold later, or all X are swapped and 1% of the quote is kept.
///
/// ############### THE LIQUIDITY PROVIDERS' SHARE (owner decision, 2026-09-28) ###############
///
/// A pool whose liquidity earns nothing gives nobody but the launch a reason to add any. So a
/// share of the trade fee, `LP_SHARE_BPS`, is left to the pool as its LP fee. It is fixed at
/// deployment for every pool this guard runs, at most `MAX_LP_SHARE_BPS`, and may be zero.
///
/// IT IS PAID ON BUYS ONLY, and that is what keeps it in the quote currency. Core charges an LP
/// fee on a swap's INPUT: the quote on a buy, the launch token on a sell. A share paid on sells
/// would arrive in the launch token, which is the thing this design exists to end. So:
///
///   a buy   pays  lp = floor(fee * LP_SHARE_BPS / 1e4)  to the pool, as the LP fee override,
///           and   fee - lp                              to this contract, in the quote;
///   a sell  pays  nothing to the pool (the override is zero) and the whole fee to this contract.
///
/// Read over a token's life, where what is bought is about what is sold, the pool's liquidity
/// earns about half of `LP_SHARE_BPS` of all trade fees, all of it in the quote.
///
/// A BUYER NEVER PAYS MORE THAN `fee`. On an exact-output buy both parts are rates on the same
/// base, the pool's quote amount, and sum to `fee` of it. On an exact-input buy this contract
/// takes its part (and the tax) of the amount named and the pool charges its part on what is
/// left, as core's protocol fee and LP fee stack: the buyer pays LESS than `fee` of the amount
/// named, by the pool's part times what this contract took. With the share at its cap that is at
/// most a quarter of the fee squared: 6.25% of the trade while the fee is at its 50% opening cap,
/// 0.0025% at a settled 1% fee. The difference is the pool's, not this ledger's. Documented.
///
/// CONSEQUENCES, stated rather than discovered:
///  * On a kit launch the locked position is the pool's liquidity, so the pool's part of a buy is
///    earned by the lock and paid out by the locker under the lock's split. It reaches the same
///    parties in the same currency by a second path (`collectFees`, then the locker's `claim`).
///  * Anything that reads the POOL fee sees a part of what a buy costs and nothing of what a sell
///    costs. What a trade costs is `feeAt` plus the tax rates, and an indexer has to say so (the
///    adapters carry both as their own fields).
///  * On Bin, the composition fee of an active-bin mint is the WHOLE guard fee, charged by core as
///    an LP fee in the token added. That route pays liquidity providers, not this ledger.
///
/// @dev ############################ WHY IT LIVES IN THE GUARDS ############################
///
/// A pool has exactly one hook, and every kit launch pool already runs a launch guard. A separate
/// "tax hook" would therefore have to REPLACE the guard, losing the trading gate, the decaying LP
/// fee and the pool-id reservation, or force the kit to choose one protection per launch. Putting
/// the tax in the guard keeps one hook per pool and one freeze rule for everything the launch owner
/// configures. The guards inherit this module; it owns the tax's storage, validation and money path
/// and asks the guard only two things: who owns a pool and whether its configuration is frozen.
///
/// ################################# THE MONEY PATH #################################
///
/// It is `RevShareHook`'s, function for function, because that path has been reviewed, exercised on
/// chain and found L-1-clean:
///
///   the swap   : fee and tax are minted to THIS contract in ONE `vault.mint` of ERC-6909 vault
///                claims, never taken as tokens inside somebody else's swap. They are added to
///                MONOTONE counters the swap path alone writes: `feeTaken[poolId][currency]`,
///                `totalTaken[poolId][currency]` (the tax) and `grossTaken[currency]` (both). One
///                SSTORE per pot instead of three for the buckets: that is why the split happens at
///                settlement rather than per swap. The pots and the obligation are VIEWS:
///                `pendingFee = feeTaken - feeSettled`, `pendingTax = totalTaken - totalSettled`,
///                `totalOwed = grossTaken + grossSkimmed - grossClaimed`. So nothing a stranger can
///                call ever rewrites a value the swap path reads (the property `deepcore-lint`
///                DEEPCORE-009 checks), and every counter is cumulative, which is what an indexer wants.
///   settleFee  : permissionless. Splits a pool's fee pot into `claimable[party][currency]` by the
///   settleTax    pool's fee split; `settleTax` does the same for the tax pot and the tax's split.
///                The rounding remainder goes to the protocol bucket, so a pot is always drained
///                to zero and nothing accumulates as unreachable dust.
///   claim      : pull, never push. Zeroes the caller's balance, decrements `totalOwed`, redeems vault
///                claims if the contract holds too few real tokens, then transfers. A recipient that
///                cannot receive a token strands only its own balance.
///   redeem     : permissionless plumbing. Converts vault claims into real tokens; pays nobody.
///   skim       : permissionless. Credits whatever the contract holds ABOVE `totalOwed` - value that
///                reached it by mistake - to the immutable protocol recipient. This is the L-1 rule
///                (a misdirected ERC-20 must have a path out) for a contract with no owner, so the
///                only possible destination is the one address fixed at deployment.
///
/// INVARIANT: `backing(currency) >= totalOwed(currency)` for every currency, where backing is real
/// balance plus vault claims. A swap raises both by the same amount; `claim` lowers both by the
/// same amount; `settleFee` and `settleTax` move value between ledgers inside `totalOwed`; `skim`
/// raises `totalOwed` up to backing. Nothing else touches either side. Second invariant:
/// `totalOwed(c) == sum over pools of (pendingFee(pool, c) + pendingTax(pool, c)) + sum over
/// accounts of claimable(account, c)`.
///
/// ############################### WHAT IS FROZEN, AND WHEN ###############################
///
/// THE FEE SPLIT IS WRITTEN ONCE. `configureFeeSplit` is the launch owner's, succeeds a single time
/// per pool, and the pool cannot be initialized without it (`FeeSplitNotConfigured`), so no fee is
/// ever taken that has nowhere to go and no party's share of it can be rewritten, before trading or
/// after. It replaces the split a lock carried, which was also written once.
///
/// ONE THING IN IT CAN MOVE, and only by its own hand: the fee split's CREATOR may hand its bucket to
/// another address in two steps (`transferCreator`, then `acceptCreator` by the nominee), the way a
/// lock's creator always could. The fee is charged forever, and a wallet is not. Shares do not move,
/// the integrator does not move, nobody else can move the creator, and what was already credited
/// stays claimable by whoever it was credited to. A pot not yet settled is split for the creator of
/// the moment it is settled, so a creator settles before it hands over.
///
/// THE TWO FUNCTIONS ARE THE LOCKERS', SIGNATURE FOR SIGNATURE (`transferCreator(uint256, address)`,
/// `acceptCreator(uint256)`, `pendingCreator(uint256)`), with the pool id as the number. That is not
/// tidiness: a `DeepCoreSplit` accepts a creator role by calling `acceptCreator(uint256)` on whatever
/// address its payee names, and splits are deployed. Speaking the lockers' interface is what lets a
/// split that already exists take over a fee it could previously only take over from a lock. They
/// move the FEE split's creator and nothing else; the creator tax's recipient is fixed with the tax.
///
/// A pool's tax is configured by its launch owner (the kit, for kit pools) through `configureTax`,
/// under the guard's own freeze rule: writable until `startTime`, or until the first swap if that
/// comes first; immutable forever after. So every rate, the expiry and every bucket a trader can
/// read before trading is the one they trade under. Expiry is a timestamp compared on every swap:
/// once `block.timestamp >= expiresAt` the tax is zero with no transaction needed. It can never be
/// permanent: `expiresAt` is at most `MAX_TAX_DURATION_SECONDS` after the configuration write, and
/// that write must precede trading.
///
/// ############################## WHAT IT DOES NOT DO ##############################
///
///  * Double-charge. Fee and tax are each a rate on the SAME base, the quote amount of the swap,
///    and each is taken once. Neither is charged on the other: at the caps a swap in the first
///    second pays 50% + 10% = 60% of its quote amount, never 50% and then 10% of the rest. The LP
///    fee is zero, so there is no core fee inside either base.
///  * Take more than the swap. Core reverts `HookDeltaExceedsSwapAmount` when a hook's specified
///    delta exceeds the amount to swap; the caps above keep the take at 60% or less.
///  * Charge for a trade that did not happen. The two shapes charged in `beforeSwap` are charged
///    on the amount the trader NAMED, before the pool has computed anything. A CL swap that runs
///    out of liquidity, or reaches its price limit, fills in part without reverting, and the take
///    would then stand on the whole amount: at the caps, 60% of what was named whatever was
///    traded. So the CL guard checks in `afterSwap` that the pool traded exactly what was named
///    less the take, and reverts `SwapNotFilled` otherwise (found by the test rework of
///    2026-09-28, before anything was deployed). It fails closed: a refund is not possible, since
///    `afterSwap` can return a delta in the unspecified currency only. A buy past the end of a
///    launch range is therefore refused rather than filled in part, and a front end sizes it. The
///    two shapes charged in `afterSwap` take their rates on what the pool traded and need no
///    check. A Bin swap cannot fill in part: core reverts `BinPool__OutOfLiquidity`.
///  * Fail. The only external call on the swap path is `vault.mint` to this contract, which cannot
///    revert for a registered app with an open lock, and the arithmetic cannot overflow (the base
///    fits `int128` and the rates are below one). There is therefore no "cannot charge" case to
///    fail open or closed on; an amount that rounds to zero simply takes zero.
///  * Identify traders. `sender` is the Vault locker (the router) and `hookData` is attacker
///    controlled; neither is read. The tax is a function of the pool, the direction and the clock.
///  * Support fee-on-transfer tokens. Claims are settled from vault claims redeemed at face value;
///    a token that shaves transfers would leave the last claimant short. The kit never launches such
///    a token AS THE LAUNCH TOKEN, which is what it controls.
///
///    ⚠ CORRECTED 2026-09-25. This used to add "and no DeepCore surface offers one as a quote", which
///    had stopped being true: the dapp's launch wizard offers "Another ERC-20 by address", and a
///    hosted launchpad could be created with `restrictQuotes` off, so an arbitrary quote — a
///    fee-on-transfer one included — was reachable from the product while this file asserted it was
///    not. The premise, not the code, was wrong.
///
///    WHAT IS ACTUALLY TRUE, and where the exposure ends. Fee and tax are both taken in the QUOTE
///    currency, on every swap, so a fee-on-transfer quote is exposed on every swap rather than on
///    sells alone: the pots and `claimable` are credited at face value while `redeem` delivers the
///    shaved amount, so `totalOwed` exceeds the backing and the LAST claimant on that currency
///    comes up short. Nobody else's money is reachable — the shortfall is
///    bounded by the fee the quote itself charged, `skim` still pays only `backing - totalOwed`, and
///    no other pool's pot is touched.
///
///    MITIGATED AT THE SURFACES RATHER THAN HERE, deliberately: correcting it would mean measuring
///    the delivered amount inside `redeem` and re-deriving every credit from it, which changes the
///    accounting of every launch to defend against a token nobody should pick. Instead
///    `restrictQuotes` now DEFAULTS ON for a new launchpad (native, the stables and the non-rebasing
///    listed stocks), and the wizard states the risk on the screen where an address is pasted. A
///    direct launch (`tenant == 0`) has no allowlist to apply, so for those the warning is the whole
///    mitigation — which is why it is worded as the creator's risk rather than a footnote.
///  * Take from liquidity operations. A CL mint or burn performs no swap. On Bin, a mint into the
///    ACTIVE bin is an implicit swap; `BinLaunchGuardHook` refuses those while a tax is live rather
///    than trying to price them (see its `_beforeMint`).
///
/// No owner, no pause, no upgrade, no setter: like the guards themselves, the only privileged party
/// is each pool's launch owner, and only until trading opens. The protocol recipient is immutable.
abstract contract LaunchTaxModule is ILockCallback, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice A rate above `MAX_TAX_BPS`.
    error TaxRateTooHigh(uint16 bps);
    /// @notice `expiresAt` is not in `(block.timestamp, block.timestamp + MAX_TAX_DURATION_SECONDS]`.
    error TaxExpiryOutOfRange(uint40 expiresAt, uint256 currentTime);
    /// @notice The three buckets do not sum to `BPS`.
    error TaxSplitDoesNotSum(uint256 sum);
    /// @notice The protocol bucket is below `MIN_PROTOCOL_BPS` or above `MAX_PROTOCOL_BPS`.
    error TaxProtocolShareOutOfBounds(uint16 bps);
    /// @notice The integrator bucket is above `MAX_INTEGRATOR_BPS`.
    error TaxIntegratorShareTooHigh(uint16 bps);
    /// @notice A bucket with a non-zero share has no recipient, or a zero-share bucket names one.
    error TaxRecipientMismatch(address recipient, uint16 bps);
    /// @notice A recipient that could never claim: this contract.
    error InvalidTaxRecipient(address recipient);
    /// @notice A tax with both rates zero must be the all-zero configuration ("no tax").
    error TaxWithoutRate();
    /// @notice `claim` found nothing for the caller in this currency.
    error NothingToClaim();
    /// @notice `skim` found nothing above `totalOwed` in this currency.
    error NothingToSkim(Currency currency);
    /// @notice `claim` to `address(0)`.
    error InvalidRecipient();
    /// @notice Accounting backstop: a payout exceeded real balance plus redeemable claims.
    error InsufficientBackedBalance(Currency currency, uint256 needed, uint256 available);
    /// @notice Native currency arrived from somebody other than the Vault.
    error NativeNotAccepted();
    /// @notice `lockAcquired` was called outside this contract's own `redeem`.
    error UnexpectedLockCallback();
    /// @notice The protocol recipient or the vault was zero at construction.
    error ZeroAddress();
    /// @notice A pool's fee split is written once.
    error FeeSplitAlreadySet(PoolId poolId);
    /// @notice A pool cannot be initialized without a fee split.
    error FeeSplitNotConfigured(PoolId poolId);
    /// @notice Only the fee split's creator may nominate its successor.
    error NotFeeCreator(PoolId poolId, address caller);
    /// @notice Only the nominee may accept.
    error NotPendingFeeCreator(PoolId poolId, address caller);
    /// @notice The liquidity providers' share is above `MAX_LP_SHARE_BPS`.
    error LpShareTooHigh(uint16 lpShareBps);
    /// @notice A swap charged on the amount it named traded a different amount: it filled in part.
    /// @param expected What the pool had to trade in the quote currency: the amount named, less
    /// the take on an exact-input buy, plus the take on an exact-output sell.
    /// @param traded What the pool did trade in the quote currency.
    error SwapNotFilled(uint256 expected, uint256 traded);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A pool's tax was written (all-zero values mean the pool has no tax).
    event TaxConfigured(
        PoolId indexed poolId,
        uint16 buyBps,
        uint16 sellBps,
        uint40 expiresAt,
        address creator,
        address integrator,
        uint16 creatorBps,
        uint16 protocolBps,
        uint16 integratorBps
    );
    /// @notice A pool's fee split was written. It is never written again.
    event FeeSplitConfigured(
        PoolId indexed poolId,
        address creator,
        address integrator,
        uint16 creatorBps,
        uint16 protocolBps,
        uint16 integratorBps
    );
    /// @notice The fee split's creator nominated `pending` (zero withdraws a nomination).
    event FeeCreatorTransferStarted(PoolId indexed poolId, address indexed current, address indexed pending);
    /// @notice The nominee accepted: later settlements of the fee pot credit `current`.
    event FeeCreatorTransferred(PoolId indexed poolId, address indexed previous, address indexed current);
    /// @notice A swap paid `amount` of `currency` (the quote) into the pool's FEE pot.
    event FeeTaken(PoolId indexed poolId, Currency indexed currency, bool isBuy, uint256 amount);
    /// @notice A pool's fee pot was split into the three buckets.
    event FeeSettled(
        PoolId indexed poolId, Currency indexed currency, uint256 toCreator, uint256 toProtocol, uint256 toIntegrator
    );
    /// @notice A swap paid `amount` of `currency` (the quote) into the pool's TAX pot.
    event TaxTaken(PoolId indexed poolId, Currency indexed currency, bool isBuy, uint256 amount);
    /// @notice A pool's pot was split into the three buckets.
    event TaxSettled(
        PoolId indexed poolId, Currency indexed currency, uint256 toCreator, uint256 toProtocol, uint256 toIntegrator
    );
    /// @notice `account` withdrew its balance in `currency` to `to`.
    event TaxClaimed(address indexed account, Currency indexed currency, address to, uint256 amount);
    /// @notice Vault claims were converted into real tokens.
    event TaxRedeemed(Currency indexed currency, uint256 amount);
    /// @notice Surplus above `totalOwed` was credited to the protocol recipient.
    event TaxSkimmed(Currency indexed currency, address indexed caller, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Split and rate denominator.
    uint16 public constant BPS = 10_000;
    /// @dev Denominator of the trade fee, core's: hundredths of a bip, 1_000_000 == 100%.
    uint256 internal constant FEE_PIPS = 1_000_000;
    /// @notice Hard cap on either rate: 10% of the swap's quote amount. Core would let a hook take
    /// up to the whole amount; this contract refuses to let a launch owner configure that.
    uint16 public constant MAX_TAX_BPS = 1_000;
    /// @notice Hard cap on how far ahead `expiresAt` may be set: "no permanent tax".
    uint40 public constant MAX_TAX_DURATION_SECONDS = 180 days;
    /// @notice The protocol's floor on every tax, validated here and nowhere else (the kit only
    /// passes a split through; anyone can configure a pool without the kit). Owner decision 2026-09-13.
    uint16 public constant MIN_PROTOCOL_BPS = 1_000;
    /// @notice The protocol's cap, the same figure the lockers carry.
    uint16 public constant MAX_PROTOCOL_BPS = 5_000;
    /// @notice The integrator's cap, the same figure the lockers carry.
    uint16 public constant MAX_INTEGRATOR_BPS = 2_000;
    /// @notice The protocol's floor on every TRADE FEE: the figure the lockers carry for locked-LP
    /// fees, which this fee replaces (owner decision 2026-09-13, "min 20%"). The tax keeps its own.
    uint16 public constant MIN_FEE_PROTOCOL_BPS = 2_000;
    /// @notice Hard cap on the liquidity providers' share of the trade fee.
    uint16 public constant MAX_LP_SHARE_BPS = 5_000;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Vault the guard's pool manager settles against; the source of every claim here.
    IVault public immutable vault;
    /// @notice Where the protocol bucket, and every skimmed surplus, is credited. The Safe on mainnet.
    address public immutable protocolRecipient;
    /// @notice The share of the trade fee left to the pool as its LP fee, on buys. See the contract note.
    uint16 public immutable LP_SHARE_BPS;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller-supplied tax terms.
    /// @param buyBps Rate on a buy (quote in, launch token out), applied to the swap's quote amount.
    /// @param sellBps Rate on a sell.
    /// @param expiresAt First `block.timestamp` at which the tax no longer applies.
    /// @param creator Creator bucket recipient; required iff `creatorBps != 0`.
    /// @param integrator Integrator (tenant) bucket recipient; required iff `integratorBps != 0`.
    /// @param creatorBps The three buckets sum to `BPS`.
    struct TaxConfig {
        uint16 buyBps;
        uint16 sellBps;
        uint40 expiresAt;
        address creator;
        address integrator;
        uint16 creatorBps;
        uint16 protocolBps;
        uint16 integratorBps;
    }

    /// @notice Stored terms. Two slots; the swap path reads only the first.
    /// @dev slot 0: creator(160) | buyBps(16) | sellBps(16) | expiresAt(40) | creatorBps(16) = 248 bits.
    /// slot 1: integrator(160) | protocolBps(16) | integratorBps(16) = 192 bits.
    struct Tax {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        uint40 expiresAt;
        uint16 creatorBps;
        address integrator;
        uint16 protocolBps;
        uint16 integratorBps;
    }

    mapping(PoolId poolId => Tax) internal _taxes;

    /// @notice Who the trade fee is split between. Two slots; written once per pool.
    /// @dev `protocolBps` is never zero on a configured pool (the floor), so it is the "set" flag.
    /// @param creator Creator bucket recipient; required iff `creatorBps != 0`.
    /// @param integrator Integrator (tenant) bucket recipient; required iff `integratorBps != 0`.
    /// @param creatorBps The three buckets sum to `BPS`.
    struct FeeSplit {
        address creator;
        uint16 creatorBps;
        uint16 protocolBps;
        uint16 integratorBps;
        address integrator;
    }

    mapping(PoolId poolId => FeeSplit) internal _feeSplits;

    /// @dev The address a fee split's creator has nominated, if any. Read through `pendingCreator`.
    mapping(PoolId poolId => address) internal _pendingFeeCreator;

    /// @notice Cumulative trade fee taken on a pool, per currency. Written by the swap path only.
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public feeTaken;

    /// @notice Cumulative trade fee settled out of a pool's pot, per currency. Written by `settleFee` only.
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public feeSettled;

    /// @notice Cumulative tax taken on a pool, per currency. Written by the swap path only, never decremented.
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public totalTaken;

    /// @notice Cumulative tax settled out of a pool's pot, per currency. Written by `settleTax` only.
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public totalSettled;

    /// @notice What each party may withdraw, per currency. Inside `totalOwed`.
    mapping(address account => mapping(Currency currency => uint256)) public claimable;

    /// @notice Cumulative fee AND tax taken across every pool, per currency. Swap path only.
    mapping(Currency currency => uint256) public grossTaken;
    /// @notice Cumulative surplus credited to the protocol by `skim`, per currency.
    mapping(Currency currency => uint256) public grossSkimmed;
    /// @notice Cumulative amount paid out by `claim`, per currency.
    mapping(Currency currency => uint256) public grossClaimed;

    /// @dev Set only across this contract's own `vault.lock` call.
    bool private _lockCallbackArmed;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    constructor(IVault vault_, address protocolRecipient_, uint16 lpShareBps_) {
        if (address(vault_) == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        if (lpShareBps_ > MAX_LP_SHARE_BPS) revert LpShareTooHigh(lpShareBps_);
        vault = vault_;
        protocolRecipient = protocolRecipient_;
        LP_SHARE_BPS = lpShareBps_;
    }

    /// @notice Accepts native currency taken out of the vault by `redeem`.
    /// @dev Restricted to the vault so a stray send cannot be mistaken for backing: this contract
    /// pays out strictly against its own accounting, and untracked native would only ever be skimmed.
    receive() external payable {
        if (msg.sender != address(vault)) revert NativeNotAccepted();
    }

    /*//////////////////////////////////////////////////////////////
                         GUARD INTEGRATION POINTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The guard answers: the pool's launch owner (zero if unclaimed) and whether its
    /// configuration is frozen (trading opened by the clock or by a first swap).
    function _launchOwnerAndFreeze(PoolId poolId) internal view virtual returns (address owner, bool frozen);

    /// @dev Validates and stores a pool's tax. The guard has already checked the key, the owner and
    /// the freeze. All-zero `cfg` clears the tax.
    function _configureTax(PoolId poolId, TaxConfig calldata cfg) internal {
        if (cfg.buyBps == 0 && cfg.sellBps == 0) {
            if (
                cfg.expiresAt != 0 || cfg.creator != address(0) || cfg.integrator != address(0) || cfg.creatorBps != 0
                    || cfg.protocolBps != 0 || cfg.integratorBps != 0
            ) revert TaxWithoutRate();
            delete _taxes[poolId];
            emit TaxConfigured(poolId, 0, 0, 0, address(0), address(0), 0, 0, 0);
            return;
        }
        if (cfg.buyBps > MAX_TAX_BPS) revert TaxRateTooHigh(cfg.buyBps);
        if (cfg.sellBps > MAX_TAX_BPS) revert TaxRateTooHigh(cfg.sellBps);
        if (cfg.expiresAt <= block.timestamp || cfg.expiresAt > block.timestamp + MAX_TAX_DURATION_SECONDS) {
            revert TaxExpiryOutOfRange(cfg.expiresAt, block.timestamp);
        }
        uint256 sum = uint256(cfg.creatorBps) + cfg.protocolBps + cfg.integratorBps;
        if (sum != BPS) revert TaxSplitDoesNotSum(sum);
        // THE FLOOR. Enforced by the hook, never by the kit: anyone can configure a pool here directly.
        if (cfg.protocolBps < MIN_PROTOCOL_BPS || cfg.protocolBps > MAX_PROTOCOL_BPS) {
            revert TaxProtocolShareOutOfBounds(cfg.protocolBps);
        }
        if (cfg.integratorBps > MAX_INTEGRATOR_BPS) revert TaxIntegratorShareTooHigh(cfg.integratorBps);
        if ((cfg.creator == address(0)) != (cfg.creatorBps == 0)) revert TaxRecipientMismatch(cfg.creator, cfg.creatorBps);
        if ((cfg.integrator == address(0)) != (cfg.integratorBps == 0)) {
            revert TaxRecipientMismatch(cfg.integrator, cfg.integratorBps);
        }
        if (cfg.creator == address(this) || cfg.integrator == address(this)) revert InvalidTaxRecipient(address(this));

        _taxes[poolId] = Tax({
            creator: cfg.creator,
            buyBps: cfg.buyBps,
            sellBps: cfg.sellBps,
            expiresAt: cfg.expiresAt,
            creatorBps: cfg.creatorBps,
            integrator: cfg.integrator,
            protocolBps: cfg.protocolBps,
            integratorBps: cfg.integratorBps
        });
        emit TaxConfigured(
            poolId,
            cfg.buyBps,
            cfg.sellBps,
            cfg.expiresAt,
            cfg.creator,
            cfg.integrator,
            cfg.creatorBps,
            cfg.protocolBps,
            cfg.integratorBps
        );
    }

    /// @dev Validates and stores a pool's fee split, once. The guard has already checked the key,
    /// the owner and the freeze.
    function _configureFeeSplit(PoolId poolId, FeeSplit calldata cfg) internal {
        if (_feeSplits[poolId].protocolBps != 0) revert FeeSplitAlreadySet(poolId);
        uint256 sum = uint256(cfg.creatorBps) + cfg.protocolBps + cfg.integratorBps;
        if (sum != BPS) revert TaxSplitDoesNotSum(sum);
        // THE FLOOR. Enforced by the hook, never by the kit: anyone can configure a pool here directly.
        if (cfg.protocolBps < MIN_FEE_PROTOCOL_BPS || cfg.protocolBps > MAX_PROTOCOL_BPS) {
            revert TaxProtocolShareOutOfBounds(cfg.protocolBps);
        }
        if (cfg.integratorBps > MAX_INTEGRATOR_BPS) revert TaxIntegratorShareTooHigh(cfg.integratorBps);
        if ((cfg.creator == address(0)) != (cfg.creatorBps == 0)) revert TaxRecipientMismatch(cfg.creator, cfg.creatorBps);
        if ((cfg.integrator == address(0)) != (cfg.integratorBps == 0)) {
            revert TaxRecipientMismatch(cfg.integrator, cfg.integratorBps);
        }
        if (cfg.creator == address(this) || cfg.integrator == address(this)) revert InvalidTaxRecipient(address(this));

        _feeSplits[poolId] = cfg;
        emit FeeSplitConfigured(
            poolId, cfg.creator, cfg.integrator, cfg.creatorBps, cfg.protocolBps, cfg.integratorBps
        );
    }

    /// @notice Nominate the address that will receive the creator's share of a pool's trade fee.
    /// @param id The pool id, as a number (`uint256(PoolId.unwrap(poolId))`): the lockers' signature.
    /// @dev The current creator only; a split with no creator share has no creator and nothing to
    /// hand over. Nominating zero withdraws a nomination. Nothing changes until the nominee accepts.
    function transferCreator(uint256 id, address newCreator) external {
        PoolId poolId = PoolId.wrap(bytes32(id));
        address current = _feeSplits[poolId].creator;
        if (current == address(0) || msg.sender != current) revert NotFeeCreator(poolId, msg.sender);
        if (newCreator == address(this)) revert InvalidTaxRecipient(newCreator);
        _pendingFeeCreator[poolId] = newCreator;
        emit FeeCreatorTransferStarted(poolId, current, newCreator);
    }

    /// @notice Accept a nomination. Later settlements credit the new creator; balances already
    /// credited stay claimable by the previous one.
    /// @param id The pool id, as a number.
    function acceptCreator(uint256 id) external {
        PoolId poolId = PoolId.wrap(bytes32(id));
        address pending = _pendingFeeCreator[poolId];
        if (pending == address(0) || msg.sender != pending) revert NotPendingFeeCreator(poolId, msg.sender);
        address previous = _feeSplits[poolId].creator;
        _feeSplits[poolId].creator = pending;
        delete _pendingFeeCreator[poolId];
        emit FeeCreatorTransferred(poolId, previous, pending);
    }

    /// @notice The address the fee split's creator has nominated for pool `id`, or zero.
    function pendingCreator(uint256 id) external view returns (address) {
        return _pendingFeeCreator[PoolId.wrap(bytes32(id))];
    }

    /// @dev Whether `poolId` has its fee split. The guard refuses to initialize a pool without one.
    function _feeSplitSet(PoolId poolId) internal view returns (bool) {
        return _feeSplits[poolId].protocolBps != 0;
    }

    /// @dev The swap-path half. Called by the guard from `beforeSwap` when the quote currency is the
    /// specified side and from `afterSwap` when it is the unspecified side, never from both for one
    /// swap, with the swap's quote amount as `base` and the guard's fee for this second as
    /// `feePips`. Returns the hook delta: what core takes from the swapper and credits to this
    /// contract, which the single `vault.mint` below settles. Effects before that one interaction.
    /// @param base The magnitude of the swap's quote amount. Below 2^127 (it came from an `int128`).
    /// @param feePips This contract's part of the fee (`_feeParts`). At most the guard's
    /// `MAX_INITIAL_FEE`, so `fee + tax <= 60%` of `base`.
    function _takeInQuote(PoolId poolId, Currency quote, uint256 base, uint24 feePips, bool isBuy)
        internal
        returns (int128)
    {
        (uint256 fee, uint256 tax) = _quoteTake(poolId, base, feePips, isBuy);
        uint256 total = fee + tax;
        if (total == 0) return 0;

        // ---- effects: monotone counters nobody else writes ----
        if (fee != 0) {
            feeTaken[poolId][quote] += fee;
            emit FeeTaken(poolId, quote, isBuy, fee);
        }
        if (tax != 0) {
            totalTaken[poolId][quote] += tax;
            emit TaxTaken(poolId, quote, isBuy, tax);
        }
        grossTaken[quote] += total;

        // ---- interaction: an ERC-6909 claim, never a token transfer inside somebody else's swap ----
        vault.mint(address(this), quote, total);

        // total <= 0.6 * base < 2^127; the checked cast is a backstop, not a path.
        return total.toInt128();
    }

    /// @dev The two parts of a trade fee of `feePips`: what the pool charges as its LP fee and what
    /// this contract takes. A sell pays the pool nothing (its LP fee would be in the launch token).
    /// The pool's part is floored, so the rounding pip goes to this contract's three parties.
    /// feePips < 2^20 and the share <= 5e3: no overflow, and the cast cannot truncate.
    function _feeParts(uint24 feePips, bool isBuy) internal view returns (uint24 lpPips, uint24 guardPips) {
        if (!isBuy) return (0, feePips);
        // forge-lint: disable-next-line(unsafe-typecast)
        lpPips = uint24((uint256(feePips) * LP_SHARE_BPS) / BPS);
        guardPips = feePips - lpPips;
    }

    /// @dev What `_takeInQuote` takes for these inputs at this second, without taking it.
    /// base < 2^127, feePips < 2^20, rate <= 1e3: no overflow. Both floor: the rounding wei stays
    /// with the swapper.
    function _quoteTake(PoolId poolId, uint256 base, uint24 feePips, bool isBuy)
        internal
        view
        returns (uint256 fee, uint256 tax)
    {
        fee = (base * feePips) / FEE_PIPS;
        Tax storage t = _taxes[poolId];
        uint40 expiresAt = t.expiresAt;
        if (expiresAt != 0 && block.timestamp < expiresAt) {
            tax = (base * (isBuy ? t.buyBps : t.sellBps)) / BPS;
        }
    }

    /// @dev The magnitude of a signed amount, via int256 so `type(int128).min` cannot wrap.
    function _abs(int128 v) internal pure returns (uint256) {
        return v > 0 ? uint256(int256(v)) : uint256(-int256(v));
    }

    /// @dev Whether a live tax applies to `poolId` at `timestamp`.
    function _taxLiveAt(PoolId poolId, uint256 timestamp) internal view returns (bool) {
        uint40 expiresAt = _taxes[poolId].expiresAt;
        return expiresAt != 0 && timestamp < expiresAt;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Split a pool's pot in `currency` into its three buckets. Permissionless, no calls.
    /// @dev Returns quietly when there is nothing to settle so `claimFrom` can call it unconditionally.
    /// Floors the creator and integrator shares; the protocol takes the remainder, so the pot is
    /// always drained to zero and `totalOwed` is unchanged (value moves between ledgers inside it).
    function settleTax(PoolId poolId, Currency currency) public {
        uint256 pot = pendingTax(poolId, currency);
        if (pot == 0) return;
        Tax storage t = _taxes[poolId];

        totalSettled[poolId][currency] += pot;
        (uint256 toCreator, uint256 toProtocol, uint256 toIntegrator) =
            _credit(currency, pot, t.creator, t.creatorBps, t.integrator, t.integratorBps);

        emit TaxSettled(poolId, currency, toCreator, toProtocol, toIntegrator);
    }

    /// @notice Split a pool's FEE pot in `currency` into its three buckets. Permissionless, no calls.
    /// @dev The twin of `settleTax`, by the pool's fee split. A pot can only exist on a pool that was
    /// initialized, and a pool cannot be initialized without its split.
    function settleFee(PoolId poolId, Currency currency) public {
        uint256 pot = pendingFee(poolId, currency);
        if (pot == 0) return;
        FeeSplit storage f = _feeSplits[poolId];

        feeSettled[poolId][currency] += pot;
        (uint256 toCreator, uint256 toProtocol, uint256 toIntegrator) =
            _credit(currency, pot, f.creator, f.creatorBps, f.integrator, f.integratorBps);

        emit FeeSettled(poolId, currency, toCreator, toProtocol, toIntegrator);
    }

    /// @dev Floors the creator and integrator shares; the protocol takes the remainder, so a pot is
    /// always drained to zero and `totalOwed` is unchanged (value moves between ledgers inside it).
    function _credit(
        Currency currency,
        uint256 pot,
        address creator,
        uint256 creatorBps,
        address integrator,
        uint256 integratorBps
    ) private returns (uint256 toCreator, uint256 toProtocol, uint256 toIntegrator) {
        toCreator = (pot * creatorBps) / BPS;
        toIntegrator = (pot * integratorBps) / BPS;
        toProtocol = pot - toCreator - toIntegrator;

        if (toCreator != 0) claimable[creator][currency] += toCreator;
        if (toIntegrator != 0) claimable[integrator][currency] += toIntegrator;
        claimable[protocolRecipient][currency] += toProtocol;
    }

    /// @notice Withdraw everything credited to `msg.sender` in `currency` to `to`.
    /// @dev Pull, never push. Checks-effects-interactions plus `nonReentrant`: the balance is zeroed
    /// before any transfer, so a token with a receive hook cannot re-enter and claim twice.
    function claim(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        return _claim(currency, to);
    }

    /// @notice Settle `pools` in `currency`, then withdraw the caller's balance to `to`.
    /// @dev The convenience path for a creator whose launch has several legs, or a tenant with many.
    /// Reverts `NothingToClaim` if the caller ends up with nothing, exactly like `claim`.
    function claimFrom(PoolId[] calldata pools, Currency currency, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        for (uint256 i; i < pools.length; ++i) {
            settleFee(pools[i], currency);
            settleTax(pools[i], currency);
        }
        return _claim(currency, to);
    }

    function _claim(Currency currency, address to) private returns (uint256 amount) {
        // `to == address(this)` would move the caller's own credit into the guard's balance, where only
        // `skim` reaches it — a forfeit to the protocol by mistake (audit B, 2026-10-07).
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        amount = claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender][currency] = 0;
        grossClaimed[currency] += amount;
        emit TaxClaimed(msg.sender, currency, to, amount);

        _ensureLiquid(currency, amount);
        currency.transfer(to, amount);
    }

    /// @notice Convert this contract's vault claims in `currency` into real tokens. Permissionless;
    /// pays nobody. `claim` does this itself when it must; this is for keepers that prefer to
    /// pre-fund payouts.
    function redeem(Currency currency) external nonReentrant returns (uint256 amount) {
        return _redeem(currency);
    }

    /// @notice Credit whatever this contract holds ABOVE its obligations in `currency` to the protocol
    /// recipient. Permissionless, and the only possible destination is the immutable recipient.
    /// @dev Surplus is `backing - totalOwed`: every unit this contract is meant to hold is inside
    /// `totalOwed`, so anything above it reached the contract by mistake (an ERC-20, an ERC-6909
    /// claim or native forced in). Nobody is owed it. This can never pay a unit of anybody's
    /// `claimable` or any pool's pot, because those are inside `totalOwed`. The L-1 rule for a
    /// contract with no owner, modelled on `DeepCoreLPLocker.skim`.
    function skim(Currency currency) external nonReentrant returns (uint256 surplus) {
        uint256 owed = totalOwed(currency);
        uint256 held = backing(currency);
        if (held <= owed) revert NothingToSkim(currency);
        unchecked {
            surplus = held - owed;
        }
        claimable[protocolRecipient][currency] += surplus;
        grossSkimmed[currency] += surplus;
        emit TaxSkimmed(currency, msg.sender, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice A pool's stored tax terms (all zero when it has none).
    function getTax(PoolId poolId) external view returns (Tax memory) {
        return _taxes[poolId];
    }

    /// @notice A pool's fee split (all zero when it has none yet).
    function getFeeSplit(PoolId poolId) external view returns (FeeSplit memory) {
        return _feeSplits[poolId];
    }

    /// @notice A pool's unsettled trade fee in `currency`: taken and not yet split. Inside `totalOwed`.
    function pendingFee(PoolId poolId, Currency currency) public view returns (uint256) {
        return feeTaken[poolId][currency] - feeSettled[poolId][currency];
    }

    /// @notice A pool's unsettled tax in `currency`: taken and not yet split. Inside `totalOwed`.
    function pendingTax(PoolId poolId, Currency currency) public view returns (uint256) {
        return totalTaken[poolId][currency] - totalSettled[poolId][currency];
    }

    /// @notice Every unit this contract is meant to hold in `currency`: taken plus skimmed, minus paid out.
    function totalOwed(Currency currency) public view returns (uint256) {
        return grossTaken[currency] + grossSkimmed[currency] - grossClaimed[currency];
    }

    /// @notice The rates a swap at `timestamp` would pay: `(0, 0)` once expired or when never set.
    function taxRatesAt(PoolId poolId, uint256 timestamp) public view returns (uint16 buyBps, uint16 sellBps) {
        Tax storage t = _taxes[poolId];
        uint40 expiresAt = t.expiresAt;
        if (expiresAt == 0 || timestamp >= expiresAt) return (0, 0);
        return (t.buyBps, t.sellBps);
    }

    /// @notice The rates a swap now would pay.
    function currentTaxRates(PoolId poolId) external view returns (uint16 buyBps, uint16 sellBps) {
        return taxRatesAt(poolId, block.timestamp);
    }

    /// @notice What this contract can actually pay out in `currency`: real balance plus vault claims.
    /// Must always be at least `totalOwed(currency)`.
    function backing(Currency currency) public view returns (uint256) {
        return currency.balanceOfSelf() + vault.balanceOf(address(this), currency);
    }

    /*//////////////////////////////////////////////////////////////
                               VAULT PLUMBING
    //////////////////////////////////////////////////////////////*/

    function _redeem(Currency currency) internal returns (uint256 amount) {
        amount = vault.balanceOf(address(this), currency);
        if (amount == 0) return 0;

        emit TaxRedeemed(currency, amount);

        _lockCallbackArmed = true;
        vault.lock(abi.encode(currency, amount));
        _lockCallbackArmed = false;
    }

    /// @inheritdoc ILockCallback
    /// @dev Reachable only through this contract's own `_redeem`: the vault calls `lockAcquired` on
    /// whoever called `lock`, and `_lockCallbackArmed` is set only across that one call. `burn`
    /// credits this contract `+amount`, `take` debits `-amount`: nothing is left unsettled.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault) || !_lockCallbackArmed) revert UnexpectedLockCallback();

        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.burn(address(this), currency, amount);
        vault.take(currency, address(this), amount);

        return "";
    }

    /// @dev Makes sure `amount` of `currency` is held as real tokens, redeeming vault claims if not.
    /// The solvency check is a backstop that can only fail if an invariant of this contract has
    /// already been broken; it fails closed rather than paying out of another party's balance.
    function _ensureLiquid(Currency currency, uint256 amount) internal {
        uint256 held = currency.balanceOfSelf();
        if (held >= amount) return;

        uint256 claims = vault.balanceOf(address(this), currency);
        if (held + claims < amount) revert InsufficientBackedBalance(currency, amount, held + claims);

        _redeem(currency);
    }
}
