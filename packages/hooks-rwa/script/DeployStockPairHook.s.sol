// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {StockPairHook} from "../src/StockPairHook.sol";
import {RwaReleaseBase} from "./RwaReleaseBase.sol";

/**
 * Deploys `StockPairHook` (CreateX label 19, `STOCK_PAIR_HOOK`) and lists it in `DeepCoreRegistry`.
 *
 * OWNERSHIP (CLAUDE.md: `StockPairHook` -> Safe, through its `PermissionedPoolHook` row). Set in the
 * constructor: no transfer window, nothing to accept. The owner's powers are the compliance side
 * (`configurePool`, `setTrustedRouter(s)`, allow/denylists, blocked jurisdictions, `pause`/`unpause`,
 * `resetInvestorLiquidity`) plus the market side (`configureMarket`, `resetCalendar`,
 * `setMarketGuardian`), `rescueERC20` and a two-step transfer. `beforeRemoveLiquidity` never calls the
 * oracle and never checks the pause; the ONE exit refusal is `freezeDeniedExits` on a locally
 * denylisted account, off by default. See the contract header.
 *
 * ⚠ THIS HOOK IS INERT UNTIL A TRUSTED ROUTER EXISTS. Every swap and every liquidity addition must
 * arrive through a router in `isTrustedRouter`, and that router must ATTEST the end user in `hookData`.
 * DeepCore's UniversalRouter forwards CALLER-supplied `hookData`, so it must NEVER be trusted here
 * (CLAUDE.md, protocol acceptance 2026-09-18). No attesting router exists on any chain today, so a
 * StockPairHook pool can be configured and initialised but cannot trade. Deploying it now reserves
 * the address and the listing; it does not open a market.
 *
 * AFTER DEPLOY THE SAFE SETS `marketGuardian` = Ops (batched in `ops/safe/rwa-release/`).
 *
 * Env: as `DeployMarketHoursHook.s.sol`, with the `STOCK_PAIR_HOOK` salt pair.
 */
contract DeployStockPairHookScript is RwaReleaseBase {
    string internal constant LABEL = "STOCK_PAIR_HOOK";

    /// @dev beforeInitialize (0) | beforeAddLiquidity (2) | beforeRemoveLiquidity (4) | beforeSwap (6)
    /// | afterSwap (7). Written out; not read from the hook under test.
    uint16 internal constant EXPECTED_BITMAP = 0x00D5;

    struct Params {
        Signer signer;
        address poolManager;
        address owner;
        address registry;
        address steward;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (StockPairHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        Signer memory s = _signerFromEnv();
        return runWith(
            Params({
                signer: s,
                poolManager: vm.envAddress("RWA_CL_POOL_MANAGER"),
                owner: vm.envAddress("RWA_OWNER"),
                registry: vm.envAddress("RWA_REGISTRY"),
                steward: vm.envAddress("RWA_STEWARD"),
                target: DeepCoreDeploy.fromEnv(LABEL, s.deployer)
            })
        );
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(type(StockPairHook).creationCode, abi.encode(ICLPoolManager(p.poolManager), p.owner));
    }

    function runWith(Params memory p) public returns (StockPairHook hook) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        _requireOwner(p.owner, deployer);
        _requireCore(p.poolManager);
        _requireRegistry(p.registry);
        require(p.steward != address(0), "RWA_STEWARD unset - the Ownership table assigns listing stewardship to Ops");
        require(p.steward != p.owner, "RWA_STEWARD must not be the Safe");

        console.log("=== StockPairHook ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Safe)    ", p.owner);
        console.log("  pool manager    ", p.poolManager);
        console.log("  registry        ", p.registry);
        console.log("  steward (Ops)   ", p.steward);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        hook = StockPairHook(DeepCoreDeploy.deploy(p.target, code, LABEL));
        _list(
            p.registry,
            address(hook),
            p.steward,
            deployer,
            "StockPair",
            "Compliance gate (trusted attesting router, allowlist, compliance oracle) plus issuer trading sessions and a Chainlink price band. Exit is never gated by the oracle, the pause or the calendar."
        );
        vm.stopBroadcast();

        _postflight(hook, p);
    }

    function _postflight(StockPairHook hook, Params memory p) internal view {
        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(address(hook).code.length > 0, "hook has no code");
        _requireOwnership(address(hook), p.owner);
        require(address(hook.poolManager()) == p.poolManager, "pool manager mismatch");
        require(hook.getHooksRegistrationBitmap() == EXPECTED_BITMAP, "bitmap is not 0x00D5");
        require(!hook.paused(), "should not deploy paused");
        require(hook.marketGuardian() == address(0), "a market guardian exists at birth");
        require(hook.ORACLE_GAS_LIMIT() == 250_000, "ORACLE_GAS_LIMIT moved");
        // Nobody is trusted at birth; in particular not the deployer and not the Safe itself.
        require(!hook.isTrustedRouter(p.signer.deployer), "deployer is a trusted router at birth");
        require(!hook.isTrustedRouter(p.owner), "owner is a trusted router at birth");
        _requireListed(p.registry, address(hook), p.steward, EXPECTED_BITMAP);

        console.log("StockPairHook     ", address(hook));
        console.log("  owner           ", hook.owner());
        console.log("  bitmap          ", hook.getHooksRegistrationBitmap());
        console.log("  runtime bytes   ", address(hook).code.length);
        console.log("NEXT (Safe): setMarketGuardian(Ops). No trusted router exists: the hook cannot trade yet.");
    }
}
