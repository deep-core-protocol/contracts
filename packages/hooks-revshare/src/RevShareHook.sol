/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";

import {IRevShareHook} from "./interfaces/IRevShareHook.sol";

/// @title RevShareHook
/// @notice "Donations and holder share of trading volume" for DeepCore Protocol CL pools, built as
/// three composable pull-based routes with no on-chain iteration over holders.
///
/// @dev ############### THE CONSTRAINT THAT DETERMINES THE WHOLE DESIGN ###############
///
/// YOU CANNOT PAY TOKEN HOLDERS FROM A SWAP CALLBACK. A holder set is unbounded and anybody can
/// grow it for the price of a dust transfer, so any loop over holders inside `afterSwap` is a
/// permanent, attacker-triggered denial of service on the pool's swap path. Nor can the hook push
/// funds to a small fixed set of recipients: a single recipient that reverts on receive - a
/// contract with no `receive()`, a blacklisting token, a proxy mid-upgrade - takes the pool
/// offline until somebody fixes it, and "somebody" may be an adversary.
///
/// Everything below follows from that. The hook does exactly two things in the swap path:
/// it adds to at most two integers, and it hands value to routes that require no iteration.
/// All payout is pulled by the receiver, in the receiver's own transaction.
///
/// ------------------------------- WHERE THE MONEY COMES FROM -------------------------------
///
/// The cut is taken in `afterSwap` as a hook delta on the UNSPECIFIED currency, which requires
/// (and this contract declares) `afterSwapReturnsDelta`. Concretely:
///
///   * exact-input swap  -> the unspecified currency is the OUTPUT. The swapper receives
///                          `out - cut` instead of `out`.
///   * exact-output swap -> the unspecified currency is the INPUT. The swapper pays
///                          `in + cut` instead of `in`.
///
/// This does NOT touch, collide with, or double-charge the protocol fee. The protocol fee is
/// skimmed off the swap INPUT by `CLPool.swap` before the LP fee is applied to the remainder
/// (`total = protocolFee + lpFee - protocolFee*lpFee/1e6`, protocol fee capped at 4000 pips).
/// This hook's cut is applied afterwards, to a different quantity, by a different actor. A trader
/// on a pool with `protocolFee = 1000`, `lpFee = 3000` and `feePips = 10_000` pays 0.3997% of
/// input to the pool/protocol and 1% of output to the revenue share. Those are two separate
/// charges and neither is computed from the other.
///
/// Deliberately NOT used: a `beforeSwap` LP-fee override. That route would fold the revenue share
/// into the LP fee, which (a) only works on a dynamic-fee pool - core SILENTLY DISCARDS a returned
/// fee when `fee != 0x800000` - and (b) pays the whole thing to liquidity providers, which is only
/// one of the three routes below.
///
/// ------------------------------- THE THREE ROUTES -------------------------------
///
/// The cut is split by basis points across three sinks, which sum to exactly 10_000:
///
///  1. `lpDonateBps` - LPs, via the protocol's native `CLPoolManager.donate`. This is the cheapest
///     and most native "share of volume": `donate` bumps `feeGrowthGlobal`, so every in-range
///     liquidity provider is paid pro rata with no iteration, no list, and no claim contract.
///     It is O(1) and it cannot fail on a recipient, because there is no recipient. When the pool
///     has zero in-range liquidity `donate` would revert, so this share is SKIPPED (the cut
///     shrinks) rather than allowed to brick the swap.
///
///  2. `beneficiaryBps` - a bounded, named roster: a treasury, a charity or donation address, a
///     creator. The swap path adds the whole share to ONE integer (`pendingBeneficiary`). A
///     separate, permissionless `settleBeneficiaries` call splits that pot across the roster by
///     weight, and each recipient later `claim`s. The weighted split loop is bounded by
///     `MAX_BENEFICIARIES` AND lives outside the swap path, so neither a long roster nor a hostile
///     recipient can affect a trade.
///
///  3. `distributorBps` - an epoch distributor, for arbitrary token holders. The swap path adds to
///     one integer; a distributor contract PULLS the accrued amount when it closes an epoch.
///     See `distributors/MerkleEpochDistributor.sol` (any ERC20, off-chain root, escrowed per
///     epoch) and `distributors/SnapshotEpochDistributor.sol` (ERC-5805 / ERC20Votes tokens,
///     fully trustless, exact per-holder accrual). Detect which one applies to your token; do not
///     assume. `distributorOf` returns a bare address, so ask the address itself: both implement
///     `IEpochDistributor.kind()`, and their `Epoch` structs are NOT interchangeable. A
///     distributor that reverts, stalls, or is never deployed can only strand its own share - it
///     can never revert a swap.
///
/// A deployment picks its mix. `10_000 / 0 / 0` is a pure LP-donation pool. `0 / 10_000 / 0` is a
/// pure treasury/charity split. `0 / 0 / 10_000` is a pure holder-dividend pool.
///
/// ------------------------------- CUSTODY -------------------------------
///
/// Retained value (routes 2 and 3) is taken as ERC-6909 vault claims via `IVault.mint`, NOT via
/// `IVault.take`. `take` performs a real ERC20 transfer out of the vault in the middle of somebody
/// else's lock; that both hands control to the token contract inside the swap path and mutates the
/// vault's ERC20 balance between a router's `sync` and its `settle`, which is exactly the
/// accounting a `settle` reads (`paid = balanceOfSelf() - reservesBefore`). `mint` is pure vault
/// bookkeeping: no external call, no balance change, no reentrancy surface, and cheaper. Claims
/// are converted to real tokens lazily by `redeem`, which takes its own lock, outside any swap.
///
/// ------------------------------- WHAT THIS DOES NOT DO -------------------------------
///
///  * It does not identify traders. `sender` in every hook callback is the VAULT LOCKER (the
///    router), not the end user, and `hookData` is attacker-controlled. Nothing here is keyed on
///    either. There are no per-wallet rules and there cannot be.
///  * It does not tax liquidity operations, donations, or transfers - only swaps against this pool.
///  * It is CL-only. There is deliberately no Bin variant: minting into a bin pool's active bin at
///    a non-bin ratio is an implicit swap, so a Bin revenue share that only hooks `swap` would
///    leave a free route around itself. Doing it correctly needs `beforeMint`/`afterMint`
///    accounting, which is a different contract, not a flag on this one.
///  * It does not make a token's holders whole. Route 3 pays whoever a distributor says to pay.
///    With `MerkleEpochDistributor` that is an off-chain computation and a trusted root poster;
///    with `SnapshotEpochDistributor` it is on-chain and trustless but only counts DELEGATED
///    voting units. Both trade-offs are documented on those contracts. Do not market route 3 as
///    trustless unless you deployed the snapshot variant.
/// ###############################################################################
contract RevShareHook is BaseCLHook, IRevShareHook, ILockCallback, Ownable2Step, ReentrancyGuard {
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Denominator for `feePips`, matching core's `PIPS_DENOMINATOR`: 1_000_000 == 100%.
    uint24 public constant PIPS_DENOMINATOR = 1_000_000;

    /// @notice Denominator for the three split weights, which must sum to exactly this.
    uint16 public constant SPLIT_DENOMINATOR = 10_000;

    /// @notice Hard cap on the revenue-share cut: 10% of the unspecified amount.
    /// @dev A trader can already be charged up to 0.4% protocol fee plus up to 100% LP fee by
    /// core. This hook refuses to be the contract that adds an unbounded third charge, and the cap
    /// is a constant so it cannot be raised by governance, by a pool owner, or by an upgrade.
    uint24 public constant MAX_FEE_PIPS = 100_000;

    /// @notice Absolute ceiling on `MAX_BENEFICIARIES`, whatever a deployment asks for.
    /// @dev The roster loop lives in `settleBeneficiaries`, which is permissionless and off the
    /// swap path, so this bounds GAS rather than protecting funds - a long roster makes settlement
    /// expensive, never impossible, and never touches a trade. The per-deployment value below is
    /// therefore a tuning knob; this is the line past which it stops being one.
    uint256 public constant MAX_BENEFICIARIES_CEILING = 32;

    /// @notice Maximum sum of beneficiary weights. Keeps `weight * amount` far from overflowing
    /// even before `Math.mulDiv` is applied.
    uint256 public constant MAX_TOTAL_WEIGHT = 1e18;

    /// @notice ERC-6372 clock mode. Every delay, expiry and stored time in this contract is
    /// `block.timestamp`. Off-chain readers call this to tell this hook from the two retired
    /// block-numbered ones, neither of which implements it.
    string public constant CLOCK_MODE = "mode=timestamp";

    /// @notice The floor on the configuration delay. Not negotiable by a deployment.
    ///
    /// @dev ############ WHY THIS IS SECONDS, AND NOW ONLY SECONDS ############
    ///
    /// The first deployed hook (`0x23CE…E446`) had `uint48 constant CONFIG_DELAY_BLOCKS = 3600`,
    /// which on Robinhood Chain's real contract clock (Arbitrum Nitro: `block.number` is
    /// Ethereum's, ~12 s) is ~12 hours. Its successor (`0xfC00…2aD2`) took a block count plus a
    /// `blockTimeCentis`, was built with the RPC's 0.1 s L2 block time, and so has a ~60-day
    /// delay and a ~1-year proposal expiry. A duration in blocks is a duration times an unknown the
    /// deployer supplies later, and on a Nitro chain the obvious measurement of that unknown is the
    /// wrong one. So the delay is now a constructor argument in SECONDS, compared with
    /// `block.timestamp`, and nothing about the chain's block cadence is declared at all.
    ///
    /// Timestamp manipulation, bounded with numbers. On Nitro the sequencer stamps blocks and may
    /// run at most 1 h ahead of real time, never backwards. At this 12 h floor a one-hour forward
    /// jump shortens a fee-rise notice by at most 1/12 (8.3%). A lagging clock only lengthens it.
    uint256 public constant MIN_CONFIG_DELAY_SECONDS = 12 hours;

    /// @notice Ceiling on the configuration delay.
    /// @dev A long delay is directionally safe - it only makes ESCALATION harder - but an absurd
    /// one ends a pool owner's ability to ever answer market conditions, and there is no admin
    /// anywhere that can shorten it. Bounded so a fat-fingered value is a revert rather than a
    /// permanent condition of every pool on the hook.
    uint256 public constant MAX_CONFIG_DELAY_SECONDS = 14 days;

    /// @notice How long a MATURED proposal stays applicable before it must be proposed again.
    ///
    /// @dev The other half of the sandwich the delay exists to prevent. A proposal that had waited
    /// out its delay used to stay armed forever while `applyPendingConfig` is permissionless, so
    /// the real sequence was: propose once, wait, then hold a 10%/enabled configuration that
    /// ANYBODY can fire, indefinitely, for the moment a large trade appears. A delay with no
    /// expiry is a scheduling inconvenience, not a protection.
    ///
    /// Clock bound: a forward sequencer jump (<= 1 h) can only SHORTEN this window, the safe
    /// direction. A clock lagging real time (<= 24 h on Nitro) can stretch it in real terms to at
    /// most ~4 days, still bounded, and a lagging clock also delays the maturity it follows.
    uint40 public constant CONFIG_PROPOSAL_TTL_SECONDS = 3 days;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool key does not name this contract as its hook
    error HookMismatch(address declared);

    /// @notice The pool key names a different pool manager than this hook serves
    error PoolManagerMismatch(address declared);

    /// @notice This hook never sets an LP fee, so a dynamic-fee pool using it would have a
    /// permanently zero LP fee and pay its liquidity providers nothing.
    error PoolMustUseStaticFee();

    /// @notice No revenue share has been registered for this pool
    error PoolNotConfigured(PoolId poolId);

    /// @notice The pool id has already been claimed by another owner
    error PoolAlreadyConfigured(PoolId poolId);

    /// @notice Caller is not the registered owner of this pool's revenue share
    error NotPoolOwner(PoolId poolId, address caller);

    /// @notice The configuration has been permanently frozen
    error ConfigFrozen(PoolId poolId);

    /// @notice `feePips` exceeds `MAX_FEE_PIPS`
    error FeeTooHigh(uint24 feePips);

    /// @notice The three split weights do not sum to `SPLIT_DENOMINATOR`
    error SplitMustSumToDenominator(uint256 sum);

    /// @notice A non-zero distributor share was configured without a distributor address
    error DistributorRequired();

    /// @notice `reduceFee` was called with a value that is not strictly lower
    error FeeNotReduced(uint24 current, uint24 proposed);

    /// @notice Roster is empty, too long, or contains an invalid entry
    error InvalidBeneficiaries();

    /// @notice A non-zero beneficiary share was configured, or frozen, with no roster to pay.
    /// @dev The beneficiary twin of `DistributorRequired`. Its absence is what let a pool accrue
    /// into `pendingBeneficiary` with `_totalWeight == 0` and then `freezeConfig` the repair away.
    error BeneficiariesRequired(PoolId poolId);

    /// @notice There is no pending configuration, or it is not due yet
    error NoPendingConfig(PoolId poolId);

    /// @notice A pending configuration exists but `effectiveAt` has not arrived
    error PendingConfigNotDue(PoolId poolId, uint40 effectiveAt);

    /// @notice A pending configuration matured but was not applied by `expiresAt`
    error PendingConfigExpired(PoolId poolId, uint40 expiresAt);

    /// @notice `configDelaySeconds` is below `MIN_CONFIG_DELAY_SECONDS`
    error ConfigDelayTooShort(uint256 delaySeconds, uint256 required);

    /// @notice `configDelaySeconds` is above `MAX_CONFIG_DELAY_SECONDS`
    error ConfigDelayTooLong(uint256 delaySeconds, uint256 allowed);

    /// @notice `maxBeneficiaries` is zero or above `MAX_BENEFICIARIES_CEILING`
    error InvalidMaxBeneficiaries(uint256 given, uint256 ceiling);

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /// @notice Caller is not the pool's configured distributor
    error NotDistributor(PoolId poolId, address caller);

    /// @notice Nothing is claimable for the caller in this currency
    error NothingToClaim();

    /// @notice Payout target is the zero address
    error InvalidRecipient();

    /// @notice `lockAcquired` was reached other than through this contract's own `redeem`
    error UnexpectedLockCallback();

    /// @notice Native currency was sent by anyone other than the vault
    error NativeNotAccepted();

    /// @notice Accounted obligations exceed what the hook can actually pay. Unreachable unless an
    /// invariant of this contract has been broken; it fails closed rather than paying out.
    error InsufficientBackedBalance(Currency currency, uint256 needed, uint256 available);

    /// @notice Caller is neither the guardian nor the owner
    error NotGuardianOrOwner();

    /// @notice `skim` found nothing above `totalOwed` in this currency
    error NothingToSkim(Currency currency);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolClaimed(PoolId indexed poolId, address indexed owner);
    event ConfigUpdated(
        PoolId indexed poolId,
        uint24 feePips,
        uint16 lpDonateBps,
        uint16 beneficiaryBps,
        uint16 distributorBps,
        address distributor,
        bool enabled
    );
    /// @param effectiveAt First `block.timestamp` at which `applyPendingConfig` succeeds.
    /// @param expiresAt Last `block.timestamp` at which it succeeds. A proposal that is not applied
    /// inside `[effectiveAt, expiresAt]` is dead and has to be proposed again.
    event ConfigProposed(PoolId indexed poolId, uint40 effectiveAt, uint40 expiresAt);
    event ConfigProposalCancelled(PoolId indexed poolId);
    event ConfigFrozenForever(PoolId indexed poolId);
    event OwnershipTransferProposed(PoolId indexed poolId, address indexed from, address indexed to);
    event PoolOwnerChanged(PoolId indexed poolId, address indexed from, address indexed to);
    event BeneficiariesUpdated(PoolId indexed poolId, uint256 count, uint256 totalWeight);

    /// @param lpDonated Amount handed to in-range LPs via `CLPoolManager.donate`
    /// @param toBeneficiaries Amount added to the pool's beneficiary pot
    /// @param toDistributor Amount added to the pool's distributor pot
    event RevShareTaken(
        PoolId indexed poolId, Currency indexed currency, uint256 lpDonated, uint256 toBeneficiaries, uint256 toDistributor
    );

    /// @notice Emitted when the LP donation share was skipped because the pool had no in-range liquidity
    event LpDonationSkipped(PoolId indexed poolId, Currency indexed currency, uint256 amount);

    event BeneficiariesSettled(PoolId indexed poolId, Currency indexed currency, uint256 distributed, uint256 dust);
    event Claimed(address indexed beneficiary, Currency indexed currency, address indexed to, uint256 amount);
    event DistributorPaid(PoolId indexed poolId, address indexed distributor, Currency indexed currency, uint256 amount);
    /// @notice A repoint moved the old distributor's uncollected pot into its escrow.
    event DistributorPotRetired(
        PoolId indexed poolId, address indexed distributor, Currency indexed currency, uint256 amount
    );
    event Redeemed(Currency indexed currency, uint256 amount);
    /// @notice The owner moved `amount` of surplus (`backing - totalOwed`) out of the hook.
    event Skimmed(Currency indexed currency, address indexed to, uint256 amount);

    event PausedSet(bool paused);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The live revenue-share configuration for one pool. Exactly one storage slot, so the
    /// swap path reads it with a single SLOAD.
    /// @param owner Pool's revenue-share owner. Zero means the pool id has never been claimed.
    /// @param feePips Cut of the unspecified swap amount, in pips. Zero disables the cut.
    /// @param lpDonateBps Share routed to in-range LPs via `donate`.
    /// @param beneficiaryBps Share routed to the weighted beneficiary roster.
    /// @param distributorBps Share routed to the epoch distributor.
    /// @param enabled Master switch for this pool. False takes no cut at all.
    /// @param frozen Once true, the configuration can never change again.
    struct PoolConfig {
        address owner; // 160
        uint24 feePips; // 24
        uint16 lpDonateBps; // 16
        uint16 beneficiaryBps; // 16
        uint16 distributorBps; // 16
        bool enabled; // 8
        bool frozen; // 8  => 248 bits, one slot
    }

    /// @notice Caller-supplied configuration. Mirrors `PoolConfig` minus the fields the hook owns.
    struct ConfigParams {
        uint24 feePips;
        uint16 lpDonateBps;
        uint16 beneficiaryBps;
        uint16 distributorBps;
        address distributor;
        bool enabled;
    }

    /// @notice A configuration waiting out `CONFIG_DELAY_SECONDS`.
    ///
    /// @dev SHAPE TRAP, and a worse one than last time. Three deployed shapes exist:
    ///   `0x23CE…E446`  (uint48 effectiveBlock, params)                  7 ABI words, blocks
    ///   `0xfC00…2aD2`  (uint48 effectiveBlock, uint48 expiryBlock, params) 8 words, blocks
    ///   this source    (uint40 effectiveAt,    uint40 expiresAt,  params) 8 words, SECONDS
    /// The last two are the SAME LENGTH and decode through each other's ABI without an error,
    /// yielding a block number read as a 1970 timestamp or vice versa. Decoding by word count no
    /// longer tells them apart. Select the ABI by the hook's ADDRESS (the SDK deployment record
    /// carries its `durationClock`) or by calling `CLOCK_MODE()`, which only this shape answers.
    ///
    /// @param effectiveAt 0 == no proposal outstanding. Otherwise the first applicable timestamp.
    /// @param expiresAt Last applicable timestamp. Always non-zero when `effectiveAt` is.
    struct PendingConfig {
        uint40 effectiveAt; // 0 == no proposal outstanding
        uint40 expiresAt;
        ConfigParams params;
    }

    /// @param recipient Who may `claim` this share. Must be non-zero.
    /// @param weight Relative weight within the pool's roster.
    struct Beneficiary {
        address recipient;
        uint96 weight;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The vault that custodies every token this hook ever holds a claim on.
    IVault public immutable vault;

    /// @notice Seconds a proposed configuration must wait before it can be applied.
    ///
    /// @dev IMMUTABLE, chosen per deployment inside [`MIN_CONFIG_DELAY_SECONDS`,
    /// `MAX_CONFIG_DELAY_SECONDS`] = [12 h, 14 days], so a tenant who wants a longer public notice
    /// than the floor can have one without forking the contract.
    ///
    /// Only PRIVILEGE ESCALATION is delayed. Raising the fee, or redirecting the split away from
    /// LPs, is a change a pool owner could otherwise land in the same block as a large trade,
    /// which is a sandwich the trader cannot price. Reductions (`reduceFee`, `disable`) and
    /// `freezeConfig` bypass the delay entirely, because delay belongs on taking more, never on
    /// taking less.
    uint40 public immutable CONFIG_DELAY_SECONDS;

    /// @notice Maximum number of weighted beneficiaries per pool.
    /// @dev Bounds `settleBeneficiaries`, the only loop in this contract. Permissionless and off
    /// the swap path, so this is a gas bound, not a fund-safety bound: a long roster makes a
    /// settlement expensive, it can never make a trade fail. Per-deployment under
    /// `MAX_BENEFICIARIES_CEILING`; SCREAMING_CASE retained because it is an existing ABI name.
    uint256 public immutable MAX_BENEFICIARIES;

    /// @notice Global kill switch. When true no pool takes any cut. Claims are unaffected.
    /// @dev Packed with `guardian` into one slot so the swap path pays for one SLOAD, not two.
    bool public paused;

    /// @notice May set `paused = true` instantly, and do nothing else.
    /// @dev Same rationale as `DeepCoreProtocolFeeController.guardian`: a delay belongs on privilege
    /// escalation, never on privilege reduction. The guardian can only ever make this contract
    /// take LESS. Un-pausing, and moving the guardian, remain owner-only.
    address public guardian;

    /// @dev Set only for the duration of this contract's own `vault.lock` call.
    bool private _lockCallbackArmed;

    /**
     * The full `PoolKey` for every pool this hook governs.
     *
     * Written once, when `configure` first claims the pool. It exists because a
     * `PoolId` is a HASH of the key and nothing can invert it: every owner and
     * maintenance call on this contract takes `PoolKey calldata`, but the hook
     * indexes by `PoolId` and no event carried the key, so a caller holding only a
     * pool id could not build a transaction at all. Front ends were reconstructing
     * it from the pool manager's `Initialize` log, or from a distributor that
     * happened to store it — neither of which exists for every pool.
     *
     * Five slots, paid once per pool at configuration time, to delete an entire
     * class of off-chain reconstruction. See `keyOf`.
     */
    mapping(PoolId poolId => PoolKey) private _keys;

    mapping(PoolId poolId => PoolConfig) private _configs;
    mapping(PoolId poolId => PendingConfig) private _pending;
    mapping(PoolId poolId => address) private _distributors;
    mapping(PoolId poolId => address) private _pendingOwners;
    mapping(PoolId poolId => Beneficiary[]) private _beneficiaries;
    mapping(PoolId poolId => uint256) private _totalWeight;

    /// @notice Route-2 pot: accrued, not yet split across the roster.
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public pendingBeneficiary;

    /// @notice Route-3 pot: accrued, waiting for the distributor to pull.
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public pendingDistributor;

    /**
     * Route-3 value that accrued under a distributor the pool has since REPOINTED away from,
     * escrowed for that distributor and only that distributor.
     *
     * Without it, `_writeConfig` overwrote `_distributors[poolId]` and `pullDistributorShare` paid
     * whoever was current, so a repoint handed the new distributor everything the old one had not
     * yet collected - including to a pool owner who proposed their own address as "distributor"
     * and waited out the delay. The fee accrued for the old distributor's holders; it stays theirs.
     *
     * Escrow rather than "refuse to repoint while the pot is non-zero", because refusal is
     * griefable by anyone: every swap refills the pot, so a single swap between the old
     * distributor's close and `applyPendingConfig` would block the repoint indefinitely.
     */
    mapping(PoolId poolId => mapping(address distributor => mapping(Currency currency => uint256))) public
        retiredDistributorPot;

    /// @dev True for every address that has ever been this pool's distributor. Lets a retired one
    /// pull its escrow (including a zero amount, which a two-currency `closeEpoch` needs) while a
    /// stranger still gets `NotDistributor`.
    mapping(PoolId poolId => mapping(address distributor => bool)) private _wasDistributor;

    /**
     * Lifetime fees taken by a pool, per currency, across all three routes.
     *
     * `pendingBeneficiary` and `pendingDistributor` are BALANCES: they fall to zero
     * when settled, so neither can answer "how much has this pool ever earned".
     * That number was previously only obtainable by summing `RevShareTaken` logs,
     * which is bounded by however far back an RPC serves them — an approximation
     * presented as a total, and one that silently shrinks as logs age out.
     *
     * One SSTORE per fee-taking swap, per currency, buys a figure a reader can
     * verify in a single `eth_call`.
     */
    mapping(PoolId poolId => mapping(Currency currency => uint256)) public totalTaken;

    /// @notice Per-recipient claimable balance, produced by `settleBeneficiaries`.
    mapping(address recipient => mapping(Currency currency => uint256)) public claimable;

    /// @notice Total obligations per currency across every pool and every route.
    /// @dev Backs the solvency assertion in `_ensureLiquid`. Every increment has a matching
    /// decrement on the way out, so this is the single number that must stay <= what the hook
    /// holds (ERC20 balance plus unredeemed vault claims).
    mapping(Currency currency => uint256) public totalOwed;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param _poolManager The CL pool manager this hook serves.
    /// @param owner_ Governance. Should be the multisig + timelock that governs
    /// `Vault.registerApp`, never an EOA on a chain holding real funds.
    /// @param guardian_ May pause instantly during an incident. May be zero.
    /// @param configDelaySeconds_ Seconds a fee RAISE must wait. Checked against
    /// [`MIN_CONFIG_DELAY_SECONDS`, `MAX_CONFIG_DELAY_SECONDS`].
    /// @param maxBeneficiaries_ Roster ceiling for `settleBeneficiaries`. 1..
    /// `MAX_BENEFICIARIES_CEILING`.
    constructor(
        ICLPoolManager _poolManager,
        address owner_,
        address guardian_,
        uint40 configDelaySeconds_,
        uint256 maxBeneficiaries_
    ) BaseCLHook(_poolManager) Ownable(owner_) {
        if (maxBeneficiaries_ == 0 || maxBeneficiaries_ > MAX_BENEFICIARIES_CEILING) {
            revert InvalidMaxBeneficiaries(maxBeneficiaries_, MAX_BENEFICIARIES_CEILING);
        }

        if (configDelaySeconds_ < MIN_CONFIG_DELAY_SECONDS) {
            revert ConfigDelayTooShort(configDelaySeconds_, MIN_CONFIG_DELAY_SECONDS);
        }
        if (configDelaySeconds_ > MAX_CONFIG_DELAY_SECONDS) {
            revert ConfigDelayTooLong(configDelaySeconds_, MAX_CONFIG_DELAY_SECONDS);
        }

        CONFIG_DELAY_SECONDS = configDelaySeconds_;
        MAX_BENEFICIARIES = maxBeneficiaries_;

        // Read the vault off the manager rather than taking it as an argument: a mismatched pair
        // would mint claims against a vault that never credits this hook a delta.
        vault = IProtocolFees(address(_poolManager)).vault();
        guardian = guardian_;
        emit GuardianUpdated(address(0), guardian_);
    }

    /**
     * Permanently disabled. Reverts for everybody, including the owner.
     *
     * `MerkleEpochDistributor` is the reference for this override and the reasoning is the same
     * shape, with a different consequence. Here the owner is the ONLY party that can restore the
     * hook after an incident:
     *
     *   * `setPaused(false)` compares against `owner()` by hand. The guardian may only ever pause.
     *   * `setGuardian` is `onlyOwner`, so a compromised or dead guardian could never be replaced.
     *
     * Renounce while paused and the hook is off forever: no pool takes a cut again, on any chain,
     * for any owner. Renounce while unpaused and the global kill switch is gone at the moment it
     * is most needed. Neither is a reduction in privilege; both are a permanent loss of the only
     * lever that can walk an incident back.
     *
     * No user funds strand either way - `claim`, `redeem`, `settleBeneficiaries` and
     * `pullDistributorShare` are permissionless and unaffected - which is precisely why this was
     * easy to under-rate on the deployed instance, where the call is still live.
     *
     * The bounded form of the same intent is untouched: `transferOwnership`, two-step via
     * `Ownable2Step`, so ownership cannot land somewhere unreachable by typo.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Accepts native currency taken out of the vault by `redeem`.
    /// @dev Restricted to the vault so a stray send cannot be mistaken for backing: this contract
    /// pays out strictly against its own accounting, and untracked native would simply be stuck.
    receive() external payable {
        if (msg.sender != address(vault)) revert NativeNotAccepted();
    }

    /// @inheritdoc IHooks
    /// @dev `beforeInitialize` rejects pools this hook cannot serve honestly and refuses unclaimed
    /// pools. `afterSwap` + `afterSwapReturnsDelta` is what lets the hook take a delta on the
    /// unspecified currency; bit 11 requires bit 7, which `BaseCLHook._validatePermissions`
    /// re-checks at deploy time. No `beforeSwap` bit: this hook never overrides the LP fee, so it
    /// has nothing to do before the swap and should not sit in front of one.
    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA;
    }

    /// @notice ERC-6372 clock: the current `block.timestamp`, the unit every time here is in.
    function clock() external view returns (uint48) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint48(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE (GLOBAL)
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner may pause or unpause; the guardian may only pause.
    function setPaused(bool paused_) external {
        if (msg.sender == owner()) {
            paused = paused_;
        } else if (msg.sender == guardian) {
            if (!paused_) revert NotGuardianOrOwner();
            paused = true;
        } else {
            revert NotGuardianOrOwner();
        }
        emit PausedSet(paused_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        address previous = guardian;
        guardian = guardian_;
        emit GuardianUpdated(previous, guardian_);
    }

    /*//////////////////////////////////////////////////////////////
                       CONFIGURATION (PER POOL)

        ACCESS-CONTROL MODEL
        --------------------
        A PoolKey is not owned by anybody - anyone may build a key naming this hook - and a
        callback's `sender` is the router, so ownership can be derived from neither. It is
        established by explicit first claim, exactly as `LaunchGuardHook` does it:

          1. `configure(key, params)` on an unclaimed pool id makes the caller its owner.
          2. `beforeInitialize` REFUSES to let the pool be created unless a claim already exists,
             so there is no such thing as an initialised-but-unconfigured pool on this hook.
          3. While the pool is still uninitialised the owner may reconfigure freely: nobody has
             traded yet, so there is nothing to sandwich.
          4. Once the pool is initialised, raising the take goes through `proposeConfig` +
             `applyPendingConfig`, separated by `CONFIG_DELAY_SECONDS`. Lowering it does not.
          5. `freezeConfig` is one-way and ends the owner's power over the fee permanently.
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim `key`'s pool id and set its revenue share, or reconfigure a pool that has not
    /// been initialised yet.
    function configure(PoolKey calldata key, ConfigParams calldata params) external {
        PoolId poolId = _validateKey(key);
        PoolConfig storage config = _configs[poolId];
        address owner_ = config.owner;

        if (owner_ == address(0)) {
            config.owner = msg.sender;
            // First sight of the full key. `_validateKey` has already confirmed it
            // hashes to `poolId` and names this hook, so what is stored here is the
            // real key and not a caller's assertion about one.
            _keys[poolId] = key;
            emit PoolClaimed(poolId, msg.sender);
        } else {
            if (msg.sender != owner_) revert NotPoolOwner(poolId, msg.sender);
            if (config.frozen) revert ConfigFrozen(poolId);
            // After initialisation, an increase must wait. `proposeConfig` is the only door.
            if (_isInitialized(poolId)) revert PoolAlreadyConfigured(poolId);
        }

        _validateParams(poolId, params);
        _writeConfig(poolId, params);
    }

    /// @notice Queue a configuration change on an initialised pool. Applies after the delay.
    /// @dev Replaces any proposal already outstanding, so a pool never carries two.
    function proposeConfig(PoolKey calldata key, ConfigParams calldata params) external {
        PoolId poolId = _requireOwner(key);
        _validateParams(poolId, params);

        // block.timestamp + at most 17 days is nowhere near uint40 (year 36812). Checked maths
        // regardless: a wrap here would produce a proposal that is instantly applicable.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 effectiveAt = uint40(block.timestamp) + CONFIG_DELAY_SECONDS;
        uint40 expiresAt = effectiveAt + CONFIG_PROPOSAL_TTL_SECONDS;
        _pending[poolId] = PendingConfig({effectiveAt: effectiveAt, expiresAt: expiresAt, params: params});

        emit ConfigProposed(poolId, effectiveAt, expiresAt);
    }

    /// @notice Apply a due proposal. Permissionless: the delay is the protection, not the caller.
    /// @dev Applicable only inside `[effectiveAt, expiresAt]`. Outside it the proposal is
    /// dead and the owner has to propose again, waiting the delay again. That window is what stops
    /// "propose once, then hold an armed 10% forever, waiting for a large trade".
    function applyPendingConfig(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        PendingConfig memory pending = _pending[poolId];
        if (pending.effectiveAt == 0) revert NoPendingConfig(poolId);
        if (block.timestamp < pending.effectiveAt) revert PendingConfigNotDue(poolId, pending.effectiveAt);
        if (block.timestamp > pending.expiresAt) revert PendingConfigExpired(poolId, pending.expiresAt);
        if (_configs[poolId].frozen) revert ConfigFrozen(poolId);

        delete _pending[poolId];
        // Re-validated on apply: the caps are constants, but the ROSTER is not - a proposal made
        // while a roster existed must not become applicable after it was emptied.
        _validateParams(poolId, pending.params);
        _writeConfig(poolId, pending.params);
    }

    /// @notice Withdraw an outstanding proposal.
    function cancelPendingConfig(PoolKey calldata key) external {
        PoolId poolId = _requireOwner(key);
        if (_pending[poolId].effectiveAt == 0) revert NoPendingConfig(poolId);
        delete _pending[poolId];
        emit ConfigProposalCancelled(poolId);
    }

    /// @dev Drops an outstanding proposal if there is one, quietly if there is not. Separate from
    /// `cancelPendingConfig` because the callers below have already done their own access control
    /// and must not revert just because no proposal happened to exist.
    function _clearPending(PoolId poolId) internal {
        if (_pending[poolId].effectiveAt != 0) {
            delete _pending[poolId];
            emit ConfigProposalCancelled(poolId);
        }
    }

    /// @notice Lower the cut immediately. Cannot raise it; that is what `proposeConfig` is for.
    ///
    /// @dev CLEARS ANY OUTSTANDING PROPOSAL, and that is not housekeeping. Without it a pool could
    /// emit `ConfigUpdated(feePips: 0)` - which every indexer reads as "the cut went away" - while
    /// a matured 10% proposal sat armed behind it, applicable by anyone, in front of a large
    /// trade. A public reduction must mean what it says, so lowering the take retracts any queued
    /// raise. An owner who wants both has to propose again and wait the delay again.
    function reduceFee(PoolKey calldata key, uint24 feePips) external {
        PoolId poolId = _requireOwner(key);
        PoolConfig storage config = _configs[poolId];
        if (feePips >= config.feePips) revert FeeNotReduced(config.feePips, feePips);
        config.feePips = feePips;
        _clearPending(poolId);
        emit ConfigUpdated(
            poolId,
            feePips,
            config.lpDonateBps,
            config.beneficiaryBps,
            config.distributorBps,
            _distributors[poolId],
            config.enabled
        );
    }

    /// @notice Stop taking a cut immediately. Accrued balances remain claimable.
    /// @dev Clears any outstanding proposal, for the reason spelled out on `reduceFee`: "off" must
    /// not be a state that anybody can undo for the price of gas.
    function disable(PoolKey calldata key) external {
        PoolId poolId = _requireOwner(key);
        PoolConfig storage config = _configs[poolId];
        config.enabled = false;
        _clearPending(poolId);
        emit ConfigUpdated(
            poolId,
            config.feePips,
            config.lpDonateBps,
            config.beneficiaryBps,
            config.distributorBps,
            _distributors[poolId],
            false
        );
    }

    /// @notice Permanently freeze this pool's configuration. One-way, and the strongest promise a
    /// pool owner can make to traders: after this the fee and the split can never move again.
    /// @dev Any outstanding proposal is discarded, so a freeze cannot be used to sneak one in.
    ///
    /// REFUSES TO FREEZE A POOL THAT CANNOT PAY ITS BENEFICIARY SHARE. `freezeConfig` is the one
    /// irreversible call a pool owner has, and it removes `setBeneficiaries` along with everything
    /// else. Freezing with `beneficiaryBps != 0` and an empty roster therefore sealed the pool
    /// into accruing a pot nothing could ever distribute - permanently, silently, and with every
    /// view reporting the pool healthy. The other two guards (`_validateParams` and
    /// `setBeneficiaries`) already make that state unreachable; this one is the backstop on the
    /// call that would make it permanent, and it costs one SLOAD on a function used once.
    function freezeConfig(PoolKey calldata key) external {
        PoolId poolId = _requireOwner(key);
        if (_configs[poolId].beneficiaryBps != 0 && _totalWeight[poolId] == 0) {
            revert BeneficiariesRequired(poolId);
        }
        delete _pending[poolId];
        _configs[poolId].frozen = true;
        emit ConfigFrozenForever(poolId);
    }

    /// @notice Step 1 of a two-step owner handover. Pass `address(0)` to cancel.
    function transferPoolOwnership(PoolKey calldata key, address newOwner) external {
        PoolId poolId = _requireOwner(key);
        _pendingOwners[poolId] = newOwner;
        emit OwnershipTransferProposed(poolId, msg.sender, newOwner);
    }

    /// @notice Step 2 of a two-step owner handover, called by the incoming owner.
    /// @dev Two-step so a treasury migration cannot end with the pool's configuration stranded at
    /// an address nobody controls.
    function acceptPoolOwnership(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        if (_pendingOwners[poolId] != msg.sender || msg.sender == address(0)) {
            revert NotPoolOwner(poolId, msg.sender);
        }
        address previous = _configs[poolId].owner;
        delete _pendingOwners[poolId];
        _configs[poolId].owner = msg.sender;
        emit PoolOwnerChanged(poolId, previous, msg.sender);
    }

    /// @notice Replace the weighted beneficiary roster.
    /// @dev Settles the OLD roster's outstanding pot for both of the pool's currencies first, so a
    /// roster change can never retroactively redirect value that accrued under the previous one.
    /// Not subject to `CONFIG_DELAY_SECONDS`: the delay protects traders from a larger take, and
    /// this changes only who receives an already-fixed take. It IS subject to `freezeConfig`,
    /// which is documented as freezing the whole arrangement, roster included.
    function setBeneficiaries(PoolKey calldata key, Beneficiary[] calldata roster) external {
        PoolId poolId = _requireOwner(key);

        settleBeneficiaries(key, key.currency0);
        settleBeneficiaries(key, key.currency1);

        uint256 count = roster.length;
        if (count > MAX_BENEFICIARIES) revert InvalidBeneficiaries();
        // An EMPTY roster is only honest when the pool routes nothing to one. The error's own
        // docstring always said "Roster is empty, too long, or contains an invalid entry"; the
        // "empty" half was never implemented, which is how a pool ended up taking a beneficiary
        // share with nobody to pay it to.
        if (count == 0 && _configs[poolId].beneficiaryBps != 0) revert BeneficiariesRequired(poolId);

        delete _beneficiaries[poolId];
        uint256 total = 0;
        for (uint256 i = 0; i < count; ++i) {
            Beneficiary calldata entry = roster[i];
            if (entry.recipient == address(0) || entry.weight == 0) revert InvalidBeneficiaries();
            total += entry.weight;
            _beneficiaries[poolId].push(Beneficiary({recipient: entry.recipient, weight: entry.weight}));
        }
        if (total > MAX_TOTAL_WEIGHT) revert InvalidBeneficiaries();

        _totalWeight[poolId] = total;
        emit BeneficiariesUpdated(poolId, count, total);
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIGURATION INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _validateKey(PoolKey calldata key) internal view returns (PoolId poolId) {
        if (address(key.hooks) != address(this)) revert HookMismatch(address(key.hooks));
        if (address(key.poolManager) != address(poolManager)) {
            revert PoolManagerMismatch(address(key.poolManager));
        }
        // Checked here as well as in `beforeInitialize` so nobody burns gas configuring a pool
        // that can never be created.
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee();
        return key.toId();
    }

    function _requireOwner(PoolKey calldata key) internal view returns (PoolId poolId) {
        poolId = _validateKey(key);
        PoolConfig storage config = _configs[poolId];
        address owner_ = config.owner;
        if (owner_ == address(0)) revert PoolNotConfigured(poolId);
        if (msg.sender != owner_) revert NotPoolOwner(poolId, msg.sender);
        if (config.frozen) revert ConfigFrozen(poolId);
    }

    /// @dev No longer `pure`: the beneficiary check reads the pool's roster.
    ///
    /// ORDERING CONSEQUENCE, stated because it is the one thing a pool owner has to learn. A
    /// roster can only be set by the pool's owner, and ownership is established by the first
    /// `configure` call, so a pool wanting a beneficiary share is configured in two steps while it
    /// is still uninitialised and untraded:
    ///
    ///   1. `configure(key, {lpDonateBps: 10_000, ...})`  - claims the pool, no roster needed
    ///   2. `setBeneficiaries(key, roster)`
    ///   3. `configure(key, {beneficiaryBps: ..., ...})`  - now the roster exists
    ///
    /// The alternative was to let step 3 happen first and catch it later, which is exactly what
    /// the deployed hook does and exactly how a pool ends up accruing to nobody.
    function _validateParams(PoolId poolId, ConfigParams memory params) internal view {
        if (params.feePips > MAX_FEE_PIPS) revert FeeTooHigh(params.feePips);

        uint256 sum = uint256(params.lpDonateBps) + params.beneficiaryBps + params.distributorBps;
        // Exact, not "at most": a split that sums to less would silently shrink the cut, which is
        // the kind of quiet misconfiguration that only shows up in a revenue report months later.
        if (sum != SPLIT_DENOMINATOR) revert SplitMustSumToDenominator(sum);

        if (params.distributorBps != 0 && params.distributor == address(0)) revert DistributorRequired();
        // The twin of the line above, and its absence was a fund-stranding bug rather than a
        // symmetry complaint: route 3 fails loudly with no distributor, route 2 used to accrue
        // into a pot with nobody on the other end.
        if (params.beneficiaryBps != 0 && _totalWeight[poolId] == 0) revert BeneficiariesRequired(poolId);
    }

    function _writeConfig(PoolId poolId, ConfigParams memory params) internal {
        address previous = _distributors[poolId];
        if (previous != params.distributor && previous != address(0)) _retireDistributorPot(poolId, previous);
        PoolConfig storage config = _configs[poolId];
        config.feePips = params.feePips;
        config.lpDonateBps = params.lpDonateBps;
        config.beneficiaryBps = params.beneficiaryBps;
        config.distributorBps = params.distributorBps;
        config.enabled = params.enabled;
        _distributors[poolId] = params.distributor;

        emit ConfigUpdated(
            poolId,
            params.feePips,
            params.lpDonateBps,
            params.beneficiaryBps,
            params.distributorBps,
            params.distributor,
            params.enabled
        );
    }

    function _isInitialized(PoolId poolId) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        return sqrtPriceX96 != 0;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * The full `PoolKey` for a pool, or a zeroed key if this hook has never
     * governed it.
     *
     * A `PoolId` is `keccak256(abi.encode(key))`, so it cannot be inverted. Every
     * write on this contract — `settleBeneficiaries`, `proposeConfig`,
     * `applyPendingConfig`, `setBeneficiaries`, `transferPoolOwnership` — takes the
     * key, which meant anything holding only an id had to find the key elsewhere or
     * give up. This is that elsewhere.
     *
     * Check `key.hooks == address(this)` to distinguish a real record from the zero
     * value; a pool that was never configured returns the latter.
     */
    function keyOf(PoolId poolId) external view returns (PoolKey memory) {
        return _keys[poolId];
    }

    /**
     * True when this hook holds the key for `poolId` — i.e. the pool has been
     * configured here at least once.
     *
     * Saves a caller comparing struct fields to spot the zero value.
     */
    function hasKey(PoolId poolId) external view returns (bool) {
        return address(_keys[poolId].hooks) == address(this);
    }

    function getConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _configs[poolId];
    }

    function getPendingConfig(PoolId poolId) external view returns (PendingConfig memory) {
        return _pending[poolId];
    }

    function poolOwner(PoolId poolId) external view returns (address) {
        return _configs[poolId].owner;
    }

    function pendingPoolOwner(PoolId poolId) external view returns (address) {
        return _pendingOwners[poolId];
    }

    function getBeneficiaries(PoolId poolId) external view returns (Beneficiary[] memory) {
        return _beneficiaries[poolId];
    }

    function totalWeight(PoolId poolId) external view returns (uint256) {
        return _totalWeight[poolId];
    }

    /// @inheritdoc IRevShareHook
    function distributorOf(PoolId poolId) external view returns (address) {
        return _distributors[poolId];
    }

    /// @inheritdoc IRevShareHook
    function pendingDistributorShare(PoolId poolId, Currency currency) external view returns (uint256) {
        return pendingDistributor[poolId][currency];
    }

    /// @notice What the hook can actually pay out in `currency` right now: tokens it already holds
    /// plus vault claims it can redeem. Must always be at least `totalOwed[currency]`.
    function backing(Currency currency) public view returns (uint256) {
        return currency.balanceOfSelf() + vault.balanceOf(address(this), currency);
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev `sender` is the caller of `initialize`, which may be any periphery contract. Ignored.
    function _beforeInitialize(address, /* sender */ PoolKey calldata key, uint160 /* sqrtPriceX96 */ )
        internal
        view
        override
        returns (bytes4)
    {
        // A dynamic-fee pool's stored LP fee starts at 0 and only the hook can change it. This
        // hook never calls `updateDynamicLPFee`, so such a pool would pay its liquidity providers
        // nothing forever while still charging the revenue share - a trap, not a feature.
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee();

        PoolId poolId = key.toId();
        if (_configs[poolId].owner == address(0)) revert PoolNotConfigured(poolId);

        return ICLHooks.beforeInitialize.selector;
    }

    /// @notice Takes the revenue-share cut and routes it.
    ///
    /// @dev `sender` is the VAULT LOCKER (the router), not the trader, and `hookData` is
    /// attacker-controlled. Neither is read. Everything here is a function of the pool and the
    /// swap's own arithmetic.
    ///
    /// The returned `int128` is the hook's delta on the UNSPECIFIED currency. Positive means the
    /// hook is owed, which core turns into `delta = delta - hookDelta` for the swapper and a
    /// matching positive delta for this contract in the vault. That delta must be zero by the end
    /// of the lock, and it is: `donate` books a negative delta of exactly `lpDonated`, `mint`
    /// books a negative delta of exactly `toBeneficiaries + toDistributor`, and the returned value
    /// is their sum. Nothing is left over, in either direction.
    ///
    /// REVERT SURFACE. This runs inside somebody else's swap, so a revert here is a tradeable-pool
    /// outage. The only external call is `poolManager.donate`, whose one realistic failure mode -
    /// zero in-range liquidity - is checked first and downgraded to "skip the LP share". There is
    /// no loop, no call to a recipient, and no unbounded work.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolConfig memory config = _configs[poolId];

        if (paused || !config.enabled || config.feePips == 0) return (ICLHooks.afterSwap.selector, int128(0));

        // Mirrors `CLHooks.afterSwap`: it composes the hook delta as
        //   (amountSpecified < 0 == zeroForOne) ? (specified, unspecified) : (unspecified, specified)
        // so the specified side is currency0 exactly when those two booleans agree.
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency currency = specifiedIsCurrency0 ? key.currency1 : key.currency0;
        int128 unspecified = specifiedIsCurrency0 ? delta.amount1() : delta.amount0();
        if (unspecified == 0) return (ICLHooks.afterSwap.selector, int128(0));

        // Magnitude via int256 so `type(int128).min` cannot wrap on negation.
        uint256 magnitude = unspecified > 0 ? uint256(int256(unspecified)) : uint256(-int256(unspecified));

        // Each share is computed in ONE division from the full-precision numerator rather than
        // dividing out `cut` first and splitting that. Two-stage division would lose up to a wei
        // per bucket per swap for no reason. `magnitude < 2^127`, `feePips <= 1e5`, `bps <= 1e4`,
        // so the numerator is below 2^127 * 1e9 ~= 2^157 and cannot overflow.
        uint256 denominator = uint256(PIPS_DENOMINATOR) * SPLIT_DENOMINATOR;
        uint256 gross = magnitude * config.feePips;
        uint256 lpAmount = (gross * config.lpDonateBps) / denominator;
        uint256 beneficiaryAmount = (gross * config.beneficiaryBps) / denominator;
        uint256 distributorAmount = (gross * config.distributorBps) / denominator;

        // `donate` reverts with NoLiquidityToReceiveFees when the pool is out of range. Skipping
        // costs the LP share; reverting costs the pool its swap path.
        if (lpAmount != 0 && poolManager.getLiquidity(poolId) == 0) {
            emit LpDonationSkipped(poolId, currency, lpAmount);
            lpAmount = 0;
        }

        // Deliberately the SUM of the floors: the up-to-3-wei rounding remainder is left with the
        // swapper rather than retained unaccounted-for by this contract. `total` is therefore
        // exactly what the three sinks receive, which is what makes the delta net to zero below.
        uint256 total = lpAmount + beneficiaryAmount + distributorAmount;
        if (total == 0) return (ICLHooks.afterSwap.selector, int128(0));

        // ---- effects, before any external call ----
        uint256 retained = beneficiaryAmount + distributorAmount;
        if (beneficiaryAmount != 0) pendingBeneficiary[poolId][currency] += beneficiaryAmount;
        if (distributorAmount != 0) pendingDistributor[poolId][currency] += distributorAmount;
        if (retained != 0) totalOwed[currency] += retained;

        // ---- interactions ----
        if (lpAmount != 0) {
            (uint256 amount0, uint256 amount1) =
                specifiedIsCurrency0 ? (uint256(0), lpAmount) : (lpAmount, uint256(0));
            // Re-enters the manager for THIS pool. Safe and intentional: `CLPool.swap` has already
            // written slot0, liquidity and feeGrowthGlobal back to storage by the time `afterSwap`
            // runs, and this hook registers neither donate callback, so `donate` cannot re-enter
            // this contract. The transient reserve dip it creates for the manager is exactly what
            // DeepCore's `AppDeficit` accounting in `Vault._accountDeltaForApp` exists to absorb; it
            // is repaid within this same call by the delta returned below.
            poolManager.donate(key, amount0, amount1, "");
        }
        if (retained != 0) {
            // ERC-6909 claim, not `take`: no ERC20 transfer inside the swap path, and no change to
            // the vault's ERC20 balance between a router's `sync` and its `settle`.
            vault.mint(address(this), currency, retained);
        }

        // Cumulative, so a reader never has to sum logs to get a lifetime figure.
        // Sums the three routes rather than the retained amount: an LP donation is
        // revenue the pool took, it simply went straight back out to liquidity.
        unchecked {
            // Bounded by the pool's own throughput; each term is a fraction of a
            // swap already accounted in uint256 above.
            totalTaken[poolId][currency] += lpAmount + beneficiaryAmount + distributorAmount;
        }

        emit RevShareTaken(poolId, currency, lpAmount, beneficiaryAmount, distributorAmount);

        // The three shares sum to at most `magnitude * feePips / 1e6 <= magnitude / 10 < 2^127`,
        // so this is comfortably in range. The cast is checked regardless and reverts rather than
        // wrapping, because a wrapped hook delta would be a negative delta the vault could not
        // reconcile.
        return (ICLHooks.afterSwap.selector, total.toInt128());
    }

    /*//////////////////////////////////////////////////////////////
                        ROUTE 2 - WEIGHTED BENEFICIARIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Split a pool's accrued beneficiary pot across its roster by weight.
    /// @dev Permissionless, and off the swap path. The loop is bounded by `MAX_BENEFICIARIES`.
    /// Returns quietly (rather than reverting) when there is nothing to do, so `setBeneficiaries`
    /// can call it unconditionally.
    ///
    /// Rounding: each share floors, and the remainder is left in `pendingBeneficiary` to be
    /// included in the next settlement. No value is created or destroyed, and nothing accumulates
    /// as unreachable dust.
    function settleBeneficiaries(PoolKey calldata key, Currency currency) public {
        PoolId poolId = key.toId();
        uint256 amount = pendingBeneficiary[poolId][currency];
        if (amount == 0) return;

        uint256 total = _totalWeight[poolId];
        // Unreachable while the pool still routes to route 2: `_validateParams` and
        // `setBeneficiaries` between them make "beneficiaryBps != 0 with no roster" impossible to
        // write. It survives for the one residual case - a pool that took its share to zero and
        // then emptied its roster, leaving a settled-down remainder - where returning leaves the
        // value in place for a roster set later, and reverting would only strand it harder. It
        // also lets `setBeneficiaries` call this unconditionally.
        if (total == 0) return;

        Beneficiary[] storage roster = _beneficiaries[poolId];
        uint256 count = roster.length;

        uint256 distributed = 0;
        for (uint256 i = 0; i < count; ++i) {
            Beneficiary memory entry = roster[i];
            // Full-precision, so a large pot times a large weight cannot overflow before dividing.
            uint256 share = Math.mulDiv(amount, entry.weight, total);
            if (share != 0) {
                claimable[entry.recipient][currency] += share;
                distributed += share;
            }
        }

        uint256 dust = amount - distributed;
        pendingBeneficiary[poolId][currency] = dust;
        emit BeneficiariesSettled(poolId, currency, distributed, dust);
    }

    /// @notice Withdraw everything settled to `msg.sender` in `currency`.
    /// @dev Pull, never push. A recipient that cannot receive the token strands only its own
    /// balance. Checks-effects-interactions plus `nonReentrant`: the balance is zeroed before any
    /// transfer, so a token with a receive hook cannot re-enter and claim twice.
    function claim(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        // `to == address(this)` would move the caller's money into the hook's own balance, where only
        // `skim` reaches it — i.e. the caller forfeits it to the protocol by mistake (audit B, 2026-10-07).
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        amount = claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender][currency] = 0;
        totalOwed[currency] -= amount;
        emit Claimed(msg.sender, currency, to, amount);

        _ensureLiquid(currency, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        ROUTE 3 - EPOCH DISTRIBUTOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRevShareHook
    /// @dev Pull, never push, for the same reason as `claim`: a distributor that reverts on
    /// receipt must not be able to touch the swap path.
    ///
    /// A distributor the pool has repointed away from may still pull its escrow
    /// (`retiredDistributorPot`); the current distributor pulls the live pot plus any escrow of its
    /// own (a pool repointed A -> B -> A). Nobody else is ever paid.
    function pullDistributorShare(PoolKey calldata key, Currency currency)
        external
        nonReentrant
        returns (uint256 amount)
    {
        PoolId poolId = key.toId();
        address distributor = msg.sender;
        bool current = distributor == _distributors[poolId];
        if (!current && !_wasDistributor[poolId][distributor]) revert NotDistributor(poolId, distributor);

        uint256 retired = retiredDistributorPot[poolId][distributor][currency];
        uint256 live = current ? pendingDistributor[poolId][currency] : 0;
        amount = retired + live;
        if (amount == 0) return 0;

        if (retired != 0) retiredDistributorPot[poolId][distributor][currency] = 0;
        if (live != 0) pendingDistributor[poolId][currency] = 0;
        totalOwed[currency] -= amount;
        emit DistributorPaid(poolId, distributor, currency, amount);

        _ensureLiquid(currency, amount);
        currency.transfer(distributor, amount);
    }

    /// @dev Moves `previous`'s uncollected pot, in both of the pool's currencies, into its escrow.
    /// `totalOwed` is unchanged: the obligation moves between two ledgers, it is not created or paid.
    /// The key is always stored by the time a distributor can change: `configure` writes `_keys`
    /// before its first `_writeConfig`, and every later write is on a configured pool.
    function _retireDistributorPot(PoolId poolId, address previous) internal {
        _wasDistributor[poolId][previous] = true;
        PoolKey storage key = _keys[poolId];
        _retireOne(poolId, previous, key.currency0);
        _retireOne(poolId, previous, key.currency1);
    }

    function _retireOne(PoolId poolId, address previous, Currency currency) private {
        uint256 amount = pendingDistributor[poolId][currency];
        if (amount == 0) return;
        pendingDistributor[poolId][currency] = 0;
        retiredDistributorPot[poolId][previous][currency] += amount;
        emit DistributorPotRetired(poolId, previous, currency, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIMS -> REAL TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert this contract's ERC-6909 vault claims on `currency` into real tokens.
    /// @dev Permissionless and idempotent. Takes its own vault lock, so it necessarily runs
    /// outside anybody's swap; an attempt to call it from inside a lock reverts on
    /// `LockerAlreadySet`, which is the desired behaviour rather than a limitation.
    ///
    /// Guarded, and separate from the internal `_redeem` that `claim` and `pullDistributorShare`
    /// reach through `_ensureLiquid`: those are already `nonReentrant`, and a guard here as well
    /// would deadlock them.
    function redeem(Currency currency) external nonReentrant returns (uint256 amount) {
        return _redeem(currency);
    }

    /// @notice Move whatever the hook holds ABOVE its obligations in `currency` to `to`. Owner only.
    ///
    /// @dev Surplus is `backing(currency) - totalOwed[currency]`: every unit the hook is meant to hold
    /// is in `totalOwed` (the single obligation counter, incremented once in `afterSwap` and decremented
    /// on the two payout paths), so anything above it is value that reached the hook by mistake - an
    /// ERC-20 or ERC-6909 claim transferred here directly, or native forced in. Nobody is owed it, which
    /// is why the owner (the Safe) may direct it anywhere non-zero; and by the same token this can never
    /// pay a single unit of a beneficiary's `claimable`, a distributor's pot or a retired pot, because all
    /// of those are inside `totalOwed`. Acceptance finding L-1 (docs/protocol-acceptance.md), 2026-09-18.
    ///
    /// Vault claims counted in the surplus are redeemed first (`_ensureLiquid`), so the transfer is
    /// always of real tokens. Reentrancy-guarded like every other payout.
    function skim(Currency currency, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert InvalidRecipient();
        uint256 owed = totalOwed[currency];
        uint256 held = backing(currency);
        // `backing >= totalOwed` is the solvency invariant `_ensureLiquid` enforces; if it ever broke,
        // there is no surplus and this reports it rather than paying out of owed money.
        amount = held > owed ? held - owed : 0;
        if (amount == 0) revert NothingToSkim(currency);

        _ensureLiquid(currency, amount);
        currency.transfer(to, amount);

        emit Skimmed(currency, to, amount);
    }

    function _redeem(Currency currency) internal returns (uint256 amount) {
        amount = vault.balanceOf(address(this), currency);
        if (amount == 0) return 0;

        emit Redeemed(currency, amount);

        _lockCallbackArmed = true;
        vault.lock(abi.encode(currency, amount));
        _lockCallbackArmed = false;
    }

    /// @inheritdoc ILockCallback
    /// @dev Reachable only through this contract's own `redeem`: the vault calls `lockAcquired` on
    /// whoever called `lock`, and `_lockCallbackArmed` is set only across that one call.
    ///
    /// The two operations net to zero for this contract's vault delta: `burn` credits it
    /// `+amount`, `take` debits it `-amount`. Nothing is left unsettled when the lock exits.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault) || !_lockCallbackArmed) revert UnexpectedLockCallback();

        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.burn(address(this), currency, amount);
        vault.take(currency, address(this), amount);

        return "";
    }

    /// @dev Makes sure `amount` of `currency` is held as real tokens, redeeming vault claims if
    /// not. The solvency check is a backstop: it can only fail if an accounting invariant of this
    /// contract has already been broken, and it fails closed rather than paying out of another
    /// pool's balance.
    function _ensureLiquid(Currency currency, uint256 amount) internal {
        uint256 held = currency.balanceOfSelf();
        if (held >= amount) return;

        uint256 claims = vault.balanceOf(address(this), currency);
        if (held + claims < amount) revert InsufficientBackedBalance(currency, amount, held + claims);

        _redeem(currency);
    }
}
