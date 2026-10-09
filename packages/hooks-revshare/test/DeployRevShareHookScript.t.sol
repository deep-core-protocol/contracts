// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";

import {RevShareHook} from "../src/RevShareHook.sol";
import {DeployRevShareHookMainnetScript} from "../script/DeployRevShareHookMainnet.s.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

/// @dev Stands in for the governance Safe: the script requires the owner to have code.
contract FakeSafe {}

/// @title DeployRevShareHookScriptTest
/// @notice Drives `runWith` directly (never `run`, which reads the environment and probes a live
/// RPC) so the Ownership-table assignments and the post-deploy assertions are exercised in CI.
contract DeployRevShareHookScriptTest is Test, Deployers {
    DeployRevShareHookMainnetScript script;
    CLPoolManager poolManager;
    address safe;

    uint256 constant PK = 0xA11CE;
    address constant OPS = address(0x0B5);

    function setUp() public {
        (, poolManager) = createFreshManager();
        script = new DeployRevShareHookMainnetScript();
        safe = address(new FakeSafe());
        CreateXTest.etch(); // the hook deploys through CreateX at a mined salt
    }

    function _params() internal view returns (DeployRevShareHookMainnetScript.Params memory) {
        return DeployRevShareHookMainnetScript.Params({
            pk: PK,
            poolManager: address(poolManager),
            owner: safe,
            guardian: OPS,
            configDelaySeconds: 12 hours,
            maxBeneficiaries: 8,
            target: CreateXTest.target(vm.addr(PK), "revshare")
        });
    }

    function test_deploysWithTheOwnershipTableAssignments() public {
        RevShareHook hook = script.runWith(_params());
        assertEq(hook.owner(), safe, "owner is the Safe");
        assertEq(hook.guardian(), OPS, "guardian is Ops");
        assertEq(uint256(hook.CONFIG_DELAY_SECONDS()), 12 hours);
        assertEq(hook.CLOCK_MODE(), "mode=timestamp");
    }

    function test_refusesAnEoaOwner() public {
        DeployRevShareHookMainnetScript.Params memory p = _params();
        p.owner = address(0xBEEF);
        vm.expectRevert(bytes("REVSHARE_OWNER has no code - must be the governance Safe"));
        script.runWith(p);
    }

    function test_refusesOwnerEqualToGuardian() public {
        DeployRevShareHookMainnetScript.Params memory p = _params();
        p.guardian = safe;
        vm.expectRevert(bytes("REVSHARE_OWNER and REVSHARE_GUARDIAN must differ"));
        script.runWith(p);
    }

    function test_refusesAMissingGuardian() public {
        DeployRevShareHookMainnetScript.Params memory p = _params();
        p.guardian = address(0);
        vm.expectRevert(bytes("REVSHARE_GUARDIAN unset - the Ownership table assigns it to Ops"));
        script.runWith(p);
    }

    function test_refusesASubFloorDelay() public {
        DeployRevShareHookMainnetScript.Params memory p = _params();
        p.configDelaySeconds = 12 hours - 1;
        vm.expectRevert(bytes("REVSHARE_CONFIG_DELAY_SECONDS is under the 12h floor"));
        script.runWith(p);
    }

    /// @dev No DeepCore governance Safe exists yet: every production chain, HyperEVM included, refuses.
    function test_onProduction_refusesAnOwnerThatIsNotTheSafeOfRecord() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        vm.chainId(999);
        vm.expectRevert(bytes("REVSHARE_OWNER is not the governance Safe of record"));
        script.runWith(_params());
    }

    /// @dev The retired hook's block count typed into the new seconds variable must not slip through.
    function test_refusesTheOldBlockCountTypedAsSeconds() public {
        DeployRevShareHookMainnetScript.Params memory p = _params();
        p.configDelaySeconds = 3600;
        vm.expectRevert(bytes("REVSHARE_CONFIG_DELAY_SECONDS is under the 12h floor"));
        script.runWith(p);
    }
}
