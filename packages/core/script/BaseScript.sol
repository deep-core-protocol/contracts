// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BackendGuard} from "./BackendGuard.sol";

/// @dev Every core deploy script inherits this. `setUp()` runs BEFORE `run()` under `forge script`,
/// with the `--rpc-url` fork already active, so `block.chainid` is the target chain's: the
/// transient-backend guard fires here, once, for all nine scripts, before any key is read and
/// before anything is broadcast. Until 2026-09-17 `BackendGuard` existed but nothing called it.
abstract contract BaseScript is BackendGuard {
    string path;

    function setUp() public virtual {
        /* Refuse an EIP-1153 build on a pre-Cancun chain (every lock would revert) and a storage
           build on a Cancun chain (every swap overpays forever). Reads script/config/eip1153.json;
           an unclassified chain reverts, on purpose. */
        assertBackendMatchesChain();

        string memory scriptConfig = vm.envString("SCRIPT_CONFIG");
        console.log("[BaseScript] SCRIPT_CONFIG: ", scriptConfig);

        string memory root = vm.projectRoot();
        path = string.concat(root, "/script/config/", scriptConfig, ".json");
        console.log("[BaseScript] Reading config from: ", path);
    }

    // reference: https://github.com/foundry-rs/foundry/blob/master/testdata/default/cheats/Json.t.sol
    function getAddressFromConfig(string memory key) public view returns (address) {
        string memory json = vm.readFile(path);
        bytes memory data = vm.parseJson(json, string.concat(".", key));

        // seems like foundry decode as 0x20 when address is not set or as "0x"
        address decodedData = abi.decode(data, (address));
        require(decodedData != address(0x20), "Address not set");

        return decodedData;
    }

    /// @notice An OWNER read from the config, validated before anything is handed to it (audit A, 2026-10-07).
    /// A wrong `poolOwner` is recoverable on the Vault (the deployer still owns it until the accept) but
    /// IRREVERSIBLE on the pool-manager owner wrappers: their `owner()` is the CREATE3 proxy child, so a
    /// pending owner nobody controls bricks `setProtocolFeeController` / `pause` / `unpause` for good.
    /// Checks: set, a contract (the Safe or a timelock, never an EOA), not the deployer, and — when the
    /// runner exports `GOVERNANCE_SAFE` (ops/deploy/tools/deploy-chain.sh always does) — exactly that
    /// address, so a config edited by hand cannot point anywhere else.
    function getOwnerFromConfig(string memory key) public view returns (address owner) {
        owner = getAddressFromConfig(key);
        require(owner != address(0), string.concat(key, " is the zero address"));
        require(owner.code.length > 0, string.concat(key, " has no code - the Safe or a timelock, never an EOA"));
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(owner != deployer, string.concat(key, " is the deployer"));
        address expected = vm.envOr("GOVERNANCE_SAFE", address(0));
        if (expected != address(0)) {
            require(owner == expected, string.concat(key, " is not GOVERNANCE_SAFE"));
        }
    }

    /// @notice must be implemented by the inheriting contract to make sure eth deployment salt is unique
    /// since the deployment salt will be the only factor to decide the address of the newly deployed contract
    function getDeploymentSalt() public pure virtual returns (bytes32) {
        revert("Deployment salt not set !");
    }
}
