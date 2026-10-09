/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

/// @notice The payout shape every DeepCore revenue source shares: `DeepCoreLPLocker`, `DeepCoreBinLPLocker`, both launch
/// guards' creator tax (`LaunchTaxModule`) and `RevShareHook` each pay the CALLER's credit in `currency` to `to`.
interface IDeepCoreClaimSource {
    function claim(Currency currency, address to) external returns (uint256 amount);
}

/// @notice `LaunchpadKitV2`'s native fee credit (a tenant's integrator launch fee).
interface IDeepCoreKitFeeSource {
    function claimFees(address to) external returns (uint256 amount);
}

/// @notice Both lockers' two-step creator rotation, for a creator who hands a lock's creator share to a split.
interface IDeepCoreCreatorRole {
    function acceptCreator(uint256 lockId) external;
}

/// @title DeepCoreSplit - a team's revenue split, fixed at creation, paid by pull
/// @notice One EIP-1167 clone per split, made by `DeepCoreSplitFactory`. Anything that reaches the split - native
/// currency or any ERC-20, sent directly or pulled from a DeepCore revenue source with `collect` - is owed to its
/// payees in proportion to their weights, after the protocol share frozen into this split at creation.
///
/// HOW MUCH EACH PAYEE IS OWED. Per currency, `totalReceived = balance + totalReleased` counts every unit that
/// ever arrived, however it arrived, with no deposit hook to call. A payee slot is owed
/// `totalReceived * (10_000 - protocolShareBps) * weight / (10_000 * totalWeight)` minus what it was already
/// released; the protocol is owed `totalReceived * protocolShareBps / 10_000` minus its releases. Every term is
/// rounded down, so the sum of entitlements never exceeds `totalReceived`, and since nobody is ever paid more
/// than its entitlement, the balance always covers every unreleased entitlement. (This is OpenZeppelin's
/// PaymentSplitter idea, written again for currencies, slots and a protocol share.)
///
/// WHO CAN DO WHAT. Nobody owns a split. Payees and weights are fixed forever at creation; so is the protocol
/// share. Anyone may `release` a slot (the money always goes to that slot's payee, never to the caller), release
/// the protocol share (it always goes to the immutable recipient), `collect` from a source, or `releaseAll`. A
/// payee may additionally `releaseTo` its own share to another address (a payee a token blacklists can still
/// take delivery), hand its own slot to a new address two-step (`transferPayee` / `acceptPayee`: a lost or
/// rotated key), and have the split accept a lock's creator role (`acceptCreator`). There is no owner, no
/// pause, no upgrade, no setter, no way to change a weight, add or remove a payee, or move one payee's money to
/// another.
///
/// FUNDS CAN NEVER BE STUCK (CLAUDE.md acceptance bar). Native reaches the split through `receive` (any sender;
/// a sender that forwards only the 2,300-gas stipend cannot pay a clone, as with any proxy) or `selfdestruct`;
/// ERC-20 through a plain transfer or a source's `claim`. Whatever the path, it is inside `totalReceived` and
/// leaves through `release` / `releaseTo` / `releaseProtocol` / `releaseAll`. What cannot leave is rounding: at
/// most one unit per slot plus one for the protocol, per currency, until the next inflow makes it whole.
/// ERC-721 has no path in (`safeTransferFrom` reverts: no receiver hook); a plain `transferFrom` strands it,
/// as it would on any contract without a hook. Fee-on-transfer and negatively rebasing tokens are unsupported
/// (a balance that shrinks by itself leaves the last payees short), as everywhere in DeepCore.
///
/// WHY `collect` MAY CALL ANY ADDRESS. It calls `claim(currency, address(this))` with no value, and the split
/// holds no approvals and makes no other call, so a fake source can take nothing: at worst it wastes the
/// caller's gas or sends the split something. The shared `nonReentrant` lock covers every function that moves
/// money, so a source cannot re-enter a release mid-collect. `receive` is deliberately not locked: a real source
/// pays native into it from inside `collect`.
contract DeepCoreSplit is ReentrancyGuard, Multicall {
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything a reader needs to render the split. `labels` are display names chosen by the creator
    /// and are not stored.
    event SplitInitialized(
        address indexed creator,
        string name,
        address[] payees,
        uint96[] weights,
        string[] labels,
        uint16 protocolShareBps
    );
    event Collected(address indexed source, Currency indexed currency, uint256 amount);
    event Released(uint256 indexed slot, address indexed payee, Currency indexed currency, address to, uint256 amount);
    event ProtocolReleased(Currency indexed currency, address indexed to, uint256 amount);
    event PayeeTransferStarted(uint256 indexed slot, address indexed payee, address indexed newPayee);
    event PayeeTransferred(uint256 indexed slot, address indexed previousPayee, address indexed newPayee);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error InvalidName();
    error InvalidLabel(uint256 index);
    error NoPayees();
    error TooManyPayees(uint256 count);
    error LengthMismatch();
    error ZeroWeight(uint256 index);
    error DuplicatePayee(address payee);
    error SelfPayee();
    error ProtocolShareTooHigh(uint16 bps);
    error NotPayee(address account);
    error NoSuchSlot(uint256 slot);
    error NothingToRelease();
    error NotPendingPayee(address account);
    error TransferFailed(Currency currency, address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 100;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_LABEL_BYTES = 32;
    /// @notice Belt and braces: the factory's own immutable cap is at or below this.
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 500;

    /// @notice The only address that may initialize a clone.
    address public immutable FACTORY;
    /// @notice Where the protocol share is paid. The governance Safe. Part of the implementation's code.
    address public immutable PROTOCOL_RECIPIENT;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Slot {
        address payee;
        uint96 weight;
    }

    // slot 0 `_status` (ReentrancyGuard; a clone starts at 0, which the guard treats as not entered)
    bool private _initialized;
    uint16 public protocolShareBps;
    uint256 public totalWeight;
    string private _name;
    Slot[] private _slots;
    /// @dev payee => slot index + 1 (0 = not a payee).
    mapping(address => uint256) private _slotPlusOne;
    /// @dev slot => address that may accept the slot.
    mapping(uint256 => address) public pendingPayee;
    mapping(Currency => uint256) public totalReleased;
    mapping(Currency => mapping(uint256 => uint256)) public released;
    mapping(Currency => uint256) public protocolReleased;

    /// @param factory The factory that clones this implementation.
    /// @param protocolRecipient The governance Safe.
    /// @dev The implementation marks itself initialized, so it can never hold a split's state.
    constructor(address factory, address protocolRecipient) {
        if (factory == address(0) || protocolRecipient == address(0)) revert ZeroAddress();
        FACTORY = factory;
        PROTOCOL_RECIPIENT = protocolRecipient;
        _initialized = true;
    }

    /// @notice Called once by the factory in the same transaction as the clone.
    function initialize(
        address creator,
        string calldata name_,
        address[] calldata payees_,
        uint96[] calldata weights_,
        string[] calldata labels_,
        uint16 protocolShareBps_
    ) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        uint256 nameLength = bytes(name_).length;
        if (nameLength == 0 || nameLength > MAX_NAME_BYTES) revert InvalidName();
        uint256 count = payees_.length;
        if (count == 0) revert NoPayees();
        if (count > MAX_PAYEES) revert TooManyPayees(count);
        if (weights_.length != count || labels_.length != count) revert LengthMismatch();
        if (protocolShareBps_ > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareTooHigh(protocolShareBps_);

        uint256 total;
        for (uint256 i; i < count; ++i) {
            address payee = payees_[i];
            if (payee == address(0)) revert ZeroAddress();
            if (payee == address(this)) revert SelfPayee();
            if (_slotPlusOne[payee] != 0) revert DuplicatePayee(payee);
            if (weights_[i] == 0) revert ZeroWeight(i);
            if (bytes(labels_[i]).length > MAX_LABEL_BYTES) revert InvalidLabel(i);
            _slots.push(Slot(payee, weights_[i]));
            _slotPlusOne[payee] = i + 1;
            total += weights_[i];
        }
        totalWeight = total;
        protocolShareBps = protocolShareBps_;
        _name = name_;
        emit SplitInitialized(creator, name_, payees_, weights_, labels_, protocolShareBps_);
    }

    /// @notice Native currency is welcome from anyone; it is split like everything else.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                 COLLECT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull this split's credit in `currency` out of a DeepCore revenue source (a locker, a launch guard's
    /// creator tax, a `RevShareHook`). Permissionless. Reverts with the source's own error when nothing is owed.
    /// @return amount What arrived, measured on this split's balance.
    function collect(address source, Currency currency) external nonReentrant returns (uint256 amount) {
        uint256 before = currency.balanceOfSelf();
        IDeepCoreClaimSource(source).claim(currency, address(this));
        amount = currency.balanceOfSelf() - before;
        emit Collected(source, currency, amount);
    }

    /// @notice Pull this split's native fee credit out of a `LaunchpadKitV2` (a tenant's integrator launch fee).
    function collectKitFees(address kit) external nonReentrant returns (uint256 amount) {
        Currency native = CurrencyLibrary.NATIVE;
        uint256 before = native.balanceOfSelf();
        IDeepCoreKitFeeSource(kit).claimFees(address(this));
        amount = native.balanceOfSelf() - before;
        emit Collected(kit, native, amount);
    }

    /// @notice Accept a lock's creator role that its creator handed to this split (`transferCreator` on a
    /// locker). Payees only: accepting commits the split for good, since a split can never hand the role on.
    function acceptCreator(address locker, uint256 lockId) external nonReentrant {
        if (_slotPlusOne[msg.sender] == 0) revert NotPayee(msg.sender);
        IDeepCoreCreatorRole(locker).acceptCreator(lockId);
    }

    /*//////////////////////////////////////////////////////////////
                                 RELEASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay `slot` everything it is owed in `currency`. Permissionless; always pays the slot's payee.
    function release(uint256 slot, Currency currency) external nonReentrant returns (uint256 amount) {
        if (slot >= _slots.length) revert NoSuchSlot(slot);
        amount = _book(slot, currency);
        address payee = _slots[slot].payee;
        emit Released(slot, payee, currency, payee, amount);
        _pay(currency, payee, amount);
    }

    /// @notice The caller's own share in `currency`, paid to `to`.
    function releaseTo(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 plusOne = _slotPlusOne[msg.sender];
        if (plusOne == 0) revert NotPayee(msg.sender);
        uint256 slot = plusOne - 1;
        amount = _book(slot, currency);
        emit Released(slot, msg.sender, currency, to, amount);
        _pay(currency, to, amount);
    }

    /// @notice Pay the protocol share owed in `currency` to the immutable recipient. Permissionless.
    function releaseProtocol(Currency currency) external nonReentrant returns (uint256 amount) {
        amount = _protocolReleasable(currency, _totalReceived(currency));
        if (amount == 0) revert NothingToRelease();
        protocolReleased[currency] += amount;
        totalReleased[currency] += amount;
        emit ProtocolReleased(currency, PROTOCOL_RECIPIENT, amount);
        _pay(currency, PROTOCOL_RECIPIENT, amount);
    }

    /// @notice Pay every slot and the protocol what they are owed in `currency`. Permissionless.
    /// @dev A payee whose transfer fails (a contract that rejects native, an address a token blacklists) is
    /// skipped and keeps its entitlement - it can still `releaseTo` elsewhere - so one bad payee never blocks
    /// the others. Entitlements are all measured against the `totalReceived` read once at the start.
    /// @return paid The total transferred.
    function releaseAll(Currency currency) external nonReentrant returns (uint256 paid) {
        uint256 received = _totalReceived(currency);
        uint256 count = _slots.length;
        for (uint256 i; i < count; ++i) {
            uint256 amount = _slotReleasable(i, currency, received);
            if (amount == 0) continue;
            address payee = _slots[i].payee;
            released[currency][i] += amount;
            totalReleased[currency] += amount;
            if (_tryPay(currency, payee, amount, BATCH_NATIVE_GAS)) {
                paid += amount;
                emit Released(i, payee, currency, payee, amount);
            } else {
                released[currency][i] -= amount;
                totalReleased[currency] -= amount;
            }
        }
        uint256 toProtocol = _protocolReleasable(currency, received);
        if (toProtocol != 0) {
            protocolReleased[currency] += toProtocol;
            totalReleased[currency] += toProtocol;
            if (_tryPay(currency, PROTOCOL_RECIPIENT, toProtocol, BATCH_NATIVE_GAS)) {
                paid += toProtocol;
                emit ProtocolReleased(currency, PROTOCOL_RECIPIENT, toProtocol);
            } else {
                protocolReleased[currency] -= toProtocol;
                totalReleased[currency] -= toProtocol;
            }
        }
        if (paid == 0) revert NothingToRelease();
    }

    /*//////////////////////////////////////////////////////////////
                             PAYEE ROTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Offer the caller's own slot - weight and every unreleased unit - to `newPayee`, who must accept.
    /// `address(0)` withdraws the offer.
    function transferPayee(address newPayee) external nonReentrant {
        uint256 plusOne = _slotPlusOne[msg.sender];
        if (plusOne == 0) revert NotPayee(msg.sender);
        if (newPayee == address(this)) revert SelfPayee();
        uint256 slot = plusOne - 1;
        pendingPayee[slot] = newPayee;
        emit PayeeTransferStarted(slot, msg.sender, newPayee);
    }

    /// @notice Take over `slot`, offered to the caller. The caller may not already hold a slot.
    function acceptPayee(uint256 slot) external nonReentrant {
        if (slot >= _slots.length) revert NoSuchSlot(slot);
        if (msg.sender == address(0) || pendingPayee[slot] != msg.sender) revert NotPendingPayee(msg.sender);
        if (_slotPlusOne[msg.sender] != 0) revert DuplicatePayee(msg.sender);
        address previous = _slots[slot].payee;
        delete pendingPayee[slot];
        delete _slotPlusOne[previous];
        _slotPlusOne[msg.sender] = slot + 1;
        _slots[slot].payee = msg.sender;
        emit PayeeTransferred(slot, previous, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function name() external view returns (string memory) {
        return _name;
    }

    function payeeCount() external view returns (uint256) {
        return _slots.length;
    }

    function slotAt(uint256 slot) external view returns (address payee, uint96 weight) {
        if (slot >= _slots.length) revert NoSuchSlot(slot);
        Slot memory s = _slots[slot];
        return (s.payee, s.weight);
    }

    /// @notice Every payee and weight, slot order.
    function payees() external view returns (address[] memory accounts, uint96[] memory weights) {
        uint256 count = _slots.length;
        accounts = new address[](count);
        weights = new uint96[](count);
        for (uint256 i; i < count; ++i) {
            accounts[i] = _slots[i].payee;
            weights[i] = _slots[i].weight;
        }
    }

    /// @notice `(true, slot)` for a current payee, `(false, 0)` otherwise.
    function slotOf(address account) external view returns (bool isPayee, uint256 slot) {
        uint256 plusOne = _slotPlusOne[account];
        if (plusOne == 0) return (false, 0);
        return (true, plusOne - 1);
    }

    /// @notice Every unit of `currency` that ever reached this split.
    function totalReceived(Currency currency) external view returns (uint256) {
        return _totalReceived(currency);
    }

    function releasable(uint256 slot, Currency currency) external view returns (uint256) {
        if (slot >= _slots.length) revert NoSuchSlot(slot);
        return _slotReleasable(slot, currency, _totalReceived(currency));
    }

    function protocolReleasable(Currency currency) external view returns (uint256) {
        return _protocolReleasable(currency, _totalReceived(currency));
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _totalReceived(Currency currency) private view returns (uint256) {
        return currency.balanceOfSelf() + totalReleased[currency];
    }

    function _slotReleasable(uint256 slot, Currency currency, uint256 received) private view returns (uint256) {
        uint256 entitled =
            Math.mulDiv(received, (BPS - protocolShareBps) * _slots[slot].weight, BPS * totalWeight);
        uint256 done = released[currency][slot];
        return entitled > done ? entitled - done : 0;
    }

    function _protocolReleasable(Currency currency, uint256 received) private view returns (uint256) {
        uint256 entitled = Math.mulDiv(received, protocolShareBps, BPS);
        uint256 done = protocolReleased[currency];
        return entitled > done ? entitled - done : 0;
    }

    /// @dev Effects for a single-slot release. Reverts when nothing is owed.
    function _book(uint256 slot, Currency currency) private returns (uint256 amount) {
        amount = _slotReleasable(slot, currency, _totalReceived(currency));
        if (amount == 0) revert NothingToRelease();
        released[currency][slot] += amount;
        totalReleased[currency] += amount;
    }

    /// @dev Gas forwarded to EACH native recipient inside `releaseAll` (audit C-3, 2026-10-07). With all gas
    /// forwarded, one payee whose `receive` burns everything it is given kept 63/64 of the batch's gas and
    /// the payees after it could not be paid: the whole call reverted, every time. 100,000 is far more than
    /// a wallet, a Safe or a forwarding contract needs to receive native; a recipient that needs more is
    /// skipped here exactly like one that refuses (its share stays its own) and is paid by `release` /
    /// `releaseTo`, which forward all gas.
    uint256 internal constant BATCH_NATIVE_GAS = 100_000;

    function _pay(Currency currency, address to, uint256 amount) private {
        if (!_tryPay(currency, to, amount, 0)) revert TransferFailed(currency, to, amount);
    }

    /// @dev Native: a plain call, with all gas when `nativeGas` is 0 and with at most `nativeGas` otherwise.
    /// ERC-20: `transfer`, success = no revert and (no return data or `true`), the SafeERC20 rule, returned
    /// instead of reverting so `releaseAll` can skip one payee.
    function _tryPay(Currency currency, address to, uint256 amount, uint256 nativeGas) private returns (bool ok) {
        if (currency.isNative()) {
            if (nativeGas == 0) (ok,) = to.call{value: amount}("");
            else (ok,) = to.call{value: amount, gas: nativeGas}("");
            return ok;
        }
        address token = Currency.unwrap(currency);
        if (token.code.length == 0) return false;
        bytes memory data;
        (ok, data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        return ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
    }
}
