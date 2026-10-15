// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CreateXTest} from "../helpers/CreateXLike.sol";
import {DeployDeepCoreOracleHookScript, OracleDeepCoreMetadata} from "../../script/DeployDeepCoreOracleHook.s.sol";
import {DeepCoreOracleHook} from "../../src/oracle/DeepCoreOracleHook.sol";

contract OracleRegistryStub {
    mapping(address => bool) public isRegistered;
    mapping(address => address) public stewardOf;

    function register(address hook, OracleDeepCoreMetadata calldata) external {
        require(!isRegistered[hook], "already");
        isRegistered[hook] = true;
        stewardOf[hook] = msg.sender;
    }

    function transferSteward(address hook, address next) external {
        require(stewardOf[hook] == msg.sender, "not steward");
        stewardOf[hook] = next;
    }
}

contract OracleSafeStandIn {}

contract DeployDeepCoreOracleHookTest is Test, Deployers {
    uint256 internal constant PK = 0xA11CE;
    address internal constant OPS = address(0x0B5);
    address internal deployer;
    address internal safe;
    CLPoolManager internal manager;
    OracleRegistryStub internal registry;
    DeployDeepCoreOracleHookScript internal script;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        (, manager) = createFreshManager();
        registry = new OracleRegistryStub();
        safe = address(new OracleSafeStandIn());
        script = new DeployDeepCoreOracleHookScript();
    }

    function _p() internal view returns (DeployDeepCoreOracleHookScript.Params memory) {
        return DeployDeepCoreOracleHookScript.Params({
            pk: PK,
            poolManager: ICLPoolManager(address(manager)),
            recipient: safe,
            registry: address(registry),
            steward: OPS,
            maxTickDelta: 100,
            minWindow: 600,
            initialCardinality: 16,
            target: CreateXTest.target(deployer, bytes11("oracle"))
        });
    }

    function test_deploys_readsBack_listsWithStewardOps() public {
        DeepCoreOracleHook hook = script.runWith(_p());
        assertEq(hook.protocolRecipient(), safe);
        assertEq(hook.ORACLE_MAX_TICK_DELTA(), 100);
        assertEq(hook.getHooksRegistrationBitmap(), 0x0042);
        assertTrue(registry.isRegistered(address(hook)));
        assertEq(registry.stewardOf(address(hook)), OPS);
    }

    function test_refusesAnEoaRecipient() public {
        DeployDeepCoreOracleHookScript.Params memory p = _p();
        p.recipient = address(0xE0A);
        vm.expectRevert(bytes("ORACLE_RECIPIENT has no code - the Safe, not an EOA"));
        script.runWith(p);
    }

    function test_onProduction_refusesARecipientThatIsNotTheSafeOfRecord_andAShortWindow() public {
        vm.chainId(999);
        vm.expectRevert(bytes("ORACLE_RECIPIENT is not the governance Safe of record"));
        script.checkInputs(_p(), deployer);
    }

    function test_refusesASecondDeployAtTheSameSalt() public {
        script.runWith(_p());
        vm.expectRevert(bytes("the predicted address already has code on this chain (DEEPCORE_ORACLE_HOOK)"));
        script.runWith(_p());
    }
}
