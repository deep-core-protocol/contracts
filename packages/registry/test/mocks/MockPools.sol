// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @notice Stands in for `Vault.isAppRegistered`, which is the registry's only trust anchor for
/// pool managers. Kept to that one function on purpose — if the registry ever needs more from the
/// Vault, this mock should stop compiling and force the question.
contract MockVault {
    mapping(address app => bool) public isAppRegistered;

    function registerApp(address app) external {
        isAppRegistered[app] = true;
    }

    function deregisterApp(address app) external {
        isAppRegistered[app] = false;
    }
}

/// @notice A pool manager whose `poolIdToPoolKey` table can be written directly.
/// @dev Two setters, deliberately. `setPool` behaves like core: the key is filed under its own
/// hash. `forgePool` files an arbitrary key under an arbitrary id, which core can never do, and
/// exists so the registry's `key.toId() == poolId` check has something to catch.
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 id => PoolKey) internal _keys;

    function setPool(PoolKey memory key) external returns (bytes32 id) {
        id = PoolId.unwrap(key.toId());
        _keys[id] = key;
    }

    function forgePool(bytes32 id, PoolKey memory key) external {
        _keys[id] = key;
    }

    function poolIdToPoolKey(PoolId id)
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            IHooks hooks,
            IPoolManager poolManager,
            uint24 fee,
            bytes32 parameters
        )
    {
        PoolKey memory k = _keys[PoolId.unwrap(id)];
        return (k.currency0, k.currency1, k.hooks, k.poolManager, k.fee, k.parameters);
    }
}

/// @notice Registered with the Vault but does not answer `poolIdToPoolKey` at all.
/// @dev A Vault app is not necessarily a pool manager. The attestation must fail loudly rather
/// than decode garbage.
contract NotAPoolManager {
    uint256 public unrelated = 1;
}
