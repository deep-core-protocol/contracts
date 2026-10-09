// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreRegistry} from "deepcore-registry/src/DeepCoreRegistry.sol";
import {DeepCoreMetadata} from "deepcore-registry/src/IDeepCoreRegistry.sol";

/**
 * STEP 1 OF 2. Deploys `LaunchGuardHook` to a MAINNET chain AND lists it in the registry.
 *
 * `LaunchpadKit` binds a hook address as an IMMUTABLE and verifies it in its own
 * constructor, so the hook has to exist first. Run this, then feed the address
 * it prints to `DeployLaunchpadKitV2.s.sol` as `LAUNCH_GUARD_HOOK`.
 *
 * WHY THE LISTING IS IN THIS SCRIPT. CLAUDE.md's Ownership table: "list the hook in
 * the same session it is deployed, or a stranger can list the protocol's own hook
 * first, with hostile metadata." `DeepCoreRegistry.register` is open to anyone. So the
 * registration is the very next broadcast after the deployment, and stewardship is
 * handed straight to the Ops steward (`LAUNCH_GUARD_STEWARD`). If a stranger does
 * win the race, the script refuses to report success, and `CURATOR_ROLE` (Ops) can
 * reassign the steward with `transferSteward` - metadata only, nothing custodial.
 *
 * WHY THE HOOK IS DEPLOYED SEPARATELY AND SHARED. The hook holds one `Launch` record
 * per pool id. Every kit and every launch on this chain should point at ONE hook,
 * because a pool key names the hook by address: two hooks means two disjoint
 * universes of pools and a registry listing that describes only half of them.
 *
 * THIS CONTRACT HAS NO OWNER, NO GUARDIAN AND NO ADMIN. That is not an
 * oversight to be corrected by a follow-up transfer — it is the design, and the
 * Ownership table records the absence as a decision. The one authority that exists
 * is per-pool `launchOwner`, established by first-claim, neither transferable nor
 * renounceable, and powerless from `startTime` onward. Do not add an owner.
 *
 * EVERY DURATION IS `block.timestamp` SECONDS (Option B, 2026-09-13). An earlier
 * version of this hook took `blockTimeCentis = 10` and 26 000 000-block caps, which on
 * an Arbitrum Nitro chain's real ~12 s contract clock is ~9.9 years. This source has a single
 * constructor argument — the pool manager — and constant bounds: decay in
 * [60 s, 30 days], start at most 30 days ahead. Nothing about the chain's block
 * cadence is declared, so nothing can be declared wrong.
 *
 * POOL-ID RESERVATION (owner decision, 2026-09-14). The hook refuses a first claim on a
 * currency with no code, and gives a `LaunchTokenFactory` token's launch pools to that token's
 * creator (the kit, for kit-created tokens). `LAUNCH_TOKEN_FACTORY` is therefore IMMUTABLE on
 * the hook: deploy the factory FIRST and pass it here. `address(0)` is accepted only when typed
 * explicitly and means "no factory tokens get reserved pools on this hook, ever" - a hook is part
 * of every pool id, so fixing that later means another hook and another pool universe.
 *
 * THE CLOCK CHECK. `run()` probes the chain's `block.timestamp` via `eth_call` and
 * refuses unless it agrees with the RPC header (60 s) and this machine's wall
 * clock (300 s). A sequencer running ahead, or catching up from an outage, is the
 * wrong moment to deploy time-bounded contracts. No waiting is involved.
 *
 * BUILD PROFILE: THE DEFAULT ONE. HyperEVM supports EIP-1153 (Cancun), so this deploys
 * the cancun build. Do NOT reach for the legacy profile on a Cancun chain: the Vault and
 * position manager there are the cancun build.
 *
 * ############################ THE ADDRESS IS MINED, NOT NONCE-DERIVED ############################
 *
 * Changed 2026-09-20 (G-4). This used to say "NO CREATE3 ... a plain `new` keeps the broadcast
 * artifact's `contractAddress` honest", which was true when only the pad factory needed a cross-chain
 * address. Under the owner's decisions (every mainnet contract at `0x7878…78`, the same address on
 * every chain) the hook goes through CreateX `deployCreate3` at
 * `DEEPCORE_SALT_LAUNCH_GUARD_HOOK_QF` like everything else. Two things follow and both matter:
 *   - the hook's permissions come from `getHooksRegistrationBitmap()`, a FUNCTION, not from address
 *     bits as in Uniswap v4, so a mined hook address is safe here and the bitmap is still asserted;
 *   - the broadcast artifact records a CALL to CreateX, so `contractAddress` is CreateX's, not the
 *     hook's. Read the hook's address from this script's log or from `DEEPCORE_ADDRESS_LAUNCH_GUARD_HOOK_QF`.
 *
 * Usage (dry run first — no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   CL_POOL_MANAGER=<this chain's DeepCore CLPoolManager> \
 *   LAUNCH_TOKEN_FACTORY=<deployed LaunchTokenFactory> \
 *   LAUNCH_GUARD_REGISTRY=<this chain's DeepCoreRegistry> \
 *   LAUNCH_GUARD_STEWARD=<ops key> TAX_PROTOCOL_RECIPIENT=<the Safe> LAUNCH_LP_SHARE_BPS=<0..5000> \
 *   forge script script/DeployLaunchGuardHookMainnet.s.sol --rpc-url $RPC
 *
 * Then, when a human has read the simulation:
 *   ... --broadcast --slow
 */
contract DeployLaunchGuardHookMainnetScript is DeepCoreSignerScript {
    /// @dev `beforeInitialize` (bit 0) | `beforeSwap` (bit 6) | `afterSwap` (bit 7) |
    /// `beforeSwapReturnsDelta` (bit 10) | `afterSwapReturnsDelta` (bit 11): the two hook deltas
    /// the guard takes its fee and the creator tax through, in the quote currency. Duplicated from
    /// `LaunchpadKitV2.CL_HOOK_BITMAP` on purpose: an assertion that reads its
    /// expectation from the thing under test asserts nothing.
    uint16 internal constant EXPECTED_HOOK_BITMAP = 0x0CC1;

    string internal constant LABEL = "LAUNCH_GUARD_HOOK_QF";

    string internal constant SOURCE_URI =
        "https://deepcore.fun/docs#contracts";

    /// @notice Entry point. Reads the environment and hands off to `runWith`.
    /// @dev The environment is read HERE AND NOWHERE ELSE, so `runWith` can be driven directly by
    /// `test/DeployScripts.t.sol` without `vm.setEnv` racing across concurrent test cases.
    function run() public returns (LaunchGuardHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        console.log("chain clock: header / wall clock   ", clock.headerTimestamp, clock.wallClockSeconds);
        uint256 pk = _pkFromEnv();
        return runWith(
            pk,
            vm.envAddress("CL_POOL_MANAGER"),
            vm.envAddress("LAUNCH_TOKEN_FACTORY"),
            vm.envAddress("LAUNCH_GUARD_REGISTRY"),
            vm.envAddress("LAUNCH_GUARD_STEWARD"),
            vm.envAddress("TAX_PROTOCOL_RECIPIENT"),
            _lpShareFromEnv(),
            DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
        );
    }

    /// @dev `LAUNCH_LP_SHARE_BPS` has NO default: the share is immutable and the same for every pool
    /// this guard will ever run, so it is stated for every deployment, zero included.
    function _lpShareFromEnv() internal view returns (uint16) {
        uint256 v = vm.envUint("LAUNCH_LP_SHARE_BPS");
        require(v <= 5_000, "LAUNCH_LP_SHARE_BPS is above the guard's cap (5000)");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(v);
    }

    /// @param pk Deployer key. Never a literal - `run` takes it from `PRIVATE_KEY`.
    /// @param poolManager The CL singleton this hook will serve, forever.
    /// @param factory The `LaunchTokenFactory` whose tokens get reserved launch pools, or zero.
    /// @param registry The LIVE `DeepCoreRegistry`. Required: listing is part of this deployment.
    /// @param steward The Ops key that ends up holding the listing's metadata rights.
    /// @param taxRecipient Where the protocol bucket of the fee and of the creator tax is credited, forever:
    /// the governance Safe.
    /// @param lpShareBps The share of the trade fee left to the pool as its LP fee, on buys, forever.
    /// @param target The mined CreateX salt this hook's address comes from.
    function runWith(
        uint256 pk,
        address poolManager,
        address factory,
        address registry,
        address steward,
        address taxRecipient,
        uint16 lpShareBps,
        DeepCoreDeploy.Target memory target
    ) public returns (LaunchGuardHook hook) {
        address deployer = _signerOf(pk);
        require(taxRecipient.code.length > 0, "TAX_PROTOCOL_RECIPIENT has no code - a Safe, not an EOA");
        require(taxRecipient != deployer, "TAX_PROTOCOL_RECIPIENT is the deployer");
        DeepCoreGovernance.requireGovernanceSafe(taxRecipient, deployer, "TAX_PROTOCOL_RECIPIENT");

        /* ---- pre-flight, before anything is broadcast ------------------- */

        require(target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(target, LABEL);

        // The pool manager is an immutable on the hook. A typo here produces a
        // hook that every `configureLaunch` rejects with `PoolManagerMismatch`,
        // which reads like a caller error rather than a deployment error.
        require(poolManager.code.length > 0, "CL_POOL_MANAGER has no code - not a contract");
        require(poolManager != deployer, "CL_POOL_MANAGER is the deployer - wrong address");
        if (factory != address(0)) {
            require(factory.code.length > 0, "LAUNCH_TOKEN_FACTORY has no code - deploy the factory first");
            // A factory answers `deployerOf` (zero for an unknown token) and has an init-code hash.
            // Probed with the deployer EOA, which can never be a factory token. NOT `address(this)`: forge
            // refuses `address(this)` inside a script contract (`forge script` 1.8.1), and the test suite,
            // which drives `runWith` from a test contract, never sees that refusal.
            require(ILaunchTokenOrigin(factory).deployerOf(deployer) == address(0), "LAUNCH_TOKEN_FACTORY is not a factory");
            (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSignature("launchTokenInitCodeHash()"));
            require(ok && ret.length == 32 && bytes32(ret) != bytes32(0), "LAUNCH_TOKEN_FACTORY has no launchTokenInitCodeHash");
        }
        require(registry.code.length > 0, "LAUNCH_GUARD_REGISTRY has no code - list in the same session");
        require(steward != address(0), "LAUNCH_GUARD_STEWARD unset - the Ownership table assigns it to Ops");
        // Probing a view is free; a registry with the wrong ABI reverts here, not after deploying.
        DeepCoreRegistry(registry).deepcoreCount();

        console.log("=== LaunchGuardHook ===");
        console.log("  chain id      ", block.chainid);
        console.log("  deployer      ", deployer);
        console.log("  poolManager   ", poolManager);
        console.log("  token factory ", factory);
        console.log("  registry      ", registry);
        console.log("  steward (Ops) ", steward);
        console.log("  tax recipient ", taxRecipient);
        console.log("  will deploy to", DeepCoreDeploy.predict(target), "(CREATE3 via CreateX)");
        console.log("");

        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;

        bytes memory code = abi.encodePacked(
            type(LaunchGuardHook).creationCode,
            abi.encode(ICLPoolManager(poolManager), ILaunchTokenOrigin(factory), taxRecipient, lpShareBps)
        );

        _startBroadcastAs(pk);
        hook = LaunchGuardHook(payable(DeepCoreDeploy.deploy(target, code, LABEL)));
        // Same session, next transaction. See the header.
        DeepCoreRegistry(registry).register(
            address(hook),
            DeepCoreMetadata({
                name: "LaunchGuard",
                description: "Decaying sniper tax and a frozen, expiring creator tax, priced on block.timestamp, not identity. Requires a dynamic-fee pool.",
                sourceURI: SOURCE_URI,
                auditURI: "",
                chainIds: chains
            })
        );
        if (steward != deployer) DeepCoreRegistry(registry).transferSteward(address(hook), steward);
        vm.stopBroadcast();

        _postflight(hook, poolManager, registry, steward, deployer);
        require(address(hook) == DeepCoreDeploy.predict(target), "hook is not at the predicted address");
        require(address(hook.LAUNCH_TOKEN_FACTORY()) == factory, "LAUNCH_TOKEN_FACTORY mismatch");
        require(hook.protocolRecipient() == taxRecipient, "tax protocolRecipient mismatch");
        require(hook.LP_SHARE_BPS() == lpShareBps, "LP_SHARE_BPS mismatch");
        require(hook.MAX_LP_SHARE_BPS() == 5_000 && hook.MIN_FEE_PROTOCOL_BPS() == 2_000, "fee bounds moved");
        console.log("  LP_SHARE_BPS          ", hook.LP_SHARE_BPS());
        require(address(hook.vault()) == address(ICLPoolManager(poolManager).vault()), "tax vault mismatch");
        require(hook.MAX_TAX_BPS() == 1_000 && hook.MIN_PROTOCOL_BPS() == 1_000, "tax bounds moved");
        require(hook.MAX_PROTOCOL_BPS() == 5_000 && hook.MAX_INTEGRATOR_BPS() == 2_000, "tax caps moved");
        require(hook.MAX_TAX_DURATION_SECONDS() == 180 days, "tax duration cap moved");
        console.log("  tax protocolRecipient ", hook.protocolRecipient());
        console.log("  LAUNCH_TOKEN_FACTORY  ", address(hook.LAUNCH_TOKEN_FACTORY()));
    }

    /// @dev Assert the deployed reality, not the intent.
    function _postflight(LaunchGuardHook hook, address poolManager, address registry, address steward, address deployer)
        internal
        view
    {
        require(address(hook).code.length > 0, "hook has no code");
        require(address(hook.poolManager()) == poolManager, "hook serves a different pool manager");

        uint16 bitmap = hook.getHooksRegistrationBitmap();
        require(bitmap == EXPECTED_HOOK_BITMAP, "unexpected permission bitmap");

        // The bounds that keep a hostile launch owner inside a survivable envelope. Constants now,
        // and read back anyway: this is the bytecode a launcher will trust without reading it.
        require(keccak256(bytes(hook.CLOCK_MODE())) == keccak256("mode=timestamp"), "hook is not timestamp-clocked");
        require(hook.MAX_INITIAL_FEE() == 500_000, "MAX_INITIAL_FEE moved");
        require(hook.MAX_FINAL_FEE() == 100_000, "MAX_FINAL_FEE moved");
        require(hook.MIN_DECAY_SECONDS() == 60, "MIN_DECAY_SECONDS moved");
        require(hook.MAX_DECAY_SECONDS() == 30 days, "MAX_DECAY_SECONDS moved");
        require(hook.MAX_START_DELAY_SECONDS() == 30 days, "MAX_START_DELAY_SECONDS moved");
        require(
            uint256(hook.MAX_START_DELAY_SECONDS()) + hook.MAX_DECAY_SECONDS() <= hook.MAX_LAUNCH_WINDOW_SECONDS(),
            "a launch tax could outlive the 180-day ceiling"
        );

        DeepCoreRegistry reg = DeepCoreRegistry(registry);
        require(reg.isRegistered(address(hook)), "hook was not listed");
        require(reg.getDeepCore(address(hook)).steward == steward, "listing steward is not the Ops steward");
        require(reg.getDeepCore(address(hook)).submitter == deployer, "someone else listed this hook first");
        require(reg.getDeepCore(address(hook)).permissions == bitmap, "registry did not read the hook's bitmap");

        console.log("LaunchGuardHook         ", address(hook));
        console.log("  poolManager           ", address(hook.poolManager()));
        console.log("  permission bitmap     ", bitmap, "(beforeInitialize | beforeSwap | afterSwap | afterSwapReturnsDelta)");
        console.log("  CLOCK_MODE            ", hook.CLOCK_MODE());
        console.log("  decay window, s       ", hook.MIN_DECAY_SECONDS(), hook.MAX_DECAY_SECONDS());
        console.log("  max start delay, s    ", hook.MAX_START_DELAY_SECONDS());
        console.log("  listed; steward      ", steward);
        console.log("");
        console.log("No owner, no guardian, no admin. Nothing to transfer, by design.");
        console.log("");
        console.log("NEXT: export LAUNCH_GUARD_HOOK=<the address above>");
        console.log("      then run script/DeployLaunchpadKitV2.s.sol");
    }
}
