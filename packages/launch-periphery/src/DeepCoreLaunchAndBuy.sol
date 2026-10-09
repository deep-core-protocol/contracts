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

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {
    ILaunchpadKitV2,
    LegKind,
    LegParams,
    ScheduleParams,
    LaunchParamsV2,
    LaunchResultV2
} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";
import {LaunchPresets, Preset, PresetParams} from "deepcore-launchpad/src/libraries/LaunchPresets.sol";

import {ILaunchGuardFee} from "./interfaces/ILaunchGuardFee.sol";
import {ILaunchpadKitV2Extras} from "./interfaces/ILaunchpadKitV2Extras.sol";

/// @title DeepCoreLaunchAndBuy - the creator's first buy, in the launch transaction
///
/// @notice Every competing launchpad lets a creator buy in the same transaction that creates the
/// launch. On DeepCore the absence is worse than a missing feature, because `LaunchGuardHook` cannot
/// implement a per-wallet cap and says so in its own header: the `sender` a hook callback receives is
/// the Vault locker, never the buyer. So DeepCore has no identity-based sniper defence at all, and a
/// creator who seeds 100% of the supply today has to queue at `startTime` alongside the bots.
/// four.meme documents the developer pre-buy as exactly that mitigation. This contract is it.
///
/// ####################### IT CHANGES NOTHING IN THE KIT, THE GUARDS OR THE LOCKERS #######################
///
/// It is a plain caller of `LaunchpadKitV2.createLaunch`, and the reason the shape works is a
/// property of the guards that was already there and is asserted by this package's tests rather than
/// assumed:
///   * `LaunchGuardHook._validateConfig` rejects `startTime < block.timestamp` - so `startTime ==
///     block.timestamp` is a legal configuration (`test_PREMISE_startTimeMayBeNow`).
///   * `LaunchGuardHook._beforeSwap` reverts only on `block.timestamp < startTime` - so a swap AT
///     `startTime` is permitted (`test_PREMISE_swapAtStartTimeIsPermitted`).
///   * `configureTax`'s freeze is `block.timestamp > startTime` (strictly greater, unlike
///     `configureLaunch`'s `>=`), precisely so a launch opening in its own second can still carry a
///     creator tax. The kit already relies on this.
/// Both guards are identical here, so a CL leg and a Bin leg behave the same way.
///
/// Pons ships the same thing as a separate contract (`PonsV2LaunchAndBuy`) rather than inside its
/// factory. That is the right precedent: a contract that handles a creator's entire token supply and
/// their money in one transaction should be separately deployable, separately auditable and
/// separately retirable from the kit that mints launches for everybody.
///
/// ############################## THE TWO THINGS THAT ARE NOT FREE ##############################
///
/// 1. THE TOKEN ADDRESS MOVES, AND IT HAD TO. `LaunchTokenFactory` salts with
///    `keccak256(abi.encode(msg.sender, userSalt))` and its own header states the consequence: "a
///    CONTRACT that calls this factory on behalf of many users ... shares one namespace across all of
///    them, and must fold its own caller into the salt it passes, or its users can squat each other."
///    Routing through this contract makes IT the kit's `msg.sender`, so this contract folds the real
///    caller in itself: the salt handed to the kit is `keccak256(abi.encode(msg.sender, userSalt))`,
///    restoring exactly the per-creator namespace the factory intended. Two creators with the same
///    `userSalt` still land on different addresses.
///
///    What cannot be restored is the address a creator would have got launching DIRECTLY: CREATE2
///    binds the deployer namespace, and the direct path's namespace is the creator's while this
///    path's is this contract's. They are different addresses and no contract can make them equal.
///    So: `predictLaunchToken(creator, userSalt)` on THIS contract is the address a launch through
///    this contract produces, and a vanity salt mined for one path is worthless on the other. To make
///    a wrong prediction impossible rather than merely documented, `BuyParams.expectedToken` is
///    checked against the prediction BEFORE anything is created; a UI that shows an address must pass
///    it back.
///
/// 2. THE FIRST BUY PAYS THE OPENING FEE. The buy lands at `elapsed == 0`, which is the most
///    expensive instant of the decay by construction - that is what the decay is for, and exempting
///    the creator would make the guard a lie. Concretely, from `LaunchPresets`:
///      FairLaunch 100_000 pips (10%), AntiSniperAggressive 500_000 (50%), Stealth 500_000 (50%),
///      NoTax 3_000 (0.30%, and it is `finalFeeBips` because that preset is disabled).
///    The guard takes the fee itself, in the QUOTE, out of `amountIn` and before the pool trades
///    (the pool's own LP fee is zero). It is not burned: it goes to the launch's fee pot on the
///    guard and is split by the launch's own fee split, claimable at once (`settleFee`, `claim`).
///    A creator on FairLaunch with a 70/10/20 split pays 10% and recovers 70% of it, a net ~3% of
///    the buy.
///    That is a real cost and nobody may be surprised by it, so it is BOTH previewed and bounded:
///    `previewOpeningFee` is a pure function a UI calls before it asks for a signature, and
///    `BuyParams.maxLpFeePips` is a bound this contract checks against the guard's own
///    `currentFee(poolId)` AFTER the launch and BEFORE the swap. A caller who passes 0 cannot be
///    charged anything at all - the launch simply reverts. (The names say "LP fee" because they
///    are this contract's ABI; the number is the guard's fee, whoever it is paid to.)
///    A creator tax (`LaunchParamsV2.tax`), if the caller configured one, is taken on top, in the
///    quote and on the same `amountIn`. Its rates are the caller's own input, so `minAmountOut` is
///    the honest bound for it and no separate one is added.
///
/// 3. THE BUY FILLS WHOLE OR NOT AT ALL ON A CL LEG. The guard charges an exact-input buy on the
///    amount named, so it refuses one the pool could only fill in part (`SwapNotFilled`): an
///    `amountIn` larger than the single-sided range can absorb reverts the launch with it. Size
///    the buy from the launch's own numbers. A Bin leg reverts in core for the same reason.
///
/// ############################## ATOMICITY, WHICH IS THE POINT ##############################
///
/// There is no `try`/`catch` anywhere in this contract. A failed buy reverts the launch with it, so
/// the half-made state the brief asks about - a launch that exists, is `launched`, is frozen, and has
/// no creator position - is not reachable. The opposite shape (buy optional, launch survives) was
/// considered and rejected: it manufactures exactly that state, and it lets a creator's slippage bound
/// be griefed into a silent no-buy.
///
/// ############################## WHAT IT CUSTODIES: NOTHING ##############################
///
/// No `receive`, no `fallback`, no ERC-721/ERC-1155/ERC-6909 receiver: nothing that needs one can
/// arrive. Native arrives only as `msg.value` on `launchAndBuy`; the kit is paid the EXACT fee in
/// force (read in the same call) so the kit's own refund path is never taken and cannot revert on a
/// contract with no `receive`; the swap's output is taken by the Vault straight to the recipient, so
/// this contract never holds it; every unspent unit goes back to `msg.sender` in the same call. The
/// only way value can rest here is `selfdestruct`, a block reward, or a misdirected ERC-20, and both
/// leave through a PERMISSIONLESS sweep that can pay only the immutable `SWEEP_RECIPIENT`.
///
/// ############################## WHAT A PRIVILEGED KEY CAN DO: NOTHING ##############################
///
/// There is no owner, no admin, no pause, no setter, no upgrade path and no `delegatecall`. Every
/// address it uses is immutable and, except the sweep recipient, READ OFF THE KIT at construction
/// rather than supplied. A compromised governance key reaches nothing here. This is deliberate and
/// must stay that way: the contract has no fee of its own to govern, so an owner would be pure risk.
contract DeepCoreLaunchAndBuy is ILockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @param legIndex Which of `p.legs` the buy is routed to. Other legs open at the same instant and
    ///        are buyable by anyone; one buy per transaction is deliberate, see the header.
    /// @param amountIn Exact input, in the chosen leg's quote currency. Native quotes take it from
    ///        `msg.value`; ERC-20 quotes are pulled from `msg.sender`, who must have approved this
    ///        contract. Exact-OUTPUT is not offered: both guards reject an exact-output buy outright
    ///        while `maxBuyPerTx` is live, so it would work for some presets and not others.
    /// @param minAmountOut Launch-token units the caller will accept. The guard's fee and any
    ///        creator tax come out of `amountIn` before the pool trades, so what is bought is less
    ///        than `amountIn` at the pool's price - a real bound, not a formality.
    /// @param recipient Who receives the bought tokens. `address(0)` means `msg.sender`.
    /// @param expectedToken The launch-token address the caller was shown. `address(0)` skips the
    ///        check; any UI that displayed an address MUST pass it.
    /// @param maxLaunchFeeWei The most the caller will pay the kit in total (protocol + integrator
    ///        launch fee). The protocol fee can rise by itself when a scheduled increase matures, so
    ///        the value in force is read in this call and checked against this bound.
    /// @param maxLpFeePips The most the caller accepts the guard to charge this first buy, in pips
    ///        (1e6 == 100%). Checked against the guard's own `currentFee` after the launch.
    struct BuyParams {
        uint8 legIndex;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        address expectedToken;
        uint256 maxLaunchFeeWei;
        uint24 maxLpFeePips;
    }

    /// @dev The whole of what crosses into the Vault lock. Not part of the external ABI.
    struct SwapPlan {
        PoolKey key;
        bool bin;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NoCode(address account);
    error VaultMismatch(address component);

    /// @notice `startDelaySeconds` must be 0: this contract exists to buy at the open, so the open is
    /// now. It is refused rather than silently overwritten - a caller's parameter is not ours to edit.
    error StartDelayMustBeZero(uint32 delaySeconds);
    error ZeroBuyAmount();
    /// @notice Core's balance deltas are `int128`. Anything above this could not be settled anyway.
    error BuyAmountTooLarge(uint256 amountIn);
    error LegIndexOutOfRange(uint8 legIndex, uint256 legCount);
    /// @notice This contract was named as creator, integrator or allocation recipient. It has no
    /// claim path on the kit or either locker, so that value would be stranded forever.
    error InvalidRecipient(address recipient);
    /// @notice The launch token this call would create is not the one the caller was shown.
    error LaunchTokenMismatch(address expected, address actual);
    error LaunchFeeAboveMax(uint256 required, uint256 maxWei);
    error OpeningFeeAboveMax(uint24 feePips, uint24 maxFeePips);
    error InsufficientValue(uint256 required, uint256 sent);
    /// @notice The swap consumed none of the input: the pool had nothing to sell at this price.
    error NothingFilled();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    /// @notice A swap returned a delta with the wrong signs for the direction asked. Unreachable
    /// through core; asserted rather than assumed, because everything after it is arithmetic on it.
    error UnexpectedDelta(int128 inDelta, int128 outDelta);
    error NotVault(address caller);
    error NotLocker(address locker);
    error NativeTransferFailed(address to, uint256 amount);
    error NothingToSweep();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @param quoteSpent Quote units the buyer paid, measured from the delta: what the pool traded
    ///        plus the guard's fee and any creator tax.
    /// @param tokensBought Launch-token units delivered to `recipient`.
    /// @param lpFeePips The guard's fee at this instant, read from the guard, in pips.
    event LaunchAndBuyExecuted(
        address indexed token,
        address indexed creator,
        address indexed recipient,
        bytes32 poolId,
        uint256 quoteSpent,
        uint256 tokensBought,
        uint24 lpFeePips
    );

    /// @notice Value that was never part of a launch left for the immutable sweep recipient.
    event Swept(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The kit this contract launches through, forever.
    ILaunchpadKitV2 public immutable KIT;
    /// @notice Read off the CL pool manager, which is read off the kit. Never a deployer argument.
    IVault public immutable VAULT;
    ICLPoolManager public immutable CL_POOL_MANAGER;
    IBinPoolManager public immutable BIN_POOL_MANAGER;
    /// @notice The only address a sweep can pay: the governance Safe. Immutable, no setter.
    address public immutable SWEEP_RECIPIENT;

    /// @notice Pips, matching core: 1_000_000 == 100%.
    uint24 public constant FEE_DENOMINATOR = 1_000_000;

    /// @param kit The deployed `LaunchpadKitV2`.
    /// @param sweepRecipient Where misdirected or forced value goes. The governance Safe.
    constructor(ILaunchpadKitV2 kit, address sweepRecipient) {
        if (address(kit) == address(0) || sweepRecipient == address(0)) revert ZeroAddress();
        if (address(kit).code.length == 0) revert NoCode(address(kit));

        address cl = ILaunchpadKitV2Extras(address(kit)).clPoolManager();
        address bin = ILaunchpadKitV2Extras(address(kit)).binPoolManager();
        IVault vault_ = ICLPoolManager(cl).vault();
        if (address(IBinPoolManager(bin).vault()) != address(vault_)) revert VaultMismatch(bin);

        KIT = kit;
        CL_POOL_MANAGER = ICLPoolManager(cl);
        BIN_POOL_MANAGER = IBinPoolManager(bin);
        VAULT = vault_;
        SWEEP_RECIPIENT = sweepRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                               THE ONE CALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a launch through `KIT` and buy on one of its legs, atomically.
    /// @dev The caller keeps every power `createLaunch` gives them: `creator`, `launchOperator` and
    /// `launchSteward` resolve to `msg.sender` when left zero, exactly as the kit would have resolved
    /// them - this contract substitutes `msg.sender` itself precisely so the kit does not substitute
    /// ITSELF's caller (us) and leave the creator with no operator rights and no locker credit.
    /// @return result Whatever `createLaunch` returned, unmodified.
    /// @return quoteSpent Quote units the buyer paid: the pool's trade plus the guard's take.
    /// @return tokensBought Launch-token units delivered.
    /// @return lpFeePips The opening fee the guard charged, in pips.
    function launchAndBuy(LaunchParamsV2 calldata p, BuyParams calldata b)
        external
        payable
        nonReentrant
        returns (LaunchResultV2 memory result, uint256 quoteSpent, uint256 tokensBought, uint24 lpFeePips)
    {
        /* ============================ CHECKS (no external calls) ============================ */
        if (b.amountIn == 0) revert ZeroBuyAmount();
        // Core settles in int128; a larger buy could not be settled and the negation below would be
        // the one arithmetic edge worth refusing rather than reasoning about.
        // Both casts are of a compile-time constant and widen; nothing can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (b.amountIn > uint256(uint128(type(int128).max))) revert BuyAmountTooLarge(b.amountIn);
        // A disabled schedule trades from birth whatever `startTime` says, so without this a delayed
        // launch on `NoTax` would be created, bought and frozen with its open still in the future.
        if (p.schedule.startDelaySeconds != 0) revert StartDelayMustBeZero(p.schedule.startDelaySeconds);
        if (b.legIndex >= p.legs.length) revert LegIndexOutOfRange(b.legIndex, p.legs.length);

        address creator = p.creator == address(0) ? msg.sender : p.creator;
        // The kit refuses ITSELF in these three roles for the same reason: neither the kit nor this
        // contract can ever call `claimFees` or `DeepCoreLPLocker.claim`, so naming either strands value.
        if (creator == address(this) || p.integrator == address(this) || p.allocationRecipient == address(this)) {
            revert InvalidRecipient(address(this));
        }

        /* ============================== THE LAUNCH ============================== */
        LaunchParamsV2 memory m = _resolve(p, creator);

        {
            address predicted = KIT.predictLaunchToken(address(this), m.userSalt);
            if (b.expectedToken != address(0) && b.expectedToken != predicted) {
                revert LaunchTokenMismatch(b.expectedToken, predicted);
            }
        }

        uint256 kitPayment = KIT.launchFeeWei() + p.integratorLaunchFeeWei;
        if (kitPayment > b.maxLaunchFeeWei) revert LaunchFeeAboveMax(kitPayment, b.maxLaunchFeeWei);

        address quote = p.legs[b.legIndex].quote;
        uint256 budget = _collect(quote, b.amountIn, kitPayment);

        // EXACTLY the fee in force, so the kit's excess-refund path is never taken. That path is a
        // raw call to `msg.sender`, and this contract has no `receive`.
        result = KIT.createLaunch{value: kitPayment}(m);

        /* ============================== THE BUY ============================== */
        (PoolKey memory key, bytes32 poolId, bool launchIsCurrency0) =
            ILaunchpadKitV2Extras(address(KIT)).computeLegKey(result.token, p.legs[b.legIndex]);

        // The guard's own number, at the instant of the swap, read from the guard. Not derived here,
        // not taken from the preset table, not trusted from the caller.
        lpFeePips = ILaunchGuardFee(address(key.hooks)).currentFee(poolId);
        if (lpFeePips > b.maxLpFeePips) revert OpeningFeeAboveMax(lpFeePips, b.maxLpFeePips);

        address recipient = b.recipient == address(0) ? msg.sender : b.recipient;
        SwapPlan memory plan = SwapPlan({
            key: key,
            bin: p.legs[b.legIndex].kind == LegKind.Bin,
            // A buy pays the quote. The quote is whichever side the launch token is not.
            zeroForOne: !launchIsCurrency0,
            amountIn: budget,
            recipient: recipient
        });
        // The "reentrancy" here is this contract's own `lockAcquired`, invoked by the Vault. It is
        // the mechanism, not a hazard: `launchAndBuy` is `nonReentrant` and `lockAcquired` is not,
        // deliberately, because the guard would otherwise refuse the Vault's callback.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bytes memory swapResult = VAULT.lock(abi.encode(plan));
        (quoteSpent, tokensBought) = abi.decode(swapResult, (uint256, uint256));

        if (quoteSpent == 0) revert NothingFilled();
        if (tokensBought < b.minAmountOut) revert InsufficientOutput(tokensBought, b.minAmountOut);

        /* ============================== REFUNDS ============================== */
        // A native quote's unspent input and the caller's native overpayment are the same pile, so
        // they are refunded as one number; an ERC-20 quote has two piles and refunds both.
        if (quote == address(0)) {
            _refund(address(0), 0, msg.value - kitPayment - quoteSpent);
        } else {
            _refund(quote, budget - quoteSpent, msg.value - kitPayment);
        }

        // After the refunds on purpose: the event reports the settled outcome, and by this point the
        // only external calls left behind it were a transfer to `msg.sender` of their own money.
        // forge-lint: disable-next-line(reentrancy-events)
        emit LaunchAndBuyExecuted(result.token, creator, recipient, poolId, quoteSpent, tokensBought, lpFeePips);
    }

    /*//////////////////////////////////////////////////////////////
                              THE VAULT LOCK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILockCallback
    /// @dev Only the Vault can reach this, and only for a lock THIS contract opened: `Vault.lock`
    /// calls back on `msg.sender`, so the Vault can only ever invoke `lockAcquired` on the address
    /// that locked it. `SettlementGuard.setLocker` refuses a second concurrent locker, so no third
    /// party can be mid-lock while we are. Both facts are asserted rather than relied on silently.
    /// There is deliberately NO persistent "a lock is in flight" flag: a storage flag that must be
    /// zero when the call ends is the exact hazard class CLAUDE.md's transient-backend invariant
    /// exists for, and the two checks below are strictly stronger than one.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault(msg.sender);
        address locker = VAULT.getLocker();
        if (locker != address(this)) revert NotLocker(locker);

        SwapPlan memory s = abi.decode(data, (SwapPlan));

        BalanceDelta delta;
        if (s.bin) {
            // Bin takes int128 directly. `amountIn` is bounded to int128 max by `launchAndBuy`.
            // forge-lint: disable-next-line(unsafe-typecast)
            delta = BIN_POOL_MANAGER.swap(s.key, s.zeroForOne, -int128(int256(s.amountIn)), "");
        } else {
            delta = CL_POOL_MANAGER.swap(
                s.key,
                ICLPoolManager.SwapParams({
                    zeroForOne: s.zeroForOne,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amountSpecified: -int256(s.amountIn),
                    // The extreme limit. Slippage is bounded by `minAmountOut` against a MEASURED
                    // output, which is the honest bound; a price limit would additionally bound the
                    // marginal price, which is not what a creator's first buy is asking for.
                    sqrtPriceLimitX96: s.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                }),
                ""
            );
        }

        (Currency inCurrency, Currency outCurrency) =
            s.zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
        int128 inDelta = s.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = s.zeroForOne ? delta.amount1() : delta.amount0();
        // A buy owes the quote (negative) and is owed the token (non-negative). Anything else and the
        // arithmetic below would be meaningless, so it fails closed instead.
        if (inDelta > 0 || outDelta < 0) revert UnexpectedDelta(inDelta, outDelta);

        // `inDelta` is in [-amountIn, 0] and `amountIn <= type(int128).max`, so the negation cannot
        // overflow (the one pathological input, `type(int128).min`, is unreachable) and neither cast
        // can truncate. `outDelta` is non-negative by the check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 spent = uint256(uint128(-inDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 out = uint256(uint128(outDelta));
        // An exact-input swap cannot consume more than it was given. Checked anyway, because the
        // refund arithmetic outside this lock subtracts it.
        if (spent > s.amountIn) revert UnexpectedDelta(inDelta, outDelta);

        // Settle what we owe before taking what we are owed. Neither order can under-pay - the lock
        // does not close until every delta is zero - but paying first is the habit worth keeping.
        if (spent != 0) {
            if (inCurrency.isNative()) {
                // `settle` returns what it credited. It is not read on purpose: the lock does not
                // close unless every delta is zero, so the Vault's own accounting is the check.
                // forge-lint: disable-next-line(unused-return)
                VAULT.settle{value: spent}();
            } else {
                VAULT.sync(inCurrency);
                IERC20(Currency.unwrap(inCurrency)).safeTransfer(address(VAULT), spent);
                // forge-lint: disable-next-line(unused-return)
                VAULT.settle();
            }
        }
        // Straight to the recipient: this contract never holds the output, not even for one opcode.
        if (out != 0) VAULT.take(outCurrency, s.recipient, out);

        return abi.encode(spent, out);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The launch-token address a launch through THIS contract would produce.
    /// @dev Same shape as `LaunchpadKitV2.predictLaunchToken` so an SDK swaps one call for the other,
    /// but the arguments mean different things: `launcher` here is the CREATOR (the address that will
    /// call `launchAndBuy`), not the kit's `msg.sender`. The double fold is the whole answer to the
    /// salt question - see the contract header, point 1.
    function predictLaunchToken(address launcher, bytes32 userSalt) external view returns (address) {
        return KIT.predictLaunchToken(address(this), keccak256(abi.encode(launcher, userSalt)));
    }

    /// @notice What the guard will charge the first buy, and what that costs on `amountIn`.
    /// @dev PURE: no chain read, so a UI can call it before anything exists. It resolves the schedule
    /// exactly as `LaunchpadKitV2._resolveSchedule` does - by importing the same `LaunchPresets`
    /// library, so the numbers cannot drift from the kit's.
    /// `lpFeeQuote` is `amountIn * pips / 1e6` rounded DOWN, which is the guard's own arithmetic
    /// on an exact-input buy. A creator tax is not part of it.
    /// @return lpFeePips The fee, in pips, at `elapsed == 0`.
    /// @return lpFeeQuote That fee applied to `amountIn`, in quote units.
    function previewOpeningFee(ScheduleParams calldata schedule, uint256 amountIn)
        external
        pure
        returns (uint24 lpFeePips, uint256 lpFeeQuote)
    {
        if (schedule.preset == Preset.Custom) {
            lpFeePips = schedule.enabled ? schedule.initialFeeBips : schedule.finalFeeBips;
        } else {
            PresetParams memory pp = LaunchPresets.params(schedule.preset);
            lpFeePips = pp.enabled ? pp.initialFeeBips : pp.finalFeeBips;
        }
        lpFeeQuote = amountIn * lpFeePips / FEE_DENOMINATOR;
    }

    /*//////////////////////////////////////////////////////////////
                                 SWEEPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Move native currency that reached this contract to the immutable recipient.
    /// @dev Permissionless, because it can only ever pay one address that no key can change, and
    /// because at rest this contract owes nobody anything: every unit belonging to a launch leaves in
    /// the launch's own transaction. With no `receive` and no `fallback` the only ways in are
    /// `selfdestruct` and a block reward. `nonReentrant` so it cannot be called from inside a
    /// `launchAndBuy` by a hostile quote token mid-flight.
    function sweepNative() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        emit Swept(address(0), SWEEP_RECIPIENT, amount);
        // `nonReentrant` is still engaged during the call, and the recipient is an immutable no key
        // can change, so a reentrant sweep reverts and a hostile recipient can only refuse its own
        // money. There is no balance state to update: the balance IS the state.
        // forge-lint: disable-next-line(reentrancy-eth)
        (bool ok,) = SWEEP_RECIPIENT.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(SWEEP_RECIPIENT, amount);
    }

    /// @notice Move a misdirected ERC-20 to the immutable recipient. Permissionless, same reasoning.
    function sweepERC20(address token) external nonReentrant returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        emit Swept(token, SWEEP_RECIPIENT, amount);
        IERC20(token).safeTransfer(SWEEP_RECIPIENT, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev The caller's parameters with the four fields this contract must own set, and nothing else
    /// touched. Every other field - supply, legs, split, tenant, schedule, tax, listing - is passed
    /// through verbatim and validated by the kit, which is where it belongs.
    function _resolve(LaunchParamsV2 calldata p, address creator) private view returns (LaunchParamsV2 memory m) {
        m = p;
        m.creator = creator;
        // Left zero, the kit would resolve these to ITS caller - this contract - and the real creator
        // would have no `reconfigureLaunch` rights and no registry stewardship over their own launch.
        m.launchOperator = p.launchOperator == address(0) ? msg.sender : p.launchOperator;
        m.launchSteward = p.launchSteward == address(0) ? msg.sender : p.launchSteward;
        // See the header, point 1: restore the per-creator salt namespace the factory documents.
        m.userSalt = keccak256(abi.encode(msg.sender, p.userSalt));
    }

    /// @dev Takes the quote side in, and checks the native side covers what the kit is owed.
    /// @return budget The quote units actually available to the swap, MEASURED for an ERC-20.
    function _collect(address quote, uint256 amountIn, uint256 kitPayment) private returns (uint256 budget) {
        if (quote == address(0)) {
            uint256 required = kitPayment + amountIn;
            if (msg.value < required) revert InsufficientValue(required, msg.value);
            return amountIn;
        }
        if (msg.value < kitPayment) revert InsufficientValue(kitPayment, msg.value);
        IERC20 token = IERC20(quote);
        // Measured, not assumed. A fee-on-transfer quote is not SUPPORTED (the kit's own note says
        // so, and the guard's cap would price it wrongly) but it must not make this contract pay out
        // units it never received.
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        budget = token.balanceOf(address(this)) - before;
        if (budget == 0) revert ZeroBuyAmount();
    }

    /// @dev Everything left over, back to the caller, last. A caller who sends the exact amounts gets
    /// no call at all, which is what lets a contract with no `receive` use this path safely.
    function _refund(address quote, uint256 quoteRemainder, uint256 nativeRemainder) private {
        if (quote != address(0) && quoteRemainder != 0) {
            IERC20(quote).safeTransfer(msg.sender, quoteRemainder);
        }
        if (nativeRemainder != 0) {
            // Still inside `nonReentrant`; the callee is the caller, being handed back their own
            // surplus, after every effect of this call has landed.
            // forge-lint: disable-next-line(reentrancy-eth)
            (bool ok,) = msg.sender.call{value: nativeRemainder}("");
            if (!ok) revert NativeTransferFailed(msg.sender, nativeRemainder);
        }
    }
}
