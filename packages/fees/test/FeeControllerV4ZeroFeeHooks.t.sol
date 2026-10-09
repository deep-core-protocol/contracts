// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {DeployFeeControllerV4Script} from "../script/DeployFeeControllerV4.s.sol";
import {MockLaunchOracle, WastefulLaunchOracle, NotAnOracle, MockProtocolFees} from "./utils/V3Mocks.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {DeepCoreDeploy, CreateXCreate3} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";

/// @dev A hook as far as V4 and its deploy gate can see one: code, and an owner.
contract OwnedHookStub {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @dev A kit as far as the deploy gate can see it: an owner, and `isLockedLaunch`.
contract OwnedOracleZH is MockLaunchOracle {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

contract SafeStubZH {}

/// @dev The zero-fee hook list (owner decision 2026-09-29): pools of a listed hook are born at zero core
/// fee; the Safe adds at once and removes only after the notice.
contract FeeControllerV4ZeroFeeHooksTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PK = 0xBEEF_0055;
    uint24 internal constant PACKED_999 = uint24(999) | (uint24(999) << 12);
    uint24 internal constant DYN = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint32 internal constant NOTICE = 7 days;

    DeepCoreProtocolFeeControllerV2 internal v2;
    DeepCoreProtocolFeeControllerV4 internal v4;
    MockLaunchOracle internal kitA;
    MockProtocolFees internal manager;
    address internal hookA;
    address internal hookB;

    address internal safe = makeAddr("safe");
    address internal stranger = makeAddr("stranger");

    event ZeroFeeHookAdded(address indexed hook);
    event ZeroFeeHookRemovalScheduled(address indexed hook, uint40 removalAt);
    event ZeroFeeHookRemovalCancelled(address indexed hook);

    function setUp() public {
        v2 = new DeepCoreProtocolFeeControllerV2(safe, makeAddr("guardian"));
        kitA = new MockLaunchOracle();
        hookA = address(new OwnedHookStub(safe));
        hookB = address(new OwnedHookStub(safe));
        v4 = _deploy(_one(hookA), NOTICE);
        manager = new MockProtocolFees(address(v4));
    }

    /* ------------------------------ helpers ------------------------------ */

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _deploy(address[] memory hooks, uint32 notice) internal returns (DeepCoreProtocolFeeControllerV4) {
        return new DeepCoreProtocolFeeControllerV4(
            safe, IProtocolFeeController(address(v2)), _one(address(kitA)), hooks, notice
        );
    }

    function _key(uint24 fee, address hooks, uint256 salt) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            hooks: IHooks(hooks),
            poolManager: IPoolManager(address(0x3333)),
            fee: fee,
            parameters: bytes32(uint256(0x3c0000) | salt)
        });
    }

    /* =====================================================================
       CONSTRUCTION
       ===================================================================== */

    function test_Constructor_ListsTheInitialHooksAndTheNotice() public view {
        assertTrue(v4.isZeroFeeHook(hookA));
        assertFalse(v4.isZeroFeeHook(hookB));
        (bool listed, uint40 removalAt) = v4.zeroFeeHook(hookA);
        assertTrue(listed);
        assertEq(removalAt, 0);
        assertEq(v4.ZERO_FEE_HOOK_REMOVAL_NOTICE(), NOTICE);
        assertEq(v4.MIN_ZERO_FEE_HOOK_REMOVAL_NOTICE(), 1 days);
        assertEq(v4.MAX_ZERO_FEE_HOOK_REMOVAL_NOTICE(), 90 days);
    }

    function test_Constructor_EmitsOneEventPerHook() public {
        vm.expectEmit(true, false, false, false);
        emit ZeroFeeHookAdded(hookA);
        vm.expectEmit(true, false, false, false);
        emit ZeroFeeHookAdded(hookB);
        _deploy(_two(hookA, hookB), NOTICE);
    }

    function test_Constructor_AcceptsAnEmptyList() public {
        DeepCoreProtocolFeeControllerV4 c = _deploy(new address[](0), NOTICE);
        assertFalse(c.isZeroFeeHook(hookA));
    }

    function test_Constructor_NoticeBounds() public {
        _deploy(new address[](0), 1 days);
        _deploy(new address[](0), 90 days);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.InvalidRemovalNotice.selector, 1 days - 1));
        _deploy(new address[](0), 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.InvalidRemovalNotice.selector, 90 days + 1));
        _deploy(new address[](0), 90 days + 1);
    }

    function test_Constructor_RefusesBadHooks() public {
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.ZeroAddress.selector);
        _deploy(_one(address(0)), NOTICE);

        /* The constructor MAY name a hook that is not deployed yet (its mined address): the dynamic-fee
           hooks are deployed after V4 is installed, so no pool on them predates the list. */
        address pending = makeAddr("not-yet-deployed-hook");
        DeepCoreProtocolFeeControllerV4 c = _deploy(_one(pending), NOTICE);
        assertTrue(c.isZeroFeeHook(pending), "a constructor-listed address with no code yet is listed");

        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.InvalidZeroFeeHook.selector, address(v2)));
        _deploy(_one(address(v2)), NOTICE);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.InvalidZeroFeeHook.selector, address(kitA)));
        _deploy(_one(address(kitA)), NOTICE);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.AlreadyZeroFeeHook.selector, hookA));
        _deploy(_two(hookA, hookA), NOTICE);
    }

    /* =====================================================================
       THE HOT PATH
       ===================================================================== */

    function test_Resolve_ListedHookPoolIsZero_OtherPoolsAreV2s() public view {
        PoolKey memory onHook = _key(DYN, hookA, 1);
        PoolKey memory onOther = _key(DYN, hookB, 1);
        PoolKey memory hookless = _key(3000, address(0), 1);

        assertEq(v2.protocolFeeForPool(onHook), PACKED_999, "V2 charges a dynamic pool");
        assertEq(v4.protocolFeeForPool(onHook), 0, "a listed hook's pool is born at zero");
        assertEq(v4.protocolFeeForPool(onOther), v2.protocolFeeForPool(onOther), "an unlisted hook pays V2's fee");
        assertEq(v4.protocolFeeForPool(hookless), v2.protocolFeeForPool(hookless), "a hookless pool pays V2's fee");
    }

    /// Static-fee pools on a listed hook are zero too: the list is by hook, not by fee type.
    function test_Resolve_StaticFeePoolOnAListedHookIsZero() public view {
        PoolKey memory key = _key(3000, hookA, 2);
        assertGt(v2.protocolFeeForPool(key), 0);
        assertEq(v4.protocolFeeForPool(key), 0);
    }

    function test_Resolve_KillSwitchStillWins() public {
        vm.prank(safe);
        v2.setFeesDisabled(true);
        assertEq(v4.protocolFeeForPool(_key(DYN, hookB, 1)), 0);
    }

    /// A listed hook's pool is answered before any oracle is asked, so it needs no oracle gas at all.
    function test_Resolve_ListedHookNeedsNoOracleGas() public {
        WastefulLaunchOracle wasteful = new WastefulLaunchOracle();
        DeepCoreProtocolFeeControllerV4 c = new DeepCoreProtocolFeeControllerV4(
            safe, IProtocolFeeController(address(v2)), _one(address(wasteful)), _one(hookA), NOTICE
        );
        wasteful.setMode(WastefulLaunchOracle.Mode.BurnAllGas);
        (bool ok, bytes memory ret) =
            address(c).staticcall{gas: 40_000}(abi.encodeCall(c.protocolFeeForPool, (_key(DYN, hookA, 1))));
        assertTrue(ok, "resolved under the oracle gas floor");
        assertEq(abi.decode(ret, (uint24)), 0);

        /* Control: the same gas on an unlisted hook's pool reaches the oracle floor and reverts. */
        (ok,) = address(c).staticcall{gas: 40_000}(abi.encodeCall(c.protocolFeeForPool, (_key(DYN, hookB, 1))));
        assertFalse(ok, "an unlisted hook's pool must ask the oracle");
    }

    function testFuzz_Resolve_UnlistedHookMatchesV2(address hook, uint256 salt) public view {
        vm.assume(hook != hookA);
        PoolKey memory key = _key(DYN, hook, salt);
        assertEq(v4.protocolFeeForPool(key), v2.protocolFeeForPool(key));
    }

    /* =====================================================================
       ADD
       ===================================================================== */

    function test_Add_TakesEffectAtOnce() public {
        PoolKey memory key = _key(DYN, hookB, 1);
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
        vm.expectEmit(true, false, false, false);
        emit ZeroFeeHookAdded(hookB);
        vm.prank(safe);
        v4.addZeroFeeHook(hookB);
        assertTrue(v4.isZeroFeeHook(hookB));
        assertEq(v4.protocolFeeForPool(key), 0);
    }

    function test_Add_OwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        v4.addZeroFeeHook(hookB);
    }

    function test_Add_Refusals() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.AlreadyZeroFeeHook.selector, hookA));
        v4.addZeroFeeHook(hookA);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.ZeroAddress.selector);
        v4.addZeroFeeHook(address(0));
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NoCode.selector, eoa));
        v4.addZeroFeeHook(eoa);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.InvalidZeroFeeHook.selector, address(v2)));
        v4.addZeroFeeHook(address(v2));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.InvalidZeroFeeHook.selector, address(kitA)));
        v4.addZeroFeeHook(address(kitA));
        vm.stopPrank();
    }

    /* =====================================================================
       REMOVE, BEHIND THE NOTICE
       ===================================================================== */

    function test_Remove_AppliesOnlyAfterTheNotice_ByTimeAlone() public {
        PoolKey memory key = _key(DYN, hookA, 1);
        uint40 at = uint40(block.timestamp) + NOTICE;
        vm.expectEmit(true, false, false, true);
        emit ZeroFeeHookRemovalScheduled(hookA, at);
        vm.prank(safe);
        v4.scheduleZeroFeeHookRemoval(hookA);

        (bool listed, uint40 removalAt) = v4.zeroFeeHook(hookA);
        assertTrue(listed);
        assertEq(removalAt, at);

        vm.warp(at - 1);
        assertTrue(v4.isZeroFeeHook(hookA), "still listed one second before");
        assertEq(v4.protocolFeeForPool(key), 0);

        vm.warp(at);
        assertFalse(v4.isZeroFeeHook(hookA), "removed at the notice, with no transaction");
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
    }

    function test_Remove_OwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        v4.scheduleZeroFeeHookRemoval(hookA);
    }

    function test_Remove_Refusals() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NotZeroFeeHook.selector, hookB));
        v4.scheduleZeroFeeHookRemoval(hookB);
        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NotZeroFeeHook.selector, hookA));
        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.stopPrank();
    }

    function test_Cancel_RestoresTheListing() public {
        vm.startPrank(safe);
        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.expectEmit(true, false, false, false);
        emit ZeroFeeHookRemovalCancelled(hookA);
        v4.cancelZeroFeeHookRemoval(hookA);
        vm.stopPrank();
        (bool listed, uint40 removalAt) = v4.zeroFeeHook(hookA);
        assertTrue(listed);
        assertEq(removalAt, 0);
        vm.warp(block.timestamp + 365 days);
        assertTrue(v4.isZeroFeeHook(hookA), "a cancelled removal never applies");
    }

    function test_Cancel_Refusals() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NoPendingRemoval.selector, hookA));
        v4.cancelZeroFeeHookRemoval(hookA);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NoPendingRemoval.selector, hookB));
        v4.cancelZeroFeeHookRemoval(hookB);
        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.warp(block.timestamp + NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NoPendingRemoval.selector, hookA));
        v4.cancelZeroFeeHookRemoval(hookA);
        vm.stopPrank();
    }

    function test_Cancel_OwnerOnly() public {
        vm.prank(safe);
        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        v4.cancelZeroFeeHookRemoval(hookA);
    }

    /// Adding a hook whose removal is pending cancels it; adding one whose removal applied re-lists it.
    function test_Add_CancelsAPendingRemoval_AndRelistsAnAppliedOne() public {
        vm.startPrank(safe);
        v4.scheduleZeroFeeHookRemoval(hookA);
        v4.addZeroFeeHook(hookA);
        (, uint40 removalAt) = v4.zeroFeeHook(hookA);
        assertEq(removalAt, 0, "the pending removal is gone");

        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.warp(block.timestamp + NOTICE);
        assertFalse(v4.isZeroFeeHook(hookA));
        v4.addZeroFeeHook(hookA);
        vm.stopPrank();
        assertTrue(v4.isZeroFeeHook(hookA));
        assertEq(v4.protocolFeeForPool(_key(DYN, hookA, 1)), 0);
    }

    /* =====================================================================
       THE OWNER'S PER-POOL PATHS
       ===================================================================== */

    function test_SetPoolProtocolFee_RefusesNonZeroOnAListedHookPool() public {
        PoolKey memory key = _key(DYN, hookA, 1);
        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.ZeroFeeHookPoolKeepsZeroFee.selector, key.toId(), hookA)
        );
        v4.setPoolProtocolFee(address(manager), key, 999);
        v4.setPoolProtocolFee(address(manager), key, 0);
        vm.stopPrank();
        assertEq(manager.poolProtocolFee(key.toId()), 0);
    }

    function test_SetPoolProtocolFee_AllowedOnceTheRemovalApplied() public {
        PoolKey memory key = _key(DYN, hookA, 1);
        vm.startPrank(safe);
        v4.scheduleZeroFeeHookRemoval(hookA);
        vm.warp(block.timestamp + NOTICE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.ZeroFeeHookPoolKeepsZeroFee.selector, key.toId(), hookA)
        );
        v4.setPoolProtocolFee(address(manager), key, 999);
        vm.warp(block.timestamp + 1);
        v4.setPoolProtocolFee(address(manager), key, 999);
        vm.stopPrank();
        assertEq(manager.poolProtocolFee(key.toId()), 999);
    }

    function test_SyncPoolToPolicy_FollowsTheList() public {
        PoolKey memory key = _key(DYN, hookB, 1);
        vm.startPrank(safe);
        assertEq(v4.syncPoolToPolicy(address(manager), key), PACKED_999, "unlisted: V2's fee");
        v4.addZeroFeeHook(hookB);
        assertEq(v4.syncPoolToPolicy(address(manager), key), 0, "listed: zero, for a pool born before");
        vm.stopPrank();
        assertEq(manager.poolProtocolFee(key.toId()), 0);
    }

    /// The list and the launch oracles are independent: a kit's locked launch stays zero whatever the list.
    function test_TheListDoesNotTouchTheLaunchRule() public {
        PoolKey memory launch = _key(DYN, hookB, 9);
        kitA.setFlag(PoolId.unwrap(launch.toId()), true);
        assertEq(v4.protocolFeeForPool(launch), 0);
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launch.toId()));
        v4.setPoolProtocolFee(address(manager), launch, 1);
        vm.stopPrank();
    }

    /* =====================================================================
       THE DEPLOY GATE
       ===================================================================== */

    function test_Script_GateAndReadBack() public {
        DeployFeeControllerV4Script s = new DeployFeeControllerV4Script();
        address stubSafe = address(new SafeStubZH());
        DeepCoreProtocolFeeControllerV2 policy = new DeepCoreProtocolFeeControllerV2(stubSafe, makeAddr("guardian"));
        address[] memory kits = _one(address(new OwnedOracleZH(stubSafe)));
        address h1 = address(new OwnedHookStub(stubSafe));
        address h2 = address(new OwnedHookStub(stubSafe));

        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _two(h1, h2), NOTICE);
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, new address[](0), NOTICE);

        CreateXTest.etch();
        DeepCoreDeploy.Target memory target = CreateXTest.target(vm.addr(PK), bytes11("dcore.fee4z"));
        DeepCoreProtocolFeeControllerV4 c = s.runWith(PK, stubSafe, address(policy), kits, _two(h1, h2), NOTICE, target);
        assertEq(address(c), DeepCoreDeploy.predict(target));
        assertTrue(c.isZeroFeeHook(h1) && c.isZeroFeeHook(h2));
        assertEq(c.ZERO_FEE_HOOK_REMOVAL_NOTICE(), NOTICE);
        s.verifyZeroFeeHooks(c, _two(h1, h2), NOTICE);

        vm.expectRevert(bytes("removal notice immutable mismatch"));
        s.verifyZeroFeeHooks(c, _two(h1, h2), NOTICE + 1);
        vm.expectRevert(bytes("a listed hook does not read as a zero-fee hook"));
        s.verifyZeroFeeHooks(c, _one(address(policy)), NOTICE);
    }

    function test_Script_GateRefusals() public {
        DeployFeeControllerV4Script s = new DeployFeeControllerV4Script();
        address stubSafe = address(new SafeStubZH());
        DeepCoreProtocolFeeControllerV2 policy = new DeepCoreProtocolFeeControllerV2(stubSafe, makeAddr("guardian"));
        address kit = address(new OwnedOracleZH(stubSafe));
        address[] memory kits = _one(kit);
        address h = address(new OwnedHookStub(stubSafe));

        vm.expectRevert(bytes("ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS is outside 1..90 days"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(h), 1 days - 1);
        vm.expectRevert(bytes("ZERO_FEE_HOOK_REMOVAL_NOTICE_SECONDS is outside 1..90 days"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(h), 90 days + 1);

        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] is the zero address"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(address(0)), NOTICE);
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] has no code and is not a dynamic-fee hook's mined address"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(makeAddr("eoa")), NOTICE);
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] is the policy or the Safe"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(address(policy)), NOTICE);
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] is the policy or the Safe"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(stubSafe), NOTICE);
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] is a launch oracle"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(kit), NOTICE);
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[1] is listed twice"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _two(h, h), NOTICE);
        address ownerless = address(new NotAnOracle());
        address foreign = address(new OwnedHookStub(stranger));
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] has no owner(): not a DeepCore hook"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(ownerless), NOTICE);
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] is not owned by the Safe"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(foreign), NOTICE);
    }

    /// A hook with no code yet is accepted only at a dynamic-fee hook's MINED address (D1/D2 run after C2).
    function test_Script_AcceptsANotYetDeployedHookOnlyAtItsMinedAddress() public {
        DeployFeeControllerV4Script s = new DeployFeeControllerV4Script();
        address stubSafe = address(new SafeStubZH());
        DeepCoreProtocolFeeControllerV2 policy = new DeepCoreProtocolFeeControllerV2(stubSafe, makeAddr("guardian"));
        address[] memory kits = _one(address(new OwnedOracleZH(stubSafe)));

        address deployer = makeAddr("salt-bound deployer");
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes1(0x00), bytes11(uint88(0x1978))));
        DeepCoreDeploy.Target memory t = DeepCoreDeploy.Target({
            createX: CreateXCreate3.CREATEX,
            createXCodeHash: CreateXCreate3.CREATEX_RUNTIME_HASH,
            deployer: deployer,
            salt: salt,
            expected: address(0)
        });
        address mined = DeepCoreDeploy.predict(t);
        vm.setEnv("DEEPCORE_SALT_DEEPCORE_DYNAMIC_FEE_HOOK", vm.toString(salt));
        vm.setEnv("DEEPCORE_ADDRESS_DEEPCORE_DYNAMIC_FEE_HOOK", vm.toString(mined));

        assertTrue(s.isMinedDynamicFeeHook(mined), "the mined address is recognised");
        assertFalse(s.isMinedDynamicFeeHook(makeAddr("elsewhere")), "any other address is not");
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(mined), NOTICE);

        /* An address variable the salt does not produce is not a mined hook, even when the entry names it. */
        address notProduced = makeAddr("named but not produced by the salt");
        vm.setEnv("DEEPCORE_ADDRESS_DEEPCORE_DYNAMIC_FEE_HOOK", vm.toString(notProduced));
        assertFalse(s.isMinedDynamicFeeHook(notProduced), "the salt must produce the address");
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] has no code and is not a dynamic-fee hook's mined address"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(notProduced), NOTICE);

        vm.setEnv("DEEPCORE_ADDRESS_DEEPCORE_DYNAMIC_FEE_HOOK", vm.toString(makeAddr("expected-elsewhere")));
        vm.expectRevert(bytes("ZERO_FEE_HOOKS[0] has no code and is not a dynamic-fee hook's mined address"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, _one(mined), NOTICE);
        vm.setEnv("DEEPCORE_SALT_DEEPCORE_DYNAMIC_FEE_HOOK", vm.toString(bytes32(0)));
    }

    /// On a production chain the notice is at least 7 days.
    function test_Script_ProductionNeedsSevenDays() public {
        DeployFeeControllerV4Script s = new DeployFeeControllerV4Script();
        address stubSafe = address(new SafeStubZH());
        DeepCoreProtocolFeeControllerV2 policy = new DeepCoreProtocolFeeControllerV2(stubSafe, makeAddr("guardian"));
        address[] memory kits = _one(address(new OwnedOracleZH(stubSafe)));
        vm.chainId(999);
        vm.expectRevert(bytes("the removal notice is under 7 days on a production chain"));
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, new address[](0), 7 days - 1);
        s.checkZeroFeeHooks(stubSafe, address(policy), kits, new address[](0), 7 days);
    }
}
