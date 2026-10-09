// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 HookProtocol
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @title BackendGuard
/// @notice Refuses to deploy a build whose transient-storage backend does not match the target chain.
///
/// @dev Deploying the EIP-1153 build to a pre-Cancun chain yields contracts that revert on every
/// lock (TSTORE is an invalid opcode there). Deploying the storage build to a Cancun chain is not
/// fatal but silently overpays gas on every swap forever. Neither is recoverable after the fact,
/// because CREATE3 addresses are deterministic and the Vault is immutable.
///
/// Chain classification is NOT hardcoded here on purpose. EIP-1153 support changes as chains
/// upgrade, and a stale constant baked into a safety check is worse than no check. Classification
/// lives in `script/config/eip1153.json`, maintained deliberately by whoever runs the deploy:
///
///     { "1": true, "8453": true, "56": false }
///
/// A chain absent from that file reverts. Fail-closed by design: an unclassified chain must be
/// verified by a human, not guessed by tooling.
abstract contract BackendGuard is Script {
    /// @notice The build's backend does not match what the chain supports
    error WrongBackendForChain(uint256 chainId, bool builtWithEip1153, bool chainSupportsEip1153);

    /// @notice Chain is not classified in script/config/eip1153.json
    error UnclassifiedChain(uint256 chainId);

    string internal constant CONFIG_PATH = "script/config/eip1153.json";

    /// @notice Revert unless this build's backend matches the target chain's EIP-1153 support.
    /// @dev Call at the top of every `run()` before any broadcast.
    function assertBackendMatchesChain() internal view {
        bool chainSupports = _chainSupportsEip1153(block.chainid);

        if (TransientSlot.IS_EIP1153 != chainSupports) {
            revert WrongBackendForChain(block.chainid, TransientSlot.IS_EIP1153, chainSupports);
        }
    }

    /// @dev Reads the operator-maintained classification. Reverts if this chain is not listed.
    function _chainSupportsEip1153(uint256 chainId) private view returns (bool) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory key = string.concat(".", vm.toString(chainId));

        if (!vm.keyExistsJson(json, key)) revert UnclassifiedChain(chainId);

        return vm.parseJsonBool(json, key);
    }
}
