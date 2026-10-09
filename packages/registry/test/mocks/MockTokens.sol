// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/// @notice A normal ERC-20's identity surface. Nothing else is read by the registry.
contract GoodToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    /// @dev Stands in for a proxy upgrade that renames the token after it has been listed.
    function rename(string calldata name_, string calldata symbol_) external {
        name = name_;
        symbol = symbol_;
    }
}

/// @notice Has code, answers nothing. Plenty of real tokens omit `name`/`symbol` entirely.
contract SilentToken {
    uint256 public unrelated = 1;
}

/// @notice `name()` and `symbol()` revert.
contract RevertingToken {
    error Nope();

    function name() external pure returns (string memory) {
        revert Nope();
    }

    function symbol() external pure returns (string memory) {
        revert Nope();
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Returns a name longer than the registry will store.
/// @dev Rejected on the length check rather than truncated: a truncated name is a different name,
/// and silently shortening attacker-controlled text is how homoglyph tricks get through.
contract LongNameToken {
    function name() external pure returns (string memory) {
        return string(new bytes(400));
    }

    function symbol() external pure returns (string memory) {
        return "LONG";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Returns a well-formed string for `symbol()` but a malformed head for `name()`.
/// @dev The ABI head must be exactly 0x20. This one points elsewhere, which a hand-rolled decoder
/// might follow into whatever the attacker laid out behind it. The registry rejects it outright.
contract MalformedNameToken {
    function name() external pure returns (string memory) {
        assembly {
            mstore(0x00, 0x40) // head: should be 0x20
            mstore(0x20, 0)
            mstore(0x40, 4)
            mstore(0x60, "ABCD")
            return(0x00, 0x80)
        }
    }

    function symbol() external pure returns (string memory) {
        return "MAL";
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice Declares a length longer than the bytes it actually returned.
/// @dev The classic short-buffer trick: a decoder that trusts the length reads whatever memory
/// happens to sit past the end of the copy. The registry requires `64 + length <= returndatasize`.
contract LyingLengthToken {
    function name() external pure returns (string memory) {
        assembly {
            mstore(0x00, 0x20)
            mstore(0x20, 100) // claims 100 bytes ...
            mstore(0x40, "AB")
            return(0x00, 0x60) // ... and returns 32 of them
        }
    }

    function symbol() external pure returns (string memory) {
        return "LIE";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice `decimals()` returns something that does not fit in a `uint8`.
contract WideDecimalsToken {
    function name() external pure returns (string memory) {
        return "Wide";
    }

    function symbol() external pure returns (string memory) {
        return "WIDE";
    }

    function decimals() external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice Burns every unit of gas it is handed on `name()`.
contract GasBurnerToken {
    uint256 public seed = 1;

    function name() external view returns (string memory) {
        uint256 acc = seed;
        while (true) {
            acc = uint256(keccak256(abi.encode(acc, seed)));
        }
        return "unreachable";
    }

    function symbol() external pure returns (string memory) {
        return "BURN";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}
