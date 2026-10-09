// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {IMulticall} from "../interfaces/IMulticall.sol";

/// @title Multicall
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract Multicall is IMulticall {
    /// @inheritdoc IMulticall
    /// @dev DeepCoreProtocol: `virtual` so MixedQuoter can scope its storage-backend sweep to the
    /// whole batch. Adds no bytecode to any inheritor that does not override it.
    function multicall(bytes[] calldata data) external payable virtual override returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // bubble up the revert reason
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
        }
    }
}
