// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "forge-std/Script.sol";

interface IOwnable2Step {
    function acceptOwnership() external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/**
 * Claims ownership of the UniversalRouter.
 *
 * CREATE3 deploys through an intermediate proxy child, so the router's constructor
 * owner is that throwaway contract. The deploy script queues a transfer to the
 * deployer, but Ownable2Step means it is only PENDING until accepted — leaving the
 * router owned by a contract nobody controls.
 */
contract AcceptRouterOwnershipScript is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        IOwnable2Step router = IOwnable2Step(vm.envAddress("UNIVERSAL_ROUTER"));

        require(router.pendingOwner() == me, "deployer is not pendingOwner");

        vm.startBroadcast(pk);
        router.acceptOwnership();
        vm.stopBroadcast();

        require(router.owner() == me, "ownership not accepted");
        console.log("UniversalRouter owner now", router.owner());
    }
}
