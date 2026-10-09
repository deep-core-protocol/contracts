// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CreateXTest} from "../helpers/CreateXLike.sol";
import {DeepCoreGovernance} from "../../script/DeepCoreGovernance.sol";
import {DeployDeepCoreDynamicFeeHookScript, DynFeeDeepCoreMetadata} from "../../script/DeployDeepCoreDynamicFeeHook.s.sol";
import {DeepCoreDynamicFeeHook} from "../../src/dex/DeepCoreDynamicFeeHook.sol";

contract RegistryStub {
    mapping(address => bool) public isRegistered;
    mapping(address => address) public stewardOf;

    function register(address hook, DynFeeDeepCoreMetadata calldata) external {
        require(!isRegistered[hook], "already");
        isRegistered[hook] = true;
        stewardOf[hook] = msg.sender;
    }

    function transferSteward(address hook, address next) external {
        require(stewardOf[hook] == msg.sender, "not steward");
        stewardOf[hook] = next;
    }
}

contract SafeStandIn {}

contract DeployDeepCoreDynamicFeeHookTest is Test, Deployers {
    uint256 internal constant PK = 0xA11CE;
    address internal constant OPS = address(0x0B5);
    address internal deployer;
    address internal safe;
    CLPoolManager internal manager;
    RegistryStub internal registry;
    DeployDeepCoreDynamicFeeHookScript internal script;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        (, manager) = createFreshManager();
        registry = new RegistryStub();
        safe = address(new SafeStandIn());
        script = new DeployDeepCoreDynamicFeeHookScript();
    }

    function _p() internal view returns (DeployDeepCoreDynamicFeeHookScript.Params memory) {
        return DeployDeepCoreDynamicFeeHookScript.Params({
            pk: PK,
            poolManager: ICLPoolManager(address(manager)),
            owner: safe,
            recipient: safe,
            registry: address(registry),
            steward: OPS,
            feeCap: 50_000,
            shareBps: 1_500,
            maxShareBps: 3_000,
            shareNotice: 7 days,
            tunerNotice: 1 days,
            maxMove: 500,
            target: CreateXTest.target(deployer, bytes11("dynfee"))
        });
    }

    function test_deploys_readsBack_listsWithStewardOps() public {
        DeepCoreDynamicFeeHook hook = script.runWith(_p());
        assertEq(hook.owner(), safe);
        assertEq(hook.protocolRecipient(), safe);
        assertEq(hook.FEE_CAP(), 50_000);
        assertEq(hook.protocolShareBps(), 1_500);
        assertTrue(registry.isRegistered(address(hook)));
        assertEq(registry.stewardOf(address(hook)), OPS);
    }

    function test_refusesAnEoaOwnerOrRecipient() public {
        DeployDeepCoreDynamicFeeHookScript.Params memory p = _p();
        p.owner = address(0xE0A);
        vm.expectRevert(bytes("DYNFEE_OWNER has no code - the Safe, not an EOA"));
        script.runWith(p);
        p = _p();
        p.recipient = deployer;
        vm.expectRevert(bytes("DYNFEE_RECIPIENT has no code - the Safe, not an EOA"));
        script.runWith(p);
    }

    function test_onProduction_refusesAShortShareNotice() public {
        vm.chainId(999);
        DeployDeepCoreDynamicFeeHookScript.Params memory p = _p();
        p.shareNotice = 1 days;
        vm.expectRevert(bytes("DYNFEE_SHARE_NOTICE_SECONDS is under 7 days on a production chain"));
        script.checkInputs(p, deployer);
    }

    /// The governance Safe of record is set (`DeepCoreGovernance.SAFE`, 2026-10-07): on every production
    /// chain, HyperEVM included, a candidate owner that is not that Safe is refused — the test stub here.
    function test_onProduction_refusesAnOwnerThatIsNotTheSafeOfRecord() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        vm.chainId(999);
        vm.expectRevert(bytes("DYNFEE_OWNER is not the governance Safe of record"));
        script.checkInputs(_p(), deployer);
    }

    function test_refusesASecondDeployAtTheSameSalt() public {
        script.runWith(_p());
        vm.expectRevert(bytes("the predicted address already has code on this chain (DEEPCORE_DYNAMIC_FEE_HOOK)"));
        script.runWith(_p());
    }

    /// Owner decision 2026-09-29: on a production chain the hook is deployed only once the INSTALLED
    /// controller lists it, so no pool on it can be born paying the core fee on top of its share.
    function test_ZEROFEE_refusesUnlessTheInstalledControllerListsTheHook() public {
        address hookAddr = makeAddr("predicted hook");
        string memory refusal = "the installed fee controller does not list this hook as zero-fee: install V4 (C2) before D1/D2";

        address v3Like = address(new ControllerHolderZF(address(new NoListControllerZF())));
        vm.expectRevert(bytes(refusal));
        script.requireListedAsZeroFee(v3Like, hookAddr);

        address listsAnother = address(new ControllerHolderZF(address(new ListingControllerZF(makeAddr("other")))));
        vm.expectRevert(bytes(refusal));
        script.requireListedAsZeroFee(listsAnother, hookAddr);

        address listsIt = address(new ControllerHolderZF(address(new ListingControllerZF(hookAddr))));
        script.requireListedAsZeroFee(listsIt, hookAddr);
    }
}

/// @dev A pool manager whose installed controller is `controller`.
contract ControllerHolderZF {
    address public protocolFeeController;

    constructor(address c) {
        protocolFeeController = c;
    }
}

/// @dev A V4-like controller listing exactly one hook.
contract ListingControllerZF {
    address public immutable listed;

    constructor(address h) {
        listed = h;
    }

    function isZeroFeeHook(address h) external view returns (bool) {
        return h == listed;
    }
}

/// @dev A V3-like controller: no zero-fee list at all.
contract NoListControllerZF {}
