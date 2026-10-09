// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";

import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {DeepCoreRegistry} from "deepcore-registry/src/DeepCoreRegistry.sol";

import {LaunchpadKit} from "../src/LaunchpadKit.sol";
import {LaunchTokenFactory} from "../src/LaunchTokenFactory.sol";
import {IHookRegistryListing} from "../src/interfaces/IHookRegistryListing.sol";
import {Preset} from "../src/libraries/LaunchPresets.sol";
import {LaunchParams} from "../src/interfaces/ILaunchpadKit.sol";
import {DeployLaunchGuardHookMainnetScript} from "../script/DeployLaunchGuardHookMainnet.s.sol";
import {LegacyBitmapLaunchGuardHook} from "./utils/LegacyBitmapLaunchGuardHook.sol";
import {DeployLaunchpadKitMainnetScript} from "../script/DeployLaunchpadKitMainnet.s.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

/// @dev What the retired block-numbered `LaunchGuardHook` (0x8b4F…575c) looks like to the kit script:
/// right pool manager, right bitmap, no `CLOCK_MODE()`.
contract RetiredBlockNumberedHook is BaseCLHook {
    constructor(ICLPoolManager _pm) BaseCLHook(_pm) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_SWAP;
    }
}

/// @title DeployScriptsTest
/// @notice Runs both mainnet deploy scripts end to end against a locally built stack.
///
/// @dev ###################### WHY THIS TEST EXISTS ######################
///
/// A deploy script is the least-exercised code in a protocol and the one with the fewest chances
/// to be right. `LaunchpadKit` has no owner, no pause and no upgrade path, so every constructor
/// argument is permanent: a script that wires it wrong produces a contract to abandon, not a
/// contract to fix. So the scripts are run here as CONTRACTS rather than read as documents.
///
/// Each pre-flight guard is additionally MUTATED: a green run of a script whose `require`s can
/// never trip proves nothing. Delete a guard and its case here stops reverting.
///
/// THE HARNESS TALKS TO `runWith`, NEVER TO THE ENVIRONMENT. `vm.setEnv` writes PROCESS
/// environment, which is not rolled back between test cases, and forge 1.x runs test cases
/// concurrently against one shared process.
///
/// TIMESTAMPS, NOT BLOCKS (Option B, 2026-09-13). This file used to test a `blockTimeCentis`
/// declaration against a measured contract clock. No contract takes a block time any more; the
/// clock guards that remain are "the hook is timestamp-clocked" and, in `run()` only, the live
/// `block.timestamp` sanity probe (`deepcore-hooks/script/ContractClock.sol`, unit-tested in hooks).
/// ###################################################################
contract DeployScriptsTest is Test, Deployers, DeployPermit2 {
    Vault vault;
    CLPoolManager poolManager;
    CLPositionManager posm;
    IAllowanceTransfer permit2;
    DeepCoreRegistry registry;
    WETH weth;
    LaunchTokenFactory factory;

    DeployLaunchGuardHookMainnetScript hookScript;
    DeployLaunchpadKitMainnetScript kitScript;

    /// @dev A publicly known throwaway. Nothing is broadcast from this test; the scripts only
    /// need a key they can derive an address from.
    uint256 constant TEST_PK = 1;

    /// @dev The Ops key that the Ownership table assigns the LaunchGuardHook listing steward to.
    address constant OPS_STEWARD = address(0x0B5);

    address constant REGISTRY_ADMIN = address(0xAD3111);

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        permit2 = IAllowanceTransfer(deployPermit2());
        weth = new WETH();
        ICLPositionDescriptor descriptor = new CLPositionDescriptorOffChain("https://deepcore.example/positions/");
        posm = new CLPositionManager(vault, poolManager, permit2, 100_000, descriptor, IWETH9(address(weth)));

        address[] memory none = new address[](0);
        registry = new DeepCoreRegistry(REGISTRY_ADMIN, address(vault), none, none);
        factory = new LaunchTokenFactory();

        // Constructed in setUp so `vm.expectRevert` lands on `runWith` and not on the script's
        // own creation - a mistake that makes every mutation below pass for the wrong reason.
        hookScript = new DeployLaunchGuardHookMainnetScript();
        kitScript = new DeployLaunchpadKitMainnetScript();
        CreateXTest.etch(); // the guard deploys through CreateX at a mined salt
    }

    function _hook() internal returns (LaunchGuardHook) {
        return hookScript.runWith(
            TEST_PK, address(poolManager), address(factory), address(registry), OPS_STEWARD, address(this), 2_000, _target()
        );
    }

    /// @dev The mined salt a real deployment reads from `ops/deploy/salts/salts.<deployer>.json`.
    function _target() internal view returns (DeepCoreDeploy.Target memory) {
        return CreateXTest.target(vm.addr(TEST_PK), "guard.cl");
    }

    /// @dev Kit v1 (`0x2a4C`, never redeployed) asserts the PRE-TAX bitmap. The v1 script is "not used"
    /// (mainnet runbook 1.6); its tests pair it with this test-only shim, not with the creator-tax guard.
    function _v1Hook() internal returns (LaunchGuardHook) {
        return new LegacyBitmapLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(factory)), address(this));
    }

    /// @dev The wiring a correct deployment uses, with the hook filled in by step 1.
    function _wiring(address hook) internal view returns (DeployLaunchpadKitMainnetScript.Wiring memory) {
        return DeployLaunchpadKitMainnetScript.Wiring({
            pk: TEST_PK,
            poolManager: address(poolManager),
            hook: hook,
            positionManager: address(posm),
            permit2: address(permit2),
            registry: address(registry)
        });
    }

    /*//////////////////////////////////////////////////////////////
                            THE HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Both scripts, in the documented order. Every `require` inside them is live; this
    /// passing means none tripped, and the post-flight assertions have read every immutable back.
    function test_bothScriptsRunInOrder() public {
        LaunchGuardHook hook = _hook();
        assertGt(address(hook).code.length, 0, "hook has no code");
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.CLOCK_MODE(), "mode=timestamp");
        assertEq(hook.getHooksRegistrationBitmap(), 0x0CC1, "the creator-tax guard");
        assertEq(hook.protocolRecipient(), address(this), "tax protocol recipient");

        // Kit v1 stays on its retired guard; its script refuses the creator-tax guard by bitmap.
        vm.expectRevert(bytes("LAUNCH_GUARD_HOOK reports a bitmap this kit cannot build pool keys for"));
        kitScript.runWith(_wiring(address(hook)));

        LaunchGuardHook v1Hook = _v1Hook();
        LaunchpadKit kit = kitScript.runWith(_wiring(address(v1Hook)));

        // The script asserts all of this internally. Repeated here so a deleted assertion inside
        // the script is caught by this file rather than by a mainnet deployment.
        assertEq(address(kit.clPoolManager()), address(poolManager));
        assertEq(address(kit.hook()), address(v1Hook));
        assertEq(address(kit.positionManager()), address(posm));
        assertEq(address(kit.permit2()), address(permit2));
        assertEq(address(kit.registry()), address(registry));
        assertEq(kit.CLOCK_MODE(), "mode=timestamp");
        assertEq(kit.hookBitmap(), 0x0041);
        assertEq(address(kit).balance, 0, "kit was born holding native value");
    }

    /// @dev The Ownership-table runbook item: the hook is listed in the same session it is
    /// deployed, and the steward ends with Ops, not the deployer.
    function test_hookScript_listsTheHookWithTheOpsSteward() public {
        LaunchGuardHook hook = _hook();
        assertTrue(registry.isRegistered(address(hook)), "listed in the same session");
        assertEq(registry.getDeepCore(address(hook)).steward, OPS_STEWARD, "steward is Ops");
        assertEq(registry.getDeepCore(address(hook)).submitter, vm.addr(TEST_PK), "listed by the deployer");
        assertEq(registry.getDeepCore(address(hook)).permissions, uint16(0x0CC1));
    }

    function test_kitScriptAcceptsNoRegistry() public {
        LaunchGuardHook hook = _v1Hook();
        DeployLaunchpadKitMainnetScript.Wiring memory w = _wiring(address(hook));
        w.registry = address(0);
        LaunchpadKit kit = kitScript.runWith(w);
        assertEq(address(kit.registry()), address(0));
    }

    /// @dev The whole point of the migration, stated as an outcome: the "five minute" FairLaunch
    /// the kit writes is 300 seconds of `block.timestamp`. The live block-numbered kit wrote 3 000
    /// blocks, which on Robinhood's ~12.1 s contract clock is ~10 hours.
    function test_presetWindowsAreTheSecondsOnTheirLabel() public {
        LaunchpadKit kit = kitScript.runWith(_wiring(address(_v1Hook())));
        LaunchParams memory p;
        p.launchToken = address(new MockERC20("L", "L", 18));
        p.quoteToken = address(0);
        p.tickSpacing = 60;
        p.preset = Preset.FairLaunch;
        assertEq(kit.previewSchedule(p).decaySeconds, 300);
        p.preset = Preset.AntiSniperAggressive;
        p.maxBuyPerTx = 1 ether; // the preset refuses to run without a per-transaction cap
        assertEq(kit.previewSchedule(p).decaySeconds, 1800);
        p.preset = Preset.Stealth;
        assertEq(kit.previewSchedule(p).decaySeconds, 120);
    }

    /*//////////////////////////////////////////////////////////////
        MUTATIONS - each violates exactly one pre-flight guard.
    //////////////////////////////////////////////////////////////*/

    function test_hookScript_rejectsAPoolManagerWithNoCode() public {
        vm.expectRevert(bytes("CL_POOL_MANAGER has no code - not a contract"));
        hookScript.runWith(TEST_PK, address(0xDEAD), address(factory), address(registry), OPS_STEWARD, address(this), 0, _target());
    }

    function test_hookScript_refusesToDeployWithoutARegistry() public {
        vm.expectRevert(bytes("LAUNCH_GUARD_REGISTRY has no code - list in the same session"));
        hookScript.runWith(TEST_PK, address(poolManager), address(factory), address(0), OPS_STEWARD, address(this), 0, _target());
    }

    function test_hookScript_refusesToDeployWithoutAnOpsSteward() public {
        vm.expectRevert(bytes("LAUNCH_GUARD_STEWARD unset - the Ownership table assigns it to Ops"));
        hookScript.runWith(TEST_PK, address(poolManager), address(factory), address(registry), address(0), address(this), 0, _target());
    }

    function test_hookScript_refusesATaxRecipientWithoutCode() public {
        vm.expectRevert(bytes("TAX_PROTOCOL_RECIPIENT has no code - a Safe, not an EOA"));
        hookScript.runWith(TEST_PK, address(poolManager), address(factory), address(registry), OPS_STEWARD, address(0xCAFE), 0, _target());
    }

    function test_hookScript_refusesTheDeployerAsTaxRecipient() public {
        vm.etch(vm.addr(TEST_PK), hex"00");
        vm.expectRevert(bytes("TAX_PROTOCOL_RECIPIENT is the deployer"));
        hookScript.runWith(TEST_PK, address(poolManager), address(factory), address(registry), OPS_STEWARD, vm.addr(TEST_PK), 0, _target());
    }

    function test_kitScript_rejectsAHookThatWasNeverDeployed() public {
        vm.expectRevert(bytes("LAUNCH_GUARD_HOOK has no code - deploy step 1 first"));
        kitScript.runWith(_wiring(address(0xBEEF)));
    }

    function test_kitScript_rejectsAHookServingADifferentPoolManager() public {
        (, CLPoolManager other) = createFreshManager();
        LaunchGuardHook strayHook = new LegacyBitmapLaunchGuardHook(other, ILaunchTokenOrigin(address(0)), address(this));
        vm.expectRevert(bytes("LAUNCH_GUARD_HOOK serves a different pool manager than CL_POOL_MANAGER"));
        kitScript.runWith(_wiring(address(strayHook)));
    }

    /// @dev THE REDEPLOY FOOTGUN: a new kit pointed at the retired block-numbered hook.
    /// MUTATION-CHECKED: delete the script's clock guard and the kit's constructor still refuses,
    /// but with `HookClockMismatch("")` instead of this sentence.
    function test_kitScript_rejectsTheRetiredBlockNumberedHook() public {
        RetiredBlockNumberedHook old = new RetiredBlockNumberedHook(poolManager);
        vm.expectRevert(bytes("LAUNCH_GUARD_HOOK is not timestamp-clocked - is it the retired block-numbered hook?"));
        kitScript.runWith(_wiring(address(old)));
    }

    function test_kitScript_rejectsAPositionManagerOnAnotherSingleton() public {
        LaunchGuardHook hook = _v1Hook();

        (Vault otherVault, CLPoolManager other) = createFreshManager();
        ICLPositionDescriptor descriptor = new CLPositionDescriptorOffChain("https://deepcore.example/other/");
        CLPositionManager strayPosm =
            new CLPositionManager(otherVault, other, permit2, 100_000, descriptor, IWETH9(address(weth)));

        DeployLaunchpadKitMainnetScript.Wiring memory w = _wiring(address(hook));
        w.positionManager = address(strayPosm);

        vm.expectRevert(bytes("CL_POSITION_MANAGER points at a different CL pool manager"));
        kitScript.runWith(w);
    }

    function test_kitScript_rejectsAPermit2ThePositionManagerDoesNotUse() public {
        LaunchGuardHook hook = _v1Hook();
        DeployLaunchpadKitMainnetScript.Wiring memory w = _wiring(address(hook));
        w.permit2 = address(registry); // has code, is not the position manager's Permit2
        vm.expectRevert(
            bytes("PERMIT2 is not the Permit2 the position manager pulls through - use the one it names")
        );
        kitScript.runWith(w);
    }

    function test_kitScript_rejectsARegistryWithTheWrongAbi() public {
        LaunchGuardHook hook = _v1Hook();
        DeployLaunchpadKitMainnetScript.Wiring memory w = _wiring(address(hook));
        w.registry = address(new MockERC20("Not", "NOT", 18));
        vm.expectRevert();
        kitScript.runWith(w);
    }

    /*//////////////////////////////////////////////////////////////
                                 GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Measured, so the runbook's funding figure is not a guess. Bounded loosely enough to be
    /// stable across compiler bumps and tightly enough to catch a contract that doubled in size.
    function test_deploymentGasIsWithinTheFundingEstimate() public {
        uint256 before = gasleft();
        LaunchGuardHook hook = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), address(this), 0);
        uint256 hookGas = before - gasleft();

        before = gasleft();
        LaunchpadKit kit =
            new LaunchpadKit(poolManager, _v1Hook(), posm, permit2, IHookRegistryListing(address(registry)));
        uint256 kitGas = before - gasleft();

        emit log_named_uint("LaunchGuardHook deploy gas", hookGas);
        emit log_named_uint("LaunchpadKit deploy gas   ", kitGas);
        emit log_named_uint("total                     ", hookGas + kitGas);

        assertGt(address(kit).code.length, 0);
        // 2026-09-18: the guard carries the creator tax (`LaunchTaxModule`), ~19.5 KB of runtime: measured
        // 3,597,327 for the guard and 6,943,461 for v1's kit. The bound moved with it; the runbook's
        // funding figure for step 3c must be re-measured from this number.
        // 2026-09-28: the guard takes its fee in the quote currency as well (a second pot, a fee split
        // and its rotation), 20.2 KB of runtime: measured 4,380,785 for the guard and 7,651,503 for v1's
        // kit in this test. The bound moved with it, and so must the runbook's funding figure.
        assertLt(hookGas + kitGas, 13_000_000, "the deployment got much more expensive");
    }
}
