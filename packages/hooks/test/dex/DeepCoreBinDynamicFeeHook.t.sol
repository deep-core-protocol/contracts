// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {BinTestHelper} from "infinity-core/test/pool-bin/helpers/BinTestHelper.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";

import {DeepCoreBinDynamicFeeHook} from "../../src/dex/DeepCoreBinDynamicFeeHook.sol";

/// @dev Two swaps inside ONE external call, so transient storage spans both.
contract TwoBinSwaps {
    BinSwapHelper internal immutable helper;

    constructor(BinSwapHelper helper_, MockERC20 x, MockERC20 y) {
        helper = helper_;
        x.approve(address(helper_), type(uint256).max);
        y.approve(address(helper_), type(uint256).max);
    }

    function run(PoolKey calldata a, PoolKey calldata b) external {
        helper.swap(a, true, -1 ether, BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}), "");
        helper.swap(b, true, -1 ether, BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}), "");
    }
}

contract DeepCoreBinDynamicFeeHookTest is BinTestHelper {
    using CurrencyLibrary for Currency;
    using BinPoolParametersHelper for bytes32;
    using PackedUint128Math for bytes32;

    address internal constant SAFE = address(0x5AFE);
    address internal constant RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TUNER = address(0x7E7E);
    address internal constant STRANGER = address(0xBAD);

    uint24 internal constant FEE_CAP = 50_000;
    uint16 internal constant SHARE = 1_500;
    uint16 internal constant MAX_SHARE = 3_000;
    uint32 internal constant NOTICE = 7 days;
    uint24 internal constant MAX_MOVE = 500;
    uint24 internal constant ACTIVE_ID = 2 ** 23;
    uint16 internal constant BIN_STEP = 10; // 10 bps per bin
    uint256 internal constant T0 = 1_800_000_000;
    /// @dev A swap small enough to stay inside the active bin (1 wei yields no output on Bin; core refuses it).
    int128 internal constant POKE = -1e12;

    Vault internal vault;
    BinPoolManager internal manager;
    BinSwapHelper internal swapHelper;
    BinLiquidityHelper internal liquidityHelper;
    DeepCoreBinDynamicFeeHook internal hook;
    MockERC20 internal tx0;
    MockERC20 internal tx1;
    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        vm.warp(T0);
        vault = new Vault();
        manager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(manager));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (tx0, tx1) = address(a) < address(b) ? (a, b) : (b, a);
        c0 = Currency.wrap(address(tx0));
        c1 = Currency.wrap(address(tx1));
        tx0.mint(address(this), 1e30);
        tx1.mint(address(this), 1e30);
        swapHelper = new BinSwapHelper(manager, vault);
        liquidityHelper = new BinLiquidityHelper(manager, vault);
        tx0.approve(address(swapHelper), type(uint256).max);
        tx1.approve(address(swapHelper), type(uint256).max);
        tx0.approve(address(liquidityHelper), type(uint256).max);
        tx1.approve(address(liquidityHelper), type(uint256).max);
        hook = new DeepCoreBinDynamicFeeHook(manager, IVault(address(vault)), SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
        (key, id) = _open(_cfg(), BIN_STEP);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _cfg() internal pure returns (DeepCoreBinDynamicFeeHook.FeeConfig memory c) {
        c.baseFee = 3_000;
        c.volSlope = 10;
        c.sameSecondSlope = 50;
        c.minBaseFee = 500;
        c.maxBaseFee = 10_000;
        c.maxVolSlope = 40;
        c.maxSameSecondSlope = 100;
        c.maxFee = 30_000;
        c.volCap = 2_000;
        c.decaySeconds = 1_800;
        c.deadband = 25; // 2 bins of 10 bps are inside it; 3 are not
        c.maxBaseFeeStep = 500;
        c.maxSlopeStep = 5;
        c.minTuneInterval = 3_600;
    }

    function _key(uint16 binStep) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: manager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setBinStep(binStep)
        });
    }

    function _open(DeepCoreBinDynamicFeeHook.FeeConfig memory c, uint16 binStep) internal returns (PoolKey memory k, PoolId pid) {
        k = _key(binStep);
        pid = k.toId();
        vm.prank(CREATOR);
        hook.configure(k, c, MAX_SHARE);
        manager.initialize(k, ACTIVE_ID);
        (IBinPoolManager.MintParams memory mp,) = _getMultipleBinMintParams(ACTIVE_ID, 10_000 ether, 10_000 ether, 40, 40);
        liquidityHelper.mint(k, mp, "");
    }

    function _swap(PoolKey memory k, bool swapForY, int128 amountSpecified) internal returns (BalanceDelta) {
        return swapHelper.swap(k, swapForY, amountSpecified, BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}), "");
    }

    function _active() internal view returns (uint24 a) {
        (a,,) = manager.getSlot0(id);
    }

    function _swapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint24,uint24,uint16)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) (,,, fee,) = abi.decode(logs[i].data, (int128, int128, uint24, uint24, uint16));
        }
    }

    function _cutSlot() internal pure returns (bytes32) {
        return bytes32(uint256(keccak256("deepcore.bindynamicfee.pendingCut")) - 1);
    }

    function _parts(bool swapForY) internal view returns (uint24 total, uint24 lpPips, uint24 protocolPips) {
        (,,, total, lpPips, protocolPips) = hook.feeParts(id, swapForY);
    }

    /*//////////////////////////////////////////////////////////////
                       DEPLOYMENT AND CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_bitmap_is_0x08C7() public view {
        assertEq(hook.getHooksRegistrationBitmap(), 0x08C7);
    }

    function test_deploy_refusesAFeeCapAboveBinsTenPercent() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.InvalidDeployment.selector, 2));
        new DeepCoreBinDynamicFeeHook(manager, IVault(address(vault)), SAFE, RECIPIENT, 100_001, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.InvalidDeployment.selector, 1));
        new DeepCoreBinDynamicFeeHook(manager, IVault(address(0x1234)), SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
    }

    function test_configure_recordsBinStepShareOwner_andStoredFee() public view {
        DeepCoreBinDynamicFeeHook.PoolAdmin memory a = hook.getAdmin(id);
        assertEq(a.owner, CREATOR);
        assertEq(a.binStep, BIN_STEP);
        assertEq(a.protocolShareBps, SHARE);
        (,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, 3_000, "the stored fee is the base fee");
    }

    function test_configure_refusals() public {
        PoolKey memory k = _key(20);
        k.fee = 3_000;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.PoolMustUseDynamicFee.selector, uint24(3_000)));
        hook.configure(k, _cfg(), MAX_SHARE);
        vm.expectRevert(DeepCoreBinDynamicFeeHook.PoolAlreadyInitialized.selector);
        hook.configure(key, _cfg(), MAX_SHARE);
        DeepCoreBinDynamicFeeHook.FeeConfig memory c = _cfg();
        c.maxFee = FEE_CAP + 1;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.InvalidConfig.selector, 3));
        hook.configure(_key(20), c, MAX_SHARE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.ProtocolShareAboveAccepted.selector, SHARE, uint16(100)));
        hook.configure(_key(20), _cfg(), 100);
        hook.configure(_key(20), _cfg(), MAX_SHARE);
        vm.expectRevert(DeepCoreBinDynamicFeeHook.PoolAlreadyConfigured.selector);
        hook.configure(_key(20), _cfg(), MAX_SHARE);
    }

    function test_initialize_refusesAnUnconfiguredPool() public {
        vm.expectRevert();
        manager.initialize(_key(25), ACTIVE_ID);
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP AND PROTOCOL CUT
    //////////////////////////////////////////////////////////////*/

    function test_swapForY_movesTheActiveBinDown() public {
        vm.warp(T0 + 10);
        uint24 before = _active();
        _swap(key, true, -3_000 ether);
        assertLt(_active(), before, "selling X lowers the active bin, the analogue of zeroForOne");
    }

    function test_swap_exactIn_lpPart_andTheCutOnTheOutput() public {
        vm.warp(T0 + 10);
        (uint24 total, uint24 lpPips, uint24 protocolPips) = _parts(true);
        assertEq(total, 3_000);
        assertEq(protocolPips, 450);
        uint256 before1 = c1.balanceOf(address(this));
        vm.recordLogs();
        _swap(key, true, -1 ether);
        assertEq(_swapFee(vm.getRecordedLogs()), lpPips, "core charged the LP part");
        uint256 received = c1.balanceOf(address(this)) - before1;
        uint256 cut = hook.protocolTaken(c1);
        assertGt(cut, 0);
        assertEq(cut, ((received + cut) * protocolPips) / 1e6);
        assertEq(vault.balanceOf(address(hook), c1), cut);
        assertEq(uint256(vm.load(address(hook), _cutSlot())), 0);
    }

    function test_swap_exactOut_theCutIsOnTheInput() public {
        vm.warp(T0 + 10);
        uint256 before0 = c0.balanceOf(address(this));
        _swap(key, true, 1 ether);
        uint256 paid = before0 - c0.balanceOf(address(this));
        uint256 cut = hook.protocolTaken(c0);
        assertGt(cut, 0);
        assertEq(hook.protocolTaken(c1), 0);
        assertEq(cut, ((paid - cut) * 450) / 1e6);
    }

    function test_pendingCut_isClearedBetweenSwapsOfOneCall() public {
        vm.prank(SAFE);
        hook.setProtocolShare(0);
        (PoolKey memory kB, PoolId idB) = _open(_cfg(), 20);
        assertEq(hook.getAdmin(idB).protocolShareBps, 0);
        TwoBinSwaps two = new TwoBinSwaps(swapHelper, tx0, tx1);
        tx0.transfer(address(two), 10 ether);
        vm.warp(T0 + 10);
        two.run(key, kB);
        assertGt(hook.protocolTaken(c1), 0);
    }

    function test_share_aConfiguredPoolKeepsPayingItsFrozenShare() public {
        vm.prank(SAFE);
        hook.setProtocolShare(0);
        vm.warp(T0 + 10);
        (,, uint24 protocolPips) = _parts(true);
        assertEq(protocolPips, 450);
        _swap(key, true, -1 ether);
        assertGt(hook.protocolTaken(c1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                THE FEE
    //////////////////////////////////////////////////////////////*/

    function test_fee_volatilityInBinsTimesBinStep_andDecay() public {
        vm.warp(T0 + 10);
        uint24 start = _active();
        _swap(key, true, -3_000 ether);
        uint256 bins = start - _active();
        assertGt(bins, 2);
        vm.warp(T0 + 11);
        uint256 move = bins * BIN_STEP;
        if (move > MAX_MOVE) move = MAX_MOVE;
        (uint24 total,,) = _parts(false);
        assertEq(total, 3_000 + 10 * move, "base + volSlope x (bins x binStep)");
        _swap(key, false, POKE);
        (uint32 vol,) = hook.volatility(id);
        assertEq(vol, move);
        vm.warp(T0 + 11 + 1_800);
        (total,,) = _parts(true);
        assertEq(total, 3_000, "decayed to the base fee");
    }

    function test_fee_deadBandInBinsTimesBinStep() public {
        vm.warp(T0 + 10);
        uint24 start = _active();
        // move exactly two bins (20 bps, inside the 25 bps band) by swapping until the active bin moves twice
        for (uint256 i; i < 400 && start - _active() < 2; ++i) _swap(key, true, -20 ether);
        assertEq(start - _active(), 2, "moved exactly two bins");
        vm.warp(T0 + 11);
        _swap(key, true, POKE);
        (uint32 vol,) = hook.volatility(id);
        assertEq(vol, 0, "two bins of 10 bps are inside a 25 bps dead band");
        for (uint256 i; i < 400 && start - _active() < 3; ++i) _swap(key, true, -20 ether);
        vm.warp(T0 + 12);
        _swap(key, true, POKE);
        (vol,) = hook.volatility(id);
        assertEq(vol, uint256(start - hook.getState(id).volRefId) * BIN_STEP, "counted whole once past the band");
        assertGe(vol, 30);
    }

    function test_fee_theReversingLegPaysTheSurcharge() public {
        vm.warp(T0 + 10);
        _swap(key, false, POKE); // anchors second 10
        uint24 start = _active();
        _swap(key, false, -500 ether); // price up: the active bin rises
        uint256 bins = _active() - start;
        assertGt(bins, 0);
        (uint24 same,,) = _parts(false);
        assertEq(same, 3_000, "same direction: no surcharge");
        (uint24 rev,,) = _parts(true);
        assertEq(rev, 3_000 + 50 * bins * BIN_STEP, "reversing: sameSecondSlope x bins x binStep");
    }

    /// @dev The Bin-only bypass: an active-bin mint is an implicit swap. In a volatile second it must
    /// pay the dynamic fee, not the stored base fee.
    function test_mint_activeBinCompositionFeeFollowsTheDynamicFee() public {
        vm.warp(T0 + 10);
        _swap(key, true, -3_000 ether); // volatility, counted by the next second's first read
        vm.warp(T0 + 11);
        _swap(key, false, POKE); // the first swap of second 11 RECORDS the move (and its time), so decay runs from here
        uint24 hotFee = hook.mintFee(id);
        assertGt(hotFee, 3_000, "the mint fee follows volatility");
        uint256 snap = vm.snapshotState();
        uint256 hotComp = _lopsidedActiveMint();

        // The SAME pool state, only the clock moved: volatility has decayed and the fee is the base.
        vm.revertToState(snap);
        vm.warp(T0 + 11 + 1_800);
        uint24 quietFee = hook.mintFee(id);
        assertEq(quietFee, 3_000);
        uint256 quietComp = _lopsidedActiveMint();

        // Core's composition fee is fee x (1 + fee) of the swapped part: the ratio of the two mints is
        // the ratio of the fees core was given, to within the (1 + fee) factor.
        assertGt(hotComp, quietComp, "the volatile mint paid more");
        assertApproxEqRel(hotComp * quietFee, quietComp * hotFee, 0.02e18, "the mint paid the dynamic fee, not the base");
    }

    /// @dev A mint has no direction, so it pays the HIGHER of the two: right after a move in the same
    /// second, the reversing direction carries a surcharge the other does not.
    function test_mint_paysTheHigherDirection() public {
        vm.warp(T0 + 10);
        _swap(key, false, POKE); // anchors second 10
        _swap(key, false, -500 ether); // the active bin rises within the second
        uint24 up = hook.currentFee(id, false);
        uint24 down = hook.currentFee(id, true); // reversing: carries the surcharge
        assertGt(down, up, "the directions differ this second");
        assertEq(hook.mintFee(id), down, "a mint pays the higher");
        // And the CALLBACK core uses returns exactly that, with the override flag.
        IBinPoolManager.MintParams memory mp = _getSingleBinMintParams(_active(), 1 ether, 0); // before the prank: _active() calls out
        vm.prank(address(manager));
        (, uint24 returned) = hook.beforeMint(address(this), key, mp, "");
        assertEq(returned, down | LPFeeLibrary.OVERRIDE_FEE_FLAG, "beforeMint returns the higher direction");
    }

    function test_fee_isClampedToMaxFee() public {
        DeepCoreBinDynamicFeeHook.FeeConfig memory c = _cfg();
        c.maxFee = 4_000;
        c.maxBaseFee = 4_000;
        (PoolKey memory k, PoolId pid) = _open(c, 30);
        vm.warp(T0 + 10);
        swapHelper.swap(k, true, -5_000 ether, BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}), "");
        vm.warp(T0 + 11);
        (,,, uint24 total,,) = hook.feeParts(pid, true);
        assertEq(total, 4_000, "clamped to maxFee");
        assertEq(hook.mintFee(pid), 4_000, "the mint fee is clamped too");
    }

    function _lopsidedActiveMint() internal returns (uint256 compX) {
        uint24 a = _active();
        IBinPoolManager.MintParams memory mp = _getSingleBinMintParams(a, 100 ether, 0);
        vm.recordLogs();
        liquidityHelper.mint(key, mp, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Mint(bytes32,address,uint256[],bytes32,bytes32[],bytes32,bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (,,, bytes32 comp,) = abi.decode(logs[i].data, (uint256[], bytes32, bytes32[], bytes32, bytes32));
                (uint128 x, uint128 y) = comp.decode();
                compX = uint256(x) + uint256(y);
            }
        }
        assertGt(compX, 0, "a lopsided active-bin mint pays a composition fee");
    }

    function testFuzz_feeNeverAboveMaxFee_swapsNeverRevert(uint256 seed) public {
        for (uint256 i; i < 10; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % 7));
            bool sfy = seed & 1 == 0;
            uint24 a = _active();
            if (a < ACTIVE_ID - 30) sfy = false;
            if (a > ACTIVE_ID + 30) sfy = true;
            _swap(key, sfy, -int128(int256(1 ether + (seed >> 8) % 2_000 ether)));
            (,,, uint24 total,,) = hook.feeParts(id, !sfy);
            assertLe(total, 30_000);
            assertLe(hook.mintFee(id), 30_000);
            (uint32 vol,) = hook.volatility(id);
            assertLe(vol, 2_000);
            assertEq(uint256(vm.load(address(hook), _cutSlot())), 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       TUNER, SHARE, OWNERSHIP, FUNDS
    //////////////////////////////////////////////////////////////*/

    function test_tune_andTheTunerLifeCycle() public {
        vm.prank(CREATOR);
        hook.proposeTuner(id, TUNER);
        vm.prank(TUNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.TunerNoticeNotElapsed.selector, uint40(block.timestamp + NOTICE)));
        hook.acceptTuner(id);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(TUNER);
        hook.acceptTuner(id);
        vm.startPrank(TUNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.StepTooLarge.selector, uint8(1), uint24(3_000), uint24(3_501), uint24(500)));
        hook.tune(key, 3_501, 10, 50);
        hook.tune(key, 3_500, 15, 55);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.TuneTooSoon.selector, uint40(block.timestamp + 3_600)));
        hook.tune(key, 3_600, 15, 55);
        vm.stopPrank();
        (,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, 3_500);
        vm.prank(CREATOR);
        hook.freeze(id);
        vm.prank(TUNER);
        vm.expectRevert(DeepCoreBinDynamicFeeHook.NotTuner.selector);
        hook.tune(key, 3_000, 10, 50);
    }

    function test_share_governance() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setProtocolShare(0);
        vm.startPrank(SAFE);
        hook.setProtocolShare(1_000);
        assertEq(hook.protocolShareBps(), 1_000);
        hook.setProtocolShare(2_500);
        assertEq(hook.protocolShareBps(), 1_000);
        vm.warp(block.timestamp + NOTICE);
        assertEq(hook.protocolShareBps(), 2_500);
        vm.expectRevert(DeepCoreBinDynamicFeeHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        vm.stopPrank();
        assertEq(hook.getAdmin(id).protocolShareBps, SHARE);
    }

    function test_flush_paysTheRecipientOnly() public {
        vm.warp(T0 + 10);
        _swap(key, true, -10 ether);
        uint256 cut = hook.protocolTaken(c1);
        tx1.transfer(address(hook), 7);
        vm.prank(STRANGER);
        assertEq(hook.flushProtocolFees(c1), cut + 7);
        assertEq(c1.balanceOf(RECIPIENT), cut + 7);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreBinDynamicFeeHook.NothingToFlush.selector, c1));
        hook.flushProtocolFees(c1);
        vm.expectRevert(DeepCoreBinDynamicFeeHook.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(c1, uint256(1)));
    }

    function test_callbacks_onlyThePoolManager() public {
        vm.expectRevert();
        hook.beforeSwap(address(this), key, true, -1, "");
        vm.expectRevert();
        hook.beforeMint(address(this), key, _getSingleBinMintParams(ACTIVE_ID, 1, 1), "");
    }
}
