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
import {DeepCoreDexHook} from "../src/dex/DeepCoreDexHook.sol";

/// @notice `DeepCoreRegistry`'s `DeepCoreMetadata`, field for field (declared here so this package needs no
/// registry remapping; the post-flight reads the listing back, so a shape mismatch cannot be silent).
struct DexDeepCoreMetadata {
    string name;
    string description;
    string sourceURI;
    string auditURI;
    uint256[] chainIds;
}

interface IDexRegistry {
    function register(address hook, DexDeepCoreMetadata calldata metadata) external;
    function transferSteward(address hook, address newSteward) external;
    function isRegistered(address hook) external view returns (bool);
}

interface IDexOwnable2StepView {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/**
 * Deploys `DeepCoreDexHook` (CreateX label `DEEPCORE_DEX_HOOK`): the accepted dynamic-fee hook compiled with
 * `OracleModule`. It is pinned to 2,000 optimizer runs by the hooks package's `compilation_restrictions`
 * (26,582 bytes at the package's 25,666 runs, over EIP-170), so THIS script's compilation unit builds it
 * at 2,000 runs. Never deploy it through any other script, and never import it into the dynamic-fee
 * hook's own script: that would compile `DeepCoreDexHook` at 2,000 runs too (different code at
 * the same address).
 *
 * Inputs, no defaults: every DYNFEE_* value of `DeployDeepCoreDynamicFeeHook.s.sol` under the prefix DEX_
 * (DEX_FEE_CAP, DEX_PROTOCOL_SHARE_BPS, DEX_MAX_PROTOCOL_SHARE_BPS, DEX_SHARE_NOTICE_SECONDS,
 * DEX_TUNER_NOTICE_SECONDS, DEX_MAX_MOVE, DEX_POOL_MANAGER, DEX_OWNER, DEX_RECIPIENT, DEX_REGISTRY,
 * DEX_STEWARD), plus the oracle's ORACLE_MAX_TICK_DELTA, ORACLE_MIN_WINDOW_SECONDS and
 * ORACLE_INITIAL_CARDINALITY.
 *
 * THE ZERO-FEE LISTING. Pools on this hook pay the protocol share; unless the installed controller lists
 * the hook as zero-fee they ALSO pay the core protocol fee. `DeepCoreProtocolFeeControllerV4.addZeroFeeHook`
 * refuses an address with no code, so the listing can only follow the deployment: on a production chain
 * this script refuses unless `DEX_ZERO_FEE_LISTING_ACK=1`, which states that the Safe's
 * `addZeroFeeHook(<hook>)` is queued for the same session and that no pool is announced before it lands.
 */
contract DeployDeepCoreDexHookScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_DEX_HOOK";
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
        uint24 oracleMaxTickDelta;
        uint32 oracleMinWindow;
        uint16 oracleInitialCardinality;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreDexHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                poolManager: ICLPoolManager(vm.envAddress("DEX_POOL_MANAGER")),
                owner: vm.envAddress("DEX_OWNER"),
                recipient: vm.envAddress("DEX_RECIPIENT"),
                registry: vm.envAddress("DEX_REGISTRY"),
                steward: vm.envAddress("DEX_STEWARD"),
                feeCap: uint24(_bounded("DEX_FEE_CAP", type(uint24).max)),
                shareBps: uint16(_bounded("DEX_PROTOCOL_SHARE_BPS", type(uint16).max)),
                maxShareBps: uint16(_bounded("DEX_MAX_PROTOCOL_SHARE_BPS", type(uint16).max)),
                shareNotice: uint32(_bounded("DEX_SHARE_NOTICE_SECONDS", type(uint32).max)),
                tunerNotice: uint32(_bounded("DEX_TUNER_NOTICE_SECONDS", type(uint32).max)),
                maxMove: uint24(_bounded("DEX_MAX_MOVE", type(uint24).max)),
                oracleMaxTickDelta: uint24(_bounded("ORACLE_MAX_TICK_DELTA", type(uint24).max)),
                oracleMinWindow: uint32(_bounded("ORACLE_MIN_WINDOW_SECONDS", type(uint32).max)),
                oracleInitialCardinality: uint16(_bounded("ORACLE_INITIAL_CARDINALITY", type(uint16).max)),
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
            require(p.shareNotice >= PRODUCTION_MIN_SHARE_NOTICE, "DEX_SHARE_NOTICE_SECONDS is under 7 days on a production chain");
        }
        require(address(p.poolManager).code.length > 0, "DEX_POOL_MANAGER has no code");
        IVault vault = p.poolManager.vault();
        require(address(vault).code.length > 0, "the pool manager's vault has no code");
        DeepCoreGovernance.requireGovernanceSafe(p.owner, deployer, "DEX_OWNER");
        DeepCoreGovernance.requireGovernanceSafe(p.recipient, deployer, "DEX_RECIPIENT");
        require(p.registry.code.length > 0, "DEX_REGISTRY has no code");
        require(p.steward != address(0), "DEX_STEWARD is unset");
    }

    function initCode(Params memory p) public view returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreDexHook).creationCode,
            abi.encode(
                p.poolManager, p.poolManager.vault(), p.owner, p.recipient, p.feeCap, p.shareBps, p.maxShareBps,
                p.shareNotice, p.tunerNotice, p.maxMove, p.oracleMaxTickDelta, p.oracleMinWindow,
                p.oracleInitialCardinality
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
            "the installed fee controller does not list this hook as zero-fee: the Safe's addZeroFeeHook has not landed"
        );
    }

    function runWith(Params memory p) public returns (DeepCoreDexHook hook) {
        address deployer = _signerOf(p.pk);
        require(p.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(p.target, LABEL);
        checkInputs(p, deployer);
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(
                vm.envOr("DEX_ZERO_FEE_LISTING_ACK", uint256(0)) == 1,
                "set DEX_ZERO_FEE_LISTING_ACK=1: the Safe lists the hook with addZeroFeeHook in this session, before any pool"
            );
            require(p.oracleMinWindow >= 600, "ORACLE_MIN_WINDOW_SECONDS is under 600 on a production chain");
        }

        console.log("=== DeepCoreDexHook ===");
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
        hook = DeepCoreDexHook(payable(DeepCoreDeploy.deploy(p.target, code, LABEL)));
        // Listed in the same session: listing is permissionless, so left for later a stranger could list
        // the protocol's own hook first, with hostile metadata.
        IDexRegistry(p.registry).register(
            address(hook),
            DexDeepCoreMetadata({
                name: "DeepCore DEX (dynamic fee + price oracle)",
                description: "A dynamic fee for ordinary pools: higher on volatility and on reversing trades within a second, capped per pool; the protocol takes a fixed share of each swap's fee. Also a truncated time-weighted average tick other contracts read.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (p.steward != deployer) IDexRegistry(p.registry).transferSteward(address(hook), p.steward);
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
        require(hook.ORACLE_MAX_TICK_DELTA() == p.oracleMaxTickDelta, "oracle max tick delta mismatch");
        require(hook.ORACLE_MIN_WINDOW_SECONDS() == p.oracleMinWindow, "oracle min window mismatch");
        require(hook.ORACLE_INITIAL_CARDINALITY() == p.oracleInitialCardinality, "oracle initial cardinality mismatch");
        require(hook.kind() == keccak256("deepcore.oracle.truncated-twap.v1"), "oracle kind mismatch");
        require(address(hook).code.length <= 24_576, "over EIP-170: the 2,000-run pin did not apply");
        require(IDexOwnable2StepView(address(hook)).owner() == p.owner, "owner is not DEX_OWNER");
        require(IDexOwnable2StepView(address(hook)).pendingOwner() == address(0), "a pending owner exists at birth");
        (bool renounced, bytes memory reason) = address(hook).staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!renounced && reason.length == 4 && bytes4(reason) == RENOUNCE_DISABLED, "renounceOwnership does not revert RenounceDisabled");
        require(IDexRegistry(p.registry).isRegistered(address(hook)), "the hook is not listed");

        console.log("DeepCoreDexHook", address(hook));
        console.log("  NEXT (Safe): addZeroFeeHook(hook) on the installed controller, before any pool");
        console.log("  runtime bytes     ", address(hook).code.length);
    }
}
