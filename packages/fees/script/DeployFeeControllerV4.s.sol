// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {ILockedLaunchOracle} from "../src/interfaces/ILockedLaunchOracle.sol";

interface IV2IdentityForV4 {
    function owner() external view returns (address);
    function DYNAMIC_FEE_PIPS() external view returns (uint16);
    function DEFAULT_SPLIT_RATIO() external view returns (uint256);
    function MAX_PROTOCOL_FEE() external view returns (uint16);
}

/**
 * Deploys DeepCoreProtocolFeeControllerV4: V3's zero rule for a fixed SET of kits instead of one.
 * Design: the header of src/DeepCoreProtocolFeeControllerV4.sol, over packages/fees/docs/controller-v3.md.
 *
 * INERT UNTIL INSTALLED. Deploying this changes no pool's fee. It prices nothing until the custody
 * timelock executes `setProtocolFeeController(V4)` on both pool-manager owner wrappers, a 48h
 * operation whose calldata `BuildInstallFeeControllerV4.s.sol` prints.
 *
 * OWNERSHIP, per the CLAUDE.md table (`DeepCoreProtocolFeeController` owner = Safe): set in the
 * constructor, never transferred, so the deployer key never holds it. V4 has no guardian; the
 * Ops guardian stays on V2, where it can only disable fees.
 *
 * THE ORACLES ARE PERMANENT. `LAUNCH_ORACLES` becomes immutables: there is no setter, so a kit left
 * out of the list is a kit whose pools this controller will never recognise, and a wrong address in
 * the list can waive the core fee on whatever it chooses to vouch for, for as long as the controller
 * is installed. Every entry must be a DeepCore kit itself (owned by the Safe), never an adapter. List
 * EVERY kit whose pools must keep their zero: the first kit as well as the newest. Order changes gas
 * only; put the kit that launches most first.
 *
 * THE ADDRESS. CreateX `deployCreate3` at `DEEPCORE_SALT_DEEPCORE_FEE_CONTROLLER_V4`, mined for the deployer
 * and chain-id free, so V4 has the same address on every chain even though its policy and kit
 * arguments differ per chain (`ops/deploy/salts/README.md`). Note what that does NOT mean: the
 * controller is still inert until a custody batch installs it on that chain's wrappers.
 *
 * Every input comes from the environment and is checked on chain BEFORE broadcasting; every
 * immutable is read back AFTER.
 *
 *   PRIVATE_KEY        deployer (gas only)
 *   FEE_OWNER_SAFE     governance Safe
 *   FEE_POLICY_V2      live DeepCoreProtocolFeeControllerV2
 *   LAUNCH_ORACLES     the kit deployments, comma separated, 1 to 4 - never an adapter
 *   ZERO_FEE_HOOKS     hooks whose pools are born at zero core fee, comma separated, or `none`.
 *                      No default: an empty list must be a choice. Each must be a Safe-owned contract.
 *                      The Safe can add more later with one transaction (`addZeroFeeHook`).
 *   ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS   the removal notice, 1..90 days; >= 7 days on production
 *
 * THE ZERO-FEE HOOK LIST IS NOT PERMANENT, UNLIKE THE ORACLES: the Safe adds at once and removes after
 * the notice. Adding only lowers the core fee on that hook's NEW pools.
 *
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   forge script script/DeployFeeControllerV4.s.sol --rpc-url $RPC            # dry run
 *   forge script script/DeployFeeControllerV4.s.sol --rpc-url $RPC --broadcast --slow
 */
contract DeployFeeControllerV4Script is DeepCoreSignerScript {
    /// @dev `_ZH`: the controller with the zero-fee hook list (2026-09-29). The label is part of the
    /// mined salt set (`ops/deploy/salts/labels.txt`); renaming it means re-mining.
    string internal constant LABEL = "DEEPCORE_FEE_CONTROLLER_V4_ZH";

    uint32 internal constant PRODUCTION_MIN_REMOVAL_NOTICE = 7 days;

    /// @dev `DeepCoreProtocolFeeControllerV4.MAX_LAUNCH_ORACLES`, restated so the gate can refuse a list
    /// before any bytecode exists. `verifyDeployment` checks the two agree.
    uint256 internal constant MAX_LAUNCH_ORACLES = 4;

    function run() external returns (DeepCoreProtocolFeeControllerV4 controller) {
        uint256 pk = _pkFromEnv();
        address safe = vm.envAddress("FEE_OWNER_SAFE");
        address policy = vm.envAddress("FEE_POLICY_V2");
        address[] memory kits = vm.envAddress("LAUNCH_ORACLES", ",");
        string memory hooksRaw = vm.envString("ZERO_FEE_HOOKS");
        address[] memory hooks = keccak256(bytes(hooksRaw)) == keccak256("none")
            ? new address[](0)
            : vm.envAddress("ZERO_FEE_HOOKS", ",");
        uint256 notice = vm.envUint("ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS");
        require(notice <= type(uint32).max, "ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS is out of range");
        return runWith(pk, safe, policy, kits, hooks, uint32(notice), DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk)));
    }

    /// @notice The controller's creation code with this chain's constructor arguments.
    function initCode(address safe, address policy, address[] memory kits, address[] memory hooks, uint32 notice)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(DeepCoreProtocolFeeControllerV4).creationCode,
            abi.encode(safe, IProtocolFeeController(policy), kits, hooks, notice)
        );
    }

    /// @dev The earlier entry point: no zero-fee hooks and a 7-day notice. Tests of the oracle gate use it.
    function runWith(
        uint256 pk,
        address safe,
        address policy,
        address[] memory kits,
        DeepCoreDeploy.Target memory target
    ) public returns (DeepCoreProtocolFeeControllerV4) {
        return runWith(pk, safe, policy, kits, new address[](0), 7 days, target);
    }

    /// @dev Environment in `run`, logic here, so a test drives the exact code that gates a deploy.
    function runWith(
        uint256 pk,
        address safe,
        address policy,
        address[] memory kits,
        address[] memory hooks,
        uint32 notice,
        DeepCoreDeploy.Target memory target
    ) public returns (DeepCoreProtocolFeeControllerV4 controller) {
        // Every production chain - see DeepCoreGovernance. `checkInputs` then proves the policy IS a
        // DeepCoreProtocolFeeControllerV2 owned by this Safe, and every kit is owned by it too.
        DeepCoreGovernance.requireGovernanceSafe(safe, _signerOf(pk), "FEE_OWNER_SAFE");

        require(target.deployer == _signerOf(pk), "the salt target is not this deployer");
        DeepCoreDeploy.preflight(target, LABEL);
        checkInputs(safe, policy, kits);
        checkZeroFeeHooks(safe, policy, kits, hooks, notice);

        console.log("=== DEPLOY DeepCoreProtocolFeeControllerV4 ===");
        console.log("  deployer     ", _signerOf(pk));
        console.log("  owner        ", safe);
        console.log("  policy (V2)  ", policy);
        console.log("  launch oracles, in the order they are asked:", kits.length);
        for (uint256 i; i < kits.length; ++i) {
            console.log("    ", i, kits[i]);
        }
        console.log("  zero-fee hooks:", hooks.length);
        for (uint256 i; i < hooks.length; ++i) {
            console.log("    ", i, hooks[i]);
        }
        console.log("  removal notice (s)", uint256(notice));
        console.log("  will deploy to", DeepCoreDeploy.predict(target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(safe, policy, kits, hooks, notice);
        _startBroadcastAs(pk);
        controller = DeepCoreProtocolFeeControllerV4(DeepCoreDeploy.deploy(target, code, LABEL));
        vm.stopBroadcast();

        require(address(controller) == DeepCoreDeploy.predict(target), "V4 is not at the predicted address");
        verifyDeployment(controller, safe, policy, kits);
        verifyZeroFeeHooks(controller, hooks, notice);

        console.log("");
        console.log("=== DEPLOYED, NOT INSTALLED ===");
        console.log("  V4 ", address(controller));
        console.log("Next: FEE_CONTROLLER_V4=<V4> forge script script/BuildInstallFeeControllerV4.s.sol --rpc-url $RPC");
    }

    /// @notice Pre-broadcast checks. Public so the test suite exercises the exact code that gates a deploy.
    function checkInputs(address safe, address policy, address[] memory kits) public view {
        require(safe != address(0) && policy != address(0), "zero address input");
        require(safe.code.length > 0, "owner must be the Safe contract, not an EOA");
        require(policy.code.length > 0, "policy has no code");
        require(policy != safe, "inputs must be distinct contracts");

        require(kits.length > 0, "LAUNCH_ORACLES is empty: name every kit whose pools must keep their zero");
        require(kits.length <= MAX_LAUNCH_ORACLES, "LAUNCH_ORACLES names more than 4 kits");

        IV2IdentityForV4 v2 = IV2IdentityForV4(policy);
        require(v2.owner() == safe, "V2 is not owned by the Safe: V4 would compose over foreign policy");
        require(v2.DYNAMIC_FEE_PIPS() == 999, "policy is not DeepCoreProtocolFeeControllerV2 (DYNAMIC_FEE_PIPS)");
        require(v2.DEFAULT_SPLIT_RATIO() == 250_000, "policy is not DeepCoreProtocolFeeControllerV2 (split)");
        require(v2.MAX_PROTOCOL_FEE() == 4000, "policy is not DeepCoreProtocolFeeControllerV2 (cap)");

        for (uint256 i; i < kits.length; ++i) {
            checkKit(safe, policy, kits, i);
        }
    }

    /// @notice The gate for one entry of `LAUNCH_ORACLES`. Every failure names the entry's position.
    function checkKit(address safe, address policy, address[] memory kits, uint256 i) public view {
        address kit = kits[i];
        string memory at = string.concat("LAUNCH_ORACLES[", vm.toString(i), "]");

        require(kit != address(0), string.concat(at, " is the zero address"));
        require(kit.code.length > 0, string.concat(at, " has no code"));
        require(kit != policy && kit != safe, string.concat(at, " is the policy or the Safe, not a kit"));
        for (uint256 j; j < i; ++j) {
            require(kits[j] != kit, string.concat(at, " is listed twice: a kit is probably missing from the list"));
        }

        (bool ok, bytes memory ret) = kit.staticcall(abi.encodeCall(ILockedLaunchOracle.isLockedLaunch, (bytes32(0))));
        require(
            ok && ret.length == 32 && uint256(bytes32(ret)) == 0,
            string.concat(at, " does not implement isLockedLaunch")
        );

        /* A kit's owner is the Safe (Kit v2 decisions #1). A kit governed by anyone else is a
           tenant's kit, and the protocol's zero-fee rule must not be bound to it. */
        (ok, ret) = kit.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && ret.length == 32, string.concat(at, " has no owner(): not a DeepCore kit"));
        require(abi.decode(ret, (address)) == safe, string.concat(at, " is not owned by the Safe: not DeepCore's kit"));
    }

    /// @notice The gate for `ZERO_FEE_HOOKS` and the removal notice.
    function checkZeroFeeHooks(
        address safe,
        address policy,
        address[] memory kits,
        address[] memory hooks,
        uint32 notice
    ) public view {
        require(notice >= 1 days && notice <= 90 days, "ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS is outside 1..90 days");
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(notice >= PRODUCTION_MIN_REMOVAL_NOTICE, "the removal notice is under 7 days on a production chain");
        }
        for (uint256 i; i < hooks.length; ++i) {
            address hook = hooks[i];
            string memory at = string.concat("ZERO_FEE_HOOKS[", vm.toString(i), "]");
            require(hook != address(0), string.concat(at, " is the zero address"));
            require(hook != policy && hook != safe, string.concat(at, " is the policy or the Safe"));
            for (uint256 j; j < kits.length; ++j) {
                require(hook != kits[j], string.concat(at, " is a launch oracle"));
            }
            for (uint256 j; j < i; ++j) {
                require(hooks[j] != hook, string.concat(at, " is listed twice"));
            }
            if (hook.code.length == 0) {
                /* Not deployed yet: allowed only as a dynamic-fee hook's MINED address (D1/D2 run after C2,
                   so no pool on the hook can predate this list). Only the salt-bound deployer can put code there. */
                require(isMinedDynamicFeeHook(hook), string.concat(at, " has no code and is not a dynamic-fee hook's mined address"));
                continue;
            }
            /* A DeepCore hook is Safe-owned. A hook owned by anyone else is not ours to exempt. */
            (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSignature("owner()"));
            require(ok && ret.length == 32, string.concat(at, " has no owner(): not a DeepCore hook"));
            require(abi.decode(ret, (address)) == safe, string.concat(at, " is not owned by the Safe"));
        }
    }

    /// @notice Whether `hook` is exactly where a mined salt from the environment puts `DeepCoreDynamicFeeHook` or
    /// `DeepCoreBinDynamicFeeHook` (CreateX CREATE3, deployer = the salt's permissioned first 20 bytes).
    function isMinedDynamicFeeHook(address hook) public view returns (bool) {
        string[2] memory labels = ["DEEPCORE_DYNAMIC_FEE_HOOK", "DEEPCORE_BIN_DYNAMIC_FEE_HOOK"];
        for (uint256 i; i < 2; ++i) {
            bytes32 salt = vm.envOr(string.concat("DEEPCORE_SALT_", labels[i]), bytes32(0));
            address expected = vm.envOr(string.concat("DEEPCORE_ADDRESS_", labels[i]), address(0));
            if (salt == bytes32(0) || expected != hook) continue;
            DeepCoreDeploy.Target memory t = DeepCoreDeploy.fromEnv(labels[i], address(bytes20(salt)));
            /* `expected == hook` is checked above; the salt must actually PRODUCE that address. */
            if (DeepCoreDeploy.predict(t) == hook) return true;
        }
        return false;
    }

    /// @notice Post-broadcast read-back of the list and the notice.
    function verifyZeroFeeHooks(DeepCoreProtocolFeeControllerV4 c, address[] memory hooks, uint32 notice) public view {
        require(c.ZERO_FEE_HOOK_REMOVAL_NOTICE() == notice, "removal notice immutable mismatch");
        for (uint256 i; i < hooks.length; ++i) {
            require(c.isZeroFeeHook(hooks[i]), "a listed hook does not read as a zero-fee hook");
            (bool listed, uint40 removalAt) = c.zeroFeeHook(hooks[i]);
            require(listed && removalAt == 0, "a listed hook has a removal pending");
        }
        require(!c.isZeroFeeHook(address(0)), "the zero address reads as a zero-fee hook");
    }

    /// @notice Post-broadcast read-back of every immutable and every ownership claim.
    function verifyDeployment(DeepCoreProtocolFeeControllerV4 c, address safe, address policy, address[] memory kits)
        public
        view
    {
        require(address(c).code.length > 0, "no code at V4");
        require(c.owner() == safe, "owner is not the Safe");
        require(c.pendingOwner() == address(0), "unexpected pending owner");
        require(address(c.policy()) == policy, "policy immutable mismatch");
        require(c.treasury() == safe, "treasury is not the Safe");
        require(c.LAUNCH_ORACLE_GAS() == 50_000, "oracle stipend changed");
        require(c.LAUNCH_ORACLE_MIN_GASLEFT() == 55_793, "oracle gas floor changed");
        require(c.MAX_LAUNCH_ORACLES() == MAX_LAUNCH_ORACLES, "oracle maximum changed");

        /* The set, three ways: the count, the list, and each immutable slot - unused slots included. */
        require(c.launchOracleCount() == kits.length, "launchOracleCount mismatch");
        address[] memory stored = c.launchOracles();
        require(stored.length == kits.length, "launchOracles length mismatch");
        for (uint256 i; i < kits.length; ++i) {
            require(stored[i] == kits[i], "launchOracles entry or order mismatch");
            require(c.isLaunchOracle(kits[i]), "isLaunchOracle denies a configured kit");
        }
        require(c.launchOracle0() == kits[0], "launchOracle0 immutable mismatch");
        require(c.launchOracle1() == (kits.length > 1 ? kits[1] : address(0)), "launchOracle1 immutable mismatch");
        require(c.launchOracle2() == (kits.length > 2 ? kits[2] : address(0)), "launchOracle2 immutable mismatch");
        require(c.launchOracle3() == (kits.length > 3 ? kits[3] : address(0)), "launchOracle3 immutable mismatch");
        require(!c.isLaunchOracle(address(0)), "the zero address reads as an oracle");
        require(!c.isLaunchOracle(policy) && !c.isLaunchOracle(safe), "the policy or the Safe reads as an oracle");

        /* V4 must NOT answer V3's `launchOracle()`: a kit reads that selector to decide whether the
           installed controller is bound to it alone. */
        (bool answers,) = address(c).staticcall(abi.encodeWithSignature("launchOracle()"));
        require(!answers, "V4 answers launchOracle(): it must not");

        /* V4 must agree with V2 on a pool no kit ever created. */
        PoolKey memory probe = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0x3)),
            fee: 3000,
            parameters: bytes32(uint256(60) << 16)
        });
        require(
            c.protocolFeeForPool(probe) == IProtocolFeeController(policy).protocolFeeForPool(probe),
            "V4 disagrees with V2 on a non-launch pool"
        );
        probe.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        probe.hooks = IHooks(address(0x4));
        require(
            c.protocolFeeForPool(probe) == IProtocolFeeController(policy).protocolFeeForPool(probe),
            "V4 disagrees with V2 on a non-launch dynamic pool"
        );

        try c.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}
    }
}
