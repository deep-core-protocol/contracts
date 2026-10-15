// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";

import {DeepCoreRangeOrders} from "../src/DeepCoreRangeOrders.sol";
import {DeepCoreDCA} from "../src/DeepCoreDCA.sol";

/**
 * Deploys `DeepCoreRangeOrders` and `DeepCoreDCA` against the chain's already-deployed DeepCore core.
 *
 * Neither is a Vault app: nothing is registered on the Vault, and no Safe transaction is needed for them
 * to work. Both are owned by the Safe from the creating transaction (constructor argument), whose ONLY
 * power is the protocol fee for NEW orders/plans inside the immutable cap, and `rescueSurplus` above
 * everything owed. Every fee is paid to the immutable recipient (the Safe).
 *
 * Every input is REQUIRED from the environment; there are no defaults in this script. The owner decisions
 * of record (2026-10-12, to confirm) are: ORDERS_FEE_BPS=10, ORDERS_MAX_FEE_BPS=50,
 * ORDERS_FEE_NOTICE_SECONDS=604800 (7 days), for both contracts.
 *
 * CreateX CREATE3, labels DEEPCORE_RANGE_ORDERS and DEEPCORE_DCA (ops/deploy/salts/labels.txt, appended;
 * salts not mined yet). One process per contract (STEP=orders | STEP=dca), per the 2026-09-17 lesson that
 * several nested broadcasts in one forge process can plan duplicate nonces.
 *
 * Usage (dry run first, no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   STEP=orders CL_POOL_MANAGER=0x.. BIN_POOL_MANAGER=0x.. ORDERS_OWNER_SAFE=0x<safe> ORDERS_FEE_RECIPIENT=0x<safe> \
 *   ORDERS_FEE_BPS=10 ORDERS_MAX_FEE_BPS=50 ORDERS_FEE_NOTICE_SECONDS=604800 ORDERS_LAUNCH_GUARDS=0x<guard>[,0x..] \
 *   forge script script/DeployDeepCoreOrders.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreOrdersScript is DeepCoreSignerScript {
    string internal constant LABEL_ORDERS = "DEEPCORE_RANGE_ORDERS";
    string internal constant LABEL_DCA = "DEEPCORE_DCA";

    struct Wiring {
        uint256 pk;
        address clPoolManager;
        address binPoolManager;
        address ownerSafe;
        address feeRecipient;
        uint16 feeBps;
        uint16 maxFeeBps;
        uint32 noticeSeconds;
        /// Every CL launch guard on this chain (address-book `clLaunchGuardHook` of every generation deployed).
        address[] launchGuards;
    }

    function run() public returns (address deployed) {
        uint256 pk = _pkFromEnv();
        Wiring memory w = Wiring({
            pk: pk,
            clPoolManager: vm.envAddress("CL_POOL_MANAGER"),
            binPoolManager: vm.envAddress("BIN_POOL_MANAGER"),
            ownerSafe: vm.envAddress("ORDERS_OWNER_SAFE"),
            feeRecipient: vm.envAddress("ORDERS_FEE_RECIPIENT"),
            feeBps: uint16(vm.envUint("ORDERS_FEE_BPS")),
            maxFeeBps: uint16(vm.envUint("ORDERS_MAX_FEE_BPS")),
            noticeSeconds: uint32(vm.envUint("ORDERS_FEE_NOTICE_SECONDS")),
            launchGuards: vm.envAddress("ORDERS_LAUNCH_GUARDS", ",")
        });
        string memory step = vm.envString("STEP");
        address deployer = _signerOf(pk);
        _checkBefore(w, deployer);
        if (keccak256(bytes(step)) == keccak256("orders")) {
            DeepCoreDeploy.Target memory t = DeepCoreDeploy.fromEnv(LABEL_ORDERS, deployer);
            DeepCoreDeploy.preflight(t, LABEL_ORDERS);
            bytes memory initCode = abi.encodePacked(
                type(DeepCoreRangeOrders).creationCode,
                abi.encode(
                    w.clPoolManager, w.ownerSafe, w.feeRecipient, w.feeBps, w.maxFeeBps, w.noticeSeconds, w.launchGuards
                )
            );
            _startBroadcastAs(pk);
            deployed = DeepCoreDeploy.deploy(t, initCode, LABEL_ORDERS);
            vm.stopBroadcast();
            DeepCoreRangeOrders o = DeepCoreRangeOrders(payable(deployed));
            require(address(o.CL_POOL_MANAGER()) == w.clPoolManager, "wrong CL manager");
            for (uint256 i; i < w.launchGuards.length; ++i) {
                require(o.isLaunchGuard(w.launchGuards[i]), "a launch guard was not recorded");
            }
            _checkFeeBase(deployed, w);
            console2.log("DeepCoreRangeOrders", deployed);
        } else if (keccak256(bytes(step)) == keccak256("dca")) {
            DeepCoreDeploy.Target memory t = DeepCoreDeploy.fromEnv(LABEL_DCA, deployer);
            DeepCoreDeploy.preflight(t, LABEL_DCA);
            bytes memory initCode = abi.encodePacked(
                type(DeepCoreDCA).creationCode,
                abi.encode(
                    w.clPoolManager, w.binPoolManager, w.ownerSafe, w.feeRecipient, w.feeBps, w.maxFeeBps, w.noticeSeconds
                )
            );
            _startBroadcastAs(pk);
            deployed = DeepCoreDeploy.deploy(t, initCode, LABEL_DCA);
            vm.stopBroadcast();
            DeepCoreDCA d = DeepCoreDCA(payable(deployed));
            require(address(d.CL_POOL_MANAGER()) == w.clPoolManager, "wrong CL manager");
            require(address(d.BIN_POOL_MANAGER()) == w.binPoolManager, "wrong Bin manager");
            _checkFeeBase(deployed, w);
            console2.log("DeepCoreDCA", deployed);
        } else {
            revert("STEP must be orders or dca");
        }
    }

    function _checkBefore(Wiring memory w, address deployer) internal view {
        require(w.clPoolManager.code.length > 0, "CL_POOL_MANAGER has no code on this chain");
        require(w.binPoolManager.code.length > 0, "BIN_POOL_MANAGER has no code on this chain");
        require(
            address(ICLPoolManager(w.clPoolManager).vault()) == address(IBinPoolManager(w.binPoolManager).vault()),
            "the two managers answer different Vaults"
        );
        DeepCoreGovernance.requireGovernanceSafe(w.ownerSafe, deployer, "ORDERS_OWNER_SAFE");
        DeepCoreGovernance.requireGovernanceSafe(w.feeRecipient, deployer, "ORDERS_FEE_RECIPIENT");
        require(w.maxFeeBps <= 50, "ORDERS_MAX_FEE_BPS above the compile-time ceiling");
        require(w.feeBps <= w.maxFeeBps, "ORDERS_FEE_BPS above ORDERS_MAX_FEE_BPS");
        // Limit orders are refused on launch pools: the guards must be named, and each must be a contract.
        require(w.launchGuards.length > 0, "ORDERS_LAUNCH_GUARDS is empty: name this chain's CL launch guard(s)");
        for (uint256 i; i < w.launchGuards.length; ++i) {
            require(w.launchGuards[i].code.length > 0, "an ORDERS_LAUNCH_GUARDS entry has no code on this chain");
        }
        require(w.noticeSeconds >= 1 days && w.noticeSeconds <= 30 days, "ORDERS_FEE_NOTICE_SECONDS out of range");
    }

    function _checkFeeBase(address deployed, Wiring memory w) internal view {
        DeepCoreRangeOrders f = DeepCoreRangeOrders(payable(deployed)); // both share OrdersFeeBase's ABI
        require(f.owner() == w.ownerSafe, "owner is not the Safe");
        require(f.pendingOwner() == address(0), "a pending owner exists");
        require(f.protocolFeeRecipient() == w.feeRecipient, "fee recipient is not the Safe");
        require(f.protocolFeeBps() == w.feeBps, "fee not as configured");
        require(f.maxProtocolFeeBps() == w.maxFeeBps, "cap not as configured");
        require(f.feeNoticeSeconds() == w.noticeSeconds, "notice not as configured");
        (bool ok,) = deployed.staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!ok, "renounceOwnership must revert");
    }
}
