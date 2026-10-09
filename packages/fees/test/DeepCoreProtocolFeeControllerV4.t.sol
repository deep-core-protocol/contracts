// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "../src/DeepCoreProtocolFeeControllerV3.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {MockLaunchOracle, WastefulLaunchOracle, NotAnOracle, MockProtocolFees} from "./utils/V3Mocks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

contract RevertingPolicyV4 {
    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        revert("policy down");
    }
}

/// @dev Unit tests against the REAL V2 as policy, with mock oracles and a mock manager. V3's unit
/// suite, re-run against V4, plus everything that only exists once there is more than one oracle.
/// The integration suite (`FeeControllerV4Live.t.sol`) runs the same rules through a real core manager.
///
/// `kitA` stands for the first kit and `kitB` for the second; `v4` names them in that order.
contract DeepCoreProtocolFeeControllerV4Test is Test {
    using PoolIdLibrary for PoolKey;

    DeepCoreProtocolFeeControllerV2 internal v2;
    DeepCoreProtocolFeeControllerV4 internal v4;
    MockLaunchOracle internal kitA;
    MockLaunchOracle internal kitB;
    MockProtocolFees internal manager;

    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("opsGuardian");
    address internal stranger = makeAddr("stranger");
    Currency internal usdg = Currency.wrap(address(0x5f65));

    uint24 internal constant PACKED_999 = uint24(999) | (uint24(999) << 12);
    uint24 internal constant DYN = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint256 internal constant FLOOR = 55_793; // 50_000 + floor(50_000 / 63) + 5_000

    function setUp() public {
        v2 = new DeepCoreProtocolFeeControllerV2(safe, guardian);
        kitA = new MockLaunchOracle();
        kitB = new MockLaunchOracle();
        v4 = _deploy(_list(address(kitA), address(kitB)));
        manager = new MockProtocolFees(address(v4));
    }

    /* ------------------------------ helpers ------------------------------ */

    function _list(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _list(address a, address b, address c) internal pure returns (address[] memory l) {
        l = new address[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
    }

    function _list(address a, address b, address c, address d) internal pure returns (address[] memory l) {
        l = new address[](4);
        l[0] = a;
        l[1] = b;
        l[2] = c;
        l[3] = d;
    }

    function _deploy(address[] memory oracles) internal returns (DeepCoreProtocolFeeControllerV4) {
        return new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), oracles, new address[](0), 7 days);
    }

    /// @dev `n` fresh honest oracles with `wrong` written over position `at`.
    function _listWith(uint256 n, uint256 at, address wrong) internal returns (address[] memory l) {
        l = new address[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = i == at ? wrong : address(new MockLaunchOracle());
        }
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

    function _flag(MockLaunchOracle kit, PoolKey memory key) internal {
        kit.setFlag(PoolId.unwrap(key.toId()), true);
    }

    /* =====================================================================
       CONSTRUCTION AND IMMUTABLES
       ===================================================================== */

    function test_Constructor_SetsEverything() public view {
        assertEq(v4.owner(), safe);
        assertEq(v4.pendingOwner(), address(0));
        assertEq(address(v4.policy()), address(v2));
        assertEq(v4.launchOracleCount(), 2);
        assertEq(v4.launchOracle0(), address(kitA));
        assertEq(v4.launchOracle1(), address(kitB));
        assertEq(v4.launchOracle2(), address(0), "unused slot");
        assertEq(v4.launchOracle3(), address(0), "unused slot");
        assertEq(v4.treasury(), safe, "treasury defaults to the owner");
        assertEq(v4.MAX_LAUNCH_ORACLES(), 4);
        assertEq(v4.LAUNCH_ORACLE_GAS(), 50_000);
        assertEq(v4.LAUNCH_ORACLE_MIN_GASLEFT(), FLOOR);
    }

    /// The stipend and the floor are V3's, to the unit: V4 changes who is asked, not how.
    function test_Constructor_GasConstantsAreV3s() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        assertEq(v4.LAUNCH_ORACLE_GAS(), v3.LAUNCH_ORACLE_GAS());
        assertEq(v4.LAUNCH_ORACLE_MIN_GASLEFT(), v3.LAUNCH_ORACLE_MIN_GASLEFT());
    }

    function test_Constructor_AcceptsOneToFourOracles() public {
        for (uint256 n = 1; n <= 4; ++n) {
            address[] memory l = _listWith(n, type(uint256).max, address(0));
            DeepCoreProtocolFeeControllerV4 c = _deploy(l);
            assertEq(c.launchOracleCount(), n);

            address[] memory got = c.launchOracles();
            assertEq(got.length, n);
            for (uint256 i; i < n; ++i) {
                assertEq(got[i], l[i], "order is the constructor's");
                assertTrue(c.isLaunchOracle(l[i]));
            }
            assertEq(c.launchOracle0(), l[0]);
            assertEq(c.launchOracle1(), n > 1 ? l[1] : address(0));
            assertEq(c.launchOracle2(), n > 2 ? l[2] : address(0));
            assertEq(c.launchOracle3(), n > 3 ? l[3] : address(0));
        }
    }

    function test_Constructor_RejectsZeroOwner() public {
        address[] memory l = _list(address(kitA));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new DeepCoreProtocolFeeControllerV4(address(0), IProtocolFeeController(address(v2)), l, new address[](0), 7 days);
    }

    function test_Constructor_RejectsZeroPolicy() public {
        address[] memory l = _list(address(kitA));
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.ZeroAddress.selector);
        new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(0)), l, new address[](0), 7 days);
    }

    function test_Constructor_RejectsEOAPolicy() public {
        address[] memory l = _list(address(kitA));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NoCode.selector, stranger));
        new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(stranger), l, new address[](0), 7 days);
    }

    function test_Constructor_RejectsAnEmptyList() public {
        address[] memory none = new address[](0);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.NoLaunchOracles.selector);
        _deploy(none);
    }

    function test_Constructor_RejectsMoreThanFour() public {
        address[] memory five = _listWith(5, type(uint256).max, address(0));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.TooManyLaunchOracles.selector, 5, 4));
        _deploy(five);

        address[] memory nine = _listWith(9, type(uint256).max, address(0));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.TooManyLaunchOracles.selector, 9, 4));
        _deploy(nine);
    }

    function test_Constructor_RejectsAZeroOracleAtEveryPosition() public {
        for (uint256 n = 1; n <= 4; ++n) {
            for (uint256 at; at < n; ++at) {
                address[] memory l = _listWith(n, at, address(0));
                vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.ZeroLaunchOracle.selector, at));
                _deploy(l);
            }
        }
    }

    function test_Constructor_RejectsAnEOAOracleAtEveryPosition() public {
        for (uint256 n = 1; n <= 4; ++n) {
            for (uint256 at; at < n; ++at) {
                address[] memory l = _listWith(n, at, stranger);
                vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NoCode.selector, stranger));
                _deploy(l);
            }
        }
    }

    function test_Constructor_RejectsThePolicyAsAnOracleAtEveryPosition() public {
        for (uint256 n = 1; n <= 4; ++n) {
            for (uint256 at; at < n; ++at) {
                address[] memory l = _listWith(n, at, address(v2));
                vm.expectRevert(
                    abi.encodeWithSelector(
                        DeepCoreProtocolFeeControllerV4.InvalidDependencies.selector, address(v2), address(v2)
                    )
                );
                _deploy(l);
            }
        }
    }

    /// Every pair of positions, adjacent or not. A duplicate is a list with a kit missing.
    function test_Constructor_RejectsADuplicateAtEveryPairOfPositions() public {
        for (uint256 n = 2; n <= 4; ++n) {
            for (uint256 first; first < n; ++first) {
                for (uint256 second = first + 1; second < n; ++second) {
                    address[] memory l = _listWith(n, type(uint256).max, address(0));
                    l[second] = l[first];
                    vm.expectRevert(
                        abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.DuplicateLaunchOracle.selector, l[first])
                    );
                    _deploy(l);
                }
            }
        }
    }

    /// A mistyped oracle address (the v1 kit, the registry, the locker) is refused at deploy rather
    /// than becoming a zero rule that silently never fires - wherever in the list it sits.
    function test_Constructor_RejectsAnOracleWithoutTheInterfaceAtEveryPosition() public {
        NotAnOracle wrong = new NotAnOracle();
        for (uint256 n = 1; n <= 4; ++n) {
            for (uint256 at; at < n; ++at) {
                address[] memory l = _listWith(n, at, address(wrong));
                vm.expectRevert(
                    abi.encodeWithSelector(
                        DeepCoreProtocolFeeControllerV4.OracleDoesNotImplementInterface.selector, address(wrong)
                    )
                );
                _deploy(l);
            }
        }
    }

    function test_Constructor_RejectsAnOracleThatVouchesForEverythingAtEveryPosition() public {
        MockLaunchOracle liar = new MockLaunchOracle();
        for (uint256 n = 1; n <= 4; ++n) {
            for (uint256 at; at < n; ++at) {
                address[] memory l = _listWith(n, at, address(liar));

                liar.setMode(MockLaunchOracle.Mode.TrueForEverything);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        DeepCoreProtocolFeeControllerV4.OracleDoesNotImplementInterface.selector, address(liar)
                    )
                );
                _deploy(l);

                liar.setMode(MockLaunchOracle.Mode.ReturnTwo);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        DeepCoreProtocolFeeControllerV4.OracleDoesNotImplementInterface.selector, address(liar)
                    )
                );
                _deploy(l);
            }
        }
    }

    /// One good kit must not carry a broken one in with it: the probe runs per oracle.
    function test_Constructor_RejectsABrokenOracleBehindAGoodOne() public {
        WastefulLaunchOracle broken = new WastefulLaunchOracle();
        broken.setMode(WastefulLaunchOracle.Mode.BurnAllGas);
        address[] memory l = _list(address(kitA), address(broken));
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.OracleDoesNotImplementInterface.selector, address(broken))
        );
        _deploy(l);
    }

    /* =====================================================================
       THE ORACLE SET - VIEWS
       ===================================================================== */

    function test_IsLaunchOracle_MembersOnly() public view {
        assertTrue(v4.isLaunchOracle(address(kitA)));
        assertTrue(v4.isLaunchOracle(address(kitB)));
        assertFalse(v4.isLaunchOracle(address(0)), "the unused slots hold zero; zero is still not an oracle");
        assertFalse(v4.isLaunchOracle(address(v2)));
        assertFalse(v4.isLaunchOracle(address(v4)));
        assertFalse(v4.isLaunchOracle(safe));
        assertFalse(v4.isLaunchOracle(stranger));
    }

    function testFuzz_IsLaunchOracle(address candidate) public view {
        bool member = candidate == address(kitA) || candidate == address(kitB);
        assertEq(v4.isLaunchOracle(candidate), member);
    }

    function test_LaunchOracles_ConfiguredOnesInOrder() public view {
        address[] memory got = v4.launchOracles();
        assertEq(got.length, 2, "no zero padding");
        assertEq(got[0], address(kitA));
        assertEq(got[1], address(kitB));
    }

    /// V4 must not answer `launchOracle()` at all. The first kit's library reads that selector off
    /// the installed controller; a set has no single answer to give it.
    function test_NoLaunchOracleGetter_TheSelectorIsAbsent() public {
        bytes memory callData = abi.encodeWithSignature("launchOracle()");

        (bool ok, bytes memory ret) = address(v4).staticcall(callData);
        assertFalse(ok, "V4 answered launchOracle()");
        assertEq(ret.length, 0, "no fallback either: the call dies with nothing");

        /* The kit's own read, as `LaunchLegs._assertBornAtZero` makes it: 20,000 gas, 32 bytes. */
        assertFalse(_kitReadsItselfAsBound(address(v4), address(kitA)));
        assertFalse(_kitReadsItselfAsBound(address(v4), address(kitB)));

        /* Positive control: the same probe does see V3's getter, so its silence above means something. */
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        (ok, ret) = address(v3).staticcall(callData);
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(kitA));
        assertTrue(_kitReadsItselfAsBound(address(v3), address(kitA)));
    }

    function _kitReadsItselfAsBound(address controller, address kit) internal view returns (bool) {
        bytes4 selector = bytes4(keccak256("launchOracle()"));
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            ok := staticcall(20000, controller, 0x00, 0x04, 0x00, 0x20)
            word := mload(0x00)
            ok := and(ok, eq(returndatasize(), 0x20))
        }
        return ok && word == uint256(uint160(kit));
    }

    /// No receive, no fallback: native cannot be sent, and an unknown selector is refused.
    function test_NoReceiveNoFallback() public {
        vm.deal(address(this), 1 ether);
        manager.setAccrued(usdg, 10);
        (bool ok,) = address(v4).call{value: 1}("");
        assertFalse(ok, "receive");
        bytes memory sweepCall = abi.encodeCall(DeepCoreProtocolFeeControllerV4.sweep, (address(manager), usdg));
        (ok,) = address(v4).call{value: 1}(sweepCall);
        assertFalse(ok, "no payable function");
        (ok,) = address(v4).call(sweepCall);
        assertTrue(ok, "the same call without value goes through: it was the value that was refused");
        (ok,) = address(v4).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "fallback");
        assertEq(address(v4).balance, 0);
    }

    /* =====================================================================
       THE RULE
       ===================================================================== */

    function test_LockedLaunchPool_VouchedByTheFirst_IsZero() public {
        PoolKey memory key = _launchKey();
        assertEq(v2.protocolFeeForPool(key), PACKED_999, "V2 alone would charge it");
        _flag(kitA, key);
        assertEq(v4.protocolFeeForPool(key), 0);
        assertTrue(v4.isLockedLaunchPool(key.toId()));
    }

    function test_LockedLaunchPool_VouchedByTheLast_IsZero() public {
        PoolKey memory key = _launchKey();
        _flag(kitB, key);
        assertEq(v4.protocolFeeForPool(key), 0);
        assertTrue(v4.isLockedLaunchPool(key.toId()));
    }

    function test_LockedLaunchPool_VouchedBySeveral_IsZero() public {
        PoolKey memory key = _launchKey();
        _flag(kitA, key);
        _flag(kitB, key);
        assertEq(v4.protocolFeeForPool(key), 0);
        assertTrue(v4.isLockedLaunchPool(key.toId()));
    }

    function test_Pool_VouchedByNone_PaysTheConfiguredFee() public view {
        PoolKey memory key = _launchKey();
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
        assertFalse(v4.isLockedLaunchPool(key.toId()));
    }

    /// Four oracles, and the pool is vouched for by exactly one of them, at each position in turn.
    function test_FourOracles_VouchedByEachPositionAlone_IsZero() public {
        MockLaunchOracle[4] memory kits =
            [new MockLaunchOracle(), new MockLaunchOracle(), new MockLaunchOracle(), new MockLaunchOracle()];
        DeepCoreProtocolFeeControllerV4 c =
            _deploy(_list(address(kits[0]), address(kits[1]), address(kits[2]), address(kits[3])));

        for (uint256 at; at < 4; ++at) {
            PoolKey memory key = _key(DYN, address(0x4444), 100 + at);
            assertEq(c.protocolFeeForPool(key), PACKED_999, "nobody vouches yet");
            _flag(kits[at], key);
            assertEq(c.protocolFeeForPool(key), 0);
            assertTrue(c.isLockedLaunchPool(key.toId()));
        }
        assertEq(c.protocolFeeForPool(_key(DYN, address(0x4444), 99)), PACKED_999, "a pool none of the four knows");
    }

    function test_NormalStaticPool_PaysTheConfiguredFee() public view {
        PoolKey memory key = _key(3000, address(0), 0);
        assertEq(v4.protocolFeeForPool(key), v2.protocolFeeForPool(key));
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
    }

    /// A flag for one key says nothing about a sibling key (other params, manager, hook, fee).
    function test_FlagIsBoundToTheExactPoolId() public {
        PoolKey memory key = _launchKey();
        _flag(kitA, key);
        _flag(kitB, key);

        PoolKey memory sibling = _launchKey();
        sibling.parameters = bytes32(uint256(0x3c0000) | 2);
        assertEq(v4.protocolFeeForPool(sibling), PACKED_999, "other parameters");

        sibling = _launchKey();
        sibling.poolManager = IPoolManager(address(0x3334));
        assertEq(v4.protocolFeeForPool(sibling), PACKED_999, "other manager");

        sibling = _launchKey();
        sibling.hooks = IHooks(address(0x4445));
        assertEq(v4.protocolFeeForPool(sibling), PACKED_999, "other hook");
    }

    /// Configuration changes on V2 flow through V4 for non-launch pools, and never un-zero a launch
    /// of either kit.
    function test_V2ConfigFlowsThrough_ButNeverChargesALaunch() public {
        PoolKey memory launchA = _launchKey();
        PoolKey memory launchB = _key(DYN, address(0x5555), 2);
        PoolKey memory normal = _key(3000, address(0), 0);
        _flag(kitA, launchA);
        _flag(kitB, launchB);

        vm.startPrank(safe);
        v2.setPoolFee(launchA.toId(), true, 4000, 4000);
        v2.setPoolFee(launchB.toId(), true, 4000, 4000);
        v2.setPoolFee(normal.toId(), true, 4000, 4000);
        v2.setDynamicFee(true, 4000, 4000);
        vm.stopPrank();

        uint24 max = uint24(4000) | (uint24(4000) << 12);
        assertEq(v4.protocolFeeForPool(normal), max, "an override on a normal pool applies");
        assertEq(v4.protocolFeeForPool(launchA), 0, "an override cannot charge the first kit's launch");
        assertEq(v4.protocolFeeForPool(launchB), 0, "nor the second kit's");

        vm.prank(safe);
        v2.setProtocolFeeSplitRatio(0);
        vm.prank(safe);
        v2.setPoolFee(normal.toId(), false, 0, 0);
        assertEq(v4.protocolFeeForPool(normal), 0, "split ratio 0 reaches static pools");
    }

    /// When V2 already says zero, V4 asks nobody - even broken oracles.
    function test_PolicyZero_SkipsEveryOracle() public {
        kitA.setMode(MockLaunchOracle.Mode.Revert);
        kitB.setMode(MockLaunchOracle.Mode.Revert);
        vm.prank(safe);
        v2.setFeesDisabled(true);
        PoolKey memory key = _launchKey();
        vm.expectCall(address(kitA), abi.encodeWithSelector(kitA.isLockedLaunch.selector), 0);
        vm.expectCall(address(kitB), abi.encodeWithSelector(kitB.isLockedLaunch.selector), 0);
        assertEq(v4.protocolFeeForPool(key), 0);
    }

    /// Asking stops at the first oracle that vouches; the ones after it are not called.
    function test_StopsAtTheFirstOracleThatVouches() public {
        PoolKey memory key = _launchKey();
        _flag(kitA, key);
        vm.expectCall(address(kitA), abi.encodeWithSelector(kitA.isLockedLaunch.selector), 1);
        vm.expectCall(address(kitB), abi.encodeWithSelector(kitB.isLockedLaunch.selector), 0);
        assertEq(v4.protocolFeeForPool(key), 0);
    }

    /// And when the first does not vouch, the next one IS asked, exactly once each.
    function test_AsksEveryOracleUntilOneVouches() public {
        PoolKey memory key = _launchKey();
        _flag(kitB, key);
        vm.expectCall(address(kitA), abi.encodeWithSelector(kitA.isLockedLaunch.selector), 1);
        vm.expectCall(address(kitB), abi.encodeWithSelector(kitB.isLockedLaunch.selector), 1);
        assertEq(v4.protocolFeeForPool(key), 0);
    }

    /// If the policy ever failed, V4 must fail closed (pool creation reverts), never fall back to
    /// zero: whoever could make V2 fail would otherwise mint zero-fee pools for life.
    function test_PolicyFailure_FailsClosed() public {
        RevertingPolicyV4 broken = new RevertingPolicyV4();
        DeepCoreProtocolFeeControllerV4 c = new DeepCoreProtocolFeeControllerV4(
            safe, IProtocolFeeController(address(broken)), _list(address(kitA), address(kitB)), new address[](0), 7 days
        );
        vm.expectRevert(bytes("policy down"));
        c.protocolFeeForPool(_key(3000, address(0), 0));
    }

    /* =====================================================================
       SPOOFING
       ===================================================================== */

    /// A third "kit" that vouches for everything, and is not in the set, is simply never asked.
    function test_Spoof_OracleOutsideTheSetIsNeverConsulted() public {
        MockLaunchOracle fake = new MockLaunchOracle();
        fake.setMode(MockLaunchOracle.Mode.TrueForEverything);
        PoolKey memory key = _launchKey();
        assertEq(fake.isLockedLaunch(PoolId.unwrap(key.toId())), true);
        vm.expectCall(address(fake), abi.encodeWithSelector(fake.isLockedLaunch.selector), 0);
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
        assertFalse(v4.isLaunchOracle(address(fake)));
    }

    /// The pool's own hook answering `isLockedLaunch == true` is irrelevant: V4 asks its set.
    function test_Spoof_HookThatClaimsToBeALaunch() public {
        MockLaunchOracle hookThatLies = new MockLaunchOracle();
        hookThatLies.setMode(MockLaunchOracle.Mode.TrueForEverything);
        PoolKey memory key = _key(DYN, address(hookThatLies), 7);
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
    }

    /// An oracle can only waive a fee, never create one: a flag on a pool V2 prices at zero stays zero.
    function test_OracleCannotRaiseAnything() public {
        kitA.setMode(MockLaunchOracle.Mode.TrueForEverything);
        kitB.setMode(MockLaunchOracle.Mode.TrueForEverything);
        vm.prank(safe);
        v2.setDynamicFee(false, 0, 0);
        assertEq(v4.protocolFeeForPool(_launchKey()), 0);
        kitA.setMode(MockLaunchOracle.Mode.Honest);
        kitB.setMode(MockLaunchOracle.Mode.Honest);
        assertEq(v4.protocolFeeForPool(_launchKey()), 0);
    }

    /// One oracle gone rogue waives fees (its bound) and cannot make any pool cost more than V2 says.
    function test_ARogueOracleCanOnlyWaive() public {
        kitB.setMode(MockLaunchOracle.Mode.TrueForEverything);
        PoolKey memory normal = _key(3000, address(0), 0);
        assertEq(v4.protocolFeeForPool(normal), 0, "the whole of its power");
        assertLe(v4.protocolFeeForPool(normal), v2.protocolFeeForPool(normal));
    }

    /* =====================================================================
       MALFORMED ORACLE ANSWERS - every one must mean "this oracle did not vouch"
       ===================================================================== */

    /// @dev `broken` misbehaves while holding a flag for the pool. With nobody else vouching the pool
    /// is charged; with the OTHER oracle vouching it is zero, whichever side of it `broken` sits.
    function _assertMalformed(MockLaunchOracle.Mode m) internal {
        PoolKey memory key = _launchKey();
        bytes32 id = PoolId.unwrap(key.toId());

        /* broken first, honest last */
        kitA.setFlag(id, true);
        kitA.setMode(m);
        assertEq(v4.protocolFeeForPool(key), PACKED_999, "a malformed answer vouched");
        assertFalse(v4.isLockedLaunchPool(key.toId()));
        kitB.setFlag(id, true);
        assertEq(v4.protocolFeeForPool(key), 0, "a malformed answer silenced the oracle after it");
        assertTrue(v4.isLockedLaunchPool(key.toId()));

        /* honest first, broken last */
        kitA.setMode(MockLaunchOracle.Mode.Honest);
        kitA.setFlag(id, false);
        kitB.setMode(m);
        assertEq(v4.protocolFeeForPool(key), PACKED_999, "a malformed answer vouched from the last slot");
        kitA.setFlag(id, true);
        assertEq(v4.protocolFeeForPool(key), 0);
    }

    function test_Malformed_Revert() public {
        _assertMalformed(MockLaunchOracle.Mode.Revert);
    }

    /// Revert data that happens to encode `true` is still a revert.
    function test_Malformed_RevertWithTrueData() public {
        _assertMalformed(MockLaunchOracle.Mode.RevertWithTrueData);
    }

    function test_Malformed_NonCanonicalBool() public {
        _assertMalformed(MockLaunchOracle.Mode.ReturnTwo);
    }

    function test_Malformed_LongReturn() public {
        _assertMalformed(MockLaunchOracle.Mode.ReturnLongTrue);
    }

    function test_Malformed_ShortReturn() public {
        _assertMalformed(MockLaunchOracle.Mode.ReturnShort);
    }

    /// 100 kB of return data from every oracle costs V4 nothing: at most 32 bytes are copied each time.
    function test_Malformed_ReturnBombIsNotCopied() public {
        PoolKey memory key = _launchKey();
        kitA.setMode(MockLaunchOracle.Mode.ReturnBomb);
        kitB.setMode(MockLaunchOracle.Mode.ReturnBomb);
        uint256 before = gasleft();
        assertEq(v4.protocolFeeForPool(key), PACKED_999);
        assertLt(before - gasleft(), 240_000, "return data must not be copied into V4's memory");
    }

    /// An oracle that reverts, or burns gas, in front of an honest one that vouches: still zero.
    function test_BrokenOracleBeforeAnHonestOne_StillResolvesToZero() public {
        WastefulLaunchOracle broken = new WastefulLaunchOracle();
        MockLaunchOracle reverting = new MockLaunchOracle();
        MockLaunchOracle honest = new MockLaunchOracle();
        DeepCoreProtocolFeeControllerV4 c = _deploy(_list(address(broken), address(reverting), address(honest)));
        reverting.setMode(MockLaunchOracle.Mode.Revert);

        PoolKey memory launch = _launchKey();
        PoolKey memory normal = _key(3000, address(0), 0);
        _flag(honest, launch);

        for (uint256 m; m <= uint256(WastefulLaunchOracle.Mode.BurnThenRevert); ++m) {
            broken.setMode(WastefulLaunchOracle.Mode(m));
            assertEq(c.protocolFeeForPool(launch), 0, "the honest oracle was silenced");
            assertTrue(c.isLockedLaunchPool(launch.toId()));
            assertEq(c.protocolFeeForPool(normal), PACKED_999, "and a plain pool is still created, and charged");
        }
    }

    /// Four oracles that all burn their whole stipend: pool creation still gets an answer, inside the
    /// bound the header states.
    function test_FourBrokenOracles_CostABoundedAmountAndBlockNothing() public {
        WastefulLaunchOracle[4] memory w = [
            new WastefulLaunchOracle(),
            new WastefulLaunchOracle(),
            new WastefulLaunchOracle(),
            new WastefulLaunchOracle()
        ];
        DeepCoreProtocolFeeControllerV4 c = _deploy(_list(address(w[0]), address(w[1]), address(w[2]), address(w[3])));
        for (uint256 i; i < 4; ++i) {
            w[i].setMode(WastefulLaunchOracle.Mode.BurnAllGas);
        }
        uint256 before = gasleft();
        assertEq(c.protocolFeeForPool(_launchKey()), PACKED_999);
        uint256 used = before - gasleft();
        assertGt(used, 4 * 50_000, "each oracle really was given its stipend");
        assertLt(used, 4 * (50_000 + 2_600) + 40_000, "and nothing beyond it");
    }

    /* =====================================================================
       GAS: the answer is a function of state, never of the caller's gas limit
       ===================================================================== */

    struct Sweep {
        uint256 okCount;
        uint256 floorCount;
        uint256 lateFloorCount;
        uint256 chargedCount;
    }

    function _callWithGas(DeepCoreProtocolFeeControllerV4 c, PoolKey memory key, uint256 g)
        internal
        view
        returns (bool ok, uint24 fee, bytes memory ret)
    {
        bool s;
        (s, ret) = address(c).staticcall{gas: g}(abi.encodeCall(DeepCoreProtocolFeeControllerV4.protocolFeeForPool, (key)));
        if (s && ret.length == 32) return (true, abi.decode(ret, (uint24)), ret);
    }

    /// @dev Scans the caller's gas limit. A floor revert whose caller brought `lateFrom` gas or more
    /// cannot have come from the first oracle call - the first check had passed - so it counts as late.
    function _sweep(DeepCoreProtocolFeeControllerV4 c, PoolKey memory key, uint256 from, uint256 to, uint256 step, uint256 lateFrom)
        internal
        view
        returns (Sweep memory s)
    {
        for (uint256 g = from; g <= to; g += step) {
            (bool ok, uint24 fee, bytes memory ret) = _callWithGas(c, key, g);
            if (ok) {
                s.okCount++;
                if (fee != 0) s.chargedCount++;
            } else if (
                ret.length == 68 && bytes4(ret) == DeepCoreProtocolFeeControllerV4.InsufficientGasForLaunchCheck.selector
            ) {
                s.floorCount++;
                (uint256 available, uint256 required) = _decodeFloor(ret);
                assertLt(available, required, "the floor refused a call that had enough");
                assertEq(required, FLOOR);
                if (g >= lateFrom) s.lateFloorCount++;
            }
        }
    }

    function _decodeFloor(bytes memory ret) internal pure returns (uint256 available, uint256 required) {
        assembly ("memory-safe") {
            available := mload(add(ret, 0x24))
            required := mload(add(ret, 0x44))
        }
    }

    /// The burners must cost enough that EIP-150 could starve them, and still fit the stipend.
    function test_Gas_BurnOraclesAreCalibrated() public {
        kitA.setMode(MockLaunchOracle.Mode.BurnThenTrue);
        uint256 before = gasleft();
        kitA.isLockedLaunch(bytes32(0));
        uint256 used = before - gasleft();
        assertGt(used, 38_000, "burn oracle must be expensive enough to starve");
        assertLt(used, 49_000, "and still fit its stipend");

        WastefulLaunchOracle w = new WastefulLaunchOracle();
        w.setMode(WastefulLaunchOracle.Mode.BurnThenFalse);
        before = gasleft();
        assertFalse(w.isLockedLaunch(bytes32(0)));
        used = before - gasleft();
        assertGt(used, 38_000);
        assertLt(used, 49_000);

        w.setMode(WastefulLaunchOracle.Mode.BurnAllGas);
        before = gasleft();
        (bool ok,) = address(w).staticcall{gas: 50_000}(abi.encodeCall(w.isLockedLaunch, (bytes32(0))));
        used = before - gasleft();
        assertFalse(ok);
        assertGt(used, 50_000, "BurnAllGas takes the whole stipend");
    }

    /// THE test for requirement "the gas floor holds per call". The oracle that vouches is LAST, its
    /// honest answer is expensive, and the oracle in front of it burns its whole stipend. Scan the
    /// caller's gas limit across the whole interesting range: the pool must either revert or come
    /// back zero. It must never come back charged.
    function test_Gas_VouchingOracleLast_BehindABurner_NeverChargedAtAnyGasLimit() public {
        WastefulLaunchOracle burner = new WastefulLaunchOracle();
        MockLaunchOracle kit = new MockLaunchOracle();
        DeepCoreProtocolFeeControllerV4 c = _deploy(_list(address(burner), address(kit)));
        // The constructor probe already ran against the quiet modes; now make both expensive.
        burner.setMode(WastefulLaunchOracle.Mode.BurnAllGas);
        kit.setMode(MockLaunchOracle.Mode.BurnThenTrue);

        Sweep memory s = _sweep(c, _launchKey(), 10_000, 220_000, 150, 85_000);
        assertEq(s.chargedCount, 0, "a locked launch was charged because of the caller's gas limit");
        assertGt(s.okCount, 0, "must succeed with enough gas");
        assertGt(s.floorCount, 0, "the gas floor must be what refuses a starved call");
        assertGt(s.lateFloorCount, 0, "the floor must also guard the SECOND call, not only the first");
    }

    /// The same with the set full: three oracles that waste gas in three different ways, then the one
    /// that vouches, expensively, in the LAST position.
    function test_Gas_FourOracles_VouchingOracleLast_NeverChargedAtAnyGasLimit() public {
        WastefulLaunchOracle w0 = new WastefulLaunchOracle();
        WastefulLaunchOracle w1 = new WastefulLaunchOracle();
        WastefulLaunchOracle w2 = new WastefulLaunchOracle();
        MockLaunchOracle kit = new MockLaunchOracle();
        DeepCoreProtocolFeeControllerV4 c = _deploy(_list(address(w0), address(w1), address(w2), address(kit)));
        w0.setMode(WastefulLaunchOracle.Mode.BurnThenFalse);
        w1.setMode(WastefulLaunchOracle.Mode.BurnAllGas);
        w2.setMode(WastefulLaunchOracle.Mode.BurnThenRevert);
        kit.setMode(MockLaunchOracle.Mode.BurnThenTrue);

        Sweep memory s = _sweep(c, _launchKey(), 10_000, 340_000, 200, 85_000);
        assertEq(s.chargedCount, 0, "a locked launch was charged because of the caller's gas limit");
        assertGt(s.okCount, 0, "must succeed with enough gas");
        assertGt(s.floorCount, 0);
        assertGt(s.lateFloorCount, 0, "the floor must guard the later calls");
    }

    /// An early oracle that ANSWERS (cheaply, "not mine") must not let the later one be skipped.
    function test_Gas_CheapHonestAnswers_VouchingOracleLast_NeverChargedAtAnyGasLimit() public {
        PoolKey memory key = _launchKey();
        _flag(kitB, key);
        Sweep memory s = _sweep(v4, key, 5_000, 140_000, 125, type(uint256).max);
        assertEq(s.chargedCount, 0);
        assertGt(s.okCount, 0);
        assertGt(s.floorCount, 0);
    }

    /// Vouched for by the FIRST oracle: later oracles being expensive or broken is irrelevant.
    function test_Gas_VouchingOracleFirst_NeverChargedAtAnyGasLimit() public {
        PoolKey memory key = _launchKey();
        kitA.setMode(MockLaunchOracle.Mode.BurnThenTrue);
        kitB.setMode(MockLaunchOracle.Mode.Revert);
        Sweep memory s = _sweep(v4, key, 5_000, 140_000, 125, type(uint256).max);
        assertEq(s.chargedCount, 0);
        assertGt(s.okCount, 0);
    }

    /// The other direction: a pool nobody vouches for is never resolved to ZERO by a gas limit
    /// either. Whenever the call returns, it returns the policy's fee.
    function test_Gas_PlainPool_NeverWaivedAtAnyGasLimit() public {
        WastefulLaunchOracle burner = new WastefulLaunchOracle();
        MockLaunchOracle kit = new MockLaunchOracle();
        DeepCoreProtocolFeeControllerV4 c = _deploy(_list(address(burner), address(kit)));
        burner.setMode(WastefulLaunchOracle.Mode.BurnAllGas);

        PoolKey memory key = _key(3000, address(0), 0);
        uint256 okCount;
        for (uint256 g = 10_000; g <= 220_000; g += 150) {
            (bool ok, uint24 fee,) = _callWithGas(c, key, g);
            if (ok) {
                okCount++;
                assertEq(fee, PACKED_999, "a plain pool was waived because of the caller's gas limit");
            }
        }
        assertGt(okCount, 0);
    }

    /// `isLockedLaunchPool` and the owner's setter share the predicate, floor included.
    function test_Gas_ViewSharesTheFloor() public {
        PoolKey memory key = _launchKey();
        _flag(kitB, key);
        bool sawFloor;
        bool sawTrue;
        for (uint256 g = 2_000; g <= 140_000; g += 250) {
            (bool s, bytes memory ret) = address(v4).staticcall{gas: g}(
                abi.encodeCall(DeepCoreProtocolFeeControllerV4.isLockedLaunchPool, (key.toId()))
            );
            if (s) {
                assertTrue(abi.decode(ret, (bool)), "the view said 'not a launch' because of the gas limit");
                sawTrue = true;
            } else if (ret.length >= 4 && bytes4(ret) == DeepCoreProtocolFeeControllerV4.InsufficientGasForLaunchCheck.selector)
            {
                sawFloor = true;
            }
        }
        assertTrue(sawFloor);
        assertTrue(sawTrue);
    }

    /* =====================================================================
       FUZZ: fee resolution
       ===================================================================== */

    function _mode(uint8 raw) internal pure returns (MockLaunchOracle.Mode mode) {
        // Every mode except the burner, whose answer depends on the stipend and is covered above.
        // Nine modes, so the modulus reaches `TrueForEverything`, the last of them.
        mode = MockLaunchOracle.Mode(raw % 9);
        if (mode == MockLaunchOracle.Mode.BurnThenTrue) mode = MockLaunchOracle.Mode.TrueForEverything;
    }

    function _vouched(MockLaunchOracle.Mode mode, bool flag) internal pure returns (bool) {
        return (mode == MockLaunchOracle.Mode.Honest && flag) || mode == MockLaunchOracle.Mode.TrueForEverything;
    }

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
        uint8 flags,
        uint8 modeRawA,
        uint8 modeRawB,
        uint256 salt
    ) public {
        ratio = bound(ratio, 0, 1e6);
        dyn0 = uint16(bound(dyn0, 0, 4000));
        dyn1 = uint16(bound(dyn1, 0, 4000));
        ov0 = uint16(bound(ov0, 0, 4000));
        ov1 = uint16(bound(ov1, 0, 4000));
        bool flagA = flags & 1 != 0;
        bool flagB = flags & 2 != 0;

        PoolKey memory key = _key(lpFee, address(uint160(0x4444 + (salt % 3))), salt % 5);

        vm.startPrank(safe);
        v2.setProtocolFeeSplitRatio(ratio);
        v2.setDynamicFee(dynSet, dyn0, dyn1);
        v2.setPoolFee(key.toId(), overrideSet, ov0, ov1);
        v2.setFeesDisabled(disabled);
        vm.stopPrank();

        if (flagA) _flag(kitA, key);
        if (flagB) _flag(kitB, key);
        kitA.setMode(_mode(modeRawA));
        kitB.setMode(_mode(modeRawB));

        bool vouched = _vouched(_mode(modeRawA), flagA) || _vouched(_mode(modeRawB), flagB);
        uint24 policyFee = v2.protocolFeeForPool(key);
        uint24 expected = vouched ? 0 : policyFee;

        uint24 got = v4.protocolFeeForPool(key);
        assertEq(got, expected);
        assertEq(v4.isLockedLaunchPool(key.toId()), vouched);
        assertLe(got, policyFee, "V4 never charges more than V2");
        assertLe(got & 0xFFF, 4000);
        assertLe(got >> 12, 4000);
    }

    /// The result does not depend on the order of the set: the same two oracles, named either way round.
    function testFuzz_OrderChangesNothing(bool flagA, bool flagB, uint8 modeRawA, uint8 modeRawB, uint256 salt)
        public
    {
        DeepCoreProtocolFeeControllerV4 reversed = _deploy(_list(address(kitB), address(kitA)));
        PoolKey memory key = _key(DYN, address(uint160(0x4444 + (salt % 3))), salt % 5);
        if (flagA) _flag(kitA, key);
        if (flagB) _flag(kitB, key);
        kitA.setMode(_mode(modeRawA));
        kitB.setMode(_mode(modeRawB));

        assertEq(v4.protocolFeeForPool(key), reversed.protocolFeeForPool(key));
        assertEq(v4.isLockedLaunchPool(key.toId()), reversed.isLockedLaunchPool(key.toId()));
    }

    /* =====================================================================
       FORWARDERS AND ACCESS CONTROL
       ===================================================================== */

    function test_Collect_OwnerOnly_AndRefusesZeroRecipient() public {
        manager.setAccrued(usdg, 1000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.collect(address(manager), usdg, 0, stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.collect(address(manager), usdg, 0, guardian);

        /* An oracle is not a role: a kit has no power over the controller. */
        vm.prank(address(kitA));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(kitA)));
        v4.collect(address(manager), usdg, 0, address(kitA));

        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.ZeroRecipient.selector);
        v4.collect(address(manager), usdg, 0, address(0));

        vm.prank(safe);
        assertEq(v4.collect(address(manager), usdg, 400, safe), 400);
        assertEq(manager.protocolFeesAccrued(usdg), 600);
        assertEq(manager.lastRecipient(), safe);
    }

    function test_Sweep_PermissionlessAndUnredirectable() public {
        manager.setAccrued(usdg, 4242);
        vm.prank(stranger);
        assertEq(v4.sweep(address(manager), usdg), 4242);
        assertEq(manager.lastRecipient(), safe);
    }

    function test_Sweep_RevertsWhenEmpty() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NothingToCollect.selector, address(manager), usdg)
        );
        v4.sweep(address(manager), usdg);
    }

    function test_Accrued_ReadsTheManager() public {
        assertEq(v4.accrued(address(manager), usdg), 0);
        manager.setAccrued(usdg, 77);
        assertEq(v4.accrued(address(manager), usdg), 77);
    }

    function test_SetTreasury_OwnerOnly_NeverZero() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.setTreasury(stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.setTreasury(guardian);

        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.ZeroRecipient.selector);
        v4.setTreasury(address(0));

        vm.prank(safe);
        v4.setTreasury(address(0xC0FFEE));
        assertEq(v4.treasury(), address(0xC0FFEE));

        manager.setAccrued(usdg, 5);
        v4.sweep(address(manager), usdg);
        assertEq(manager.lastRecipient(), address(0xC0FFEE));
    }

    function test_SetPoolProtocolFee_OwnerOnly() public {
        PoolKey memory key = _key(3000, address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.setPoolProtocolFee(address(manager), key, 0);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.setPoolProtocolFee(address(manager), key, 0);

        vm.prank(safe);
        v4.setPoolProtocolFee(address(manager), key, 123);
        assertEq(manager.poolProtocolFee(key.toId()), 123);
    }

    function test_SyncPoolToPolicy_OwnerOnly_AndResolvesTheRule() public {
        PoolKey memory launchA = _launchKey();
        PoolKey memory launchB = _key(DYN, address(0x5555), 2);
        PoolKey memory normal = _key(3000, address(0), 0);
        _flag(kitA, launchA);
        _flag(kitB, launchB);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.syncPoolToPolicy(address(manager), launchA);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.syncPoolToPolicy(address(manager), launchA);

        /* Launches left charged by an earlier controller: V2 was installed when they were stamped.
           V4's own setter can no longer produce this state (LockedLaunchPoolKeepsZeroFee). */
        manager.setController(address(v2));
        vm.startPrank(safe);
        v2.setPoolProtocolFee(address(manager), launchA, PACKED_999);
        v2.setPoolProtocolFee(address(manager), launchB, PACKED_999);
        vm.stopPrank();
        assertEq(manager.poolProtocolFee(launchA.toId()), PACKED_999);
        assertEq(manager.poolProtocolFee(launchB.toId()), PACKED_999);

        manager.setController(address(v4));
        vm.startPrank(safe);
        assertEq(v4.syncPoolToPolicy(address(manager), launchA), 0);
        assertEq(v4.syncPoolToPolicy(address(manager), launchB), 0);
        assertEq(v4.syncPoolToPolicy(address(manager), normal), PACKED_999);
        vm.stopPrank();
        assertEq(manager.poolProtocolFee(launchA.toId()), 0);
        assertEq(manager.poolProtocolFee(launchB.toId()), 0);
        assertEq(manager.poolProtocolFee(normal.toId()), PACKED_999);
    }

    function test_TransferOwnership_TwoStep_OwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.transferOwnership(stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.transferOwnership(guardian);

        address next = makeAddr("nextSafe");
        vm.prank(safe);
        v4.transferOwnership(next);
        assertEq(v4.owner(), safe, "nomination alone moves nothing");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.acceptOwnership();

        vm.prank(next);
        v4.acceptOwnership();
        assertEq(v4.owner(), next);

        /* A new owner inherits the powers and not one more: the set did not move with the key. */
        address[] memory got = v4.launchOracles();
        assertEq(got.length, 2);
        assertEq(got[0], address(kitA));
        assertEq(got[1], address(kitB));
    }

    function test_RenounceOwnership_Reverts() public {
        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.RenounceDisabled.selector);
        v4.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.RenounceDisabled.selector);
        v4.renounceOwnership();
        assertEq(v4.owner(), safe);
    }

    /// The guardian's only power is V2's: it disables fees, which only ever lowers V4's answers.
    function test_Guardian_OnlyReduces() public {
        PoolKey memory normal = _key(3000, address(0), 0);
        assertEq(v4.protocolFeeForPool(normal), PACKED_999);

        vm.prank(guardian);
        v2.emergencyDisableFees();
        assertEq(v4.protocolFeeForPool(normal), 0);

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
        _flag(kitA, launch);
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launch.toId())
        );
        v4.setPoolProtocolFee(address(manager), launch, 999);
        /* Zero is always allowed: it is the rule itself. */
        vm.prank(safe);
        v4.setPoolProtocolFee(address(manager), launch, 0);
        assertEq(manager.poolProtocolFee(launch.toId()), 0);
        /* A normal pool is unaffected. */
        PoolKey memory normal = _key(3000, address(0), 0);
        vm.prank(safe);
        v4.setPoolProtocolFee(address(manager), normal, 999);
        assertEq(manager.poolProtocolFee(normal.toId()), 999);
    }

    /// Finding B, for the reason V4 exists: the refusal holds for a pool vouched for from EVERY
    /// position of the set, the first kit's and the newest kit's alike.
    function test_FIX_SetPoolProtocolFee_RefusesOnAPoolVouchedForByEachPosition() public {
        MockLaunchOracle[4] memory kits =
            [new MockLaunchOracle(), new MockLaunchOracle(), new MockLaunchOracle(), new MockLaunchOracle()];
        DeepCoreProtocolFeeControllerV4 c =
            _deploy(_list(address(kits[0]), address(kits[1]), address(kits[2]), address(kits[3])));
        MockProtocolFees m = new MockProtocolFees(address(c));

        for (uint256 at; at < 4; ++at) {
            PoolKey memory launch = _key(DYN, address(0x4444), 200 + at);
            _flag(kits[at], launch);

            vm.prank(safe);
            vm.expectRevert(
                abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launch.toId())
            );
            c.setPoolProtocolFee(address(m), launch, PACKED_999);

            vm.prank(safe);
            vm.expectRevert(
                abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launch.toId())
            );
            c.setPoolProtocolFee(address(m), launch, 1);
            assertEq(m.poolProtocolFee(launch.toId()), 0, "nothing was stamped");

            vm.prank(safe);
            c.setPoolProtocolFee(address(m), launch, 0);
            assertEq(m.poolProtocolFee(launch.toId()), 0);
        }
    }

    /// The refusal survives a broken oracle in front of the one that vouches.
    function test_FIX_SetPoolProtocolFee_RefusesBehindABrokenOracle() public {
        WastefulLaunchOracle broken = new WastefulLaunchOracle();
        MockLaunchOracle honest = new MockLaunchOracle();
        DeepCoreProtocolFeeControllerV4 c = _deploy(_list(address(broken), address(honest)));
        MockProtocolFees m = new MockProtocolFees(address(c));
        broken.setMode(WastefulLaunchOracle.Mode.BurnAllGas);

        PoolKey memory launch = _launchKey();
        _flag(honest, launch);
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launch.toId())
        );
        c.setPoolProtocolFee(address(m), launch, PACKED_999);
    }

    /// Finding A: a misdirected ERC-20 has a path out, owner only, and only when there is something.
    function test_FIX_RescueERC20_OwnerOnly_NothingToRescue_HappyPath() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.NothingToRescue.selector, address(stray)));
        v4.rescueERC20(address(stray), safe);

        stray.mint(address(v4), 7e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        v4.rescueERC20(address(stray), stranger);
        vm.prank(safe);
        vm.expectRevert(DeepCoreProtocolFeeControllerV4.RescueToZero.selector);
        v4.rescueERC20(address(stray), address(0));

        vm.prank(safe);
        v4.rescueERC20(address(stray), address(0xBEEF));
        assertEq(stray.balanceOf(address(0xBEEF)), 7e18);
        assertEq(stray.balanceOf(address(v4)), 0);
    }
}
