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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

import {DeepCoreFeeGate} from "../fees/DeepCoreFeeGate.sol";

/// @title DeepCoreTokenLock - time-locks and vesting for any ERC-20 or native, with no way out early
/// @notice Team, treasury and investor allocations, locked in public: a lock holds `amount` of a currency for a
/// beneficiary and releases it on a fixed schedule - nothing before `cliff`, linearly from `start` to `end`
/// after that (a plain time-lock is `start == cliff == end`). The schedule is fixed at creation: no owner, no
/// admin and no key can shorten it, revoke it, or move a unit anywhere but to the beneficiary's chosen address.
///
/// VESTED(t) = 0 if t < cliff; amount if t >= end; otherwise amount * (t - start) / (end - start), rounded
/// down, so what is claimable never exceeds what is vested and the last unit always vests at `end`.
///
/// OWNERSHIP AND FEES. The contract owner (the governance Safe) controls the flat lock fee (`DeepCoreFeeGate`) and
/// can rescue only SURPLUS - tokens above what every lock is still owed (`totalHeld`). It cannot touch a lock.
/// The beneficiary rotates two-step and can have the release paid to any address.
///
/// FUNDS CAN NEVER BE STUCK. A lock's amount enters through `lock` (ERC-20 by `transferFrom`, credited as the
/// balance delta, so a fee-on-transfer token locks what actually arrived; native as part of `msg.value`) and
/// leaves only through `claim` (the beneficiary, to any address) or `release` (anyone, to the beneficiary), in
/// full by `end`. The fee (native) leaves through the permissionless
/// `flushProtocolFees`, which never touches native held for locks. Tokens sent here outside a lock leave
/// through `rescueSurplus`. A token that shrinks balances by itself (negative rebase, a burn by its issuer)
/// makes the last claims short; that is the token's behaviour and is isolated to that token.
contract DeepCoreTokenLock is DeepCoreFeeGate {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    struct TokenLock {
        Currency currency;
        address beneficiary;
        uint48 start;
        uint48 cliff;
        uint48 end;
        address pendingBeneficiary;
        uint256 amount;
        uint256 claimed;
        address creator;
    }

    event Locked(
        uint256 indexed lockId,
        Currency indexed currency,
        address indexed beneficiary,
        uint256 amount,
        uint48 start,
        uint48 cliff,
        uint48 end,
        address creator
    );
    event Claimed(uint256 indexed lockId, address indexed beneficiary, address to, uint256 amount);
    event BeneficiaryTransferStarted(uint256 indexed lockId, address indexed beneficiary, address indexed newBeneficiary);
    event BeneficiaryTransferred(uint256 indexed lockId, address indexed previous, address indexed newBeneficiary);
    event SurplusRescued(Currency indexed currency, address indexed to, uint256 amount);

    error InvalidBeneficiary(address beneficiary);
    error InvalidSchedule(uint48 start, uint48 cliff, uint48 end);
    error ZeroAmount();
    error NativeValueMismatch(uint256 expected, uint256 sent);
    error NoSuchLock(uint256 lockId);
    error NotBeneficiary(uint256 lockId, address caller);
    error NotPendingBeneficiary(uint256 lockId, address caller);
    error NothingToClaim(uint256 lockId);
    error NothingToRescue(Currency currency);
    /// @notice `release` by a third party to a contract beneficiary that is not a vouched `DeepCoreSplit`.
    error ReleaseNotAllowed(uint256 lockId, address beneficiary);

    uint256 public constant MAX_LOCK_SECONDS = 100 * 365 days;

    TokenLock[] private _locks;
    mapping(Currency => uint256[]) private _lockIdsByCurrency;
    mapping(address => uint256[]) private _lockIdsByBeneficiary;
    /// @notice Per currency: what every lock is still owed (amount - claimed, summed). Never above the balance
    /// for a well-behaved token.
    mapping(Currency => uint256) public totalHeld;

    constructor(address owner_, address protocolFeeRecipient_, uint256 initialFeeWei, uint256 maxFeeWei_, uint32 noticeSeconds_)
        DeepCoreFeeGate(owner_, protocolFeeRecipient_, initialFeeWei, maxFeeWei_, noticeSeconds_)
    {}

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock `amount` of `currency` for `beneficiary` on the schedule given. ERC-20: approve first; the
    /// credited amount is what arrives. Native: `msg.value` must be `amount` plus at least the fee.
    /// @return lockId The new lock's id (its index; ids are never reused).
    function lock(Currency currency, uint256 amount, address beneficiary, uint48 start, uint48 cliff, uint48 end)
        external
        payable
        nonReentrant
        returns (uint256 lockId)
    {
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary(beneficiary);
        if (amount == 0) revert ZeroAmount();
        if (!(start <= cliff && cliff <= end) || end <= block.timestamp || end > block.timestamp + MAX_LOCK_SECONDS) {
            revert InvalidSchedule(start, cliff, end);
        }

        uint256 feeValue = msg.value;
        uint256 credited = amount;
        if (currency.isNative()) {
            if (msg.value < amount) revert NativeValueMismatch(amount, msg.value);
            feeValue = msg.value - amount;
        } else {
            uint256 before = currency.balanceOfSelf();
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
            credited = currency.balanceOfSelf() - before;
            if (credited == 0) revert ZeroAmount();
        }
        uint256 surplus = _takeFee(feeValue);

        lockId = _locks.length;
        _locks.push(
            TokenLock({
                currency: currency,
                beneficiary: beneficiary,
                start: start,
                cliff: cliff,
                end: end,
                pendingBeneficiary: address(0),
                amount: credited,
                claimed: 0,
                creator: msg.sender
            })
        );
        _lockIdsByCurrency[currency].push(lockId);
        _lockIdsByBeneficiary[beneficiary].push(lockId);
        totalHeld[currency] += credited;
        emit Locked(lockId, currency, beneficiary, credited, start, cliff, end, msg.sender);

        if (surplus != 0) _sendNative(msg.sender, surplus);
    }

    /// @notice Pay the beneficiary everything vested and not yet claimed, to `to`.
    function claim(uint256 lockId, address to) external nonReentrant returns (uint256 amount) {
        TokenLock storage l = _get(lockId);
        if (msg.sender != l.beneficiary) revert NotBeneficiary(lockId, msg.sender);
        if (to == address(0)) revert ZeroAddress();
        amount = _pay(l, lockId, to);
    }

    /// @notice Pay everything vested and unclaimed to the lock's CURRENT beneficiary, and only to it. Anyone may
    /// call it when the beneficiary can use what it receives: an account with no code, or a `DeepCoreSplit` its own
    /// factory vouches for (whose payees are paid from its balance - the reason this exists). For any other
    /// contract only the beneficiary itself may call it, because such a contract may be able to `claim` to
    /// another address but not to move tokens it holds, and a stranger must never be able to strand them there.
    function release(uint256 lockId) external nonReentrant returns (uint256 amount) {
        TokenLock storage l = _get(lockId);
        address b = l.beneficiary;
        if (msg.sender != b && b.code.length != 0 && !_isVouchedSplit(b)) revert ReleaseNotAllowed(lockId, b);
        amount = _pay(l, lockId, b);
    }

    /// @dev `b.FACTORY().isSplit(b)`, failing closed on anything unexpected. A contract that fakes both answers
    /// only opts ITSELF in to receiving its own vested tokens, so faking buys nothing.
    function _isVouchedSplit(address b) private view returns (bool) {
        (bool ok, bytes memory ret) = b.staticcall(abi.encodeWithSignature("FACTORY()"));
        if (!ok || ret.length != 32) return false;
        address factory = abi.decode(ret, (address));
        if (factory.code.length == 0) return false;
        (ok, ret) = factory.staticcall(abi.encodeWithSignature("isSplit(address)", b));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function _pay(TokenLock storage l, uint256 lockId, address to) private returns (uint256 amount) {
        amount = _unclaimed(l, block.timestamp);
        if (amount == 0) revert NothingToClaim(lockId);
        l.claimed += amount;
        totalHeld[l.currency] -= amount;
        emit Claimed(lockId, l.beneficiary, to, amount);
        l.currency.transfer(to, amount);
    }

    function transferBeneficiary(uint256 lockId, address newBeneficiary) external nonReentrant {
        TokenLock storage l = _get(lockId);
        if (msg.sender != l.beneficiary) revert NotBeneficiary(lockId, msg.sender);
        if (newBeneficiary == address(this)) revert InvalidBeneficiary(newBeneficiary);
        l.pendingBeneficiary = newBeneficiary;
        emit BeneficiaryTransferStarted(lockId, msg.sender, newBeneficiary);
    }

    function acceptBeneficiary(uint256 lockId) external nonReentrant {
        TokenLock storage l = _get(lockId);
        if (msg.sender == address(0) || msg.sender != l.pendingBeneficiary) revert NotPendingBeneficiary(lockId, msg.sender);
        emit BeneficiaryTransferred(lockId, l.beneficiary, msg.sender);
        l.beneficiary = msg.sender;
        l.pendingBeneficiary = address(0);
        _lockIdsByBeneficiary[msg.sender].push(lockId);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNER (THE SAFE) - RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Tokens above what every lock is owed (sent here outside `lock`) go to `to`. Never a unit of a
    /// lock. Native surplus is fee and leaves through `flushProtocolFees`, so this takes ERC-20 only.
    function rescueSurplus(Currency currency, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        if (currency.isNative()) revert NothingToRescue(currency);
        uint256 balance = currency.balanceOfSelf();
        uint256 held = totalHeld[currency];
        if (balance <= held) revert NothingToRescue(currency);
        amount = balance - held;
        emit SurplusRescued(currency, to, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function getLock(uint256 lockId) external view returns (TokenLock memory) {
        return _get(lockId);
    }

    function vestedAt(uint256 lockId, uint256 timestamp) external view returns (uint256) {
        return _vested(_get(lockId), timestamp);
    }

    /// @notice What the beneficiary can claim now.
    function claimable(uint256 lockId) external view returns (uint256) {
        return _unclaimed(_get(lockId), block.timestamp);
    }

    function currencyLockCount(Currency currency) external view returns (uint256) {
        return _lockIdsByCurrency[currency].length;
    }

    /// @notice Every lock ever made of `currency`: the explorer's per-token list.
    function currencyLockIds(Currency currency, uint256 start, uint256 end) external view returns (uint256[] memory) {
        return _page(_lockIdsByCurrency[currency], start, end);
    }

    /// @notice Every lock `account` was ever made beneficiary of (check `getLock` for the current one).
    function beneficiaryLockIds(address account, uint256 start, uint256 end) external view returns (uint256[] memory) {
        return _page(_lockIdsByBeneficiary[account], start, end);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _get(uint256 lockId) private view returns (TokenLock storage) {
        if (lockId >= _locks.length) revert NoSuchLock(lockId);
        return _locks[lockId];
    }

    function _vested(TokenLock storage l, uint256 t) private view returns (uint256) {
        if (t < l.cliff) return 0;
        if (t >= l.end) return l.amount;
        // start < end here: start <= cliff <= t < end.
        return Math.mulDiv(l.amount, t - l.start, uint256(l.end) - l.start);
    }

    /// @dev Vested minus claimed, never negative (vesting only grows with time, but a view may be asked about
    /// any moment).
    function _unclaimed(TokenLock storage l, uint256 t) private view returns (uint256) {
        uint256 vested = _vested(l, t);
        return vested > l.claimed ? vested - l.claimed : 0;
    }

    /// @dev Native locked for users is not fee: `flushProtocolFees` leaves it alone.
    function _nativeHeldForUsers() internal view override returns (uint256) {
        return totalHeld[CurrencyLibrary.NATIVE];
    }

    function _page(uint256[] storage list, uint256 start, uint256 end) private view returns (uint256[] memory page) {
        uint256 length = list.length;
        if (end > length) end = length;
        if (start >= end) return page;
        page = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = list[i];
        }
    }
}
