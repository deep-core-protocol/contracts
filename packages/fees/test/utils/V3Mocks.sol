// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {ILockedLaunchOracle} from "../../src/interfaces/ILockedLaunchOracle.sol";

/// @dev An oracle that can answer honestly or misbehave in every way the controller must survive.
contract MockLaunchOracle is ILockedLaunchOracle {
    enum Mode {
        Honest,
        Revert,
        RevertWithTrueData,
        ReturnTwo,
        ReturnLongTrue,
        ReturnShort,
        ReturnBomb,
        BurnThenTrue,
        TrueForEverything
    }

    Mode public mode;
    mapping(bytes32 => bool) public flagged;
    /// @dev Loop iterations run by `BurnThenTrue`. Calibrated in a test to cost 30k-48k gas.
    uint256 public burnSlots = 400;

    function setMode(Mode m) external {
        mode = m;
    }

    function setFlag(bytes32 poolId, bool value) external {
        flagged[poolId] = value;
    }

    function setBurnSlots(uint256 n) external {
        burnSlots = n;
    }

    function isLockedLaunch(bytes32 poolId) external view returns (bool) {
        Mode m = mode;
        if (m == Mode.Honest) return flagged[poolId];
        if (m == Mode.TrueForEverything) return true;
        if (m == Mode.Revert) revert("nope");
        if (m == Mode.RevertWithTrueData) {
            assembly {
                mstore(0x00, 1)
                revert(0x00, 0x20)
            }
        }
        if (m == Mode.ReturnTwo) {
            assembly {
                mstore(0x00, 2)
                return(0x00, 0x20)
            }
        }
        if (m == Mode.ReturnLongTrue) {
            assembly {
                mstore(0x00, 1)
                mstore(0x20, 1)
                return(0x00, 0x40)
            }
        }
        if (m == Mode.ReturnShort) {
            assembly {
                mstore(0x00, shl(8, 1))
                return(0x00, 0x1f)
            }
        }
        if (m == Mode.ReturnBomb) {
            assembly {
                mstore(0x00, 1)
                return(0x00, 100000)
            }
        }
        // BurnThenTrue: an honest answer that happens to be expensive.
        // Pure computation, so the cost does not depend on slot warmth inside one test transaction.
        uint256 n = burnSlots;
        uint256 acc;
        assembly {
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(0x00, add(acc, i))
                acc := keccak256(0x00, 0x20)
            }
        }
        return acc == acc;
    }
}

/// @dev A contract with code and no `isLockedLaunch`: the v1 kit, the registry, the locker.
contract NotAnOracle {
    function hello() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Stands in for a pool manager's `ProtocolFees` surface, gated like core.
contract MockProtocolFees {
    using PoolIdLibrary for PoolKey;

    error InvalidCaller();

    address public controller;
    mapping(Currency => uint256) public protocolFeesAccrued;
    mapping(PoolId => uint24) public poolProtocolFee;
    address public lastRecipient;

    constructor(address controller_) {
        controller = controller_;
    }

    function setController(address c) external {
        controller = c;
    }

    function setAccrued(Currency currency, uint256 amount) external {
        protocolFeesAccrued[currency] = amount;
    }

    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
        if (msg.sender != controller) revert InvalidCaller();
        poolProtocolFee[key.toId()] = newProtocolFee;
    }

    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        returns (uint256 amountCollected)
    {
        if (msg.sender != controller) revert InvalidCaller();
        amountCollected = amount == 0 ? protocolFeesAccrued[currency] : amount;
        protocolFeesAccrued[currency] -= amountCollected;
        lastRecipient = recipient;
    }
}

/// @dev An oracle that NEVER vouches, and can waste gas on the way to saying so. It stands in front of
/// an honest oracle in `DeepCoreProtocolFeeControllerV4`'s set: whatever it burns, the oracle after it
/// must still be asked with a full stipend. Quiet at construction, so it passes the constructor probe.
contract WastefulLaunchOracle is ILockedLaunchOracle {
    enum Mode {
        Quiet,
        BurnAllGas,
        BurnThenFalse,
        BurnThenRevert
    }

    Mode public mode;
    /// @dev Loop iterations run by the two `BurnThen...` modes. Same calibration as `MockLaunchOracle`.
    uint256 public burnSlots = 400;

    function setMode(Mode m) external {
        mode = m;
    }

    function setBurnSlots(uint256 n) external {
        burnSlots = n;
    }

    function isLockedLaunch(bytes32) external view returns (bool) {
        Mode m = mode;
        if (m == Mode.Quiet) return false;
        if (m == Mode.BurnAllGas) {
            // INVALID consumes everything the caller forwarded: the whole stipend, every time.
            assembly {
                invalid()
            }
        }
        uint256 n = burnSlots;
        uint256 acc;
        assembly {
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(0x00, add(acc, i))
                acc := keccak256(0x00, 0x20)
            }
        }
        if (m == Mode.BurnThenRevert) revert("burned");
        return acc != acc;
    }
}
