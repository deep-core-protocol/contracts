// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";
import {DeepCoreLiquidityRewardsHook} from "../src/DeepCoreLiquidityRewardsHook.sol";
import {LiquidityRewardsModule} from "../src/LiquidityRewardsModule.sol";

/// @notice `DeepCoreRegistry`'s `DeepCoreMetadata`, field for field (declared here so this package needs no
/// registry remapping; the post-flight reads the listing back).
struct RewardsDeepCoreMetadata {
    string name;
    string description;
    string sourceURI;
    string auditURI;
    uint256[] chainIds;
}

interface IRewardsRegistry {
    function register(address hook, RewardsDeepCoreMetadata calldata metadata) external;
    function transferSteward(address hook, address newSteward) external;
    function isRegistered(address hook) external view returns (bool);
}

interface IPosmManager {
    function clPoolManager() external view returns (ICLPoolManager);
}

/**
 * Deploys `DeepCoreLiquidityRewardsHook` (CreateX label `DEEPCORE_LIQUIDITY_REWARDS_HOOK`) against DeepCore core
 * and lists it in `DeepCoreRegistry` in the same session, handing the listing's steward to Ops.
 *
 * Every value below is a constructor immutable; a wrong one is a redeploy and a new salt. No defaults:
 *   LPR_POOL_MANAGER, LPR_POSITION_MANAGER (the canonical CLPositionManager of that manager)
 *   LPR_OWNER_SAFE, LPR_RECIPIENT       both the governance Safe on a production chain
 *   LPR_INITIAL_FEE_BPS                 design: 100 (1% of every funding)
 *   LPR_MAX_FEE_BPS                     design: 300 (the contract's ceiling)
 *   LPR_FEE_NOTICE_SECONDS              house: 604800 (7 days; at least 7 days on a production chain)
 *   LPR_RECYCLE_DELAY                   design: 7776000 (90 days)
 *   LPR_RECLAIM_DELAY                   design: 2592000 (30 days)
 *   LPR_MIN_ELIGIBLE_LIQUIDITY          the smallest liquidity a position needs to be mirrored
 *   LPR_REGISTRY, LPR_STEWARD (Ops)
 * Also: PRIVATE_KEY | DEPLOYER and the DEEPCORE_LIQUIDITY_REWARDS_HOOK salt pair.
 */
contract DeployDeepCoreLiquidityRewardsHookScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_LIQUIDITY_REWARDS_HOOK";
    uint16 internal constant BITMAP = 0x0095;
    string internal constant SOURCE_URI = "https://deepcore.fun/docs#contracts";

    struct Params {
        uint256 pk;
        ICLPoolManager poolManager;
        LiquidityRewardsModule.ModuleParams module;
        address registry;
        address steward;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreLiquidityRewardsHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                poolManager: ICLPoolManager(vm.envAddress("LPR_POOL_MANAGER")),
                module: LiquidityRewardsModule.ModuleParams({
                    owner: vm.envAddress("LPR_OWNER_SAFE"),
                    positionManager: vm.envAddress("LPR_POSITION_MANAGER"),
                    protocolFeeRecipient: vm.envAddress("LPR_RECIPIENT"),
                    initialFeeBps: uint16(_bounded("LPR_INITIAL_FEE_BPS", type(uint16).max)),
                    maxFeeBps: uint16(_bounded("LPR_MAX_FEE_BPS", type(uint16).max)),
                    feeNoticeSeconds: uint32(_bounded("LPR_FEE_NOTICE_SECONDS", type(uint32).max)),
                    recycleDelay: uint64(_bounded("LPR_RECYCLE_DELAY", type(uint64).max)),
                    reclaimDelay: uint64(_bounded("LPR_RECLAIM_DELAY", type(uint64).max)),
                    minEligibleLiquidity: uint128(_bounded("LPR_MIN_ELIGIBLE_LIQUIDITY", type(uint128).max))
                }),
                registry: vm.envAddress("LPR_REGISTRY"),
                steward: vm.envAddress("LPR_STEWARD"),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function _bounded(string memory name, uint256 max) internal view returns (uint256 v) {
        v = vm.envUint(name);
        require(v <= max, string.concat(name, " overflows its type"));
    }

    function checkInputs(Params memory p, address deployer) public view {
        require(address(p.poolManager).code.length > 0, "LPR_POOL_MANAGER has no code");
        require(p.module.positionManager.code.length > 0, "LPR_POSITION_MANAGER has no code");
        require(
            address(IPosmManager(p.module.positionManager).clPoolManager()) == address(p.poolManager),
            "LPR_POSITION_MANAGER serves another pool manager"
        );
        DeepCoreGovernance.requireGovernanceSafe(p.module.owner, deployer, "LPR_OWNER_SAFE");
        DeepCoreGovernance.requireGovernanceSafe(p.module.protocolFeeRecipient, deployer, "LPR_RECIPIENT");
        require(p.registry.code.length > 0, "LPR_REGISTRY has no code");
        require(p.steward != address(0), "LPR_STEWARD is unset");
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(p.module.feeNoticeSeconds >= 7 days, "LPR_FEE_NOTICE_SECONDS is under 7 days on a production chain");
            require(p.module.reclaimDelay >= 30 days && p.module.recycleDelay >= 30 days, "delays under 30 days");
        }
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(type(DeepCoreLiquidityRewardsHook).creationCode, abi.encode(p.poolManager, p.module));
    }

    function runWith(Params memory p) public returns (DeepCoreLiquidityRewardsHook hook) {
        address deployer = _signerOf(p.pk);
        require(p.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(p.target, LABEL);
        checkInputs(p, deployer);

        console.log("=== DeepCoreLiquidityRewardsHook ===");
        console.log("  chain id          ", block.chainid);
        console.log("  pool manager      ", address(p.poolManager));
        console.log("  position manager  ", p.module.positionManager);
        console.log("  owner (Safe)      ", p.module.owner);
        console.log("  recipient (Safe)  ", p.module.protocolFeeRecipient);
        console.log("  fee bps / cap     ", p.module.initialFeeBps, p.module.maxFeeBps);
        console.log("  will deploy to    ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        _startBroadcastAs(p.pk);
        hook = DeepCoreLiquidityRewardsHook(payable(DeepCoreDeploy.deploy(p.target, code, LABEL)));
        IRewardsRegistry(p.registry).register(
            address(hook),
            RewardsDeepCoreMetadata({
                name: "DeepCore Liquidity Rewards",
                description: "Streams project-funded rewards to in-range concentrated liquidity, per second, measured by the pool's own hook. REGISTERS LIQUIDITY CALLBACKS (add and remove) to measure time in range; the removal callback makes no external call, transfers nothing and cannot revert on reward accounting. Positions on this DeepCore cannot be locked in DeepCoreLPLocker.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (p.steward != deployer) IRewardsRegistry(p.registry).transferSteward(address(hook), p.steward);
        vm.stopBroadcast();

        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(hook.getHooksRegistrationBitmap() == BITMAP, "bitmap is not 0x0095");
        require(address(hook.poolManager()) == address(p.poolManager), "poolManager mismatch");
        require(hook.POSITION_MANAGER() == p.module.positionManager, "position manager mismatch");
        require(hook.owner() == p.module.owner, "owner mismatch");
        require(hook.protocolFeeRecipient() == p.module.protocolFeeRecipient, "recipient mismatch");
        require(hook.protocolFeeBps() == p.module.initialFeeBps, "fee mismatch");
        require(hook.maxProtocolFeeBps() == p.module.maxFeeBps, "cap mismatch");
        require(hook.feeNoticeSeconds() == p.module.feeNoticeSeconds, "notice mismatch");
        require(hook.RECYCLE_DELAY() == p.module.recycleDelay, "recycle delay mismatch");
        require(hook.RECLAIM_DELAY() == p.module.reclaimDelay, "reclaim delay mismatch");
        require(hook.MIN_ELIGIBLE_LIQUIDITY() == p.module.minEligibleLiquidity, "min liquidity mismatch");
        require(hook.kind() == keccak256("deepcore.liquidity-rewards.cl.v1"), "kind mismatch");
        require(IRewardsRegistry(p.registry).isRegistered(address(hook)), "the hook is not listed");
        console.log("DeepCoreLiquidityRewardsHook", address(hook));
        console.log("  runtime bytes     ", address(hook).code.length);
    }
}

/// @notice Devnet only (plain anvil): `new`, no CreateX, no registry. For the live bar against DevLocalStack.
/// Env: PRIVATE_KEY, LPR_POOL_MANAGER, LPR_POSITION_MANAGER, LPR_OWNER_SAFE, LPR_RECIPIENT.
contract DeployLiquidityRewardsDevScript is Script {
    function run() external returns (DeepCoreLiquidityRewardsHook hook) {
        require(!DeepCoreGovernance.isProductionChain(block.chainid), "devnet only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        hook = new DeepCoreLiquidityRewardsHook(
            ICLPoolManager(vm.envAddress("LPR_POOL_MANAGER")),
            LiquidityRewardsModule.ModuleParams({
                owner: vm.envAddress("LPR_OWNER_SAFE"),
                positionManager: vm.envAddress("LPR_POSITION_MANAGER"),
                protocolFeeRecipient: vm.envAddress("LPR_RECIPIENT"),
                initialFeeBps: 100,
                maxFeeBps: 300,
                feeNoticeSeconds: 7 days,
                recycleDelay: 90 days,
                reclaimDelay: 30 days,
                minEligibleLiquidity: 1_000
            })
        );
        vm.stopBroadcast();
        console.log("DeepCoreLiquidityRewardsHook", address(hook));
    }
}
