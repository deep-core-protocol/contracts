// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {IDeepCoreLaunchOrigin} from "../../src/IDeepCoreLaunchOrigin.sol";
import {LaunchMetadata, LaunchpadMetadata} from "../../src/IDeepCoreLaunchRegistry.sol";

/// @notice The slice of `DeepCoreLaunchRegistry` a launchpad calls, so the mocks below can drive it
/// without compiling the whole registry into each of them.
interface ILaunchRegistrar {
    function registerLaunch(
        address poolManager,
        bytes32 poolId,
        address token,
        address launchpad,
        address creator,
        address steward,
        LaunchMetadata calldata metadata
    ) external;

    function attestLaunchOrigin(bytes32 poolId, address launchpad, address creator) external;

    function registerLaunchpad(address launchpad, address steward, LaunchpadMetadata calldata metadata) external;

    function claimLaunchpad(address newSteward) external;
}

/// @notice A launchpad that behaves. Records the pools it created and answers for exactly those.
contract HonestLaunchpad is IDeepCoreLaunchOrigin {
    mapping(bytes32 poolId => address creator) public creatorOf;

    /// @dev Stands in for whatever the real kit writes during `createLaunch`.
    function recordLaunch(bytes32 poolId, address creator) external {
        creatorOf[poolId] = creator;
    }

    function launchOriginOf(bytes32 poolId) external view returns (address) {
        return creatorOf[poolId];
    }

    /// @dev The strong path: the launchpad registers the launch itself, in its own transaction.
    function registerLaunch(
        address registry,
        address poolManager,
        bytes32 poolId,
        address token,
        address creator,
        address steward,
        LaunchMetadata calldata metadata
    ) external {
        ILaunchRegistrar(registry).registerLaunch(poolManager, poolId, token, address(this), creator, steward, metadata);
    }

    function selfRegister(address registry, address steward, LaunchpadMetadata calldata metadata) external {
        ILaunchRegistrar(registry).registerLaunchpad(address(this), steward, metadata);
    }

    function claim(address registry, address steward) external {
        ILaunchRegistrar(registry).claimLaunchpad(steward);
    }

    /// @dev Retroactive self-vouching, for a launchpad that shipped before the registry existed.
    function attestOwn(address registry, bytes32 poolId, address creator) external {
        ILaunchRegistrar(registry).attestLaunchOrigin(poolId, address(this), creator);
    }
}

/// @notice A launchpad that predates `IDeepCoreLaunchOrigin` and cannot answer at all.
/// @dev The staticcall lands on a contract with no matching function and no fallback, so it
/// reverts and reads as "did not vouch".
contract SilentLaunchpad {
    uint256 public unrelated = 1;

    function registerLaunch(
        address registry,
        address poolManager,
        bytes32 poolId,
        address token,
        address creator,
        address steward,
        LaunchMetadata calldata metadata
    ) external {
        ILaunchRegistrar(registry).registerLaunch(poolManager, poolId, token, address(this), creator, steward, metadata);
    }
}

/// @notice Answers for every pool id in existence, including ones it never touched.
/// @dev The honest limit of the mechanism: a launchpad can over-claim AS ITSELF. It still cannot
/// name a different launchpad, which is the property the tests pin down.
contract OverClaimingLaunchpad is IDeepCoreLaunchOrigin {
    address public immutable puppet;

    constructor(address puppet_) {
        puppet = puppet_;
    }

    function launchOriginOf(bytes32) external view returns (address) {
        return puppet;
    }
}

/// @notice Answers `address(0)` for everything: a well-behaved launchpad saying "not mine".
contract DenyingLaunchpad is IDeepCoreLaunchOrigin {
    function launchOriginOf(bytes32) external pure returns (address) {
        return address(0);
    }
}

/// @notice Reverts with a custom error.
contract RevertingLaunchpad {
    error Nope();

    function launchOriginOf(bytes32) external pure returns (address) {
        revert Nope();
    }
}

/// @notice Never returns. Consumes every unit of gas it is given.
/// @dev Reads storage inside the loop so the optimizer cannot fold it away.
contract GasBurnerLaunchpad {
    uint256 public seed = 1;

    function launchOriginOf(bytes32) external view returns (address) {
        uint256 acc = seed;
        while (true) {
            acc = uint256(keccak256(abi.encode(acc, seed)));
        }
        return address(uint160(acc));
    }
}

/// @notice Returns a full word with dirty high bits above the address.
/// @dev solc's own decoder would reject this. Accepting the low 160 bits would let a launchpad
/// present one creator to a decoder and another to a raw reader.
contract DirtyAddressLaunchpad {
    function launchOriginOf(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(type(uint256).max));
    }
}

/// @notice Returns fewer than 32 bytes.
contract ShortReturnLaunchpad {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 4)
        }
    }
}

/// @notice Returns megabytes. Bounded by the probe's gas cap and rejected on size before a byte
/// of it is copied.
contract BombLaunchpad {
    fallback() external {
        assembly {
            return(0, 100000)
        }
    }
}

/// @notice Answers `launchOriginOf` differently depending on who is asking.
/// @dev The `msg.sender` branch that makes an untrusted `view` a claim rather than a measurement.
/// Included to make the point that the launch registry never treats the answer as anything more
/// than the launchpad's own word about ITSELF — which is why the branch buys nothing here.
contract TwoFacedLaunchpad is IDeepCoreLaunchOrigin {
    address public immutable registry;
    address public immutable creator;

    constructor(address registry_, address creator_) {
        registry = registry_;
        creator = creator_;
    }

    function launchOriginOf(bytes32) external view returns (address) {
        if (msg.sender == registry) return creator;
        return address(0);
    }
}
