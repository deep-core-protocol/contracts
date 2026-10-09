// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeepCoreLaunchAndBuy} from "../../src/DeepCoreLaunchAndBuy.sol";
import {LaunchParamsV2} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";

/// @notice A quote token that calls back into `DeepCoreLaunchAndBuy` from inside `transferFrom`.
/// @dev The ONLY untrusted external contract in the whole flow is the quote currency, because the
/// launch token is always a freshly minted `LaunchToken` (a plain fixed-supply ERC-20 with no hooks)
/// and every other address is an immutable read off the kit. So the reentrancy surface is exactly
/// this, and this is what tests it.
contract ReentrantQuoteToken is MockERC20 {
    enum Mode {
        None,
        LaunchAndBuy,
        SweepERC20,
        SweepNative,
        LockAcquired
    }

    DeepCoreLaunchAndBuy public target;
    Mode public mode;
    LaunchParamsV2 internal _params;
    DeepCoreLaunchAndBuy.BuyParams internal _buy;

    constructor() MockERC20("Reentrant Quote", "RQ", 18) {}

    function arm(DeepCoreLaunchAndBuy t, Mode m) external {
        target = t;
        mode = m;
    }

    function armLaunch(LaunchParamsV2 calldata p, DeepCoreLaunchAndBuy.BuyParams calldata b) external {
        _params = p;
        _buy = b;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _attack();
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _attack();
        return super.transfer(to, amount);
    }

    function _attack() internal {
        Mode m = mode;
        if (m == Mode.None) return;
        // One shot: the inner call must not loop forever if the guard somehow lets it through.
        mode = Mode.None;
        if (m == Mode.LaunchAndBuy) {
            target.launchAndBuy(_params, _buy);
        } else if (m == Mode.SweepERC20) {
            target.sweepERC20(address(this));
        } else if (m == Mode.SweepNative) {
            target.sweepNative();
        } else if (m == Mode.LockAcquired) {
            target.lockAcquired("");
        }
    }
}

/// @notice A quote token that attacks from inside `transfer` ONLY - that is, while
/// `DeepCoreLaunchAndBuy` is settling INSIDE the Vault lock and still holds the quote budget.
///
/// @dev `ReentrantQuoteToken` above attacks from `transferFrom`, which is the pull: at that instant
/// the contract holds nothing, so a sweep attempted there would revert `NothingToSweep` even with no
/// reentrancy guard at all, and a test that expects "a revert" cannot tell the two apart. This one
/// fires at the only moment there is something to take. Found by the live-transaction bar
/// (docs/launch-and-buy-acceptance.md), 2026-09-28.
///
/// With `swallow == false` the refusal is bubbled, so the outer revert data IS the inner refusal.
/// With `swallow == true` the token carries on, and the evidence is left in storage.
contract MidLockQuoteToken is MockERC20 {
    enum Mode {
        None,
        SweepERC20,
        SweepNative,
        LockAcquired
    }

    address public target;
    Mode public mode;
    bool public swallow;
    uint256 public fired;
    bool public lastOk;
    bytes public lastRevert;
    uint256 public targetBalanceAtAttack;

    constructor() MockERC20("Mid-lock Quote", "MLQ", 18) {}

    function arm(address t, Mode m, bool swallow_) external {
        target = t;
        mode = m;
        swallow = swallow_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode m = mode;
        if (m != Mode.None && msg.sender == target) {
            mode = Mode.None;
            targetBalanceAtAttack = balanceOf[target];
            bytes memory data;
            if (m == Mode.SweepERC20) {
                data = abi.encodeCall(DeepCoreLaunchAndBuy.sweepERC20, (address(this)));
            } else if (m == Mode.SweepNative) {
                data = abi.encodeCall(DeepCoreLaunchAndBuy.sweepNative, ());
            } else {
                data = abi.encodeCall(DeepCoreLaunchAndBuy.lockAcquired, (""));
            }
            (bool ok, bytes memory ret) = target.call(data);
            fired += 1;
            lastOk = ok;
            lastRevert = ret;
            if (!ok && !swallow) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transfer(to, amount);
    }
}

/// @notice Takes 1% of every transfer. Unsupported by design; it must fail closed.
contract FeeOnTransferQuoteToken is MockERC20 {
    constructor() MockERC20("Fee Quote", "FEEQ", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100;
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
            totalSupply -= fee;
        }
        emit Transfer(msg.sender, to, amount - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount - fee;
            totalSupply -= fee;
        }
        emit Transfer(from, to, amount - fee);
        return true;
    }
}

/// @notice Refuses every native transfer.
contract NativeRefuser {
    receive() external payable {
        revert("no native");
    }

    /// @dev Lets the refuser originate a call, so a test can make IT the `msg.sender` of a launch.
    function call(address target, uint256 value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @notice Pushes native currency into an address that has no `receive`.
contract Forcer {
    constructor(address payable to) payable {
        // solc warns; EIP-6780 still TRANSFERS the balance, and this contract is created and
        // destroyed in the same transaction, which is the case the opcode fully supports.
        selfdestruct(to);
    }
}
