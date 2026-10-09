// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";

/// @dev Minimal surface so this script needs no core import.
interface IProtocolFeesLike {
    function setProtocolFeeController(address controller) external;
    function protocolFeeController() external view returns (address);
    function owner() external view returns (address);
}

/// Points both pool managers at DeepCore's fee controller.
/// Without this the managers have no controller and every pool reports a zero protocol fee.
contract WireFeeControllerScript is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address controller = vm.envAddress("FEE_CONTROLLER");
        address cl = vm.envAddress("CL_POOL_MANAGER");
        address bin = vm.envAddress("BIN_POOL_MANAGER");

        vm.startBroadcast(pk);
        IProtocolFeesLike(cl).setProtocolFeeController(controller);
        IProtocolFeesLike(bin).setProtocolFeeController(controller);
        vm.stopBroadcast();

        require(IProtocolFeesLike(cl).protocolFeeController() == controller, "CL not wired");
        require(IProtocolFeesLike(bin).protocolFeeController() == controller, "BIN not wired");

        console.log("CL  protocolFeeController ", IProtocolFeesLike(cl).protocolFeeController());
        console.log("BIN protocolFeeController ", IProtocolFeesLike(bin).protocolFeeController());
    }
}
