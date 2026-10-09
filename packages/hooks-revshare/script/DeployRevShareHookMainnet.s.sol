// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {RevShareHook} from "../src/RevShareHook.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

/**
 * Deploys `RevShareHook` to a MAINNET chain.
 *
 * It deploys the hook and nothing else: no pools, liquidity or swaps happen as
 * a side effect of a deployment.
 *
 * OWNERSHIP IS SET IN THE CONSTRUCTOR, not transferred afterwards. `RevShareHook`
 * passes `owner_` straight to `Ownable(owner_)`, so there is no two-step dance and
 * no window where the deployer owns it. Per CLAUDE.md's Ownership table:
 *
 *   owner    -> Safe (the governance multisig, directly). Sets the guardian,
 *               pauses and unpauses. Global switches only; cannot reach user funds.
 *   guardian -> Ops. Can ONLY pause, never unpause. A pause during an incident
 *               cannot wait for two signatures, and a guardian that could unpause
 *               would be an owner wearing a smaller name.
 *
 * `renounceOwnership` reverts `RenounceDisabled` on this source, and the script
 * asserts it after deploy.
 *
 * The hook takes no fee until a pool owner calls `configure`, so deploying it
 * changes nothing on its own — it is infrastructure waiting to be pointed at.
 *
 * ####################### THE DELAY IS SECONDS NOW #######################
 *
 * DECIDED 2026-09-13 (Option B). Earlier versions of this hook were
 * block-denominated, and so depended on somebody declaring the chain's block time
 * correctly (on an Arbitrum Nitro chain `block.number` is Ethereum's ~12 s clock,
 * not the RPC's). This source takes the delay in seconds of `block.timestamp` and
 * has no block-time argument at all.
 *
 * `REVSHARE_CONFIG_DELAY_SECONDS` must be inside [12 h, 14 days]; 43200 is the
 * floor and the recommended value. The proposal TTL is a constant 3 days.
 *
 * THE CLOCK CHECK stays, in its timestamp form: before broadcasting, `run()` probes
 * the chain's `block.timestamp` and refuses unless it agrees with the RPC header
 * (60 s) and with this machine's wall clock (300 s). No waiting.
 *
 * ####################### THE ADDRESS IS MINED #######################
 *
 * CreateX `deployCreate3` at `DEEPCORE_SALT_REV_SHARE_HOOK` (owner decisions 2026-09-19/20: every mainnet
 * contract at `0x7878…78`, the same address on every chain). A hook's permissions come from
 * `getHooksRegistrationBitmap()`, a function, not from address bits as in Uniswap v4, so a mined hook
 * address is safe here. The hook address is part of every pool id it ever serves, so this address is the
 * one traders see forever - and the broadcast artifact records a CALL to CreateX, not a CREATE, so read
 * the hook address from this script's log rather than from `contractAddress`.
 *
 * Usage (dry run first — no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   CL_POOL_MANAGER=<this chain's DeepCore CLPoolManager, from its read-back>
 *   REVSHARE_OWNER=<governance Safe>  REVSHARE_GUARDIAN=<ops key>
 *   REVSHARE_CONFIG_DELAY_SECONDS=43200  REVSHARE_MAX_BENEFICIARIES=8
 *   forge script script/DeployRevShareHookMainnet.s.sol --rpc-url <chain>
 */
contract DeployRevShareHookMainnetScript is Script {
    struct Params {
        /// @dev Deployer key. Never a literal - `run` takes it from `PRIVATE_KEY`.
        uint256 pk;
        address poolManager;
        address owner;
        address guardian;
        uint256 configDelaySeconds;
        uint256 maxBeneficiaries;
        /// @dev The mined CreateX salt this hook's address comes from.
        DeepCoreDeploy.Target target;
    }

    /// @dev The env suffix and the line in `ops/deploy/salts/labels.txt`.
    string internal constant LABEL = "REV_SHARE_HOOK";

    /// @notice Entry point. Reads the environment and hands off to `runWith`.
    /// @dev Environment in one function, logic in another, so `runWith` can be driven by a test
    /// without `vm.setEnv` racing across concurrently-run test cases.
    function run() public returns (RevShareHook hook) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        console.log("chain clock: header / wall clock   ", clock.headerTimestamp, clock.wallClockSeconds);

        /* Every one of these has no safe default, which is why none is supplied.
           `vm.envUint` reverts on an unset variable, and that is the desired behaviour. */
        uint256 pk = vm.envUint("PRIVATE_KEY");
        return runWith(
            Params({
                pk: pk,
                poolManager: vm.envAddress("CL_POOL_MANAGER"),
                owner: vm.envAddress("REVSHARE_OWNER"),
                guardian: vm.envAddress("REVSHARE_GUARDIAN"),
                configDelaySeconds: vm.envUint("REVSHARE_CONFIG_DELAY_SECONDS"),
                maxBeneficiaries: vm.envUint("REVSHARE_MAX_BENEFICIARIES"),
                target: DeepCoreDeploy.fromEnv(LABEL, vm.addr(pk))
            })
        );
    }

    /// @notice The hook's creation code with this chain's constructor arguments.
    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(RevShareHook).creationCode,
            abi.encode(
                ICLPoolManager(p.poolManager), p.owner, p.guardian, uint40(p.configDelaySeconds), p.maxBeneficiaries
            )
        );
    }

    function runWith(Params memory p) public returns (RevShareHook hook) {
        address deployer = vm.addr(p.pk);

        require(p.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(p.target, LABEL);

        // A typo'd owner is almost always an EOA, and nothing downstream would
        // notice that the hook's pause switch answers to one key.
        require(p.owner.code.length > 0, "REVSHARE_OWNER has no code - must be the governance Safe");
        require(p.owner != deployer, "REVSHARE_OWNER must not be the deployer");
        DeepCoreGovernance.requireGovernanceSafe(p.owner, deployer, "REVSHARE_OWNER");
        require(p.guardian != address(0), "REVSHARE_GUARDIAN unset - the Ownership table assigns it to Ops");
        require(p.owner != p.guardian, "REVSHARE_OWNER and REVSHARE_GUARDIAN must differ");
        require(p.poolManager.code.length > 0, "CL_POOL_MANAGER has no code");

        /* The hook checks these too, and it must: a script is not a security boundary. They are
           repeated so a bad value fails with a sentence, before anything is signed. */
        require(p.configDelaySeconds >= 12 hours, "REVSHARE_CONFIG_DELAY_SECONDS is under the 12h floor");
        require(p.configDelaySeconds <= 14 days, "REVSHARE_CONFIG_DELAY_SECONDS is over the 14-day ceiling");
        require(p.maxBeneficiaries > 0 && p.maxBeneficiaries <= 32, "REVSHARE_MAX_BENEFICIARIES outside 1..32");

        console.log("=== RevShareHook ===");
        console.log("  chain id            ", block.chainid);
        console.log("  deployer            ", deployer);
        console.log("  owner (Safe)        ", p.owner);
        console.log("  guardian (Ops)      ", p.guardian);
        console.log("  config delay, s     ", p.configDelaySeconds);
        console.log("  config delay, h     ", p.configDelaySeconds / 1 hours);
        console.log("  maxBeneficiaries    ", p.maxBeneficiaries);
        console.log("  will deploy to      ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");
        console.log("");

        bytes memory code = initCode(p);
        vm.startBroadcast(p.pk);
        hook = RevShareHook(payable(DeepCoreDeploy.deploy(p.target, code, LABEL)));
        vm.stopBroadcast();

        require(address(hook) == DeepCoreDeploy.predict(p.target), "hook is not at the predicted address");
        _postflight(hook, p);
    }

    /// @dev Assert the deployed reality, not the intent. Every immutable and every constant a
    /// trader relies on is read back, because an immutable set wrong is a redeployment.
    function _postflight(RevShareHook hook, Params memory p) internal view {
        require(address(hook).code.length > 0, "hook has no code");
        require(hook.owner() == p.owner, "owner not set");
        require(hook.pendingOwner() == address(0), "a pending owner exists at birth");
        require(hook.guardian() == p.guardian, "guardian not set");
        require(!hook.paused(), "should not deploy paused");
        require(address(hook.poolManager()) == p.poolManager, "pool manager mismatch");
        require(
            address(hook.vault()) == address(ICLPoolManager(p.poolManager).vault()), "vault is not the manager's vault"
        );

        require(keccak256(bytes(hook.CLOCK_MODE())) == keccak256("mode=timestamp"), "hook is not timestamp-clocked");
        require(uint256(hook.CONFIG_DELAY_SECONDS()) == p.configDelaySeconds, "CONFIG_DELAY_SECONDS mismatch");
        require(uint256(hook.CONFIG_PROPOSAL_TTL_SECONDS()) == 3 days, "CONFIG_PROPOSAL_TTL_SECONDS moved");
        require(hook.MIN_CONFIG_DELAY_SECONDS() == 12 hours, "MIN_CONFIG_DELAY_SECONDS moved");
        require(hook.MAX_CONFIG_DELAY_SECONDS() == 14 days, "MAX_CONFIG_DELAY_SECONDS moved");
        require(hook.MAX_BENEFICIARIES() == p.maxBeneficiaries, "MAX_BENEFICIARIES mismatch");
        require(hook.MAX_FEE_PIPS() == 100_000, "MAX_FEE_PIPS moved");

        // `renounceOwnership` must revert for everybody. It is `pure`, so a static call proves it.
        (bool renounced,) = address(hook).staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!renounced, "renounceOwnership did not revert");

        uint16 bitmap = hook.getHooksRegistrationBitmap();

        console.log("RevShareHook          ", address(hook));
        console.log("  owner               ", hook.owner());
        console.log("  guardian            ", hook.guardian());
        console.log("  poolManager         ", address(hook.poolManager()));
        console.log("  vault               ", address(hook.vault()));
        console.log("  permission bitmap   ", bitmap);
        console.log("  CLOCK_MODE          ", hook.CLOCK_MODE());
        console.log("  CONFIG_DELAY_SECONDS", hook.CONFIG_DELAY_SECONDS());
        console.log("  PROPOSAL_TTL_SECONDS", hook.CONFIG_PROPOSAL_TTL_SECONDS());
        console.log("  MAX_BENEFICIARIES   ", hook.MAX_BENEFICIARIES());
        console.log("");
        console.log("Takes nothing until a pool owner calls configure().");
        console.log("A pool wanting a beneficiary share configures in steps while uninitialised:");
        console.log("  1. configure(key, {lpDonateBps: 10000})   - claims the pool");
        console.log("  2. setBeneficiaries(key, roster)");
        console.log("  3. configure(key, {beneficiaryBps: ...})  - the roster now exists");
    }
}
