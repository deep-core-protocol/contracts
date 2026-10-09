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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeepCoreFillExecutor - the only contract in the routing package that makes an arbitrary call
/// @notice It exists for exactly one reason, and the reason is worth stating at the top of the file
/// rather than in a design doc nobody reads at 3am:
///
/// `DeepCoreFillRouter` holds users' ERC-20 allowances, usually unlimited. The fill it performs needs a
/// call to an address the CALLER chose with calldata the CALLER built. If the router made that call
/// itself, a caller could pass `target = someToken` and
/// `data = transferFrom(victim, attacker, allowance)`: `msg.sender` at the token would be the router,
/// which is precisely the address the victim approved, and every approval the router has ever been
/// granted would be drainable by anybody, with no privileged key involved.
///
/// So the contract that HOLDS allowances and the contract that MAKES arbitrary calls are different
/// contracts. Nobody approves this one. It has no owner, no storage, no upgrade path and no balance
/// at rest. The worst an arbitrary call from here can do is lose the funds the router handed it for
/// the fill in flight - which belong to the caller who chose the venue, and whose loss makes the
/// whole transaction revert on the router's `minAmountOut` anyway.
///
/// Because of that separation there is no venue allowlist and no routing key anywhere in this
/// package: governance cannot decide where a user may trade, and cannot be compromised into it.
///
/// FUNDS CAN NEVER BE STUCK (CLAUDE.md acceptance bar). Value reaches this contract two ways: the
/// router hands it over for a fill (swept back to the router before the same call returns), or
/// somebody misdirects/donates it (swept into the next fill, or moved out by the permissionless
/// `sweepStray`, which can only ever pay the router's immutable fee recipient). An ERC-721 sent with
/// a plain `transferFrom` would strand - no receiver callback is implemented, so a safe transfer
/// cannot arrive; recorded as accepted, identically to `DeepCorePadFactory`.
contract DeepCoreFillExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice A misdirected or donated balance was moved out to the protocol fee recipient.
    event StraySwept(address indexed currency, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error NotRouter(address caller);
    /// @notice `target` may not be this contract or the router: both would be a reentrancy attempt
    /// dressed as a route.
    error InvalidTarget(address target);
    /// @notice A call to an address with no code succeeds silently and returns nothing, which would
    /// burn the caller's gas and then revert on output. Refuse it by name instead.
    error TargetHasNoCode(address target);
    /// @notice The venue reverted with no reason data.
    error VenueCallFailed(address target);
    error NativeTransferFailed(address to, uint256 amount);
    error NothingToSweep(address currency);

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The `DeepCoreFillRouter` that deployed this executor. The only caller of `execute`, and
    /// the only address a fill's funds are ever swept to.
    address public immutable ROUTER;
    /// @notice The governance Safe. The only address `sweepStray` can pay. Same value the router
    /// holds; passed in at construction so a sweep needs no external call to read it.
    address public immutable protocolFeeRecipient;

    /// @notice `address(0)` means the chain's native currency, here and in the router.
    address internal constant NATIVE = address(0);

    modifier onlyRouter() {
        if (msg.sender != ROUTER) revert NotRouter(msg.sender);
        _;
    }

    constructor(address router_, address protocolFeeRecipient_) {
        if (router_ == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        ROUTER = router_;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// @notice Native arrives here as a venue's output. Anything that arrives any other way is
    /// stray and leaves through `sweepStray` or the next fill.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                EXECUTE
    //////////////////////////////////////////////////////////////*/

    /// @notice Performs the caller-chosen venue call with the funds the router just handed over, then
    /// sweeps everything it holds of both currencies back to the router.
    /// @dev Deliberately returns nothing about amounts. The router measures its OWN balance deltas
    /// across this call, so a venue (or this contract) cannot report a number the router acts on.
    /// The ERC-20 allowance granted to `target` is exactly the balance held and is set back to zero
    /// immediately after the call, so no standing allowance survives - and since nothing is held at
    /// rest, a surviving one would reach nothing anyway.
    /// @param target The venue entry point. Any address with code that is neither the router nor this.
    /// @param data The calldata, built off chain from the venue's public ABI.
    /// @param venueIn The currency handed over (`address(0)` = native, arriving as `msg.value`).
    /// @param venueOut The currency expected back.
    function execute(address target, bytes calldata data, address venueIn, address venueOut)
        external
        payable
        onlyRouter
        nonReentrant
    {
        if (target == ROUTER || target == address(this)) revert InvalidTarget(target);
        if (target.code.length == 0) revert TargetHasNoCode(target);

        uint256 approved = 0;
        if (venueIn != NATIVE) {
            // Approve exactly what is held - not an amount argument a caller could inflate, and not
            // an unlimited allowance.
            approved = IERC20(venueIn).balanceOf(address(this));
            if (approved != 0) IERC20(venueIn).forceApprove(target, approved);
        }

        // Only the native the router sent for THIS fill is forwarded. A stray native balance stays
        // put and leaves through the sweep below or `sweepStray`, rather than being donated to a venue.
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) _bubble(target, ret);

        if (approved != 0) IERC20(venueIn).forceApprove(target, 0);

        // Sweep both sides unconditionally: whatever the venue did, this contract ends the call empty
        // of the two currencies, and the router measures what actually came back.
        _sweepTo(venueIn, ROUTER);
        _sweepTo(venueOut, ROUTER);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless. Moves a misdirected or donated balance to the immutable protocol fee
    /// recipient. Nothing is ever owed to a user from this contract's resting balance - a fill
    /// empties it before it returns - so the whole balance goes.
    /// @dev `nonReentrant` is shared with `execute`: a venue cannot call this mid-fill to divert the
    /// funds in flight.
    function sweepStray(address currency) external nonReentrant returns (uint256 amount) {
        amount = currency == NATIVE ? address(this).balance : IERC20(currency).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep(currency);
        emit StraySwept(currency, protocolFeeRecipient, amount);
        _send(currency, protocolFeeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _sweepTo(address currency, address to) private {
        uint256 amount = currency == NATIVE ? address(this).balance : IERC20(currency).balanceOf(address(this));
        if (amount != 0) _send(currency, to, amount);
    }

    function _send(address currency, address to, uint256 amount) private {
        if (currency == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed(to, amount);
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    /// @dev Re-raises the venue's own revert so a user sees why their route failed, rather than a
    /// generic wrapper that hides it.
    function _bubble(address target, bytes memory ret) private pure {
        if (ret.length == 0) revert VenueCallFailed(target);
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}
