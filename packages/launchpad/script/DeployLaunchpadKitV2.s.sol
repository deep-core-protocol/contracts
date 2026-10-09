// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinFungibleToken} from "infinity-periphery/src/pool-bin/interfaces/IBinFungibleToken.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {ILockedLaunchOracle} from "deepcore-fees/src/interfaces/ILockedLaunchOracle.sol";
import {FeeControllerV3Checks} from "deepcore-fees/script/DeployFeeControllerV3.s.sol";

import {LaunchpadKitV2} from "../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {ILaunchTokenFactory} from "../src/interfaces/ILaunchTokenFactory.sol";
import {ILaunchRegistryWriter} from "../src/interfaces/ILaunchRegistryWriter.sol";

interface IVaultApps {
    function isAppRegistered(address app) external view returns (bool);
}

/**
 * Deploys `LaunchpadKitV2` against an EXISTING shared core, through CreateX at the mined salt, linked to
 * an ALREADY-DEPLOYED `LaunchLegs`. Design: docs/kit-v2-integration.md, "Kit v2 (implemented)".
 *
 * ORDER (each step asserts the previous):
 *   1. DeployDeepCoreLPLocker.s.sol        -> DeepCoreLPLocker + LaunchTokenFactory
 *   2. DeployDeepCoreBinLPLocker.s.sol     -> DeepCoreBinLPLocker (same Safe, same bounds)
 *   3. DeployLaunchGuardHookMainnet     -> LaunchGuardHook(clPoolManager, factory), listed
 *   4. DeployBinLaunchGuardHook         -> BinLaunchGuardHook(binPoolManager, factory), listed
 *   5. DeployLaunchLegs.s.sol           -> LaunchLegs, at its own mined salt
 *   6. THIS SCRIPT                      -> LaunchpadKitV2 (owner = Safe from birth; never the deployer)
 *   7. packages/fees DeployFeeControllerV3 with LAUNCHPAD_KIT_V2 = the address printed here
 *   8. Custody (48h): setProtocolFeeController(V3) on both manager-owner wrappers
 * Until step 8 executes, kit pools are born at V2's 999 pips and the Safe zeroes each by hand (Kit v2
 * decision #2). The kit's own `ProtocolFeeNotZero` assertion is gated on the installed controller naming
 * THIS kit, so it does not block launches in that window.
 *
 * ############################ THE LINKED LIBRARY ############################
 *
 * The kit DELEGATECALLs `LaunchLegs` at an address fixed when the artifact is LINKED, so:
 *   - `LAUNCH_LEGS` must already be deployed (step 5) and is asserted to have code;
 *   - this script must be run with `--libraries src/libraries/LaunchLegs.sol:LaunchLegs:$LAUNCH_LEGS`,
 *     and it PROVES the creation code it is about to send references exactly that address. Without the
 *     flag forge silently auto-deploys its own copy of the library from the deployer's nonce and links
 *     to that: a kit at the right address delegating to a library nobody planned, at an address that
 *     differs per chain. The two guards below turn that into a refusal.
 *
 * WHAT CANNOT BE UNDONE: every argument except the launch fee value. The owner's only power is
 * `setLaunchFee` inside `maxLaunchFeeWei` (CLAUDE.md "Kit v2 decisions" #1 and the Ownership table row
 * `LaunchpadKit v2 owner -> Safe`). So every immutable is asserted before the broadcast and read back after.
 *
 * THE NUMBERS. Owner-decided: protocol LP floor 20% / cap 50% / integrator cap 20% (asserted on both lockers),
 * notice ~7 days. Measured here: `MAX_LEGS = 4` and `MAX_BINS_PER_LEG = 20` - four 32-bin legs cost 35.5M gas,
 * over Nitro's 32M block; four 20-bin legs cost 24.4M (`test/kitv2/LaunchpadKitV2Gas.t.sol`). The fee values
 * (initial wei, cap wei, integrator cap wei) are the owner's to price in native and come from the environment.
 *
 * CLOCK: `run()` probes the chain's `block.timestamp` (ContractClockProbe) before anything else; the kit's
 * constructor refuses any guard that is not `CLOCK_MODE() == "mode=timestamp"`; the notice delay is seconds.
 *
 * BUILD PROFILE: default (cancun) on HyperEVM, as for every other contract on a Cancun chain. The
 * kit and its library compile at 9000 optimizer runs (foundry.toml `compilation_restrictions`) to fit EIP-170.
 *
 * Usage (dry run - never add --broadcast without a human reading the simulation):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   CL_POOL_MANAGER=.. BIN_POOL_MANAGER=.. CL_POSITION_MANAGER=.. BIN_POSITION_MANAGER=.. \
 *   LAUNCH_GUARD_HOOK=.. BIN_LAUNCH_GUARD_HOOK=.. DEEPCORE_LP_LOCKER=.. DEEPCORE_BIN_LP_LOCKER=.. \
 *   LAUNCH_TOKEN_FACTORY=.. LAUNCH_REGISTRY=.. KIT_OWNER_SAFE=<governance Safe> \
 *   LAUNCHPAD_STEWARD=<ops> INITIAL_LAUNCH_FEE_WEI=.. MAX_LAUNCH_FEE_WEI=.. MAX_INTEGRATOR_LAUNCH_FEE_WEI=.. \
 *   FEE_POLICY_V2=<this chain's DeepCoreProtocolFeeControllerV2> \
 *   forge script script/DeployLaunchpadKitV2.s.sol --rpc-url $RPC \
 *     --libraries src/libraries/LaunchLegs.sol:LaunchLegs:$DEEPCORE_ADDRESS_LAUNCH_LEGS_QF
 */
contract DeployLaunchpadKitV2Script is DeepCoreSignerScript {
    uint16 internal constant CL_BITMAP = 0x0CC1;
    uint16 internal constant BIN_BITMAP = 0x0CC5;
    uint16 internal constant MIN_PROTOCOL_BPS = 2_000;
    uint16 internal constant MAX_PROTOCOL_BPS = 5_000;
    uint16 internal constant MAX_INTEGRATOR_BPS = 2_000;
    uint32 internal constant LAUNCH_FEE_NOTICE_SECONDS = 7 days;
    uint8 internal constant MAX_LEGS = 4;
    uint16 internal constant MAX_BINS_PER_LEG = 20;

    string internal constant LABEL = "LAUNCHPAD_KIT_V2_QF";

    struct Wiring {
        uint256 pk;
        address clPoolManager;
        address binPoolManager;
        address clPositionManager;
        address binPositionManager;
        address clHook;
        address binHook;
        address clLocker;
        address binLocker;
        address tokenFactory;
        address launchRegistry;
        address safe;
        address launchpadSteward;
        uint256 initialLaunchFeeWei;
        uint256 maxLaunchFeeWei;
        uint256 maxIntegratorLaunchFeeWei;
        /// @dev Optional. When set, the V3 deploy script's own input checks are run against the new kit.
        address feePolicyV2;
        /// @dev The deployed `LaunchLegs` the creation code must be linked to.
        address launchLegs;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (LaunchpadKitV2 kit) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        console.log("chain clock: header / wall clock   ", clock.headerTimestamp, clock.wallClockSeconds);
        uint256 pk = _pkFromEnv();
        return runWith(
            Wiring({
                pk: pk,
                clPoolManager: vm.envAddress("CL_POOL_MANAGER"),
                binPoolManager: vm.envAddress("BIN_POOL_MANAGER"),
                clPositionManager: vm.envAddress("CL_POSITION_MANAGER"),
                binPositionManager: vm.envAddress("BIN_POSITION_MANAGER"),
                clHook: vm.envAddress("LAUNCH_GUARD_HOOK"),
                binHook: vm.envAddress("BIN_LAUNCH_GUARD_HOOK"),
                clLocker: vm.envAddress("DEEPCORE_LP_LOCKER"),
                binLocker: vm.envAddress("DEEPCORE_BIN_LP_LOCKER"),
                tokenFactory: vm.envAddress("LAUNCH_TOKEN_FACTORY"),
                launchRegistry: vm.envAddress("LAUNCH_REGISTRY"),
                safe: vm.envAddress("KIT_OWNER_SAFE"),
                launchpadSteward: vm.envAddress("LAUNCHPAD_STEWARD"),
                initialLaunchFeeWei: vm.envUint("INITIAL_LAUNCH_FEE_WEI"),
                maxLaunchFeeWei: vm.envUint("MAX_LAUNCH_FEE_WEI"),
                maxIntegratorLaunchFeeWei: vm.envUint("MAX_INTEGRATOR_LAUNCH_FEE_WEI"),
                feePolicyV2: vm.envOr("FEE_POLICY_V2", address(0)),
                launchLegs: vm.envAddress("DEEPCORE_ADDRESS_LAUNCH_LEGS_QF"),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    /// @notice The constructor arguments, as the kit's own struct.
    function deployment(Wiring memory w) public pure returns (LaunchpadKitV2.Deployment memory) {
        return LaunchpadKitV2.Deployment({
            owner: w.safe,
            clPoolManager: ICLPoolManager(w.clPoolManager),
            clHook: LaunchGuardHook(payable(w.clHook)),
            clPositionManager: ICLPositionManager(w.clPositionManager),
            clLocker: DeepCoreLPLocker(payable(w.clLocker)),
            binPoolManager: IBinPoolManager(w.binPoolManager),
            binHook: BinLaunchGuardHook(payable(w.binHook)),
            binPositionManager: IBinPositionManager(w.binPositionManager),
            binLocker: DeepCoreBinLPLocker(payable(w.binLocker)),
            tokenFactory: ILaunchTokenFactory(w.tokenFactory),
            launchRegistry: ILaunchRegistryWriter(w.launchRegistry),
            protocolFeeRecipient: w.safe,
            launchpadSteward: w.launchpadSteward,
            initialLaunchFeeWei: w.initialLaunchFeeWei,
            maxLaunchFeeWei: w.maxLaunchFeeWei,
            launchFeeNoticeSeconds: LAUNCH_FEE_NOTICE_SECONDS,
            maxIntegratorLaunchFeeWei: w.maxIntegratorLaunchFeeWei,
            maxLegs: MAX_LEGS,
            maxBinsPerLeg: MAX_BINS_PER_LEG
        });
    }

    /// @notice The kit's creation code with this chain's constructor arguments, LINKED to `LaunchLegs`.
    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(type(LaunchpadKitV2).creationCode, abi.encode(deployment(w)));
    }

    function runWith(Wiring memory w) public returns (LaunchpadKitV2 kit) {
        preflight(w);

        bytes memory code = initCode(w);
        _startBroadcastAs(w.pk);
        kit = LaunchpadKitV2(payable(DeepCoreDeploy.deploy(w.target, code, LABEL)));
        vm.stopBroadcast();

        postflight(kit, w);
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        address deployer = _signerOf(w.pk);

        // ---- the address, and the library the code is linked to ----
        require(w.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);
        /* `run()` takes this from DEEPCORE_ADDRESS_LAUNCH_LEGS_QF and `vm.envAddress` reverts when it is unset,
           so the production path always checks. It is skippable ONLY for a caller that drives `runWith`
           directly - the in-EVM test suite, where forge links the kit to a library it deployed itself at
           an address no test can name. That is why the skip says so out loud. */
        if (w.launchLegs != address(0)) {
            requireLinkedTo(w.launchLegs, type(LaunchpadKitV2).creationCode);
        } else {
            console.log("WARNING: launchLegs is zero - the linked-library check is SKIPPED (runWith caller)");
        }

        address[11] memory mustHaveCode = [
            w.clPoolManager,
            w.binPoolManager,
            w.clPositionManager,
            w.binPositionManager,
            w.clHook,
            w.binHook,
            w.clLocker,
            w.binLocker,
            w.tokenFactory,
            w.launchRegistry,
            w.safe
        ];
        for (uint256 i; i < mustHaveCode.length; ++i) {
            require(mustHaveCode[i].code.length > 0, "an input address has no code");
        }

        // ---- ownership: the Safe from birth, and it is also the protocol fee recipient ----
        require(w.safe != deployer, "KIT_OWNER_SAFE is the deployer");
        DeepCoreGovernance.requireGovernanceSafe(w.safe, deployer, "KIT_OWNER_SAFE");
        require(w.launchpadSteward != address(0), "LAUNCHPAD_STEWARD unset - Ops");

        // ---- fees ----
        require(w.maxLaunchFeeWei > 0, "MAX_LAUNCH_FEE_WEI is zero - the owner could never charge");
        require(w.initialLaunchFeeWei <= w.maxLaunchFeeWei, "INITIAL_LAUNCH_FEE_WEI above the cap");

        // ---- one core ----
        address vault = address(ICLPoolManager(w.clPoolManager).vault());
        require(address(IBinPoolManager(w.binPoolManager).vault()) == vault, "managers on different vaults");
        require(IVaultApps(vault).isAppRegistered(w.clPoolManager), "CL manager not a Vault app");
        require(IVaultApps(vault).isAppRegistered(w.binPoolManager), "Bin manager not a Vault app");
        require(ILaunchRegistryWriter(w.launchRegistry).vault() == vault, "launch registry trusts another vault");
        require(address(IImmutableState(w.clPositionManager).vault()) == vault, "CL position manager vault");
        require(address(IImmutableState(w.binPositionManager).vault()) == vault, "Bin position manager vault");

        // ---- guards: timestamp clock, reservation bound to THIS factory ----
        LaunchGuardHook cl = LaunchGuardHook(payable(w.clHook));
        BinLaunchGuardHook bin = BinLaunchGuardHook(payable(w.binHook));
        /* One kit, one rule for where a launch's fee goes: a CL leg and a Bin leg of the same launch
           must leave their pools the same share. */
        require(cl.LP_SHARE_BPS() == bin.LP_SHARE_BPS(), "the two guards carry different LP_SHARE_BPS");
        require(address(cl.poolManager()) == w.clPoolManager, "CL guard: pool manager");
        require(address(bin.poolManager()) == w.binPoolManager, "Bin guard: pool manager");
        require(cl.getHooksRegistrationBitmap() == CL_BITMAP, "CL guard: bitmap");
        require(bin.getHooksRegistrationBitmap() == BIN_BITMAP, "Bin guard: bitmap");
        require(keccak256(bytes(cl.CLOCK_MODE())) == keccak256("mode=timestamp"), "CL guard: not timestamp");
        require(keccak256(bytes(bin.CLOCK_MODE())) == keccak256("mode=timestamp"), "Bin guard: not timestamp");
        require(address(cl.LAUNCH_TOKEN_FACTORY()) == w.tokenFactory, "CL guard: reservation factory");
        require(address(bin.LAUNCH_TOKEN_FACTORY()) == w.tokenFactory, "Bin guard: reservation factory - the pre-port hook?");
        require(cl.protocolRecipient() == w.safe && bin.protocolRecipient() == w.safe, "guards: creator tax must pay the Safe");

        // ---- lockers: the owner's numbers, paying the Safe ----
        DeepCoreLPLocker cll = DeepCoreLPLocker(payable(w.clLocker));
        DeepCoreBinLPLocker bll = DeepCoreBinLPLocker(payable(w.binLocker));
        require(address(cll.positionManager()) == w.clPositionManager, "CL locker: position manager");
        require(address(bll.positionManager()) == w.binPositionManager, "Bin locker: position manager");
        require(cll.protocolRecipient() == w.safe && bll.protocolRecipient() == w.safe, "a locker pays someone other than the Safe");
        require(cll.minProtocolBps() == MIN_PROTOCOL_BPS && bll.minProtocolBps() == MIN_PROTOCOL_BPS, "locker floor");
        require(cll.maxProtocolBps() == MAX_PROTOCOL_BPS && bll.maxProtocolBps() == MAX_PROTOCOL_BPS, "locker cap");
        require(cll.maxIntegratorBps() == MAX_INTEGRATOR_BPS && bll.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "integrator cap");
        require(bll.maxBinsPerLock() >= MAX_BINS_PER_LEG, "Bin locker cannot hold a full leg");
    }

    /// @notice Refuse creation code that is not linked to the `LaunchLegs` this deployment planned.
    /// @dev Two distinct failures, two distinct messages:
    ///   - an UNLINKED artifact still carries solc's `__$<hash>$__` placeholder (ASCII `__$`), which is
    ///     what a run without `--libraries` produces when forge has nothing to link against;
    ///   - a LINKED artifact that does not mention `legs` was linked to some other address - typically
    ///     forge's own auto-deployed copy, whose address depends on the deployer's nonce.
    /// Public so tests drive it.
    function requireLinkedTo(address legs, bytes memory code) public view {
        require(legs != address(0), "DEEPCORE_ADDRESS_LAUNCH_LEGS_QF unset - deploy LaunchLegs first");
        require(legs.code.length > 0, "DEEPCORE_ADDRESS_LAUNCH_LEGS_QF has no code - deploy LaunchLegs first");
        bool unlinked;
        bool found;
        uint256 n = code.length;
        for (uint256 i = 0; i + 20 <= n; ++i) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 32), i))
            }
            if (address(uint160(word >> 96)) == legs) found = true;
            /* solc's unresolved placeholder is exactly `__$` + 34 hex characters + `$__`, 40 bytes.
               Both ends are checked: `__$` alone appears by chance in 48 KB of bytecode about once in
               every 350 builds, and a false "unlinked" refusal on deploy day would be indistinguishable
               from a real one. */
            if (uint24(bytes3(bytes32(word))) == 0x5f5f24 && i + 40 <= n) {
                uint256 tail;
                assembly ("memory-safe") {
                    tail := mload(add(add(code, 32), add(i, 37)))
                }
                if (uint24(bytes3(bytes32(tail))) == 0x245f5f) unlinked = true;
            }
        }
        require(!unlinked, "LaunchpadKitV2 is UNLINKED: re-run with --libraries src/libraries/LaunchLegs.sol:LaunchLegs:<LaunchLegs>");
        require(found, "LaunchpadKitV2 is linked to a different LaunchLegs than DEEPCORE_ADDRESS_LAUNCH_LEGS_QF");
    }

    /// @notice Read back the deployed reality. Public so tests drive it.
    function postflight(LaunchpadKitV2 kit, Wiring memory w) public {
        require(address(kit) == DeepCoreDeploy.predict(w.target), "kit is not at the predicted address");
        require(address(kit).code.length > 0 && address(kit).code.length <= 24_576, "kit code size");
        // The DEPLOYED runtime, not only the plan: the library address is in the code a user will call.
        if (w.launchLegs != address(0)) requireLinkedTo(w.launchLegs, address(kit).code);
        require(kit.owner() == w.safe, "owner is not the Safe");
        require(kit.pendingOwner() == address(0), "unexpected pending owner");
        require(address(kit.clPoolManager()) == w.clPoolManager, "clPoolManager");
        require(address(kit.binPoolManager()) == w.binPoolManager, "binPoolManager");
        require(address(kit.clPositionManager()) == w.clPositionManager, "clPositionManager");
        require(address(kit.binPositionManager()) == w.binPositionManager, "binPositionManager");
        require(address(kit.clHook()) == w.clHook, "clHook");
        require(address(kit.binHook()) == w.binHook, "binHook");
        require(address(kit.clLocker()) == w.clLocker, "clLocker");
        require(address(kit.binLocker()) == w.binLocker, "binLocker");
        require(address(kit.tokenFactory()) == w.tokenFactory, "tokenFactory");
        require(address(kit.launchRegistry()) == w.launchRegistry, "launchRegistry");
        require(kit.protocolFeeRecipient() == w.safe, "protocolFeeRecipient");
        require(kit.launchpadSteward() == w.launchpadSteward, "launchpadSteward");
        require(kit.maxLaunchFeeWei() == w.maxLaunchFeeWei, "maxLaunchFeeWei");
        require(kit.launchFeeWei() == w.initialLaunchFeeWei, "launchFeeWei");
        require(kit.launchFeeNoticeSeconds() == LAUNCH_FEE_NOTICE_SECONDS, "notice");
        require(kit.maxIntegratorLaunchFeeWei() == w.maxIntegratorLaunchFeeWei, "maxIntegratorLaunchFeeWei");
        require(kit.maxLegs() == MAX_LEGS && kit.maxBinsPerLeg() == MAX_BINS_PER_LEG, "caps");
        require(kit.maxIntegratorBps() == MAX_INTEGRATOR_BPS, "maxIntegratorBps");
        require(keccak256(bytes(kit.CLOCK_MODE())) == keccak256("mode=timestamp"), "clock mode");
        (uint256 pendingWei, uint64 pendingAt) = kit.pendingLaunchFee();
        require(pendingWei == 0 && pendingAt == 0, "born with a pending fee change");
        require(kit.totalFeesOwed() == 0 && address(kit).balance == 0, "kit not empty");
        require(
            IBinFungibleToken(w.binPositionManager).isApprovedForAll(address(kit), w.binLocker),
            "Bin locker approval missing"
        );
        try kit.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}

        // ---- the V3 relationship: exactly what DeepCoreProtocolFeeControllerV3's constructor probes ----
        (bool ok, bytes memory ret) =
            address(kit).staticcall{gas: 50_000}(abi.encodeCall(ILockedLaunchOracle.isLockedLaunch, (bytes32(0))));
        require(ok && ret.length == 32 && uint256(bytes32(ret)) == 0, "isLockedLaunch(0) is not a 32-byte false within V3's stipend");
        if (w.feePolicyV2 != address(0)) {
            // Runs the V3 deploy script's own pre-broadcast checks against this kit, so step 7 cannot fail.
            // Inlined library code, NOT `new DeployFeeControllerV3Script()`: a script must not create a contract of
            // its own (it returns address(0) on OP-stack chains under forge's default sender; see the library).
            FeeControllerV3Checks.checkInputs(w.safe, w.feePolicyV2, address(kit));
        }

        console.log("LaunchpadKitV2          ", address(kit), "(CREATE3 via CreateX: same on every chain)");
        console.log("  LaunchLegs (linked)   ", w.launchLegs);
        console.log("  owner (Safe)          ", kit.owner());
        console.log("  launch fee / cap, wei ", kit.launchFeeWei(), kit.maxLaunchFeeWei());
        console.log("  notice, s             ", kit.launchFeeNoticeSeconds());
        console.log("  integrator fee cap    ", kit.maxIntegratorLaunchFeeWei());
        console.log("  legs / bins per leg   ", kit.maxLegs(), kit.maxBinsPerLeg());
        console.log("");
        console.log("OWNERSHIP: Safe from the constructor; the deployer never held it. The owner can ONLY set");
        console.log("  the launch fee inside the immutable cap (raise: 7 days notice; lower: immediate).");
        console.log("NEXT: packages/fees DeployFeeControllerV3 with LAUNCHPAD_KIT_V2=<kit>, then the Custody install.");
        console.log("  Until V3 is installed, the runbook must zero each kit pool's core fee in the launch session.");
    }
}
