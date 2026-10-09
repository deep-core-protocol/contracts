// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ContractClockProbe} from "./ContractClock.sol";
import {DeepCoreDeploy} from "./DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "./DeepCoreGovernance.sol";
import {DeepCoreSignerScript} from "./DeepCoreSigner.sol";
import {DeepCoreBinDynamicFeeHook} from "../src/dex/DeepCoreBinDynamicFeeHook.sol";
import {DynFeeDeepCoreMetadata, IDynFeeRegistry, IOwnable2StepView} from "./DeployDeepCoreDynamicFeeHook.s.sol";

/**
 * Deploys `DeepCoreBinDynamicFeeHook` (CreateX label `DEEPCORE_BIN_DYNAMIC_FEE_HOOK`) against DeepCore core's
 * BIN pool manager, and lists it in `DeepCoreRegistry` in the same session with the steward handed to Ops.
 * The twin of `DeployDeepCoreDynamicFeeHook.s.sol`: the same rules, the same NO-DEFAULT inputs (prefixed
 * `BINDYNFEE_`), plus: `BINDYNFEE_FEE_CAP` at most 100,000 (Bin's 10% ceiling).
 *
 * Env: PRIVATE_KEY | DEPLOYER (+ --account/--ledger), the DEEPCORE_BIN_DYNAMIC_FEE_HOOK salt pair,
 * BINDYNFEE_POOL_MANAGER, BINDYNFEE_OWNER, BINDYNFEE_RECIPIENT, BINDYNFEE_REGISTRY, BINDYNFEE_STEWARD,
 * BINDYNFEE_FEE_CAP, BINDYNFEE_PROTOCOL_SHARE_BPS, BINDYNFEE_MAX_PROTOCOL_SHARE_BPS,
 * BINDYNFEE_SHARE_NOTICE_SECONDS, BINDYNFEE_TUNER_NOTICE_SECONDS, BINDYNFEE_MAX_MOVE.
 */
contract DeployDeepCoreBinDynamicFeeHookScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_BIN_DYNAMIC_FEE_HOOK";
    uint32 internal constant PRODUCTION_MIN_SHARE_NOTICE = 7 days;
    uint16 internal constant BITMAP = 0x08C7;
    bytes4 internal constant RENOUNCE_DISABLED = bytes4(keccak256("RenounceDisabled()"));
    string internal constant SOURCE_URI = "https://deepcore.fun/docs#contracts";

    struct Params {
        uint256 pk;
        IBinPoolManager poolManager;
        address owner;
        address recipient;
        address registry;
        address steward;
        uint24 feeCap;
        uint16 shareBps;
        uint16 maxShareBps;
        uint32 shareNotice;
        uint32 tunerNotice;
        uint24 maxMove;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreBinDynamicFeeHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                poolManager: IBinPoolManager(vm.envAddress("BINDYNFEE_POOL_MANAGER")),
                owner: vm.envAddress("BINDYNFEE_OWNER"),
                recipient: vm.envAddress("BINDYNFEE_RECIPIENT"),
                registry: vm.envAddress("BINDYNFEE_REGISTRY"),
                steward: vm.envAddress("BINDYNFEE_STEWARD"),
                feeCap: uint24(_bounded("BINDYNFEE_FEE_CAP", type(uint24).max)),
                shareBps: uint16(_bounded("BINDYNFEE_PROTOCOL_SHARE_BPS", type(uint16).max)),
                maxShareBps: uint16(_bounded("BINDYNFEE_MAX_PROTOCOL_SHARE_BPS", type(uint16).max)),
                shareNotice: uint32(_bounded("BINDYNFEE_SHARE_NOTICE_SECONDS", type(uint32).max)),
                tunerNotice: uint32(_bounded("BINDYNFEE_TUNER_NOTICE_SECONDS", type(uint32).max)),
                maxMove: uint24(_bounded("BINDYNFEE_MAX_MOVE", type(uint24).max)),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function _bounded(string memory name, uint256 max) internal view returns (uint256 v) {
        v = vm.envUint(name);
        require(v <= max, string.concat(name, " overflows its type"));
    }

    function checkInputs(Params memory p, address deployer) public view {
        // Checked first so it is enforced (and testable) independently of the Safe-of-record check.
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(p.shareNotice >= PRODUCTION_MIN_SHARE_NOTICE, "BINDYNFEE_SHARE_NOTICE_SECONDS is under 7 days on a production chain");
        }
        require(address(p.poolManager).code.length > 0, "BINDYNFEE_POOL_MANAGER has no code");
        IVault vault = p.poolManager.vault();
        require(address(vault).code.length > 0, "the pool manager's vault has no code");
        DeepCoreGovernance.requireGovernanceSafe(p.owner, deployer, "BINDYNFEE_OWNER");
        DeepCoreGovernance.requireGovernanceSafe(p.recipient, deployer, "BINDYNFEE_RECIPIENT");
        require(p.registry.code.length > 0, "BINDYNFEE_REGISTRY has no code");
        require(p.steward != address(0), "BINDYNFEE_STEWARD is unset");
    }

    function initCode(Params memory p) public view returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreBinDynamicFeeHook).creationCode,
            abi.encode(
                p.poolManager, p.poolManager.vault(), p.owner, p.recipient, p.feeCap, p.shareBps, p.maxShareBps,
                p.shareNotice, p.tunerNotice, p.maxMove
            )
        );
    }

    /// @notice Refuses unless the pool manager's installed protocol fee controller answers
    /// `isZeroFeeHook(hook) == true`. A controller without the function (V3) refuses too.
    function requireListedAsZeroFee(address poolManager, address hook) public view {
        (bool ok, bytes memory ret) = poolManager.staticcall(abi.encodeWithSignature("protocolFeeController()"));
        require(ok && ret.length == 32, "the pool manager has no protocolFeeController()");
        address controller = abi.decode(ret, (address));
        (ok, ret) = controller.staticcall(abi.encodeWithSignature("isZeroFeeHook(address)", hook));
        require(
            ok && ret.length == 32 && abi.decode(ret, (bool)),
            "the installed fee controller does not list this hook as zero-fee: install V4 (C2) before D1/D2"
        );
    }

    function runWith(Params memory p) public returns (DeepCoreBinDynamicFeeHook hook) {
        address deployer = _signerOf(p.pk);
        require(p.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(p.target, LABEL);
        checkInputs(p, deployer);
        /* Owner decision 2026-09-29: these pools pay the hook's share and NOT the core fee. The installed
           controller must already list this hook's address, or the first pools opened on it are born paying
           both. So on a production chain the hook is deployed only after V4 (which lists it by address) is
           installed: step C2 before D1/D2. */
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            requireListedAsZeroFee(address(p.poolManager), DeepCoreDeploy.predict(p.target));
        }

        console.log("=== DeepCoreBinDynamicFeeHook ===");
        console.log("  chain id          ", block.chainid);
        console.log("  deployer          ", deployer);
        console.log("  bin pool manager  ", address(p.poolManager));
        console.log("  owner (Safe)      ", p.owner);
        console.log("  fee cap, pips     ", p.feeCap);
        console.log("  share / cap, bps  ", p.shareBps, p.maxShareBps);
        console.log("  will deploy to    ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        _startBroadcastAs(p.pk);
        hook = DeepCoreBinDynamicFeeHook(payable(DeepCoreDeploy.deploy(p.target, code, LABEL)));
        IDynFeeRegistry(p.registry).register(
            address(hook),
            DynFeeDeepCoreMetadata({
                name: "DeepCore Dynamic Fee (Bin)",
                description: "A dynamic fee for ordinary Bin pools: higher on volatility and on reversing trades within a second, capped per pool; active-bin mints pay it too; the protocol takes a fixed share of each swap's fee.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (p.steward != deployer) IDynFeeRegistry(p.registry).transferSteward(address(hook), p.steward);
        vm.stopBroadcast();

        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(hook.getHooksRegistrationBitmap() == BITMAP, "bitmap is not 0x08C7");
        require(address(hook.poolManager()) == address(p.poolManager), "poolManager mismatch");
        require(address(hook.vault()) == address(p.poolManager.vault()), "vault mismatch");
        require(hook.protocolRecipient() == p.recipient, "recipient mismatch");
        require(hook.FEE_CAP() == p.feeCap, "FEE_CAP mismatch");
        require(hook.MAX_PROTOCOL_SHARE_BPS() == p.maxShareBps, "share cap mismatch");
        require(hook.protocolShareBps() == p.shareBps, "share mismatch");
        require(IOwnable2StepView(address(hook)).owner() == p.owner, "owner is not BINDYNFEE_OWNER");
        require(IOwnable2StepView(address(hook)).pendingOwner() == address(0), "a pending owner exists at birth");
        (bool renounced, bytes memory reason) = address(hook).staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!renounced && reason.length == 4 && bytes4(reason) == RENOUNCE_DISABLED, "renounceOwnership does not revert RenounceDisabled");
        require(IDynFeeRegistry(p.registry).isRegistered(address(hook)), "the hook is not listed");

        console.log("DeepCoreBinDynamicFeeHook", address(hook));
        console.log("  runtime bytes     ", address(hook).code.length);
    }
}
