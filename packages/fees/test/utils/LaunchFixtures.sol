// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

import {ILockedLaunchOracle} from "../../src/interfaces/ILockedLaunchOracle.sol";

/// @dev A first-claim launch hook shaped like `LaunchGuardHook`: `beforeInitialize` refuses a pool
/// nobody claimed, or one being created by someone other than its claimant. Bitmap = beforeInitialize.
contract MockCLLaunchHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => address) public launchOwner;

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return 1; // HOOKS_BEFORE_INITIALIZE_OFFSET = 0
    }

    function claim(PoolKey calldata key) external {
        PoolId id = key.toId();
        require(launchOwner[id] == address(0), "claimed");
        launchOwner[id] = msg.sender;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        address o = launchOwner[key.toId()];
        require(o != address(0) && o == sender, "not the claimant");
        return ICLHooks.beforeInitialize.selector;
    }
}

/// @dev The part of `DeepCoreLPLocker` the kit's atomicity argument needs: a lock that can fail.
contract MockLocker {
    mapping(PoolId => bool) public isLockedPool;
    bool public failNext;

    function setFailNext(bool v) external {
        failNext = v;
    }

    function lock(PoolId id) external {
        require(!failNext, "lock failed");
        isLockedPool[id] = true;
    }
}

/// @dev A kit that follows `docs/controller-v3.md` section 4: flag BEFORE initialize, lock after,
/// no try/catch, revert if the lock is not there.
contract MockCLLaunchKit is ILockedLaunchOracle {
    using PoolIdLibrary for PoolKey;

    ICLPoolManager public immutable manager;
    MockCLLaunchHook public immutable hook;
    MockLocker public immutable locker;

    mapping(bytes32 => bool) private _lockedLaunch;

    constructor(ICLPoolManager manager_, MockCLLaunchHook hook_, MockLocker locker_) {
        manager = manager_;
        hook = hook_;
        locker = locker_;
    }

    function createLockedLaunch(PoolKey calldata key, uint160 sqrtPriceX96) external {
        PoolId id = key.toId();
        require(!_lockedLaunch[PoolId.unwrap(id)], "exists");
        _lockedLaunch[PoolId.unwrap(id)] = true; // effect before any interaction
        hook.claim(key);
        manager.initialize(key, sqrtPriceX96);
        locker.lock(id);
        require(locker.isLockedPool(id), "not locked");
    }

    /// @dev An unlocked launch shape (e.g. Bin before a Bin locker exists). Never flagged.
    function createUnlockedLaunch(PoolKey calldata key, uint160 sqrtPriceX96) external {
        hook.claim(key);
        manager.initialize(key, sqrtPriceX96);
    }

    /// @dev The timing trap, on purpose: the flag lands after core has already read the fee.
    function createLaunchFlaggedTooLate(PoolKey calldata key, uint160 sqrtPriceX96) external {
        PoolId id = key.toId();
        hook.claim(key);
        manager.initialize(key, sqrtPriceX96);
        _lockedLaunch[PoolId.unwrap(id)] = true;
        locker.lock(id);
    }

    function isLockedLaunch(bytes32 poolId) external view returns (bool) {
        return _lockedLaunch[poolId];
    }
}
