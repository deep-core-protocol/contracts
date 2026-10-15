// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @dev A stand-in for `OracleModule`: answers `consult` with a settable tick. Its bitmap is 0, so a pool
/// may carry it as its hook and core never calls it. Modes model a hostile or broken oracle.
contract MockOracle {
    enum Mode {
        Normal,
        Revert,
        LongAnswer,
        BadTick,
        BurnGas,
        ShortAnswer
    }

    bytes32 public kindValue = keccak256("deepcore.oracle.truncated-twap.v1");
    uint32 public minWindow = 600;
    int24 public tick;
    Mode public mode;
    uint256 public reads;

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return 0;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setKind(bytes32 k) external {
        kindValue = k;
    }

    function setMinWindow(uint32 w) external {
        minWindow = w;
    }

    function kind() external view returns (bytes32) {
        return kindValue;
    }

    function ORACLE_MIN_WINDOW_SECONDS() external view returns (uint32) {
        return minWindow;
    }

    function consult(PoolId, uint32) external view returns (int24, uint32) {
        Mode m = mode;
        if (m == Mode.Revert) revert("oracle down");
        if (m == Mode.BurnGas) {
            uint256 x;
            while (true) {
                x++; // runs out of gas
            }
        }
        if (m == Mode.LongAnswer) {
            assembly {
                mstore(0, 7)
                return(0, 0x400)
            }
        }
        if (m == Mode.ShortAnswer) {
            assembly {
                mstore(0, 7)
                return(0, 0x20)
            }
        }
        if (m == Mode.BadTick) {
            assembly {
                mstore(0, 0x7fffffff)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        return (tick, 0);
    }
}

/// @dev Burns 1% of every transfer.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("FOT", "FOT", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 burnt = amount / 100;
        super.transferFrom(from, to, amount);
        _burn(to, burnt);
        return true;
    }
}

/// @dev A native receiver that reads the vault while being paid (read-only reentrancy probe).
contract ReadingReceiver {
    address public vault;
    bool public readReverted;

    constructor(address v) {
        vault = v;
    }

    receive() external payable {
        (bool ok,) = vault.staticcall(abi.encodeWithSignature("totalAmounts()"));
        readReverted = !ok;
    }
}
