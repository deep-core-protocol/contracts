// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Transfers each pool manager to its OWN owner wrapper (deployed by 06 / 07). The managers are
 * single-step `Ownable`, so this takes effect in the transaction: afterwards `owner()` on each manager
 * reads its wrapper, and the wrapper's `owner()` (the Safe) holds every manager power.
 *
 * Found 2026-10-07 while preparing the HyperEVM rehearsal: this script used to transfer BOTH managers
 * to the single `poolOwner`; the wrappers' per-manager design needs two different addresses, which the
 * config has carried all along (`clPoolManagerOwnerContract` / `binPoolManagerOwnerContract`).
 *
 * ORDER (audit A, 2026-10-07): this script runs ONLY AFTER the Safe has accepted both wrappers (runbook
 * step 5b). Until then a wrapper's `owner()` is the CREATE3 proxy child with `poolOwner` merely pending,
 * and handing the managers to it is a one-way door: should the accept never happen, `setProtocolFeeController`
 * / `pause` / `unpause` are lost for good. The script therefore REQUIRES `owner() == poolOwner` on both
 * wrappers and refuses otherwise.
 *
 * forge script script/09_TransferPoolManagerOwner.s.sol:TransferPoolManagerOwner -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 */
contract TransferPoolManagerOwner is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address clPoolManager = getAddressFromConfig("clPoolManager");
        address binPoolManager = getAddressFromConfig("binPoolManager");
        address clPoolManagerOwner = getAddressFromConfig("clPoolManagerOwnerContract");
        address binPoolManagerOwner = getAddressFromConfig("binPoolManagerOwnerContract");

        require(clPoolManagerOwner.code.length > 0, "clPoolManagerOwnerContract has no code: run 06 first");
        require(binPoolManagerOwner.code.length > 0, "binPoolManagerOwnerContract has no code: run 07 first");
        require(clPoolManagerOwner != binPoolManagerOwner, "the two wrappers must be different contracts");

        // The one-way door: the Safe must already OWN both wrappers (step 5b), not merely be pending.
        address poolOwner = getOwnerFromConfig("poolOwner");
        require(
            Ownable(clPoolManagerOwner).owner() == poolOwner,
            "CLPoolManagerOwner is not owned by poolOwner yet: the Safe must acceptOwnership() first (step 5b)"
        );
        require(
            Ownable(binPoolManagerOwner).owner() == poolOwner,
            "BinPoolManagerOwner is not owned by poolOwner yet: the Safe must acceptOwnership() first (step 5b)"
        );

        vm.startBroadcast(deployerPrivateKey);

        Ownable(clPoolManager).transferOwnership(clPoolManagerOwner);
        console.log("clPoolManager pending owner -> CLPoolManagerOwner ", clPoolManagerOwner);

        Ownable(binPoolManager).transferOwnership(binPoolManagerOwner);
        console.log("binPoolManager pending owner -> BinPoolManagerOwner ", binPoolManagerOwner);

        vm.stopBroadcast();
    }
}
