/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILaunchpadKitV2, TenantConfig} from "../interfaces/ILaunchpadKitV2.sol";
import {DeepCorePad} from "./DeepCorePad.sol";

/// @title DeepCorePadFactory - "launch a launchpad": one transaction, one flat site fee, one address on every chain
/// @notice Clones a `DeepCorePad` (EIP-1167) per caller and makes it a `LaunchpadKitV2` tenant in the same
/// transaction. Anyone may create a pad. The implementation is deployed here, bound to this factory and to
/// one kit forever.
///
/// ONE LAUNCHPAD, THE SAME ADDRESS ON EVERY CHAIN (owner decision 2026-09-19: "created DEXes and Launchpads
/// are multi-chain"; the developer picks the chains and pays the site fee on each). Multi-chain by
/// deployment, never by bridging: nothing here talks to another chain. The address is the same because
/// every input to it is:
///   * the pad is a CREATE2 clone at `keccak256(abi.encode(creator, userSalt))` (`padSalt`), so its
///     address is `f(factory, padSalt, clone init code)`, and the clone init code embeds only
///     `IMPLEMENTATION`;
///   * `IMPLEMENTATION` is the factory's first CREATE (nonce 1) in this constructor, so it is
///     `f(factory)` alone - the same wherever the factory address is the same, whatever `KIT` it embeds;
///   * the factory itself is deployed through CreateX's CREATE3 (`deployCreate3`) with a salt that
///     PERMISSIONS the deployer (first 20 bytes = the deployer, byte 21 = 0x00: no chain id), so its
///     address depends only on (CreateX, deployer, salt) - never on the constructor arguments, which differ
///     per chain (kit, fee, cap, recipient, notice). `script/DeployDeepCorePadFactory.s.sol` asserts it.
/// The creator is bound INTO the salt, so nobody can squat another developer's address on a chain the
/// developer has not reached yet: the same `userSalt` from any other sender lands somewhere else. Only
/// the original creator (the address that called `createPad`, not a later owner of the pad) can extend a
/// pad to a new chain; `padOrigin(pad)` returns the `(creator, userSalt)` to do it with. Each chain's copy
/// is its own contract with its own owner, brand and tenant terms, written on that chain.
///
/// THE SITE FEE (owner decision 2026-09-18: a flat, per-chain fee for a hosted launchpad or DEX, paid to
/// the governance Safe as a spam filter). The mechanism is the kit's launch fee, copied rather than
/// re-invented, so an operator who understands one understands both:
///   * `padFeeWei()` is what a `createPad` in THIS block pays; `msg.value` below it reverts; the excess is
///     refunded to `msg.sender`, last, in the same call.
///   * The owner (the Safe; `Ownable2Step`, `renounceOwnership` reverts) may set it inside the immutable
///     `maxPadFeeWei`. A decrease applies at once. An increase is announced and takes effect by itself
///     `padFeeNoticeSeconds` later; a new increase restarts the notice; `cancelPendingPadFee` withdraws it.
///     Nothing is retroactive: a pad pays what was in force in its block.
///   * The fee is PULL-credited (`protocolFeesOwed`), never pushed inside `createPad`: a recipient that
///     cannot receive native currency cannot block anybody's site. `flushProtocolFees` is permissionless
///     and can only ever pay the immutable `protocolFeeRecipient`.
///   * The contract stores wei. "$10" is an off-chain conversion the Safe makes when it sets the value.
///
/// WHAT THE OWNER CANNOT DO, stated because the previous factory had no owner and the reason was "an owner
/// could only gate who may run a launchpad". This owner still cannot: there is no allowlist, no pause, no
/// per-creator anything, and `createPad` has no owner branch - the owner pays the same fee as anyone. It
/// cannot reach a pad (the pad's owner is its creator; `initialize` is callable once, by this factory,
/// inside `createPad`), a pad's terms (written on the kit under the pad's address, by the pad), the kit,
/// or a creator's funds (the only value here is the fee already paid, which leaves to the Safe alone).
/// Its powers are exactly: `setPadFee` inside the cap, `cancelPendingPadFee`, `rescueERC20`
/// (misdirected tokens only; the factory never holds a token by design), and `transferOwnership`.
///
/// FUNDS CAN NEVER BE STUCK (CLAUDE.md acceptance bar). Native reaches the factory by ONE path,
/// `createPad`'s `msg.value` (no `receive`, no `fallback`), and every wei of it is either credited to
/// `protocolFeesOwed` or refunded in the same call. `flushProtocolFees` sends the factory's WHOLE balance
/// to `protocolFeeRecipient`, so even native forced in by `selfdestruct` leaves by the same door: nothing
/// else is ever owed to anyone from this balance. A misdirected ERC-20 leaves through `rescueERC20`.
/// Nothing else can be here: the factory holds no pad, no share, no claim.
///
/// What a pad gives a tenant that a raw wallet does not: a transferable identity (every launch names the
/// pad, and the pad changes hands two-step), an on-chain name and brand pointer (`metadataURI`), and a
/// directory (`PadCreated`, `padCount` / `padAt`). What it does NOT give: custody of anything. Fees are
/// credited by the kit and the lockers to the integrator wallet the owner names, never to the pad.
contract DeepCorePadFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unchanged from the fee-less factory: every reader of the directory keeps working.
    event PadCreated(address indexed pad, address indexed owner, string name);
    /// @notice The site fee a pad paid at creation. Not emitted when the fee in force was zero.
    event PadFeePaid(address indexed pad, address indexed payer, uint256 feeWei);
    /// @notice The fee in force changed: a decrease, or an increase whose notice elapsed.
    event PadFeeChanged(uint256 previousWei, uint256 newWei);
    event PadFeeIncreaseScheduled(uint256 currentWei, uint256 newWei, uint64 effectiveAt);
    event PendingPadFeeCancelled(uint256 cancelledWei, uint64 effectiveAt);
    /// @notice The factory's balance went to the immutable recipient. `owed` is what `createPad` had credited.
    event ProtocolFeesFlushed(address indexed to, uint256 amount, uint256 owed);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Where a pad came from: the creator and the salt it chose. The same pair on another chain's
    /// factory (same address) creates the same pad address there. Emitted beside `PadCreated`, whose
    /// signature is unchanged so existing directory readers keep working.
    event PadOriginRecorded(address indexed pad, address indexed creator, bytes32 indexed userSalt);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidNotice(uint32 noticeSeconds);
    error PadFeeAboveCap(uint256 feeWei, uint256 capWei);
    error InsufficientPadFee(uint256 required, uint256 sent);
    error NoPendingPadFee();
    error NothingToFlush();
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceDisabled();
    error NothingToRescue(address token);
    /// @notice This creator already used this salt on this chain. Pick another salt for another pad.
    error PadAlreadyExists(address pad);

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Bounds on `padFeeNoticeSeconds`, the kit's (`LaunchpadKitV2.MIN_FEE_NOTICE_SECONDS`).
    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;

    ILaunchpadKitV2 public immutable KIT;
    DeepCorePad public immutable IMPLEMENTATION;
    /// @notice The governance Safe. The only address `flushProtocolFees` can pay.
    address public immutable protocolFeeRecipient;
    /// @notice The owner can never set a fee above this.
    uint256 public immutable maxPadFeeWei;
    /// @notice How long an announced increase waits before it is the fee.
    uint32 public immutable padFeeNoticeSeconds;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    // slot 0 `_owner` (Ownable), slot 1 `_pendingOwner` (Ownable2Step), slot 2 `_status` (ReentrancyGuard)
    uint256 private _padFeeWei; // slot 3
    uint256 private _pendingPadFeeWei; // slot 4
    uint64 private _pendingPadFeeEffectiveAt; // slot 5
    /// @notice Site fees credited by `createPad` and not yet flushed. Never more than the balance.
    uint256 public protocolFeesOwed; // slot 6

    address[] private _pads; // slot 7
    mapping(address => bool) public isPad; // slot 8

    struct PadOrigin {
        address creator;
        bytes32 userSalt;
    }

    mapping(address => PadOrigin) private _padOrigin; // slot 9

    /// @param kit The one kit every pad this factory makes is a tenant of.
    /// @param owner_ The governance Safe. Fee only.
    /// @param protocolFeeRecipient_ Where flushed fees go. The Safe. Immutable.
    /// @param initialPadFeeWei The fee in force from birth (`<= maxPadFeeWei_`; zero is allowed).
    /// @param maxPadFeeWei_ The immutable cap. The deploy script refuses zero (a fee that could never be charged).
    /// @param padFeeNoticeSeconds_ Notice on increases, `MIN_FEE_NOTICE_SECONDS..MAX_FEE_NOTICE_SECONDS`.
    constructor(
        ILaunchpadKitV2 kit,
        address owner_,
        address protocolFeeRecipient_,
        uint256 initialPadFeeWei,
        uint256 maxPadFeeWei_,
        uint32 padFeeNoticeSeconds_
    ) Ownable(owner_) {
        if (address(kit) == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (padFeeNoticeSeconds_ < MIN_FEE_NOTICE_SECONDS || padFeeNoticeSeconds_ > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(padFeeNoticeSeconds_);
        }
        if (initialPadFeeWei > maxPadFeeWei_) revert PadFeeAboveCap(initialPadFeeWei, maxPadFeeWei_);
        KIT = kit;
        IMPLEMENTATION = new DeepCorePad(kit, address(this));
        protocolFeeRecipient = protocolFeeRecipient_;
        maxPadFeeWei = maxPadFeeWei_;
        padFeeNoticeSeconds = padFeeNoticeSeconds_;
        _padFeeWei = initialPadFeeWei;
        emit PadFeeChanged(0, initialPadFeeWei);
    }

    /*//////////////////////////////////////////////////////////////
                                CREATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a pad owned by the caller and configures it as a kit tenant. Pays the site fee.
    /// @dev Checks, effects, interactions: the fee is checked and credited, the pad is cloned, initialized
    /// and listed, and only then is the surplus refunded. `nonReentrant` is shared with `flushProtocolFees`:
    /// a creator contract that re-enters either from its `receive` makes the refund fail, and with it the
    /// whole create (`NativeTransferFailed`). Nothing is left half-done. Send the exact fee, or receive quietly.
    ///
    /// The pad lands at `predictPad(msg.sender, userSalt)`, on this chain and on every chain whose factory
    /// shares this factory's address. The owner is `msg.sender`, always. There is deliberately no "create
    /// for someone else" form: the address is bound to the key that SENDS, and a separate owner argument
    /// would only add a way to confuse the two. A pad changes hands afterwards with `transferOwnership`.
    /// @param userSalt Any 32 bytes the creator picks. The same value on every chain gives the same address;
    /// a second pad on one chain needs a different value (`PadAlreadyExists` otherwise).
    /// @param name_ 1 to 40 bytes. Shown in the directory; the brand lives in `metadataURI_`.
    /// @param metadataURI_ The brand: a `data:application/json...` URI, `ipfs://`, or `https://`. May be empty.
    /// @param config The tenant config the kit stores for the pad. `config.integrator` is where the pad's
    /// launch fees and locked-LP fee shares are paid; it may not be the pad. The kit validates the caps.
    /// @param allowedQuotes Quotes allowed from birth (only consulted when `config.restrictQuotes`).
    function createPad(
        bytes32 userSalt,
        string calldata name_,
        string calldata metadataURI_,
        TenantConfig calldata config,
        address[] calldata allowedQuotes
    ) external payable nonReentrant returns (address pad) {
        uint256 fee = padFeeWei();
        if (msg.value < fee) revert InsufficientPadFee(fee, msg.value);

        bytes32 salt = padSalt(msg.sender, userSalt);
        address predicted = Clones.predictDeterministicAddress(address(IMPLEMENTATION), salt, address(this));
        // Only this factory can put code at a predicted address, and every pad it makes is listed in the same
        // call, so `isPad` is the whole collision check: a named error instead of CREATE2's anonymous failure.
        if (isPad[predicted]) revert PadAlreadyExists(predicted);

        pad = Clones.cloneDeterministic(address(IMPLEMENTATION), salt);
        DeepCorePad(pad).initialize(msg.sender, name_, metadataURI_, config, allowedQuotes);
        _pads.push(pad);
        isPad[pad] = true;
        _padOrigin[pad] = PadOrigin({creator: msg.sender, userSalt: userSalt});
        emit PadCreated(pad, msg.sender, name_);
        emit PadOriginRecorded(pad, msg.sender, userSalt);

        if (fee != 0) {
            protocolFeesOwed += fee;
            emit PadFeePaid(pad, msg.sender, fee);
        }
        if (msg.value > fee) _sendNative(msg.sender, msg.value - fee);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The CREATE2 salt a pad by `creator` with `userSalt` is cloned at. Binds the creator: no two
    /// senders can reach the same salt, so nobody can take another developer's address on any chain.
    function padSalt(address creator, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(creator, userSalt));
    }

    /// @notice The address `createPad(userSalt, ...)` sent by `creator` gives - here, and on every chain whose
    /// factory has this factory's address. Whether it exists yet on this chain is `isPad(predicted)`.
    function predictPad(address creator, bytes32 userSalt) external view returns (address) {
        return Clones.predictDeterministicAddress(address(IMPLEMENTATION), padSalt(creator, userSalt), address(this));
    }

    /// @notice The creator and salt a pad of this factory was made with; `(0, 0)` for anything else. The
    /// creator sends `createPad` with this salt on another chain to open the same pad address there.
    function padOrigin(address pad) external view returns (address creator, bytes32 userSalt) {
        PadOrigin storage o = _padOrigin[pad];
        return (o.creator, o.userSalt);
    }

    function padCount() external view returns (uint256) {
        return _pads.length;
    }

    function padAt(uint256 index) external view returns (address) {
        return _pads[index];
    }

    /// @notice A page of pads, creation order. `end` is exclusive and clamped.
    function pads(uint256 start, uint256 end) external view returns (address[] memory page) {
        uint256 length = _pads.length;
        if (end > length) end = length;
        if (start >= end) return page;
        page = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = _pads[i];
        }
    }

    /// @notice The site fee a `createPad` in THIS block pays.
    function padFeeWei() public view returns (uint256) {
        uint64 at = _pendingPadFeeEffectiveAt;
        if (at != 0 && block.timestamp >= at) return _pendingPadFeeWei;
        return _padFeeWei;
    }

    /// @notice An announced increase that has not taken effect yet. `(0, 0)` when there is none.
    function pendingPadFee() external view returns (uint256 feeWei, uint64 effectiveAt) {
        effectiveAt = _pendingPadFeeEffectiveAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        feeWei = _pendingPadFeeWei;
    }

    /*//////////////////////////////////////////////////////////////
                            SITE FEE (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner's only power. `<=` the fee in force applies now and cancels any pending increase;
    /// `>` it is announced and takes effect `padFeeNoticeSeconds` later, by itself. A new increase
    /// replaces a pending one and restarts the notice, so no announcement can ever shorten the wait.
    function setPadFee(uint256 newFeeWei) external onlyOwner {
        if (newFeeWei > maxPadFeeWei) revert PadFeeAboveCap(newFeeWei, maxPadFeeWei);
        _materialisePadFee();
        uint256 current = _padFeeWei;
        if (newFeeWei <= current) {
            _clearPending();
            _padFeeWei = newFeeWei;
            emit PadFeeChanged(current, newFeeWei);
        } else {
            uint64 effectiveAt = uint64(block.timestamp) + padFeeNoticeSeconds;
            _pendingPadFeeWei = newFeeWei;
            _pendingPadFeeEffectiveAt = effectiveAt;
            emit PadFeeIncreaseScheduled(current, newFeeWei, effectiveAt);
        }
    }

    /// @notice Withdraws an announced increase that has not taken effect. One that has is the fee already.
    function cancelPendingPadFee() external onlyOwner {
        _materialisePadFee();
        if (_pendingPadFeeEffectiveAt == 0) revert NoPendingPadFee();
        _clearPending();
    }

    /// @notice Disabled. An owner that could renounce would freeze the fee at its current level forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent to the factory by mistake to `to`. Owner only.
    /// @dev The factory never holds a token by design - nothing here takes one - so any balance is
    /// misdirection with, otherwise, no path out. This cannot reach a pad, a launch, a lock or a credit:
    /// none of those is ever an ERC-20 balance of the factory.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               FLUSH
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless: sends the factory's whole native balance to the immutable
    /// `protocolFeeRecipient`. The balance is the credited site fees plus anything forced in, and nobody
    /// but the recipient is ever owed any of it, so the whole of it goes.
    function flushProtocolFees() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToFlush();
        uint256 owed = protocolFeesOwed;
        protocolFeesOwed = 0;
        emit ProtocolFeesFlushed(protocolFeeRecipient, amount, owed);
        _sendNative(protocolFeeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _materialisePadFee() private {
        uint64 at = _pendingPadFeeEffectiveAt;
        if (at != 0 && block.timestamp >= at) {
            uint256 next = _pendingPadFeeWei;
            emit PadFeeChanged(_padFeeWei, next);
            _padFeeWei = next;
            _pendingPadFeeWei = 0;
            _pendingPadFeeEffectiveAt = 0;
        }
    }

    function _clearPending() private {
        uint64 at = _pendingPadFeeEffectiveAt;
        if (at == 0) return;
        emit PendingPadFeeCancelled(_pendingPadFeeWei, at);
        _pendingPadFeeWei = 0;
        _pendingPadFeeEffectiveAt = 0;
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }
}
