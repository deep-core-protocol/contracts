// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * DeepCore Protocol needs its OWN CREATE3 factory.
 *
 * The upstream config pointed at PancakeSwap's factory, which is gated by `onlyWhitelisted`
 * and owned by an address we do not control — every deploy reverted with NotWhitelisted().
 * Deploying our own also gives DeepCore its own deterministic-address namespace across every
 * target chain, rather than depending on a third party's factory on five networks.
 *
 * Create3Factory's constructor whitelists its deployer, so no follow-up call is needed for
 * the deployer itself. Additional deployers go through setWhitelistUser (onlyOwner).
 *
 * forge script script/00_DeployCreate3Factory.s.sol:DeployCreate3FactoryScript \
 *   --rpc-url $RPC_URL --broadcast --slow --verify
 */
contract DeployCreate3FactoryScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        Create3Factory factory = new Create3Factory();

        require(factory.isUserWhitelisted(deployer), "deployer not self-whitelisted");
        require(factory.owner() == deployer, "unexpected factory owner");

        vm.stopBroadcast();

        console.log("Create3Factory deployed at ", address(factory));
        console.log("  owner                    ", factory.owner());
        console.log("  deployer whitelisted     ", factory.isUserWhitelisted(deployer));
        console.log("");
        console.log("Put this address in script/config/<network>.json as create3Factory.");
    }
}
