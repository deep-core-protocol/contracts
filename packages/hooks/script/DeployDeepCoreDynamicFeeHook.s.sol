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
import {DeepCoreDynamicFeeHook} from "../src/dex/DeepCoreDynamicFeeHook.sol";

/// @notice `DeepCoreRegistry`'s `DeepCoreMetadata`, field for field (declared here so this package needs no
/// registry remapping; the post-flight reads the listing back, so a shape mismatch cannot be silent).
struct DynFeeDeepCoreMetadata {
    string name;
    string description;
    string sourceURI;
    string auditURI;
    uint256[] chainIds;
}

interface IDynFeeRegistry {
    function register(address hook, DynFeeDeepCoreMetadata calldata metadata) external;
    function transferSteward(address hook, address newSteward) external;
    function isRegistered(address hook) external view returns (bool);
}

interface IOwnable2StepView {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/**
 * Deploys `DeepCoreDynamicFeeHook` (CreateX label `DEEPCORE_DYNAMIC_FEE_HOOK`) against DeepCore core, and lists
 * it in `DeepCoreRegistry` in the same session, handing the listing's steward to Ops.
 *
 * EVERY ECONOMIC VALUE IS AN INPUT WITH NO DEFAULT. `FEE_CAP`, the share cap and both notices are
 * immutable: a wrong value is a redeploy AND a new salt (the mined address is then taken). They are the
 * owner's decisions, so the script refuses to guess them:
 *   DYNFEE_FEE_CAP                   pips, 1 .. 100,000 (the design recommends 50,000 = 5%)
 *   DYNFEE_PROTOCOL_SHARE_BPS        the share for the first pools, <= the cap
 *   DYNFEE_MAX_PROTOCOL_SHARE_BPS    the immutable ceiling, <= 5,000
 *   DYNFEE_SHARE_NOTICE_SECONDS      >= 7 days on a production chain (1 day is the contract's floor)
 *   DYNFEE_TUNER_NOTICE_SECONDS      >= 1 day
 *   DYNFEE_MAX_MOVE                  ticks, 1 .. 2,000
 *
 * On a production chain the owner AND the protocol recipient must be the governance Safe of record
 * (`DeepCoreGovernance.SAFE`, refused while unset). The pool manager and registry are checked for code;
 * no core of record exists yet, so they are not pinned to an address.
 *
 * Env also: PRIVATE_KEY | DEPLOYER (+ --account/--ledger), the DEEPCORE_DYNAMIC_FEE_HOOK salt pair,
 * DYNFEE_POOL_MANAGER, DYNFEE_OWNER, DYNFEE_RECIPIENT, DYNFEE_REGISTRY, DYNFEE_STEWARD (Ops).
 */
contract DeployDeepCoreDynamicFeeHookScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_DYNAMIC_FEE_HOOK";
    uint32 internal constant PRODUCTION_MIN_SHARE_NOTICE = 7 days;
    uint16 internal constant BITMAP = 0x08C3;
    bytes4 internal constant RENOUNCE_DISABLED = bytes4(keccak256("RenounceDisabled()"));
    string internal constant SOURCE_URI = "https://deepcore.fun/docs#contracts";

    struct Params {
        uint256 pk;
        ICLPoolManager poolManager;
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

    function run() public returns (DeepCoreDynamicFeeHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                poolManager: ICLPoolManager(vm.envAddress("DYNFEE_POOL_MANAGER")),
                owner: vm.envAddress("DYNFEE_OWNER"),
                recipient: vm.envAddress("DYNFEE_RECIPIENT"),
                registry: vm.envAddress("DYNFEE_REGISTRY"),
                steward: vm.envAddress("DYNFEE_STEWARD"),
                feeCap: uint24(_bounded("DYNFEE_FEE_CAP", type(uint24).max)),
                shareBps: uint16(_bounded("DYNFEE_PROTOCOL_SHARE_BPS", type(uint16).max)),
                maxShareBps: uint16(_bounded("DYNFEE_MAX_PROTOCOL_SHARE_BPS", type(uint16).max)),
                shareNotice: uint32(_bounded("DYNFEE_SHARE_NOTICE_SECONDS", type(uint32).max)),
                tunerNotice: uint32(_bounded("DYNFEE_TUNER_NOTICE_SECONDS", type(uint32).max)),
                maxMove: uint24(_bounded("DYNFEE_MAX_MOVE", type(uint24).max)),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function _bounded(string memory name, uint256 max) internal view returns (uint256 v) {
        v = vm.envUint(name);
        require(v <= max, string.concat(name, " overflows its type"));
    }

    /// @notice Everything checked before broadcast. Public so a test can drive it without a deploy.
    function checkInputs(Params memory p, address deployer) public view {
        // Checked first so it is enforced (and testable) independently of the Safe-of-record check.
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(p.shareNotice >= PRODUCTION_MIN_SHARE_NOTICE, "DYNFEE_SHARE_NOTICE_SECONDS is under 7 days on a production chain");
        }
        require(address(p.poolManager).code.length > 0, "DYNFEE_POOL_MANAGER has no code");
        IVault vault = p.poolManager.vault();
        require(address(vault).code.length > 0, "the pool manager's vault has no code");
        DeepCoreGovernance.requireGovernanceSafe(p.owner, deployer, "DYNFEE_OWNER");
        DeepCoreGovernance.requireGovernanceSafe(p.recipient, deployer, "DYNFEE_RECIPIENT");
        require(p.registry.code.length > 0, "DYNFEE_REGISTRY has no code");
        require(p.steward != address(0), "DYNFEE_STEWARD is unset");
    }

    function initCode(Params memory p) public view returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreDynamicFeeHook).creationCode,
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

    function runWith(Params memory p) public returns (DeepCoreDynamicFeeHook hook) {
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

        console.log("=== DeepCoreDynamicFeeHook ===");
        console.log("  chain id          ", block.chainid);
        console.log("  deployer          ", deployer);
        console.log("  pool manager      ", address(p.poolManager));
        console.log("  owner (Safe)      ", p.owner);
        console.log("  recipient (Safe)  ", p.recipient);
        console.log("  fee cap, pips     ", p.feeCap);
        console.log("  share / cap, bps  ", p.shareBps, p.maxShareBps);
        console.log("  notices, s        ", p.shareNotice, p.tunerNotice);
        console.log("  will deploy to    ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        _startBroadcastAs(p.pk);
        hook = DeepCoreDynamicFeeHook(payable(DeepCoreDeploy.deploy(p.target, code, LABEL)));
        // Listed in the same session: listing is permissionless, so left for later a stranger could list
        // the protocol's own hook first, with hostile metadata.
        IDynFeeRegistry(p.registry).register(
            address(hook),
            DynFeeDeepCoreMetadata({
                name: "DeepCore Dynamic Fee",
                description: "A dynamic fee for ordinary pools: higher on volatility and on reversing trades within a second, capped per pool; the protocol takes a fixed share of each swap's fee.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (p.steward != deployer) IDynFeeRegistry(p.registry).transferSteward(address(hook), p.steward);
        vm.stopBroadcast();

        // ---- read-backs, not script logs ----
        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(hook.getHooksRegistrationBitmap() == BITMAP, "bitmap is not 0x08C3");
        require(address(hook.poolManager()) == address(p.poolManager), "poolManager mismatch");
        require(address(hook.vault()) == address(p.poolManager.vault()), "vault mismatch");
        require(hook.protocolRecipient() == p.recipient, "recipient mismatch");
        require(hook.FEE_CAP() == p.feeCap, "FEE_CAP mismatch");
        require(hook.MAX_PROTOCOL_SHARE_BPS() == p.maxShareBps, "share cap mismatch");
        require(hook.protocolShareBps() == p.shareBps, "share mismatch");
        require(hook.SHARE_NOTICE_SECONDS() == p.shareNotice && hook.TUNER_NOTICE_SECONDS() == p.tunerNotice, "notice mismatch");
        require(IOwnable2StepView(address(hook)).owner() == p.owner, "owner is not DYNFEE_OWNER");
        require(IOwnable2StepView(address(hook)).pendingOwner() == address(0), "a pending owner exists at birth");
        (bool renounced, bytes memory reason) = address(hook).staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!renounced && reason.length == 4 && bytes4(reason) == RENOUNCE_DISABLED, "renounceOwnership does not revert RenounceDisabled");
        require(IDynFeeRegistry(p.registry).isRegistered(address(hook)), "the hook is not listed");

        console.log("DeepCoreDynamicFeeHook", address(hook));
        console.log("  runtime bytes     ", address(hook).code.length);
    }
}
