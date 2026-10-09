// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../../src/DeepCoreBinLPLocker.sol";
import {IDeepCoreLPLocker, Lock} from "../../src/interfaces/IDeepCoreLPLocker.sol";
import {IDeepCoreBinLPLocker} from "../../src/interfaces/IDeepCoreBinLPLocker.sol";
import {LaunchTaxModule} from "deepcore-hooks/src/launch/LaunchTaxModule.sol";
import {BinLaunchShapes} from "../../src/libraries/BinLaunchShapes.sol";
import {
    ILaunchpadKitV2,
    LegKind,
    BinShape,
    LegParams,
    LaunchParamsV2,
    LaunchResultV2
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev Answers every view the kit's constructor checks exactly like the real CL locker, accepts the NFT, and
/// records NOTHING. The kit's post-lock assertion is the only thing standing between this and a flagged,
/// unlocked pool.
contract LyingCLLocker is IERC721Receiver {
    DeepCoreLPLocker internal immutable real;

    constructor(DeepCoreLPLocker real_) {
        real = real_;
    }

    function positionManager() external view returns (ICLPositionManager) {
        return real.positionManager();
    }

    function protocolRecipient() external view returns (address) {
        return real.protocolRecipient();
    }

    function minProtocolBps() external view returns (uint16) {
        return real.minProtocolBps();
    }

    function maxProtocolBps() external view returns (uint16) {
        return real.maxProtocolBps();
    }

    function maxIntegratorBps() external view returns (uint16) {
        return real.maxIntegratorBps();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function getLock(uint256) external pure returns (Lock memory lk) {}

    function isLocked(uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev A quote token that tries to re-enter the kit from every mutating ERC-20 entry point. A single-sided
/// launch never calls any of them, which is itself the property under test (`attempts == 0`).
contract ReenteringQuote is MockERC20 {
    LaunchpadKitV2 public kit;
    uint256 public attempts;
    bytes public lastRevert;

    constructor() MockERC20("Evil", "EVIL", 18) {}

    function arm(LaunchpadKitV2 kit_) external {
        kit = kit_;
    }

    function _reenter() internal {
        if (address(kit) == address(0)) return;
        ++attempts;
        try kit.flushProtocolFees() {} catch (bytes memory data) {
            lastRevert = data;
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transferFrom(from, to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _reenter();
        return super.approve(spender, amount);
    }
}

/// @dev A launcher contract that re-enters the kit when its refund arrives.
contract ReenteringLauncher {
    LaunchpadKitV2 public immutable kit;
    bytes public createRevert;
    bytes public claimRevert;
    bool public reentered;
    bytes internal stored;

    constructor(LaunchpadKitV2 kit_) {
        kit = kit_;
    }

    function launch(LaunchParamsV2 calldata p, uint256 value) external {
        stored = abi.encode(p);
        kit.createLaunch{value: value}(p);
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        try kit.createLaunch(abi.decode(stored, (LaunchParamsV2))) {} catch (bytes memory data) {
            createRevert = data;
        }
        try kit.claimFees(address(this)) {} catch (bytes memory data) {
            claimRevert = data;
        }
    }
}

/// @notice Squatting, the V3 oracle, atomicity, reentrancy, Bin shape rules, and constructor validation.
contract LaunchpadKitV2SecurityTest is KitV2Fixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployAll();
    }

    /*//////////////////////////////////////////////////////////////
                                SQUATTING
    //////////////////////////////////////////////////////////////*/

    /// @dev The Kit 1 attack: through a kit that forgets to fold the launcher in, one launcher lands on
    /// another's mined address. Here the same user salt gives different addresses per launcher.
    function test_SQUAT_launcherFoldedIntoTheSalt() public {
        bytes32 salt = keccak256("vanity");
        address mine = kit.predictLaunchToken(LAUNCHER, salt);
        address theirs = kit.predictLaunchToken(ATTACKER, salt);
        assertTrue(mine != theirs);
        assertEq(mine, factory.predictTokenAddress(address(kit), keccak256(abi.encode(LAUNCHER, salt))));

        // The attacker copies the launcher's exact params and goes first: they get THEIR address, not mine.
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        p.legs[0] = _clLeg(theirs, address(quote), 10_000);
        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        LaunchResultV2 memory r = kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);
        assertEq(r.token, theirs);
        assertEq(mine.code.length, 0, "the launcher's address is still free");

        // And the launcher's own launch still goes through.
        LaunchResultV2 memory r2 = _launch(_oneCL(salt, address(quote)));
        assertEq(r2.token, mine);
    }

    /// @dev Direct factory use cannot take the kit's address either: the factory folds ITS caller in.
    function test_SQUAT_directFactoryCallLandsElsewhere() public {
        bytes32 salt = keccak256("direct");
        address predicted = _token(salt);
        vm.prank(ATTACKER);
        address a = factory.createToken("X", "X", "", 1, ATTACKER, keccak256(abi.encode(LAUNCHER, salt)));
        assertTrue(a != predicted);
        _launch(_oneCL(salt, address(quote)));
    }

    /// @dev Before the launch transaction the token has no code, so no guard accepts a claim on its pools.
    function test_SQUAT_predictedPoolsCannotBeClaimedBeforeTheLaunch() public {
        bytes32 salt = keccak256("front-run");
        LaunchParamsV2 memory p = _clAndBin(salt, address(quote));
        address token = _token(salt);
        (PoolKey memory clKey,,) = kit.computeLegKey(token, p.legs[0]);
        (PoolKey memory binKey,,) = kit.computeLegKey(token, p.legs[1]);

        LaunchGuardHook.LaunchConfig memory c = LaunchGuardHook.LaunchConfig(uint40(block.timestamp + 10), 60, 1, 1, 0, true, true);
        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.CurrencyHasNoCode.selector, token));
        clHook.configureLaunch(clKey, c);
        BinLaunchGuardHook.LaunchConfig memory bc = BinLaunchGuardHook.LaunchConfig(uint40(block.timestamp + 10), 60, 1, 1, 0, true, true);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.CurrencyHasNoCode.selector, token));
        binHook.configureLaunch(binKey, bc);
        vm.stopPrank();

        _launch(p);
    }

    /// @dev After the launch, the token is a factory token whose creator is the kit: nobody else can open
    /// another guarded pool for it on either hook (the CL reservation, and the Bin port closing the open LOW).
    function test_SQUAT_afterLaunchSiblingPoolsAreReservedOnBothGuards() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("siblings"), address(quote));
        LaunchResultV2 memory r = _launch(p);
        MockERC20 other = new MockERC20("Other", "OTH", 18);

        LegParams memory clSibling = _clLeg(r.token, address(other), 10_000);
        (PoolKey memory clKey,,) = kit.computeLegKey(r.token, clSibling);
        LegParams memory binSibling = _binLeg(address(other), 10_000, BinShape.Flat, 4);
        (PoolKey memory binKey,,) = kit.computeLegKey(r.token, binSibling);

        vm.startPrank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchPoolReserved.selector, r.token, address(kit), ATTACKER));
        clHook.configureLaunch(clKey, LaunchGuardHook.LaunchConfig(uint40(block.timestamp + 10), 60, 1, 1, 0, true, true));
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchPoolReserved.selector, r.token, address(kit), ATTACKER));
        binHook.configureLaunch(binKey, BinLaunchGuardHook.LaunchConfig(uint40(block.timestamp + 10), 60, 1, 1, 0, true, true));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              V3 ORACLE
    //////////////////////////////////////////////////////////////*/

    function test_ORACLE_flagOnlyForKitLegs() public {
        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("oracle"), address(quote)));
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
        assertTrue(kit.isLockedLaunch(r.poolIds[1]));
        assertFalse(kit.isLockedLaunch(bytes32(0)), "V3's constructor probe answer");
        assertFalse(kit.isLockedLaunch(keccak256("anything")));
        // A pool of the launch token that the kit did NOT create: no hook, static fee. Pays the core fee.
        PoolKey memory plain = PoolKey({
            currency0: Currency.wrap(uint160(r.token) < uint160(address(quote)) ? r.token : address(quote)),
            currency1: Currency.wrap(uint160(r.token) < uint160(address(quote)) ? address(quote) : r.token),
            hooks: IHooks(address(0)),
            poolManager: clPM,
            fee: 3_000,
            parameters: bytes32(uint256(uint24(TICK_SPACING)) << 16)
        });
        vm.prank(ATTACKER);
        clPM.initialize(plain, SQRT_1_1);
        assertFalse(kit.isLockedLaunch(PoolId.unwrap(plain.toId())));
        assertGt(_clProtocolFee(PoolId.unwrap(plain.toId())), 0, "not a locked launch: core fee applies");
    }

    /// @dev The same kit-shaped key on a non-factory token, claimed and initialized by a stranger straight on
    /// both guards: V3 asks the kit, the kit says no, V2's 999 applies.
    function test_ORACLE_spoofThroughTheGuardsDirectlyPaysTheFee() public {
        MockERC20 fake = new MockERC20("Fake", "FAKE", 18);
        LegParams memory clLeg = _clLeg(address(fake), address(quote), 10_000);
        (PoolKey memory clKey,,) = kit.computeLegKey(address(fake), clLeg);
        LegParams memory binLeg = _binLeg(address(quote), 10_000, BinShape.Flat, 4);
        (PoolKey memory binKey,,) = kit.computeLegKey(address(fake), binLeg);

        vm.startPrank(ATTACKER);
        clHook.configureLaunch(clKey, LaunchGuardHook.LaunchConfig(uint40(block.timestamp + 10), 60, 1, 1, 0, true, true));
        clHook.configureFeeSplit(clKey, LaunchTaxModule.FeeSplit(ATTACKER, 8_000, 2_000, 0, address(0)));
        clPM.initialize(clKey, SQRT_1_1);
        binHook.configureLaunch(binKey, BinLaunchGuardHook.LaunchConfig(uint40(block.timestamp + 10), 60, 1, 1, 0, true, true));
        binHook.configureFeeSplit(binKey, LaunchTaxModule.FeeSplit(ATTACKER, 8_000, 2_000, 0, address(0)));
        binPM.initialize(binKey, ACTIVE_ID);
        vm.stopPrank();

        assertEq(_clProtocolFee(PoolId.unwrap(clKey.toId())), PACKED_999);
        assertEq(_binProtocolFee(PoolId.unwrap(binKey.toId())), PACKED_999);
        assertFalse(kit.isLockedLaunch(PoolId.unwrap(clKey.toId())));
    }

    /*//////////////////////////////////////////////////////////////
                               ATOMICITY
    //////////////////////////////////////////////////////////////*/

    /// @dev A split no contract will take (integrator share above the cap) reverts EVERYTHING: no token, no
    /// pool, no flag, no fee credit. The guard and the locker carry the same cap and the guard is written
    /// first, so since 2026-09-28 the refusal is the guard's; a locker that refuses on its own is
    /// `test_ATOMIC_lockerThatRecordsNothingRevertsTheLaunch`.
    function test_ATOMIC_lockFailureRevertsTheWholeLaunch() public {
        bytes32 salt = keccak256("atomic");
        LaunchParamsV2 memory p = _clAndBin(salt, address(quote));
        p.integratorBps = 2_001;
        p.creatorBps = 5_999;
        address token = _token(salt);
        (PoolKey memory clKey, bytes32 clId,) = kit.computeLegKey(token, p.legs[0]);
        (, bytes32 binId,) = kit.computeLegKey(token, p.legs[1]);

        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxIntegratorShareTooHigh.selector, uint16(2_001)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);

        assertEq(token.code.length, 0, "no token");
        assertFalse(kit.isLockedLaunch(clId), "no CL flag");
        assertFalse(kit.isLockedLaunch(binId), "no Bin flag");
        (uint160 sqrtPrice,,,) = clPM.getSlot0(clKey.toId());
        assertEq(sqrtPrice, 0, "no pool");
        assertEq(kit.totalFeesOwed(), 0, "no fee credit");
        assertEq(kit.legsOf(token).length, 0);
    }

    /// @dev The Bin leg failing in core (bin step above the manager's max) AFTER the CL leg has been
    /// initialized, seeded and locked still reverts the CL leg, its lock, its flag and the token.
    function test_ATOMIC_secondLegFailureRevertsTheFirst() public {
        bytes32 salt = keccak256("atomic-2");
        LaunchParamsV2 memory p = _clAndBin(salt, address(quote));
        p.legs[1].bin.binStep = 101;
        address token = _token(salt);
        (PoolKey memory clKey, bytes32 clId,) = kit.computeLegKey(token, p.legs[0]);

        vm.expectRevert();
        this.launchAs(p, INITIAL_LAUNCH_FEE);

        assertFalse(kit.isLockedLaunch(clId));
        assertEq(token.code.length, 0);
        (uint160 sqrtPrice,,,) = clPM.getSlot0(clKey.toId());
        assertEq(sqrtPrice, 0, "the CL pool is gone too");
        assertEq(clLocker.lockCount(), 0, "and its lock");
    }

    /// @dev MUTATION-CHECKED: deleting the post-lock assertion in `LaunchLegs._openCL` makes this launch
    /// succeed with a flagged pool whose position nobody recorded.
    function test_ATOMIC_lockerThatRecordsNothingRevertsTheLaunch() public {
        LyingCLLocker liar = new LyingCLLocker(clLocker);
        LaunchpadKitV2.Deployment memory d = _deployment();
        d.clLocker = DeepCoreLPLocker(payable(address(liar)));
        LaunchpadKitV2 liarKit = new LaunchpadKitV2(d);

        bytes32 salt = keccak256("liar");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        address token = liarKit.predictLaunchToken(LAUNCHER, salt);
        p.legs[0] = _clLeg(token, address(quote), 10_000);
        (, bytes32 id,) = liarKit.computeLegKey(token, p.legs[0]);

        vm.deal(LAUNCHER, 1 ether);
        vm.prank(LAUNCHER);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LockNotRecorded.selector, uint256(0), uint256(1)));
        liarKit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);
        assertFalse(liarKit.isLockedLaunch(id));
    }

    function launchAs(LaunchParamsV2 memory p, uint256 value) external {
        vm.deal(LAUNCHER, LAUNCHER.balance + value);
        vm.prank(LAUNCHER);
        kit.createLaunch{value: value}(p);
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_REENTRANCY_maliciousQuoteIsNeverCalledByALaunch() public {
        ReenteringQuote evil = new ReenteringQuote();
        evil.arm(kit);
        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("evil"), address(evil)));
        assertEq(evil.attempts(), 0, "a single-sided launch never touches the quote");
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
        assertTrue(kit.isLockedLaunch(r.poolIds[1]));
        assertEq(_clProtocolFee(r.poolIds[0]), 0);
    }

    /// @dev Where the quote IS called - trading - its re-entry reaches a kit that is not mid-call, and every
    /// kit entry point it can reach is either guarded or pays only fixed recipients.
    function test_REENTRANCY_maliciousQuoteDuringTradingCannotMoveKitFunds() public {
        ReenteringQuote evil = new ReenteringQuote();
        evil.mint(address(this), 1e30);
        evil.approve(address(clRouter), type(uint256).max);
        LaunchParamsV2 memory p = _oneCL(keccak256("evil-trade"), address(evil));
        LaunchResultV2 memory r = _launch(p);
        evil.arm(kit);
        uint256 owed = kit.totalFeesOwed();
        vm.warp(block.timestamp + 120);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 1 ether);
        assertGt(evil.attempts(), 0);
        // `flushProtocolFees` could only ever pay the Safe.
        assertEq(kit.totalFeesOwed() + (safe.balance), owed);
    }

    function test_REENTRANCY_refundReceiverCannotReenter() public {
        ReenteringLauncher attacker = new ReenteringLauncher(kit);
        vm.deal(address(attacker), 10 ether);
        bytes32 salt = keccak256("reenter");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        p.legs[0] = _clLeg(kit.predictLaunchToken(address(attacker), salt), address(quote), 10_000);
        vm.deal(address(this), 10 ether);
        attacker.launch(p, 1 ether);
        assertTrue(attacker.reentered());
        assertEq(bytes4(attacker.createRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(bytes4(attacker.claimRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    /*//////////////////////////////////////////////////////////////
                           INVALID BIN SHAPES
    //////////////////////////////////////////////////////////////*/

    function _customBin(uint24[] memory offsets, uint64[] memory weights, uint16 floorBins)
        internal
        view
        returns (LaunchParamsV2 memory p)
    {
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _binLeg(address(quote), 10_000, BinShape.Custom, 0);
        legs[0].bin.offsets = offsets;
        legs[0].bin.weights = weights;
        legs[0].bin.floorBins = floorBins;
        p = _params(keccak256(abi.encode("shape", offsets, weights, floorBins)), legs);
    }

    function _u24(uint24 a, uint24 b, uint24 c) internal pure returns (uint24[] memory x) {
        x = new uint24[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _u64(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory x) {
        x = new uint64[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    uint64 constant THIRD = 333_333_333_333_333_333;
    uint64 constant LAST = 333_333_333_333_333_334;

    function test_SHAPE_validCustomPasses() public {
        _launch(_customBin(_u24(1, 2, 3), _u64(THIRD, THIRD, LAST), 3));
    }

    function test_SHAPE_R1_offsetZeroIsNotSingleSided() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeNotSingleSided.selector, uint256(0)));
        this.launchAs(_customBin(_u24(0, 1, 2), _u64(THIRD, THIRD, LAST), 1), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R2_nonMonotonic() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeNotMonotonic.selector, uint256(2)));
        this.launchAs(_customBin(_u24(1, 3, 3), _u64(THIRD, THIRD, LAST), 1), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R3_gapBelowTheFloor() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeGapBelowFloor.selector, uint256(1)));
        this.launchAs(_customBin(_u24(1, 3, 4), _u64(THIRD, THIRD, LAST), 2), INITIAL_LAUNCH_FEE);
        // The same gap ABOVE a declared floor of 1 is a stepped shape, and allowed.
        _launch(_customBin(_u24(1, 3, 4), _u64(THIRD, THIRD, LAST), 1));
    }

    function test_SHAPE_R3_firstBinMustTouchTheActiveBin() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeGapBelowFloor.selector, uint256(0)));
        this.launchAs(_customBin(_u24(2, 3, 4), _u64(THIRD, THIRD, LAST), 1), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R3_floorOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeInvalidFloor.selector, uint256(0), uint256(3)));
        this.launchAs(_customBin(_u24(1, 2, 3), _u64(THIRD, THIRD, LAST), 0), INITIAL_LAUNCH_FEE);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeInvalidFloor.selector, uint256(4), uint256(3)));
        this.launchAs(_customBin(_u24(1, 2, 3), _u64(THIRD, THIRD, LAST), 4), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R4_binCountCap() public {
        uint256 n = MAX_BINS_PER_LEG + 1;
        uint24[] memory offsets = new uint24[](n);
        uint64[] memory weights = new uint64[](n);
        for (uint256 k; k < n; ++k) {
            offsets[k] = uint24(k + 1);
            weights[k] = uint64(1e18 / n);
        }
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeBadCount.selector, n, uint256(MAX_BINS_PER_LEG)));
        this.launchAs(_customBin(offsets, weights, 1), INITIAL_LAUNCH_FEE);

        // Named shapes obey the same cap.
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _binLeg(address(quote), 10_000, BinShape.Linear, uint16(n));
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeBadCount.selector, n, uint256(MAX_BINS_PER_LEG)));
        this.launchAs(_params(keccak256("named-cap"), legs), INITIAL_LAUNCH_FEE);

        // And the kit's cap can never exceed the locker's (constructor).
        LaunchpadKitV2.Deployment memory d = _deployment();
        d.maxBinsPerLeg = binLocker.maxBinsPerLock() + 1;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidBinCap.selector, d.maxBinsPerLeg));
        new LaunchpadKitV2(d);
    }

    function test_SHAPE_R4_lengthMismatch() public {
        uint64[] memory two = new uint64[](2);
        two[0] = 5e17;
        two[1] = 5e17;
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeLengthMismatch.selector, uint256(3), uint256(2)));
        this.launchAs(_customBin(_u24(1, 2, 3), two, 1), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R5_weightsMustSumExactly() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeWeightsDoNotSum.selector, uint256(1e18 - 1)));
        this.launchAs(_customBin(_u24(1, 2, 3), _u64(THIRD, THIRD, THIRD), 1), INITIAL_LAUNCH_FEE);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeWeightsDoNotSum.selector, uint256(1e18 + 1)));
        this.launchAs(_customBin(_u24(1, 2, 3), _u64(THIRD, LAST, LAST), 1), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R6_zeroWeight() public {
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeZeroWeight.selector, uint256(1)));
        this.launchAs(_customBin(_u24(1, 2, 3), _u64(5e17, 0, 5e17), 1), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_R6_dustBin() public {
        LaunchParamsV2 memory p = _customBin(_u24(1, 2, 3), _u64(1e18 - 2, 1, 1), 1);
        p.seedSupply = 1e17; // 1e17 * 1 / 1e18 == 0 launch-token units in bin 1
        p.totalSupply = 1e17;
        p.allocationRecipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchShapes.BinShapeDustBin.selector, uint256(1)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_idRangeBelowActive() public {
        bytes32 salt;
        for (uint256 k;; ++k) {
            salt = keccak256(abi.encode("below", k));
            if (uint160(_token(salt)) > uint160(address(quote))) break;
        }
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _binLeg(address(quote), 10_000, BinShape.Flat, 4);
        legs[0].bin.activeId = 3;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.BinIdOutOfRange.selector, uint256(0), uint24(3), uint24(3)));
        this.launchAs(_params(salt, legs), INITIAL_LAUNCH_FEE);
    }

    function test_SHAPE_fiftyPercentPresetRefusedOnBin() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("stealth-bin"), address(quote));
        p.schedule.preset = Preset.Stealth;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.PresetUnavailableOnBin.selector, Preset.Stealth));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                           LAUNCH-SHAPE CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_CHECK_legCountWeightsSupplyQuotes() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("checks"), address(quote));
        LegParams[] memory legs = p.legs;

        p.legs = new LegParams[](0);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidLegCount.selector, uint256(0), MAX_LEGS));
        this.launchAs(p, INITIAL_LAUNCH_FEE);

        p.legs = legs;
        p.legs[1].weightBps = 3_999;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LegWeightsDoNotSum.selector, uint256(9_999)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
        p.legs[1].weightBps = 4_000;

        p.seedSupply = TOTAL_SUPPLY + 1;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidSeedSupply.selector, TOTAL_SUPPLY + 1, TOTAL_SUPPLY));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
        p.seedSupply = SEED_SUPPLY;

        p.allocationRecipient = address(0);
        vm.expectRevert(ILaunchpadKitV2.AllocationRecipientRequired.selector);
        this.launchAs(p, INITIAL_LAUNCH_FEE);
        p.allocationRecipient = ALLOCATION;

        p.legs[1].quote = address(0xC0DE1E55);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.QuoteHasNoCode.selector, address(0xC0DE1E55)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);

        p.legs[1].quote = _token(keccak256("checks"));
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.QuoteIsLaunchToken.selector, p.legs[1].quote));
        this.launchAs(p, INITIAL_LAUNCH_FEE);

        // Two legs resolving to the same pool id.
        p.legs[1] = p.legs[0];
        p.legs[0].weightBps = 5_000;
        p.legs[1].weightBps = 5_000;
        (, bytes32 dup,) = kit.computeLegKey(_token(keccak256("checks")), p.legs[0]);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.DuplicateLegPool.selector, dup));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
    }

    function test_CHECK_theKitCannotBeARecipient() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("self"), address(quote));
        p.creator = address(kit);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidRecipient.selector, address(kit)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
        p.creator = CREATOR;
        p.integrator = address(kit);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidRecipient.selector, address(kit)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
        p.integrator = INTEGRATOR;
        p.allocationRecipient = address(kit);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidRecipient.selector, address(kit)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
    }

    function test_CHECK_clRangeMustBeSingleSidedAgainstCoresTick() public {
        bytes32 salt = keccak256("two-sided");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        bool is0 = uint160(_token(salt)) < uint160(address(quote));
        // Straddle tick 0, which the pool opens at.
        p.legs[0].cl.tickLower = is0 ? int24(0) : int24(-600);
        p.legs[0].cl.tickUpper = is0 ? int24(600) : int24(60);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILaunchpadKitV2.RangeNotSingleSided.selector, uint256(0), p.legs[0].cl.tickLower, p.legs[0].cl.tickUpper, int24(0)
            )
        );
        this.launchAs(p, INITIAL_LAUNCH_FEE);
    }

    function test_CHECK_presetRequiringMaxBuy() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("aggressive"), address(quote));
        p.schedule.preset = Preset.AntiSniperAggressive;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.MaxBuyRequiredByPreset.selector, Preset.AntiSniperAggressive));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
        p.legs[0].maxBuyPerTx = 1 ether;
        _launch(p);
    }

    function test_CHECK_startDelayCap() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("delay"), address(quote));
        p.schedule.startDelaySeconds = 30 days + 1;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.StartDelayTooLong.selector, uint32(30 days + 1)));
        this.launchAs(p, INITIAL_LAUNCH_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_CTOR_rejectsMiswiring() public {
        LaunchpadKitV2.Deployment memory d;

        d = _deployment();
        d.maxLegs = 0;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidLegCap.selector, uint8(0)));
        new LaunchpadKitV2(d);

        d = _deployment();
        d.maxLegs = 9;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidLegCap.selector, uint8(9)));
        new LaunchpadKitV2(d);

        d = _deployment();
        d.launchFeeNoticeSeconds = 1 days - 1;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InvalidNotice.selector, uint32(1 days - 1)));
        new LaunchpadKitV2(d);

        d = _deployment();
        d.initialLaunchFeeWei = MAX_LAUNCH_FEE + 1;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LaunchFeeAboveCap.selector, MAX_LAUNCH_FEE + 1, MAX_LAUNCH_FEE));
        new LaunchpadKitV2(d);

        d = _deployment();
        d.protocolFeeRecipient = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LockerMismatch.selector, address(binLocker)));
        new LaunchpadKitV2(d);

        // A CL guard with no factory would let anybody squat launch pools: refused.
        d = _deployment();
        d.clHook = new LaunchGuardHook(ICLPoolManager(address(clPM)), ILaunchTokenOrigin(address(0)), safe, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.HookFactoryMismatch.selector, address(d.clHook), address(factory))
        );
        new LaunchpadKitV2(d);

        // Hooks swapped between managers.
        d = _deployment();
        d.clHook = LaunchGuardHook(payable(address(binHook)));
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.HookPoolManagerMismatch.selector, address(clPM), address(binPM))
        );
        new LaunchpadKitV2(d);

        // A locker floor below the owner's 20%.
        d = _deployment();
        DeepCoreLPLocker lowCl = new DeepCoreLPLocker(clPosm, safe, 1_000, 5_000, 2_000);
        DeepCoreBinLPLocker lowBin = new DeepCoreBinLPLocker(binPosm, safe, 1_000, 5_000, 2_000, 64);
        d.clLocker = lowCl;
        d.binLocker = lowBin;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LockerFloorTooLow.selector, address(lowCl), uint16(1_000)));
        new LaunchpadKitV2(d);

        d = _deployment();
        d.owner = address(0);
        vm.expectRevert();
        new LaunchpadKitV2(d);
    }

    function test_CTOR_binLockerApprovalIsTheOnlyStandingApproval() public view {
        assertTrue(binPosm.isApprovedForAll(address(kit), address(binLocker)));
        assertEq(IERC20(address(quote)).allowance(address(kit), address(permit2)), 0);
    }
}
