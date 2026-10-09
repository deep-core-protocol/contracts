// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IComplianceOracle, ComplianceAction} from "../../src/interfaces/IComplianceOracle.sol";

/// @dev An oracle that answers whatever the test told it to, including non-canonical encodings.
/// The dirty-bit case exists to prove the hook masks the oracle's return rather than trusting it.
contract ConfigurableComplianceOracle is IComplianceOracle {
    bool public permitted = true;
    uint64 public expiresAt;
    uint16 public jurisdiction;

    /// @dev When set, the return words are written raw, so a test can smuggle high-order bits into
    /// the `uint64` and `uint16` slots.
    bool public useRawReturn;
    bytes32 public rawPermitted;
    bytes32 public rawExpiresAt;
    bytes32 public rawJurisdiction;

    function set(bool _permitted, uint64 _expiresAt, uint16 _jurisdiction) external {
        permitted = _permitted;
        expiresAt = _expiresAt;
        jurisdiction = _jurisdiction;
        useRawReturn = false;
    }

    function setRaw(bytes32 _permitted, bytes32 _expiresAt, bytes32 _jurisdiction) external {
        useRawReturn = true;
        rawPermitted = _permitted;
        rawExpiresAt = _expiresAt;
        rawJurisdiction = _jurisdiction;
    }

    function checkCompliance(address, PoolId, ComplianceAction)
        external
        view
        override
        returns (bool, uint64, uint16)
    {
        if (useRawReturn) {
            bytes32 a = rawPermitted;
            bytes32 b = rawExpiresAt;
            bytes32 c = rawJurisdiction;
            assembly ("memory-safe") {
                let out := mload(0x40)
                mstore(out, a)
                mstore(add(out, 0x20), b)
                mstore(add(out, 0x40), c)
                return(out, 0x60)
            }
        }
        return (permitted, expiresAt, jurisdiction);
    }
}

/// @dev Always reverts. Entry must fail CLOSED.
contract RevertingComplianceOracle is IComplianceOracle {
    error Nope();

    function checkCompliance(address, PoolId, ComplianceAction) external pure override returns (bool, uint64, uint16) {
        revert Nope();
    }
}

/// @dev Burns every wei of gas it is given. Proves `ORACLE_GAS_LIMIT` bounds the loss and that the
/// hook survives to revert cleanly rather than dying with the callee (EIP-150's 1/64 reserve).
contract GasBombComplianceOracle is IComplianceOracle {
    function checkCompliance(address, PoolId, ComplianceAction) external view override returns (bool, uint64, uint16) {
        uint256 acc;
        // Bounded only so the compiler does not flag the tail as unreachable; the bound is far
        // beyond any gas budget, so in practice this runs until the callee is out of gas.
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, gasleft())));
        }
        return (acc != 0, 0, 0);
    }
}

/// @dev Returns megabytes. Proves `returndatasize` is checked BEFORE anything is copied.
contract ReturnBombComplianceOracle is IComplianceOracle {
    function checkCompliance(address, PoolId, ComplianceAction) external pure override returns (bool, uint64, uint16) {
        assembly ("memory-safe") {
            // 64 KiB of zeroes: enough that copying it would be visible in the gas, and enough to
            // fail the exact-size check.
            return(0, 0x10000)
        }
    }
}

/// @dev Returns two words where three are required.
contract ShortReturnComplianceOracle is IComplianceOracle {
    function checkCompliance(address, PoolId, ComplianceAction) external pure override returns (bool, uint64, uint16) {
        assembly ("memory-safe") {
            return(0, 0x40)
        }
    }
}

/// @dev Writes state, so the hook's `staticcall` reverts. Proves the interface's `view` rule is
/// enforced by construction rather than by convention.
///
/// It deliberately does NOT inherit `IComplianceOracle`: Solidity refuses to let a non-view
/// function override a view one, which is itself part of the point. The selector is what the hook
/// calls, and the selector is identical.
contract StateWritingComplianceOracle {
    uint256 public calls;

    function checkCompliance(address, PoolId, ComplianceAction) external returns (bool, uint64, uint16) {
        calls++;
        return (true, 0, 0);
    }
}
