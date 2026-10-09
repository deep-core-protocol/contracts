// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "../src/DeepCoreProtocolFeeControllerV3.sol";
import {MockLaunchOracle, NotAnOracle, MockProtocolFees} from "./utils/V3Mocks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

contract RevertingPolicy {
    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        revert("policy down");
    }
}

/// @dev Unit tests against the REAL V2 as policy, with mock oracles and a mock manager. The
/// integration suite (`FeeControllerV3Live.t.sol`) runs the same rules through real core managers.
contract DeepCoreProtocolFeeControllerV3Test is Test {
    using PoolIdLibrary for PoolKey;

    DeepCoreProtocolFeeControllerV2 internal v2;
    DeepCoreProtocolFeeControllerV3 internal v3;
    MockLaunchOracle internal kit;
    MockProtocolFees internal manager;

    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("opsGuardian");
    address internal stranger = makeAddr("stranger");
    Currency internal usdg = Currency.wrap(address(0x5f65));

    uint24 internal constant PACKED_999 = uint24(999) | (uint24(999) << 12);
    uint24 internal constant DYN = LPFeeLibrary.DYNAMIC_FEE_FLAG;

    function setUp() public {
        v2 = new DeepCoreProtocolFeeControllerV2(safe, guardian);
        kit = new MockLaunchOracle();
        v3 = new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kit));
        manager = new MockProtocolFees(address(v3));
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

    function _launchKey() internal pure returns (PoolKey memory) {
        return _key(DYN, address(0x4444), 1);
    }

    function _flag(PoolKey memory key) internal {
        kit.setFlag(PoolId.unwrap(key.toId()), true);
    }

    /* =====================================================================
       CONSTRUCTION AND IMMUTABLES
       ===================================================================== */

    function test_Constructor_SetsEverything() public view {
        assertEq(v3.owner(), safe);
        assertEq(v3.pendingOwner(), address(0));
        assertEq(address(v3.policy()), address(v2));
        assertEq(v3.launchOracle(), address(kit));
        assertEq(v3.treasury(), safe, "treasury defaults to the owner");
        assertEq(v3.LAUNCH_ORACLE_GAS(), 50_000);
        assertEq(v3.LAUNCH_ORACLE_MIN_GASLEFT(), uint256(55_793)); // 50_000 + floor(50_000 / 63) + 5_000
    }

    function test_Constructor_RejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DeepCoreProtocolFeeControllerV3(address(0), IProtocolFeeController(address(v2)), address(kit));
    }

    function test_Constructor_RejectsZeroDependencies() public {
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.ZeroAddress.selector);
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(0)), address(kit));
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.ZeroAddress.selector);
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(0));
    }

    function test_Constructor_RejectsEOADependencies() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.NoCode.selector, stranger));
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(stranger), address(kit));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.NoCode.selector, stranger));
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), stranger);
    }

    function test_Constructor_RejectsSameContractForBoth() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.InvalidDependencies.selector, address(kit), address(kit))
        );
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(kit)), address(kit));
    }

    /// A mistyped oracle address (the v1 kit, the registry, the locker, V2 itself) is refused at
    /// deploy rather than becoming a zero rule that silently never fires.
    function test_Constructor_RejectsAnOracleWithoutTheInterface() public {
        NotAnOracle wrong = new NotAnOracle();
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.OracleDoesNotImplementInterface.selector, address(wrong))
        );
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(wrong));

        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.OracleDoesNotImplementInterface.selector, address(v2))
        );
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(manager)), address(v2));
    }

    function test_Constructor_RejectsAnOracleThatVouchesForEverything() public {
        MockLaunchOracle liar = new MockLaunchOracle();
        liar.setMode(MockLaunchOracle.Mode.TrueForEverything);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.OracleDoesNotImplementInterface.selector, address(liar))
        );
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(liar));

        liar.setMode(MockLaunchOracle.Mode.ReturnTwo);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.OracleDoesNotImplementInterface.selector, address(liar))
        );
        new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(liar));
    }

    /* =====================================================================
       THE RULE
       ===================================================================== */

    function test_LockedLaunchPool_IsZero() public {
        PoolKey memory key = _launchKey();
        assertEq(v2.protocolFeeForPool(key), PACKED_999, "V2 alone would charge it");
        _flag(key);
        assertEq(v3.protocolFeeForPool(key), 0);
        assertTrue(v3.isLockedLaunchPool(key.toId()));
    }

    function test_NormalStaticPool_PaysTheConfiguredFee() public view {
        PoolKey memory key = _key(3000, address(0), 0);
        assertEq(v3.protocolFeeForPool(key), v2.protocolFeeForPool(key));
        assertEq(v3.protocolFeeForPool(key), PACKED_999);
    }

    function test_NormalDynamicPool_PaysTheConfiguredFee() public view {
        PoolKey memory key = _launchKey();
        assertEq(v3.protocolFeeForPool(key), PACKED_999);
        assertFalse(v3.isLockedLaunchPool(key.toId()));
    }

    /// A flag for one key says nothing about a sibling key (other params, manager, hook, fee).
    function test_FlagIsBoundToTheExactPoolId() public {
        PoolKey memory key = _launchKey();
        _flag(key);

        PoolKey memory sibling = _launchKey();
        sibling.parameters = bytes32(uint256(0x3c0000) | 2);
        assertEq(v3.protocolFeeForPool(sibling), PACKED_999, "other parameters");

        sibling = _launchKey();
        sibling.poolManager = IPoolManager(address(0x3334));
        assertEq(v3.protocolFeeForPool(sibling), PACKED_999, "other manager");

        sibling = _launchKey();
        sibling.hooks = IHooks(address(0x4445));
        assertEq(v3.protocolFeeForPool(sibling), PACKED_999, "other hook");
    }

    /// Configuration changes on V2 flow through V3 for non-launch pools, and never un-zero a launch.
    function test_V2ConfigFlowsThrough_ButNeverChargesALaunch() public {
        PoolKey memory launch = _launchKey();
        PoolKey memory normal = _key(3000, address(0), 0);
        _flag(launch);

        vm.startPrank(safe);
        v2.setPoolFee(launch.toId(), true, 4000, 4000);
        v2.setPoolFee(normal.toId(), true, 4000, 4000);
        v2.setDynamicFee(true, 4000, 4000);
        vm.stopPrank();

        uint24 max = uint24(4000) | (uint24(4000) << 12);
        assertEq(v3.protocolFeeForPool(normal), max, "an override on a normal pool applies");
        assertEq(v3.protocolFeeForPool(launch), 0, "an override cannot charge a locked launch at birth");

        vm.prank(safe);
        v2.setProtocolFeeSplitRatio(0);
        vm.prank(safe);
        v2.setPoolFee(normal.toId(), false, 0, 0);
        assertEq(v3.protocolFeeForPool(normal), 0, "split ratio 0 reaches static pools");
    }

    /// When V2 already says zero, V3 does not call the oracle at all - even a broken one.
    function test_PolicyZero_SkipsTheOracle() public {
        kit.setMode(MockLaunchOracle.Mode.Revert);
        vm.prank(safe);
        v2.setFeesDisabled(true);
        PoolKey memory key = _launchKey();
        vm.expectCall(address(kit), abi.encodeWithSelector(kit.isLockedLaunch.selector), 0);
        assertEq(v3.protocolFeeForPool(key), 0);
    }

    /// If the policy ever failed, V3 must fail closed (pool creation reverts), never fall back to
    /// zero: whoever could make V2 fail would otherwise mint zero-fee pools for life.
    function test_PolicyFailure_FailsClosed() public {
        RevertingPolicy broken = new RevertingPolicy();
        DeepCoreProtocolFeeControllerV3 c =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(broken)), address(kit));
        vm.expectRevert(bytes("policy down"));
        c.protocolFeeForPool(_key(3000, address(0), 0));
    }

    /* =====================================================================
       SPOOFING
       ===================================================================== */

    /// A second "kit" that vouches for everything is simply never asked.
    function test_Spoof_FakeOracleIsNeverConsulted() public {
        MockLaunchOracle fake = new MockLaunchOracle();
        fake.setMode(MockLaunchOracle.Mode.TrueForEverything);
        PoolKey memory key = _launchKey();
        assertEq(fake.isLockedLaunch(PoolId.unwrap(key.toId())), true);
        assertEq(v3.protocolFeeForPool(key), PACKED_999);
    }

    /// The pool's own hook answering `isLockedLaunch == true` is irrelevant: V3 asks `launchOracle`.
    function test_Spoof_HookThatClaimsToBeALaunch() public {
        MockLaunchOracle hookThatLies = new MockLaunchOracle();
        hookThatLies.setMode(MockLaunchOracle.Mode.TrueForEverything);
        PoolKey memory key = _key(DYN, address(hookThatLies), 7);
        assertEq(v3.protocolFeeForPool(key), PACKED_999);
    }

    /// An oracle can only waive a fee, never create one: a flag on a pool V2 prices at zero stays zero.
    function test_OracleCannotRaiseAnything() public {
        kit.setMode(MockLaunchOracle.Mode.TrueForEverything);
        vm.prank(safe);
        v2.setDynamicFee(false, 0, 0);
        assertEq(v3.protocolFeeForPool(_launchKey()), 0);
        kit.setMode(MockLaunchOracle.Mode.Honest);
        assertEq(v3.protocolFeeForPool(_launchKey()), 0);
    }

    /* =====================================================================
       MALFORMED ORACLE ANSWERS - every one must mean "charge the fee"
       ===================================================================== */

    function _assertCharged(MockLaunchOracle.Mode m) internal {
        PoolKey memory key = _launchKey();
        _flag(key);
        kit.setMode(m);
        assertEq(v3.protocolFeeForPool(key), PACKED_999);
        assertFalse(v3.isLockedLaunchPool(key.toId()));
    }

    function test_Malformed_RevertMeansCharged() public {
        _assertCharged(MockLaunchOracle.Mode.Revert);
    }

    /// Revert data that happens to encode `true` is still a revert.
    function test_Malformed_RevertWithTrueDataMeansCharged() public {
        _assertCharged(MockLaunchOracle.Mode.RevertWithTrueData);
    }

    function test_Malformed_NonCanonicalBoolMeansCharged() public {
        _assertCharged(MockLaunchOracle.Mode.ReturnTwo);
    }

    function test_Malformed_LongReturnMeansCharged() public {
        _assertCharged(MockLaunchOracle.Mode.ReturnLongTrue);
    }

    function test_Malformed_ShortReturnMeansCharged() public {
        _assertCharged(MockLaunchOracle.Mode.ReturnShort);
    }

    /// 100 kB of return data costs V3 nothing: at most 32 bytes are copied.
    function test_Malformed_ReturnBombIsNotCopied() public {
        PoolKey memory key = _launchKey();
        kit.setMode(MockLaunchOracle.Mode.ReturnBomb);
        uint256 before = gasleft();
        assertEq(v3.protocolFeeForPool(key), PACKED_999);
        assertLt(before - gasleft(), 120_000, "return data must not be copied into V3's memory");
    }

    /* =====================================================================
       GAS: the answer is a function of state, never of the caller's gas limit
       ===================================================================== */

    function _callWithGas(PoolKey memory key, uint256 g)
        internal
        view
        returns (bool ok, uint24 fee, bytes4 errSel)
    {
        (bool s, bytes memory r) =
            address(v3).staticcall{gas: g}(abi.encodeCall(DeepCoreProtocolFeeControllerV3.protocolFeeForPool, (key)));
        if (s && r.length == 32) return (true, abi.decode(r, (uint24)), bytes4(0));
        if (r.length >= 4) errSel = bytes4(r);
    }

    /// The burner must cost enough that EIP-150 could starve it, and still fit the stipend.
    function test_Gas_BurnOracleIsCalibrated() public {
        kit.setMode(MockLaunchOracle.Mode.BurnThenTrue);
        uint256 before = gasleft();
        kit.isLockedLaunch(bytes32(0));
        uint256 used = before - gasleft();
        assertGt(used, 38_000, "burn oracle must be expensive enough to starve");
        assertLt(used, 49_000, "and still fit its stipend");
    }

    /// Scan the caller's gas limit across the whole interesting range. A locked launch whose kit
    /// answer is expensive must either revert or come back zero. It must never come back charged.
    function test_Gas_ExpensiveHonestAnswer_NeverChargedAtAnyGasLimit() public {
        // The constructor probe already ran against the honest mode; now make the answer expensive.
        kit.setMode(MockLaunchOracle.Mode.BurnThenTrue);

        PoolKey memory key = _launchKey();
        uint256 okCount;
        uint256 gasGuardCount;
        for (uint256 g = 10_000; g <= 160_000; g += 150) {
            (bool ok, uint24 fee, bytes4 errSel) = _callWithGas(key, g);
            if (ok) {
                okCount++;
                assertEq(fee, 0, "a locked launch was charged because of the caller's gas limit");
            } else if (errSel == DeepCoreProtocolFeeControllerV3.InsufficientGasForLaunchCheck.selector) {
                gasGuardCount++;
            }
        }
        assertGt(okCount, 0, "must succeed with enough gas");
        assertGt(gasGuardCount, 0, "the gas floor must be what refuses a starved call");
    }

    /// Same scan with a cheap honest kit: still never charged.
    function test_Gas_CheapHonestAnswer_NeverChargedAtAnyGasLimit() public {
        PoolKey memory key = _launchKey();
        _flag(key);
        for (uint256 g = 5_000; g <= 120_000; g += 250) {
            (bool ok, uint24 fee,) = _callWithGas(key, g);
            if (ok) assertEq(fee, 0);
        }
    }

    function test_Gas_InsufficientGasRevertsWithTheFloor() public {
        PoolKey memory key = _launchKey();
        bool sawFloor;
        for (uint256 g = 5_000; g <= 80_000; g += 500) {
            (, , bytes4 errSel) = _callWithGas(key, g);
            if (errSel == DeepCoreProtocolFeeControllerV3.InsufficientGasForLaunchCheck.selector) sawFloor = true;
        }
        assertTrue(sawFloor);
    }

    /* =====================================================================
       FUZZ: fee resolution
       ===================================================================== */

    function testFuzz_Resolution(
        uint24 lpFee,
        uint256 ratio,
        bool dynSet,
        uint16 dyn0,
        uint16 dyn1,
        bool disabled,
        bool overrideSet,
        uint16 ov0,
        uint16 ov1,
        bool flag,
        uint8 modeRaw,
        uint256 salt
    ) public {
        ratio = bound(ratio, 0, 1e6);
        dyn0 = uint16(bound(dyn0, 0, 4000));
        dyn1 = uint16(bound(dyn1, 0, 4000));
        ov0 = uint16(bound(ov0, 0, 4000));
        ov1 = uint16(bound(ov1, 0, 4000));
        // Every mode except the burner, whose answer depends on the stipend and is covered above.
        MockLaunchOracle.Mode mode = MockLaunchOracle.Mode(modeRaw % 7);
        if (modeRaw % 7 == uint8(MockLaunchOracle.Mode.BurnThenTrue)) mode = MockLaunchOracle.Mode.TrueForEverything;

        PoolKey memory key = _key(lpFee, address(uint160(0x4444 + (salt % 3))), salt % 5);

        vm.startPrank(safe);
        v2.setProtocolFeeSplitRatio(ratio);
        v2.setDynamicFee(dynSet, dyn0, dyn1);
        v2.setPoolFee(key.toId(), overrideSet, ov0, ov1);
        v2.setFeesDisabled(disabled);
        vm.stopPrank();

        if (flag) _flag(key);
        kit.setMode(mode);

        bool vouched = (mode == MockLaunchOracle.Mode.Honest && flag) || mode == MockLaunchOracle.Mode.TrueForEverything;
        uint24 policyFee = v2.protocolFeeForPool(key);
        uint24 expected = vouched ? 0 : policyFee;

        uint24 got = v3.protocolFeeForPool(key);
        assertEq(got, expected);
        assertLe(got, policyFee, "V3 never charges more than V2");
        assertLe(got & 0xFFF, 4000);
        assertLe(got >> 12, 4000);
    }

    /* =====================================================================
       FORWARDERS AND ACCESS CONTROL
       ===================================================================== */

    function test_Collect_OwnerOnly_AndRefusesZeroRecipient() public {
        manager.setAccrued(usdg, 1000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.collect(address(manager), usdg, 0, stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.collect(address(manager), usdg, 0, guardian);

        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.ZeroRecipient.selector);
        v3.collect(address(manager), usdg, 0, address(0));

        vm.prank(safe);
        assertEq(v3.collect(address(manager), usdg, 400, safe), 400);
        assertEq(manager.protocolFeesAccrued(usdg), 600);
        assertEq(manager.lastRecipient(), safe);
    }

    function test_Sweep_PermissionlessAndUnredirectable() public {
        manager.setAccrued(usdg, 4242);
        vm.prank(stranger);
        assertEq(v3.sweep(address(manager), usdg), 4242);
        assertEq(manager.lastRecipient(), safe);
    }

    function test_Sweep_RevertsWhenEmpty() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.NothingToCollect.selector, address(manager), usdg)
        );
        v3.sweep(address(manager), usdg);
    }

    function test_SetTreasury_OwnerOnly_NeverZero() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.setTreasury(stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.setTreasury(guardian);

        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.ZeroRecipient.selector);
        v3.setTreasury(address(0));

        vm.prank(safe);
        v3.setTreasury(address(0xC0FFEE));
        assertEq(v3.treasury(), address(0xC0FFEE));

        manager.setAccrued(usdg, 5);
        v3.sweep(address(manager), usdg);
        assertEq(manager.lastRecipient(), address(0xC0FFEE));
    }

    function test_SetPoolProtocolFee_OwnerOnly() public {
        PoolKey memory key = _key(3000, address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.setPoolProtocolFee(address(manager), key, 0);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.setPoolProtocolFee(address(manager), key, 0);

        vm.prank(safe);
        v3.setPoolProtocolFee(address(manager), key, 123);
        assertEq(manager.poolProtocolFee(key.toId()), 123);
    }

    function test_SyncPoolToPolicy_OwnerOnly_AndResolvesTheRule() public {
        PoolKey memory launch = _launchKey();
        PoolKey memory normal = _key(3000, address(0), 0);
        _flag(launch);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.syncPoolToPolicy(address(manager), launch);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.syncPoolToPolicy(address(manager), launch);

        /* A launch left behind under V2: V2 was the controller when it was stamped. V3's own setter
           can no longer produce this state (LockedLaunchPoolKeepsZeroFee), which is the point. */
        manager.setController(address(v2));
        vm.prank(safe);
        v2.setPoolProtocolFee(address(manager), launch, PACKED_999);
        assertEq(manager.poolProtocolFee(launch.toId()), PACKED_999);
        manager.setController(address(v3));
        vm.startPrank(safe);
        assertEq(v3.syncPoolToPolicy(address(manager), launch), 0);
        assertEq(v3.syncPoolToPolicy(address(manager), normal), PACKED_999);
        vm.stopPrank();
        assertEq(manager.poolProtocolFee(launch.toId()), 0);
        assertEq(manager.poolProtocolFee(normal.toId()), PACKED_999);
    }

    function test_TransferOwnership_TwoStep_OwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.transferOwnership(stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.transferOwnership(guardian);

        address next = makeAddr("nextSafe");
        vm.prank(safe);
        v3.transferOwnership(next);
        assertEq(v3.owner(), safe, "nomination alone moves nothing");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.acceptOwnership();

        vm.prank(next);
        v3.acceptOwnership();
        assertEq(v3.owner(), next);
    }

    function test_RenounceOwnership_Reverts() public {
        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.RenounceDisabled.selector);
        v3.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.RenounceDisabled.selector);
        v3.renounceOwnership();
        assertEq(v3.owner(), safe);
    }

    /// The guardian's only power is V2's: it disables fees, which only ever lowers V3's answers.
    function test_Guardian_OnlyReduces() public {
        PoolKey memory normal = _key(3000, address(0), 0);
        assertEq(v3.protocolFeeForPool(normal), PACKED_999);

        vm.prank(guardian);
        v2.emergencyDisableFees();
        assertEq(v3.protocolFeeForPool(normal), 0);

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v2.setFeesDisabled(false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v2.setDynamicFee(true, 4000, 4000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v2.setPoolFee(normal.toId(), true, 4000, 4000);
        vm.stopPrank();
    }

    function test_OwnerConfigCapsStillHold() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.FeeExceedsMaximum.selector, 4001, 4000));
        v2.setDynamicFee(true, 4001, 0);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.FeeExceedsMaximum.selector, 4001, 4000));
        v2.setPoolFee(_launchKey().toId(), true, 0, 4001);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.InvalidSplitRatio.selector, 1e6 + 1));
        v2.setProtocolFeeSplitRatio(1e6 + 1);
        vm.stopPrank();
    }

    /* =====================================================================
       ACCEPTANCE FINDINGS, 2026-09-18
       ===================================================================== */

    /// Finding B: the owner's per-pool setter must not be able to stamp a fee on a locked launch pool.
    function test_FIX_SetPoolProtocolFee_RefusesNonZeroOnLockedLaunchPool() public {
        PoolKey memory launch = _launchKey();
        _flag(launch);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.LockedLaunchPoolKeepsZeroFee.selector, launch.toId()));
        v3.setPoolProtocolFee(address(manager), launch, 999);
        /* Zero is always allowed: it is the rule itself. */
        vm.prank(safe);
        v3.setPoolProtocolFee(address(manager), launch, 0);
        assertEq(manager.poolProtocolFee(launch.toId()), 0);
        /* A normal pool is unaffected. */
        PoolKey memory normal = _key(3000, address(0), 0);
        vm.prank(safe);
        v3.setPoolProtocolFee(address(manager), normal, 999);
        assertEq(manager.poolProtocolFee(normal.toId()), 999);
    }

    /// Finding A: a misdirected ERC-20 has a path out, owner only, and only when there is something.
    function test_FIX_RescueERC20_OwnerOnly_NothingToRescue_HappyPath() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.NothingToRescue.selector, address(stray)));
        v3.rescueERC20(address(stray), safe);

        stray.mint(address(v3), 7e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v3.rescueERC20(address(stray), stranger);
        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV3.RescueToZero.selector);
        v3.rescueERC20(address(stray), address(0));

        vm.prank(safe);
        v3.rescueERC20(address(stray), address(0xBEEF));
        assertEq(stray.balanceOf(address(0xBEEF)), 7e18);
        assertEq(stray.balanceOf(address(v3)), 0);
    }
}
