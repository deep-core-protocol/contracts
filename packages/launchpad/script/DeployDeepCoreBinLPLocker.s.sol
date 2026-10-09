// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";

/**
 * Deploys `DeepCoreBinLPLocker` against an EXISTING shared core's `BinPositionManager`, through CreateX
 * `deployCreate3` at `DEEPCORE_SALT_DEEPCORE_BIN_LP_LOCKER` - a `0x7878…78` address, the same on every chain
 * (`ops/deploy/salts/README.md`).
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 *
 * Everything. No owner, no setter, no pause, no upgrade. `protocolRecipient`, the three bps bounds and
 * `maxBinsPerLock` are immutables every future lock is validated against, forever, and every share locked
 * under a wrong value stays locked under it. So every argument is checked before the broadcast and read
 * back after it.
 *
 * THE NUMBERS ARE THE OWNER'S, not this script's. CLAUDE.md "Kit fees: decided by the owner, 2026-09-13":
 * protocol floor 20% of LP fees, protocol cap 50%, integrator cap 20% - the same as `DeepCoreLPLocker`.
 * Duplicated as constants here rather than read from the contract, because an assertion that sources its
 * expectation from the contract under test asserts nothing.
 *
 * MAX_BINS_PER_LOCK = 64 is sized from `test_gas_lockCollectClaim_10_and_64_bins`: a 64-bin lock and a
 * worst-case 64-bin collect (every bin crossed) both fit comfortably in one transaction on an Arbitrum
 * Nitro chain. Kit v2's own `maxBins` must be <= this.
 *
 * If `DEEPCORE_LP_LOCKER` is set, the script also asserts the CL locker on the same chain uses the same
 * protocol recipient and the same bounds, so a Bin leg and a CL leg of one launch cannot silently disagree.
 *
 * OWNERSHIP: nothing to transfer, nothing to accept. `protocolRecipient` must be the governance Safe
 * (CLAUDE.md "The governance Safe"), and the script refuses an EOA.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   BIN_POSITION_MANAGER=0x... \
 *   LOCKER_PROTOCOL_RECIPIENT=<governance Safe> \
 *   DEEPCORE_LP_LOCKER=0x... \
 *   forge script script/DeployDeepCoreBinLPLocker.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreBinLPLockerScript is Script {
    uint16 internal constant MIN_PROTOCOL_BPS = 2_000;
    uint16 internal constant MAX_PROTOCOL_BPS = 5_000;
    uint16 internal constant MAX_INTEGRATOR_BPS = 2_000;
    uint16 internal constant MAX_BINS_PER_LOCK = 64;

    string internal constant LABEL = "DEEPCORE_BIN_LP_LOCKER";

    struct Wiring {
        /// @dev Deployer key. Never a literal - `run` takes it from `PRIVATE_KEY`.
        uint256 pk;
        address positionManager;
        address protocolRecipient;
        /// @dev Optional. `address(0)` skips the cross-check.
        address clLocker;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreBinLPLocker locker) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        return runWith(
            Wiring({
                pk: pk,
                positionManager: vm.envAddress("BIN_POSITION_MANAGER"),
                protocolRecipient: vm.envAddress("LOCKER_PROTOCOL_RECIPIENT"),
                clLocker: vm.envOr("DEEPCORE_LP_LOCKER", address(0)),
                target: DeepCoreDeploy.fromEnv(LABEL, vm.addr(pk))
            })
        );
    }

    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreBinLPLocker).creationCode,
            abi.encode(
                IBinPositionManager(w.positionManager),
                w.protocolRecipient,
                MIN_PROTOCOL_BPS,
                MAX_PROTOCOL_BPS,
                MAX_INTEGRATOR_BPS,
                MAX_BINS_PER_LOCK
            )
        );
    }

    function runWith(Wiring memory w) public returns (DeepCoreBinLPLocker locker) {
        _preflight(w);

        bytes memory code = initCode(w);
        vm.startBroadcast(w.pk);
        locker = DeepCoreBinLPLocker(payable(DeepCoreDeploy.deploy(w.target, code, LABEL)));
        vm.stopBroadcast();

        _postflight(locker, w);
    }

    function _preflight(Wiring memory w) internal view {
        require(w.target.deployer == vm.addr(w.pk), "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);

        require(w.positionManager.code.length > 0, "BIN_POSITION_MANAGER has no code");
        address vault = address(IImmutableState(w.positionManager).vault());
        require(vault != address(0), "BIN_POSITION_MANAGER reports no vault");
        address bpm = address(IBinPositionManager(w.positionManager).binPoolManager());
        require(bpm.code.length > 0, "BIN_POSITION_MANAGER reports no bin pool manager");
        require(address(IBinPoolManager(bpm).vault()) == vault, "bin pool manager and position manager disagree on vault");

        require(w.protocolRecipient != address(0), "LOCKER_PROTOCOL_RECIPIENT is zero");
        // A Safe, not an EOA: the recipient is immutable, and a Safe's signers rotate without its address changing.
        require(w.protocolRecipient.code.length > 0, "LOCKER_PROTOCOL_RECIPIENT has no code - must be the Safe");
        require(w.protocolRecipient != vm.addr(w.pk), "LOCKER_PROTOCOL_RECIPIENT is the deployer");

        if (w.clLocker != address(0)) {
            DeepCoreLPLocker cl = DeepCoreLPLocker(payable(w.clLocker));
            require(cl.protocolRecipient() == w.protocolRecipient, "CL locker pays a different protocol recipient");
            require(cl.minProtocolBps() == MIN_PROTOCOL_BPS, "CL locker floor differs");
            require(cl.maxProtocolBps() == MAX_PROTOCOL_BPS, "CL locker cap differs");
            require(cl.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "CL locker integrator cap differs");
            require(cl.vault() == vault, "CL locker is on a different vault");
        }
    }

    function _postflight(DeepCoreBinLPLocker locker, Wiring memory w) internal view {
        require(address(locker) == DeepCoreDeploy.predict(w.target), "locker is not at the predicted address");
        require(address(locker.positionManager()) == w.positionManager, "locker: positionManager");
        require(
            address(locker.binPoolManager()) == address(IBinPositionManager(w.positionManager).binPoolManager()),
            "locker: binPoolManager"
        );
        require(locker.vault() == address(IImmutableState(w.positionManager).vault()), "locker: vault");
        require(locker.protocolRecipient() == w.protocolRecipient, "locker: protocolRecipient");
        require(locker.minProtocolBps() == MIN_PROTOCOL_BPS, "locker: minProtocolBps");
        require(locker.maxProtocolBps() == MAX_PROTOCOL_BPS, "locker: maxProtocolBps");
        require(locker.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "locker: maxIntegratorBps");
        require(locker.maxBinsPerLock() == MAX_BINS_PER_LOCK, "locker: maxBinsPerLock");
        require(locker.BPS_DENOMINATOR() == 10_000, "locker: denominator");
        require(locker.MAX_BINS_HARD_CAP() == 256, "locker: hard cap");
        require(locker.lockCount() == 0, "locker: not fresh");

        console.log("DeepCoreBinLPLocker   ", address(locker), "(CREATE3 via CreateX: same on every chain)");
        console.log("positionManager    ", w.positionManager);
        console.log("protocolRecipient  ", w.protocolRecipient);
    }
}
