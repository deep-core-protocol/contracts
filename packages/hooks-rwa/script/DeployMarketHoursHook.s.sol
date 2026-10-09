// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {RwaReleaseBase} from "./RwaReleaseBase.sol";

/**
 * Deploys `MarketHoursHook` (CreateX label 18, `MARKET_HOURS_HOOK`) and lists it in `DeepCoreRegistry`.
 *
 * OWNERSHIP (CLAUDE.md Ownership table: `MarketHoursHook | owner | Safe`). Set in the constructor, so
 * the deployer never owns it and the Safe has nothing to accept. The owner's powers: `configureMarket`
 * (a pool's issuer, oracle, band widths, `bandEnabled`, `sessionEnabled`), `resetCalendar`,
 * `setMarketGuardian`, `rescueERC20` of misdirected tokens, two-step transfer. It cannot move an LP's
 * funds: no `beforeRemoveLiquidity` is registered, so nothing here can block an exit.
 *
 * AFTER DEPLOY THE SAFE SETS `marketGuardian` = Ops (halt only, never resume). Until then only an
 * issuer can halt a pool. That is a Safe transaction, batched in `ops/safe/rwa-release/`.
 *
 * Takes nothing and gates nothing until the Safe calls `configureMarket` for a pool: an unconfigured
 * pool cannot even be initialised on this hook.
 *
 * Env (see `ops/deploy/rwa-release-2026-09-28.md`):
 *   PRIVATE_KEY | DEPLOYER        signer (see RwaReleaseBase)
 *   DEEPCORE_SALT_MARKET_HOURS_HOOK / DEEPCORE_ADDRESS_MARKET_HOURS_HOOK   from salts-env.mjs
 *   RWA_CL_POOL_MANAGER           DeepCore core CL pool manager
 *   RWA_OWNER                     the governance Safe
 *   RWA_REGISTRY                  DeepCoreRegistry
 *   RWA_STEWARD                   Ops (registry listing steward, metadata only)
 */
contract DeployMarketHoursHookScript is RwaReleaseBase {
    string internal constant LABEL = "MARKET_HOURS_HOOK";

    /// @dev beforeInitialize (bit 0) | beforeAddLiquidity (2) | beforeSwap (6) | afterSwap (7).
    /// Written out rather than read from the hook: an assertion that reads its expectation from the
    /// thing under test asserts nothing.
    uint16 internal constant EXPECTED_BITMAP = 0x00C5;

    struct Params {
        Signer signer;
        address poolManager;
        address owner;
        address registry;
        address steward;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (MarketHoursHook hook) {
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
        return abi.encodePacked(type(MarketHoursHook).creationCode, abi.encode(ICLPoolManager(p.poolManager), p.owner));
    }

    function runWith(Params memory p) public returns (MarketHoursHook hook) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        _requireOwner(p.owner, deployer);
        _requireCore(p.poolManager);
        _requireRegistry(p.registry);
        require(p.steward != address(0), "RWA_STEWARD unset - the Ownership table assigns listing stewardship to Ops");
        require(p.steward != p.owner, "RWA_STEWARD must not be the Safe");

        console.log("=== MarketHoursHook ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Safe)    ", p.owner);
        console.log("  pool manager    ", p.poolManager);
        console.log("  registry        ", p.registry);
        console.log("  steward (Ops)   ", p.steward);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        hook = MarketHoursHook(DeepCoreDeploy.deploy(p.target, code, LABEL));
        _list(
            p.registry,
            address(hook),
            p.steward,
            deployer,
            "MarketHours",
            "Issuer-defined trading sessions, halts and a Chainlink price band for tokenized-equity pools. Never blocks a liquidity exit. Static-fee pools only."
        );
        vm.stopBroadcast();

        _postflight(hook, p);
    }

    function _postflight(MarketHoursHook hook, Params memory p) internal view {
        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        require(address(hook).code.length > 0, "hook has no code");
        _requireOwnership(address(hook), p.owner);
        require(address(hook.poolManager()) == p.poolManager, "pool manager mismatch");
        require(hook.getHooksRegistrationBitmap() == EXPECTED_BITMAP, "bitmap is not 0x00C5");
        require(hook.marketGuardian() == address(0), "a market guardian exists at birth");
        _requireListed(p.registry, address(hook), p.steward, EXPECTED_BITMAP);

        console.log("MarketHoursHook   ", address(hook));
        console.log("  owner           ", hook.owner());
        console.log("  bitmap          ", hook.getHooksRegistrationBitmap());
        console.log("  runtime bytes   ", address(hook).code.length);
        console.log("NEXT (Safe): setMarketGuardian(Ops). Then per pool: configureMarket before initialize.");
    }
}
