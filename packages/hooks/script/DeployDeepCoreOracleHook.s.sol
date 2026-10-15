// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ContractClockProbe} from "./ContractClock.sol";
import {DeepCoreDeploy} from "./DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "./DeepCoreGovernance.sol";
import {DeepCoreSignerScript} from "./DeepCoreSigner.sol";
import {DeepCoreOracleHook} from "../src/oracle/DeepCoreOracleHook.sol";

/// @notice `DeepCoreRegistry`'s `DeepCoreMetadata`, field for field (declared here so this package needs no
/// registry remapping; the post-flight reads the listing back).
struct OracleDeepCoreMetadata {
    string name;
    string description;
    string sourceURI;
    string auditURI;
    uint256[] chainIds;
}

interface IOracleRegistry {
    function register(address hook, OracleDeepCoreMetadata calldata metadata) external;
    function transferSteward(address hook, address newSteward) external;
    function isRegistered(address hook) external view returns (bool);
}

/**
 * Deploys `DeepCoreOracleHook` (CreateX label `DEEPCORE_ORACLE_HOOK`) against DeepCore core and lists it in
 * `DeepCoreRegistry` in the same session, handing the listing's steward to Ops.
 *
 * The hook has NO owner and no setter: every value below is immutable, and a wrong one is a redeploy
 * and a new salt. No defaults:
 *   ORACLE_MAX_TICK_DELTA        1 .. 1,000 (design: 100)
 *   ORACLE_MIN_WINDOW_SECONDS    60 .. 86,400 (design: 600; 1,800 advised for anything holding value)
 *   ORACLE_INITIAL_CARDINALITY   1 .. 1,024 (design: 16). Paid at EVERY pool's initialize, about 22k gas
 *                                a slot: on HyperEVM's 3M small blocks keep it at or under ~64.
 * Also: PRIVATE_KEY | DEPLOYER, the DEEPCORE_ORACLE_HOOK salt pair, ORACLE_POOL_MANAGER, ORACLE_RECIPIENT
 * (the Safe; where misdirected value is swept), ORACLE_REGISTRY, ORACLE_STEWARD (Ops).
 */
contract DeployDeepCoreOracleHookScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_ORACLE_HOOK";
    uint16 internal constant BITMAP = 0x0042;
    string internal constant SOURCE_URI = "https://deepcore.fun/docs#contracts";

    struct Params {
        uint256 pk;
        ICLPoolManager poolManager;
        address recipient;
        address registry;
        address steward;
        uint24 maxTickDelta;
        uint32 minWindow;
        uint16 initialCardinality;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreOracleHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                poolManager: ICLPoolManager(vm.envAddress("ORACLE_POOL_MANAGER")),
                recipient: vm.envAddress("ORACLE_RECIPIENT"),
                registry: vm.envAddress("ORACLE_REGISTRY"),
                steward: vm.envAddress("ORACLE_STEWARD"),
                maxTickDelta: uint24(_bounded("ORACLE_MAX_TICK_DELTA", type(uint24).max)),
                minWindow: uint32(_bounded("ORACLE_MIN_WINDOW_SECONDS", type(uint32).max)),
                initialCardinality: uint16(_bounded("ORACLE_INITIAL_CARDINALITY", type(uint16).max)),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function _bounded(string memory name, uint256 max) internal view returns (uint256 v) {
        v = vm.envUint(name);
        require(v <= max, string.concat(name, " overflows its type"));
    }

    function checkInputs(Params memory p, address deployer) public view {
        require(address(p.poolManager).code.length > 0, "ORACLE_POOL_MANAGER has no code");
        require(address(p.poolManager.vault()).code.length > 0, "the pool manager's vault has no code");
        DeepCoreGovernance.requireGovernanceSafe(p.recipient, deployer, "ORACLE_RECIPIENT");
        require(p.registry.code.length > 0, "ORACLE_REGISTRY has no code");
        require(p.steward != address(0), "ORACLE_STEWARD is unset");
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            // The design's floor for anything holding value is 1,800; the contract's own floor is 60.
            require(p.minWindow >= 600, "ORACLE_MIN_WINDOW_SECONDS is under 600 on a production chain");
        }
    }

    function initCode(Params memory p) public view returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreOracleHook).creationCode,
            abi.encode(p.poolManager, p.poolManager.vault(), p.recipient, p.maxTickDelta, p.minWindow, p.initialCardinality)
        );
    }

    function runWith(Params memory p) public returns (DeepCoreOracleHook hook) {
        address deployer = _signerOf(p.pk);
        require(p.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(p.target, LABEL);
        checkInputs(p, deployer);

        console.log("=== DeepCoreOracleHook ===");
        console.log("  chain id          ", block.chainid);
        console.log("  pool manager      ", address(p.poolManager));
        console.log("  recipient (Safe)  ", p.recipient);
        console.log("  max tick delta    ", p.maxTickDelta);
        console.log("  min window, s     ", p.minWindow);
        console.log("  initial slots     ", p.initialCardinality);
        console.log("  will deploy to    ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        _startBroadcastAs(p.pk);
        hook = DeepCoreOracleHook(payable(DeepCoreDeploy.deploy(p.target, code, LABEL)));
        IOracleRegistry(p.registry).register(
            address(hook),
            OracleDeepCoreMetadata({
                name: "DeepCore Price Oracle",
                description: "A truncated time-weighted average tick other contracts read: one observation per second at most, clamped per observation, minimum window enforced. Lags by design; not a spot price.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (p.steward != deployer) IOracleRegistry(p.registry).transferSteward(address(hook), p.steward);
        vm.stopBroadcast();

        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(hook.getHooksRegistrationBitmap() == BITMAP, "bitmap is not 0x0042");
        require(address(hook.poolManager()) == address(p.poolManager), "poolManager mismatch");
        require(address(hook.vault()) == address(p.poolManager.vault()), "vault mismatch");
        require(hook.protocolRecipient() == p.recipient, "recipient mismatch");
        require(hook.ORACLE_MAX_TICK_DELTA() == p.maxTickDelta, "max tick delta mismatch");
        require(hook.ORACLE_MIN_WINDOW_SECONDS() == p.minWindow, "min window mismatch");
        require(hook.ORACLE_INITIAL_CARDINALITY() == p.initialCardinality, "initial cardinality mismatch");
        require(hook.kind() == keccak256("deepcore.oracle.truncated-twap.v1"), "kind mismatch");
        (bool hasOwner,) = address(hook).staticcall(abi.encodeWithSignature("owner()"));
        require(!hasOwner, "the oracle hook must have no owner");
        require(IOracleRegistry(p.registry).isRegistered(address(hook)), "the hook is not listed");
        console.log("DeepCoreOracleHook", address(hook));
        console.log("  runtime bytes     ", address(hook).code.length);
    }
}
