// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev A reward token whose issuer can pause it or block an address, the shape of a regulated stablecoin.
contract PausableToken is MockERC20 {
    bool public paused;
    mapping(address => bool) public blocked;

    error Paused();
    error Blocked(address account);

    constructor() MockERC20("Pausable", "PAUSE", 18) {}

    function setPaused(bool v) external {
        paused = v;
    }

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    function _check(address from, address to) internal view {
        if (paused) revert Paused();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(from, to);
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Returns false instead of reverting once switched off.
contract FalseReturningToken is MockERC20 {
    bool public off;

    constructor() MockERC20("False", "FALSE", 18) {}

    function setOff(bool v) external {
        off = v;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (off) return false;
        return super.transfer(to, amount);
    }
}

/// @dev Takes 1% of every transferFrom: the ledger must book what arrived.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Taxed", "TAX", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100;
        super.transferFrom(from, address(0xdead), fee);
        return super.transferFrom(from, to, amount - fee);
    }
}

interface IReenterTarget {
    function claimCredit(address token, address to) external returns (uint256);
}

/// @dev Re-enters the hook from inside `transfer`.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public lastReentrySucceeded;
    bytes public lastReentryError;

    constructor() MockERC20("Reentrant", "RE", 18) {}

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory err) = target.call(payload);
            lastReentrySucceeded = ok;
            lastReentryError = err;
        }
        return super.transfer(to, amount);
    }
}
