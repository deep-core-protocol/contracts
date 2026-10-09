/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IWrappedNative} from "./interfaces/IWrappedNative.sol";
import {DeepCoreFillExecutor} from "./DeepCoreFillExecutor.sol";

/// @title DeepCoreFillRouter - DeepCore's fee on a trade filled somewhere else
/// @notice Owner decision, 2026-09-20: "the ROUTER may fill a user's trade on a third-party AMM; the
/// PROTOCOL still may not integrate with one." This contract is the router half of that sentence,
/// and everything about its shape follows from the other half.
///
/// WHAT IT IS. A user wants a pair DeepCore has no liquidity in. Rather than showing them nothing, the
/// widget quotes an external venue and fills there, and DeepCore takes a governed percentage for doing
/// it. On a DeepCore pool the same trade pays zero - not by a branch in here, but because a DeepCore pool
/// trade never touches this contract at all.
///
/// WHAT IT IS NOT, which matters more. There is no third-party interface anywhere in this package.
/// The venue is `address target` plus `bytes data`, both supplied by the caller and both built off
/// chain from a deployed contract's PUBLIC ABI. Nothing is vendored, imported, linked or named: this
/// contract does not know what a Uniswap or a PancakeSwap is, and it never will. It is also not a
/// Vault app - it imports nothing from core or periphery, takes no lock, and knows nothing about
/// Infinity pools. DeepCore's own core is not becoming a client of anybody.
///
/// THE FEE IS GOVERNED, NEVER A CONSTANT (CLAUDE.md, "Kit fees"; the same mechanism as
/// `DeepCorePadFactory`'s site fee and `DeepCoreFeeGate`, copied rather than re-invented so an operator who
/// understands one understands all of them):
///   * `feeBps()` is what a fill in THIS block pays. The owner (the governance Safe; `Ownable2Step`,
///     `renounceOwnership` reverts) may set it inside the immutable `maxFeeBps`, itself bounded at
///     compile time by `ABSOLUTE_MAX_FEE_BPS`.
///   * A decrease applies at once - delay never sits on privilege reduction. An increase is
///     announced and takes effect by itself `feeNoticeSeconds` later; a new increase restarts the
///     notice; `cancelPendingFee` withdraws it.
///   * Nothing is retroactive, and a quote cannot be repriced under a user who already signed:
///     `fill` carries the `maxFeeBps` the caller was quoted and reverts if the fee in force is
///     higher.
///
/// THE FEE IS TAKEN ON THE INPUT, AND THE OUTPUT IS NEVER TOUCHED. This is the answer to the second
/// hazard CLAUDE.md names - "the fee must never turn an exact-output swap into a worse fill than
/// quoted; price impact and the fee are different numbers". There is one fill path, not an exact-in
/// branch and an exact-out branch:
///
///     budget = amountIn * 10_000 / (10_000 + feeBps)   // the most the venue may consume
///     spent  = budget - (unspent input the venue gave back)
///     fee    = spent * feeBps / 10_000                 // charged on what was ACTUALLY consumed
///     refund = amountIn - spent - fee                  // to the caller, always >= 0
///
/// Because `spent <= budget`, `spent + fee <= amountIn` always: the caller's total outlay is bounded
/// by the number they signed whatever the venue does, which is exactly what an exact-output fill
/// needs. And the output handed to the recipient is the raw amount the venue produced, with nothing
/// added and nothing subtracted, so `minAmountOut` compares against a number this contract has not
/// touched. "10 bps" therefore means 10 bps of what reaches the venue (~9.99 bps of the total
/// outlay); the event states `spent` and `feeAmount` separately so nobody has to derive it.
///
/// EVERY NUMBER IS A MEASURED DELTA. What the caller actually paid, what the venue actually consumed
/// and what it actually produced are all balance deltas taken across the call, never an amount an
/// argument or a return value claimed. A fee-on-transfer or rebasing token therefore cannot make
/// this contract mis-pay or drift; it can only make the caller's quote wrong, at which point
/// `minAmountOut` reverts the trade. Such tokens are not supported for QUOTING and the SDK must not
/// offer them - they are merely unable to break anything here.
///
/// WHAT THE OWNER CANNOT DO. There is no pause, no allowlist, no per-user anything, and no branch in
/// `fill` that reads the owner. It cannot change `protocolFeeRecipient`, `WNATIVE`, `EXECUTOR` or the
/// cap (all immutable), cannot reach a user's funds or allowances, cannot decide or block a route,
/// cannot un-exempt a venue, and cannot renounce. A pause is deliberately absent: nothing is
/// custodied between transactions, so a pause would protect nothing while adding a key that can stop
/// the product. The frontend stops routing without anybody's key.
///
/// FUNDS CAN NEVER BE STUCK (CLAUDE.md acceptance bar). Native reaches this contract as a fill's
/// `msg.value`, as a venue's output swept back from the executor, as an unwrap, or forced in. ERC-20s
/// reach it as a fill's input, as a venue's output, or misdirected. Everything belonging to a fill
/// leaves inside that same call (to the recipient, or refunded to the caller); everything else is
/// protocol or stray and leaves through the permissionless `flushFees`, which can only ever pay the
/// immutable recipient. Nothing is ever owed to a user from the resting balance, which is why
/// flushing the WHOLE balance is correct here as it is on `DeepCorePadFactory`. An ERC-721 sent with a
/// plain `transferFrom` would strand: no receiver callback is implemented, so a safe transfer cannot
/// arrive. Recorded as accepted, identically to `DeepCorePadFactory`.
contract DeepCoreFillRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @param target The venue entry point the caller chose. Any address with code that is neither
    /// this router nor its executor.
    /// @param currencyIn What the caller parts with. `address(0)` is native, sent as `msg.value`.
    /// @param currencyOut What the recipient receives. `address(0)` is native.
    /// @param amountIn The MOST the caller parts with, fee included. For an exact-input trade it is
    /// simply the trade size; for an exact-output trade it is the quoted maximum.
    /// @param minAmountOut The LEAST the recipient accepts. The only slippage control, checked
    /// against the measured output. For an exact-output trade, set it to the exact output wanted.
    /// @param maxFeeBps The fee the caller was quoted. The fill reverts if the fee in force exceeds
    /// it, so a governance change can never reprice a transaction already signed. Pass the quoted
    /// value, never `type(uint16).max`.
    /// @param wrapInput Wrap the venue's share of a native input into `WNATIVE` first, for venues
    /// that do not take native. Requires `currencyIn == address(0)` and a configured `WNATIVE`.
    /// @param unwrapOutput Unwrap a `WNATIVE` output back to native before paying the recipient.
    /// Requires `currencyOut == address(0)` and a configured `WNATIVE`.
    /// @param recipient Who receives `currencyOut`. Never zero. The refund always goes to the caller.
    /// @param deadline Unix seconds. A transaction stuck in the mempool cannot be filled stale.
    /// @param data The venue calldata, built off chain from its public ABI.
    struct FillParams {
        address target;
        address currencyIn;
        address currencyOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint16 maxFeeBps;
        bool wrapInput;
        bool unwrapOutput;
        address recipient;
        uint256 deadline;
        bytes data;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice One routed fill. `spent` and `feeAmount` are separate fields on purpose: the fee is
    /// not part of the price and must never be shown as if it were.
    /// @param payer Who paid, and who the refund went to.
    /// @param spent What the venue actually consumed of `currencyIn`.
    /// @param feeAmount The protocol fee, in `currencyIn`, charged on `spent`.
    /// @param refund What went back to the payer: `amountIn - spent - feeAmount`.
    event Filled(
        address indexed payer,
        address indexed target,
        address indexed recipient,
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 spent,
        uint256 feeAmount,
        uint256 amountOut,
        uint256 refund
    );

    /// @notice The fee in force changed: a decrease, or an increase whose notice elapsed.
    event FeeChanged(uint16 previousBps, uint16 newBps);
    event FeeIncreaseScheduled(uint16 currentBps, uint16 newBps, uint64 effectiveAt);
    event PendingFeeCancelled(uint16 cancelledBps, uint64 effectiveAt);
    /// @notice A venue that pays no fee, forever. Irreversible - see `exemptVenue`.
    event VenueFeeExempted(address indexed target);
    event FeesFlushed(address indexed currency, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidNotice(uint32 noticeSeconds);
    /// @notice The requested fee is above the immutable cap, or the cap above the compile-time ceiling.
    error FeeAboveCap(uint16 feeBps, uint16 capBps);
    error NoPendingFee();
    error RenounceDisabled();
    error AlreadyExempt(address target);

    error DeadlinePassed(uint256 deadline, uint256 nowTimestamp);
    error ZeroAmount();
    /// @notice The fee in force is higher than the one the caller was quoted.
    error FeeAboveQuoted(uint16 inForceBps, uint16 acceptedBps);
    /// @notice `currencyIn` and `currencyOut` must differ, on the caller's side and at the venue.
    error IdenticalCurrencies(address currency);
    /// @notice Native input must arrive as exactly `amountIn`; an ERC-20 input must carry no value.
    error UnexpectedValue(uint256 expected, uint256 sent);
    /// @notice Wrapping was asked for on a chain where no wrapped-native address was configured.
    error WrappedNativeNotSet();
    /// @notice `wrapInput` needs a native input; `unwrapOutput` needs a native output.
    error WrapMismatch();
    /// @notice The venue produced less than the caller accepted. The whole fill reverts.
    error InsufficientOutput(uint256 received, uint256 minimum);
    error NothingToFlush(address currency);
    error NativeTransferFailed(address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                          CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The highest cap any deployment may carry, so even a mis-deployed `maxFeeBps` cannot be
    /// predatory. The owner's decision is 10 bps with a suggested cap of 50; this is the contract's
    /// own ceiling on that cap.
    uint16 public constant ABSOLUTE_MAX_FEE_BPS = 100;

    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;

    /// @notice `address(0)` means the chain's native currency throughout this package.
    address internal constant NATIVE = address(0);

    /// @notice The only contract in this package that makes an arbitrary call. Deployed here, in the
    /// constructor, so it can never be re-pointed.
    DeepCoreFillExecutor public immutable EXECUTOR;
    /// @notice The governance Safe. The only address a fee can ever reach.
    address public immutable protocolFeeRecipient;
    /// @notice The chain's wrapped native contract, or `address(0)` to refuse wrapping entirely.
    address public immutable WNATIVE;
    /// @notice The owner can never set a fee above this. Immutable.
    uint16 public immutable maxFeeBps;
    /// @notice How long an announced increase waits before it is the fee.
    uint32 public immutable feeNoticeSeconds;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    // slot 0 `_owner` (Ownable), slot 1 `_pendingOwner` (Ownable2Step), slot 2 `_status` (ReentrancyGuard)
    uint16 private _feeBps;
    uint16 private _pendingFeeBps;
    uint64 private _pendingFeeAt;

    /// @notice Venues that pay no fee. Set once, never unset - see `exemptVenue`.
    mapping(address => bool) public isFeeExempt;
    /// @notice Cumulative fees taken, per currency. Accounting only: nothing in this contract reads
    /// it, and no invariant depends on it. Monotone.
    mapping(address => uint256) public totalFeeCollected;

    /// @param owner_ The governance Safe. Fee only.
    /// @param protocolFeeRecipient_ Where fees go. The Safe. Immutable.
    /// @param wrappedNative_ The chain's wrapped-native contract, or zero to refuse wrapping.
    /// @param initialFeeBps The fee in force from birth (`<= maxFeeBps_`; zero is allowed).
    /// @param maxFeeBps_ The immutable cap, `<= ABSOLUTE_MAX_FEE_BPS`.
    /// @param feeNoticeSeconds_ Notice on increases, `MIN_FEE_NOTICE_SECONDS..MAX_FEE_NOTICE_SECONDS`.
    /// @param initialExemptVenue DeepCore's own router on this chain, exempted at birth. A constructor
    /// argument rather than a follow-up transaction on purpose: "0 on a DeepCore pool" is the owner's
    /// decision, and an exemption that has to be remembered per chain is an exemption that gets
    /// forgotten on one of them. Zero skips it (a chain where nothing is exempt yet).
    constructor(
        address owner_,
        address protocolFeeRecipient_,
        address wrappedNative_,
        uint16 initialFeeBps,
        uint16 maxFeeBps_,
        uint32 feeNoticeSeconds_,
        address initialExemptVenue
    ) Ownable(owner_) {
        if (protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (maxFeeBps_ > ABSOLUTE_MAX_FEE_BPS) revert FeeAboveCap(maxFeeBps_, ABSOLUTE_MAX_FEE_BPS);
        if (initialFeeBps > maxFeeBps_) revert FeeAboveCap(initialFeeBps, maxFeeBps_);
        if (feeNoticeSeconds_ < MIN_FEE_NOTICE_SECONDS || feeNoticeSeconds_ > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(feeNoticeSeconds_);
        }
        protocolFeeRecipient = protocolFeeRecipient_;
        WNATIVE = wrappedNative_;
        maxFeeBps = maxFeeBps_;
        feeNoticeSeconds = feeNoticeSeconds_;
        _feeBps = initialFeeBps;
        EXECUTOR = new DeepCoreFillExecutor(address(this), protocolFeeRecipient_);
        emit FeeChanged(0, initialFeeBps);
        if (initialExemptVenue != address(0)) {
            isFeeExempt[initialExemptVenue] = true;
            emit VenueFeeExempted(initialExemptVenue);
        }
    }

    /// @notice Native arrives as a venue's output swept back from the executor, as an unwrap, or
    /// misdirected. Nothing here is ever owed to a user at rest; strays leave through `flushFees`.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                  FILL
    //////////////////////////////////////////////////////////////*/

    /// @notice Fills the caller's trade at the venue they chose and takes the protocol fee on the
    /// input side.
    /// @dev Checks, effects, interactions. The venue call is the one interaction that happens before
    /// the payouts, and it must: there is nothing to pay out until it has happened. Everything the
    /// contract then acts on is a balance delta measured across it, and the whole function is
    /// `nonReentrant`, shared with `flushFees`, so a venue that calls back reverts.
    /// @return amountOut What the recipient received.
    /// @return spent What the venue consumed of `currencyIn`.
    /// @return feeAmount The protocol fee, in `currencyIn`.
    /// @return refund What went back to the caller.
    function fill(FillParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 spent, uint256 feeAmount, uint256 refund)
    {
        if (block.timestamp > p.deadline) revert DeadlinePassed(p.deadline, block.timestamp);
        if (p.recipient == address(0)) revert ZeroAddress();
        if (p.amountIn == 0) revert ZeroAmount();
        if (p.currencyIn == p.currencyOut) revert IdenticalCurrencies(p.currencyIn);

        uint16 bps = _feeBpsFor(p.target);
        if (bps > p.maxFeeBps) revert FeeAboveQuoted(bps, p.maxFeeBps);

        (address venueIn, address venueOut) = _venueCurrencies(p);

        // --- pull, measured ---
        uint256 received = _pullFromPayer(p.currencyIn, p.amountIn);
        if (received == 0) revert ZeroAmount();

        // The most the venue may consume, so that `spent + fee(spent)` can never exceed what the
        // caller parted with. The remainder stays here and always covers the fee: see the header.
        uint256 budget = (received * BPS_DENOMINATOR) / (uint256(BPS_DENOMINATOR) + bps);

        (amountOut, spent) = _runVenue(p, venueIn, venueOut, budget);

        if (amountOut < p.minAmountOut) revert InsufficientOutput(amountOut, p.minAmountOut);

        feeAmount = (spent * bps) / BPS_DENOMINATOR;
        refund = received - spent - feeAmount;

        // --- effects ---
        if (feeAmount != 0) totalFeeCollected[p.currencyIn] += feeAmount;
        emit Filled(
            msg.sender,
            p.target,
            p.recipient,
            p.currencyIn,
            p.currencyOut,
            received,
            spent,
            feeAmount,
            amountOut,
            refund
        );

        // --- interactions ---
        if (amountOut != 0) _send(p.currencyOut, p.recipient, amountOut);
        if (refund != 0) _send(p.currencyIn, msg.sender, refund);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The fee a fill in THIS block pays, in basis points of what reaches the venue.
    function feeBps() public view returns (uint16) {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) return _pendingFeeBps;
        return _feeBps;
    }

    /// @notice An announced increase that has not taken effect yet. `(0, 0)` when there is none.
    function pendingFee() external view returns (uint16 newFeeBps, uint64 effectiveAt) {
        effectiveAt = _pendingFeeAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        newFeeBps = _pendingFeeBps;
    }

    /// @notice What a fill of `amountIn` through `target` in this block would split into, so a UI can
    /// show the fee as its own line beside price impact rather than merged into it.
    /// @return bps The fee in force for this venue (zero if it is exempt).
    /// @return budget The most of `amountIn` that reaches the venue - quote against THIS, not
    /// `amountIn`.
    /// @return maxFee The fee if the venue consumes the whole budget. A venue that consumes less is
    /// charged less.
    function quoteFill(address target, uint256 amountIn)
        external
        view
        returns (uint16 bps, uint256 budget, uint256 maxFee)
    {
        bps = _feeBpsFor(target);
        budget = (amountIn * BPS_DENOMINATOR) / (uint256(BPS_DENOMINATOR) + bps);
        maxFee = (budget * bps) / BPS_DENOMINATOR;
    }

    /*//////////////////////////////////////////////////////////////
                             FEE (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @notice `<=` the fee in force applies now and cancels any pending increase; `>` it is
    /// announced and takes effect `feeNoticeSeconds` later, by itself. A new increase replaces a
    /// pending one and restarts the notice, so no announcement can shorten the wait. Nothing is
    /// retroactive, and `FillParams.maxFeeBps` means no signed transaction can be repriced.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > maxFeeBps) revert FeeAboveCap(newFeeBps, maxFeeBps);
        _materialise();
        uint16 current = _feeBps;
        if (newFeeBps <= current) {
            _clearPending();
            _feeBps = newFeeBps;
            emit FeeChanged(current, newFeeBps);
        } else {
            uint64 effectiveAt = uint64(block.timestamp) + feeNoticeSeconds;
            _pendingFeeBps = newFeeBps;
            _pendingFeeAt = effectiveAt;
            emit FeeIncreaseScheduled(current, newFeeBps, effectiveAt);
        }
    }

    /// @notice Withdraws an announced increase that has not taken effect. One that has is the fee.
    function cancelPendingFee() external onlyOwner {
        _materialise();
        if (_pendingFeeAt == 0) revert NoPendingFee();
        _clearPending();
    }

    /// @notice Marks a venue as paying no fee, forever. Used for DeepCore's own router, so that a
    /// widget which sends every fill through one code path still charges zero on a DeepCore pool.
    /// @dev IRREVERSIBLE BY DESIGN. An exemption only ever lowers what the protocol takes, so making
    /// it one-way removes the "un-exempt to raise the fee without notice" lever entirely. The cost is
    /// stated rather than hidden: a compromised owner could permanently zero the fee on a venue,
    /// which is a revenue incident needing a redeploy, and which touches no user.
    function exemptVenue(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        if (isFeeExempt[target]) revert AlreadyExempt(target);
        isFeeExempt[target] = true;
        emit VenueFeeExempted(target);
    }

    /// @notice Disabled. An owner that could renounce would freeze the fee where it stands forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                                 FLUSH
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless: sends this contract's whole balance of `currency` to the immutable
    /// `protocolFeeRecipient`. A fill leaves nothing behind, so the resting balance is accrued fees
    /// plus anything misdirected or forced in, and nobody but the recipient is ever owed any of it.
    /// @dev `nonReentrant` is shared with `fill`: this can never run while a fill holds user funds.
    function flushFees(address currency) external nonReentrant returns (uint256 amount) {
        amount = currency == NATIVE ? address(this).balance : IERC20(currency).balanceOf(address(this));
        if (amount == 0) revert NothingToFlush(currency);
        emit FeesFlushed(currency, protocolFeeRecipient, amount);
        _send(currency, protocolFeeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _feeBpsFor(address target) private view returns (uint16) {
        return isFeeExempt[target] ? 0 : feeBps();
    }

    /// @dev Resolves what the VENUE sees, which differs from what the caller pays only when wrapping
    /// is asked for. Both sides must still differ, or the two balance deltas would conflate.
    function _venueCurrencies(FillParams calldata p) private view returns (address venueIn, address venueOut) {
        venueIn = p.currencyIn;
        venueOut = p.currencyOut;
        if (p.wrapInput) {
            if (p.currencyIn != NATIVE) revert WrapMismatch();
            if (WNATIVE == address(0)) revert WrappedNativeNotSet();
            venueIn = WNATIVE;
        }
        if (p.unwrapOutput) {
            if (p.currencyOut != NATIVE) revert WrapMismatch();
            if (WNATIVE == address(0)) revert WrappedNativeNotSet();
            venueOut = WNATIVE;
        }
        if (venueIn == venueOut) revert IdenticalCurrencies(venueIn);
    }

    /// @dev What the caller actually parted with, measured. Native must arrive as exactly `amountIn`;
    /// an ERC-20 input must carry no value, or that value would be swept away as a "fee".
    function _pullFromPayer(address currency, uint256 amountIn) private returns (uint256 received) {
        if (currency == NATIVE) {
            if (msg.value != amountIn) revert UnexpectedValue(amountIn, msg.value);
            return amountIn;
        }
        if (msg.value != 0) revert UnexpectedValue(0, msg.value);
        uint256 before = IERC20(currency).balanceOf(address(this));
        IERC20(currency).safeTransferFrom(msg.sender, address(this), amountIn);
        return IERC20(currency).balanceOf(address(this)) - before;
    }

    /// @dev Hands the budget to the executor, lets it make the caller's venue call, and measures what
    /// came back. Nothing the venue or the executor RETURNS is used: only this contract's own balance
    /// deltas, which a resting fee balance cannot distort because a delta cancels it.
    function _runVenue(FillParams calldata p, address venueIn, address venueOut, uint256 budget)
        private
        returns (uint256 amountOut, uint256 spent)
    {
        address executor = address(EXECUTOR);

        // Wrap the venue's share only. The fee's share of a native input stays native, so DeepCore is
        // paid in the currency the caller actually handed over.
        if (p.wrapInput && budget != 0) IWrappedNative(WNATIVE).deposit{value: budget}();

        uint256 valueSent = 0;
        if (venueIn == NATIVE) {
            valueSent = budget;
        } else if (budget != 0) {
            IERC20(venueIn).safeTransfer(executor, budget);
        }

        uint256 inBefore = _balance(venueIn);
        uint256 outBefore = _balance(venueOut);

        EXECUTOR.execute{value: valueSent}(p.target, p.data, venueIn, venueOut);

        // `inBefore` was taken before the native value left with the call, so subtract it back out.
        uint256 unspent = _balance(venueIn) - (inBefore - valueSent);
        // A venue (or anyone it calls) can push extra `venueIn` here to make `unspent` exceed the
        // budget. Clamping keeps `spent` well defined instead of reverting on an underflow; the
        // excess stays behind as a donation to the protocol, flushable like any other stray.
        if (unspent > budget) unspent = budget;
        spent = budget - unspent;

        amountOut = _balance(venueOut) - outBefore;

        // Back to the caller's currencies. 1:1 both ways, so no amount is re-derived.
        if (p.unwrapOutput && amountOut != 0) IWrappedNative(WNATIVE).withdraw(amountOut);
        if (p.wrapInput && unspent != 0) IWrappedNative(WNATIVE).withdraw(unspent);
    }

    function _balance(address currency) private view returns (uint256) {
        return currency == NATIVE ? address(this).balance : IERC20(currency).balanceOf(address(this));
    }

    function _send(address currency, address to, uint256 amount) private {
        if (currency == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed(to, amount);
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    function _materialise() private {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) {
            uint16 next = _pendingFeeBps;
            emit FeeChanged(_feeBps, next);
            _feeBps = next;
            _pendingFeeBps = 0;
            _pendingFeeAt = 0;
        }
    }

    function _clearPending() private {
        uint64 at = _pendingFeeAt;
        if (at == 0) return;
        emit PendingFeeCancelled(_pendingFeeBps, at);
        _pendingFeeBps = 0;
        _pendingFeeAt = 0;
    }
}
