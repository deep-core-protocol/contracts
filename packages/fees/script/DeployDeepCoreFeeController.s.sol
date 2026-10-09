// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreProtocolFeeController} from "../src/DeepCoreProtocolFeeController.sol";

/**
 * Deploys DeepCore's OWN protocol fee controller.
 *
 * core/script/04_DeployCLProtocolFeeController.s.sol deploys PancakeSwap's inherited
 * ProtocolFeeController, which defaults dynamic-fee pools to 300 pips. DeepCore's controller
 * defaults to 1000 pips (0.1%) with per-pool and per-tier overrides, a hard 0.4% cap, and a
 * guardian that can zero fees instantly without waiting on governance.
 *
 * TESTNET: owner and guardian are the deployer.
 * MAINNET: owner MUST be the Policy-tier DeepCoreTimelock (6h) and the guardian a separate
 * incident-response address. The guardian can only ever reduce what the protocol takes.
 *
 * Three of DeepCore's five target chains are stablecoin chains (Plasma, Arc, Stable), where a
 * flat 0.1% is ~11x a 0.01% stable pool's own fee. Call setTierFee on the low tiers before
 * any pool goes live there.
 */
contract DeployDeepCoreFeeControllerScript is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        DeepCoreProtocolFeeController controller = new DeepCoreProtocolFeeController(deployer, deployer);
        vm.stopBroadcast();

        (, uint16 z, uint16 o) = controller.defaultFee();
        console.log("DeepCoreProtocolFeeController ", address(controller));
        console.log("  owner                    ", controller.owner());
        console.log("  guardian                 ", controller.guardian());
        console.log("  default zeroForOne (pips)", z);
        console.log("  default oneForZero (pips)", o);
        console.log("  max protocol fee (pips)  ", controller.MAX_PROTOCOL_FEE());
    }
}
