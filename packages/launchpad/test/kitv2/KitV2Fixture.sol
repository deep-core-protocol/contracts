// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";

import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {BinPositionManager} from "infinity-periphery/src/pool-bin/BinPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {DeepCoreRegistry} from "deepcore-registry/src/DeepCoreRegistry.sol";
import {DeepCoreLaunchRegistry} from "deepcore-registry/src/DeepCoreLaunchRegistry.sol";
import {LaunchMetadata} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";
import {DeepCoreProtocolFeeControllerV2} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV3.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../../src/DeepCoreBinLPLocker.sol";
import {LaunchTokenFactory} from "../../src/LaunchTokenFactory.sol";
import {ILaunchTokenFactory} from "../../src/interfaces/ILaunchTokenFactory.sol";
import {ILaunchRegistryWriter} from "../../src/interfaces/ILaunchRegistryWriter.sol";
import {
    LegKind,
    BinShape,
    CLLegParams,
    BinLegParams,
    LegParams,
    ScheduleParams,
    TaxParams,
    LaunchParamsV2,
    LaunchResultV2
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";

/// @dev A Safe stand-in: a contract that accepts native value, so `flushProtocolFees` can pay it.
contract FakeSafe {
    receive() external payable {}
}

/// @dev Robinhood `Stock`-like quote: issuer pause, per-address block, and a DISPLAY multiplier that must never
/// affect raw units. Nothing in the kit, the lockers or core reads `uiMultiplier`.
contract MockStockToken is MockERC20 {
    bool public paused;
    uint256 public uiMultiplier = 1e18;
    mapping(address => bool) public blocked;

    error EnforcedPause();
    error Blocked(address account);

    constructor() MockERC20("NVIDIA Stock Token", "NVDA", 18) {}

    function setPaused(bool value) external {
        paused = value;
    }

    function setUiMultiplier(uint256 value) external {
        uiMultiplier = value;
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _check(address from, address to) internal view {
        if (paused) revert EnforcedPause();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(from, to);
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Real Vault, CL + Bin pool managers, both position managers, Permit2, both lockers, both guards (with
/// the pool-id reservation), the factory, both registries, and V2 + V3 with V3 INSTALLED on both managers.
abstract contract KitV2Fixture is Test, DeployPermit2 {
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    uint24 internal constant ACTIVE_ID = 2 ** 23;
    uint16 internal constant BIN_STEP = 10;
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant PACKED_999 = uint24(999) | (uint24(999) << 12);

    uint256 internal constant INITIAL_LAUNCH_FEE = 0.001 ether;
    uint256 internal constant MAX_LAUNCH_FEE = 0.01 ether;
    uint32 internal constant NOTICE = 7 days;
    uint256 internal constant MAX_INTEGRATOR_FEE = 0.005 ether;
    uint8 internal constant MAX_LEGS = 4;
    uint16 internal constant MAX_BINS_PER_LEG = 32;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SEED_SUPPLY = 800_000_000 ether;

    address internal constant LAUNCHER = address(0xA11CE);
    address internal constant CREATOR = address(0xC4EA);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant STEWARD = address(0x57E3);
    address internal constant INTEGRATOR = address(0x1478);
    address internal constant ALLOCATION = address(0xA110C);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant GUARDIAN = address(0x6A4D);
    address internal constant REGISTRY_ADMIN = address(0xAD3111);
    address internal constant LAUNCHPAD_STEWARD = address(0x0B5);

    Vault internal vault;
    CLPoolManager internal clPM;
    BinPoolManager internal binPM;
    IAllowanceTransfer internal permit2;
    WETH internal weth;
    CLPositionManager internal clPosm;
    BinPositionManager internal binPosm;
    LaunchTokenFactory internal factory;
    LaunchGuardHook internal clHook;
    BinLaunchGuardHook internal binHook;
    DeepCoreLPLocker internal clLocker;
    DeepCoreBinLPLocker internal binLocker;
    DeepCoreRegistry internal deepcoreRegistry;
    DeepCoreLaunchRegistry internal launchRegistry;
    DeepCoreProtocolFeeControllerV2 internal v2;
    DeepCoreProtocolFeeControllerV3 internal v3;
    LaunchpadKitV2 internal kit;
    address internal safe;

    CLPoolManagerRouter internal clRouter;
    BinSwapHelper internal binSwapper;

    MockERC20 internal quote;
    MockStockToken internal stock;

    /// @dev The share of a buy's trade fee both guards leave to the pool. Zero here, so every suite
    /// built on this fixture states the guard's take as the whole fee; `LaunchpadKitV2LpShare.t.sol`
    /// overrides it.
    function _lpShareBps() internal pure virtual returns (uint16) {
        return 0;
    }

    function _deployAll() internal {
        vault = new Vault();
        clPM = new CLPoolManager(IVault(address(vault)));
        binPM = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(clPM));
        vault.registerApp(address(binPM));

        permit2 = IAllowanceTransfer(deployPermit2());
        weth = new WETH();
        ICLPositionDescriptor descriptor = new CLPositionDescriptorOffChain("https://deepcore.example/positions/");
        clPosm = new CLPositionManager(
            IVault(address(vault)), ICLPoolManager(address(clPM)), permit2, 100_000, descriptor, IWETH9(address(weth))
        );
        binPosm = new BinPositionManager(
            IVault(address(vault)), IBinPoolManager(address(binPM)), permit2, IWETH9(address(weth))
        );

        safe = address(new FakeSafe());
        factory = new LaunchTokenFactory();
        clHook = new LaunchGuardHook(
            ICLPoolManager(address(clPM)), ILaunchTokenOrigin(address(factory)), safe, _lpShareBps()
        );
        binHook = new BinLaunchGuardHook(
            IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(factory)), safe, _lpShareBps()
        );
        clLocker = new DeepCoreLPLocker(clPosm, safe, 2_000, 5_000, 2_000);
        binLocker = new DeepCoreBinLPLocker(binPosm, safe, 2_000, 5_000, 2_000, 64);

        address[] memory none = new address[](0);
        deepcoreRegistry = new DeepCoreRegistry(REGISTRY_ADMIN, address(vault), none, none);
        launchRegistry = new DeepCoreLaunchRegistry(address(vault), address(deepcoreRegistry));

        v2 = new DeepCoreProtocolFeeControllerV2(safe, GUARDIAN);
        kit = new LaunchpadKitV2(_deployment());
        v3 = new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kit));
        clPM.setProtocolFeeController(v3);
        binPM.setProtocolFeeController(v3);

        clRouter = new CLPoolManagerRouter(IVault(address(vault)), ICLPoolManager(address(clPM)));
        binSwapper = new BinSwapHelper(IBinPoolManager(address(binPM)), IVault(address(vault)));

        quote = new MockERC20("Quote", "QUOT", 18);
        stock = new MockStockToken();
        quote.mint(address(this), 1e36);
        stock.mint(address(this), 1e36);
        quote.approve(address(clRouter), type(uint256).max);
        quote.approve(address(binSwapper), type(uint256).max);
        stock.approve(address(clRouter), type(uint256).max);
        stock.approve(address(binSwapper), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);
        vm.deal(LAUNCHER, 1_000 ether);
    }

    function _deployment() internal view returns (LaunchpadKitV2.Deployment memory d) {
        d = LaunchpadKitV2.Deployment({
            owner: safe,
            clPoolManager: ICLPoolManager(address(clPM)),
            clHook: clHook,
            clPositionManager: clPosm,
            clLocker: clLocker,
            binPoolManager: IBinPoolManager(address(binPM)),
            binHook: binHook,
            binPositionManager: binPosm,
            binLocker: binLocker,
            tokenFactory: ILaunchTokenFactory(address(factory)),
            launchRegistry: ILaunchRegistryWriter(address(launchRegistry)),
            protocolFeeRecipient: safe,
            launchpadSteward: LAUNCHPAD_STEWARD,
            initialLaunchFeeWei: INITIAL_LAUNCH_FEE,
            maxLaunchFeeWei: MAX_LAUNCH_FEE,
            launchFeeNoticeSeconds: NOTICE,
            maxIntegratorLaunchFeeWei: MAX_INTEGRATOR_FEE,
            maxLegs: MAX_LEGS,
            maxBinsPerLeg: MAX_BINS_PER_LEG
        });
    }

    /// @dev A second, independent kit deployment paying `otherSafe`, the way another chain's stack would be:
    /// its own guards and lockers (the kit refuses guards or lockers that pay a different Safe), on the same
    /// managers and position managers for convenience.
    function _deploymentFor(address otherSafe) internal returns (LaunchpadKitV2.Deployment memory d) {
        d = _deployment();
        d.owner = otherSafe;
        d.protocolFeeRecipient = otherSafe;
        d.clHook = new LaunchGuardHook(ICLPoolManager(address(clPM)), ILaunchTokenOrigin(address(factory)), otherSafe, 0);
        d.binHook = new BinLaunchGuardHook(IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(factory)), otherSafe, 0);
        d.clLocker = new DeepCoreLPLocker(clPosm, otherSafe, 2_000, 5_000, 2_000);
        d.binLocker = new DeepCoreBinLPLocker(binPosm, otherSafe, 2_000, 5_000, 2_000, 64);
    }

    /*//////////////////////////////////////////////////////////////
                               PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function _token(bytes32 salt) internal view returns (address) {
        return kit.predictLaunchToken(LAUNCHER, salt);
    }

    function _clLeg(address token, address quoteToken, uint16 weightBps) internal pure returns (LegParams memory leg) {
        leg.kind = LegKind.CL;
        leg.quote = quoteToken;
        leg.weightBps = weightBps;
        bool is0 = uint160(token) < uint160(quoteToken);
        // Opens at tick 0. Launch token = currency0 sells upward (range above spot); currency1 sells downward.
        leg.cl = CLLegParams({
            tickSpacing: TICK_SPACING,
            sqrtPriceX96: SQRT_1_1,
            tickLower: is0 ? int24(60) : int24(-60_000),
            tickUpper: is0 ? int24(60_000) : int24(0)
        });
    }

    function _binLeg(address quoteToken, uint16 weightBps, BinShape shape, uint16 count)
        internal
        pure
        returns (LegParams memory leg)
    {
        leg.kind = LegKind.Bin;
        leg.quote = quoteToken;
        leg.weightBps = weightBps;
        leg.bin = BinLegParams({
            binStep: BIN_STEP,
            activeId: ACTIVE_ID,
            shape: shape,
            binCount: count,
            offsets: new uint24[](0),
            weights: new uint64[](0),
            floorBins: 0
        });
    }

    function _metadata() internal pure returns (LaunchMetadata memory m) {
        m.description = "A kit v2 test launch.";
        m.websiteURI = "https://example.invalid";
        m.xHandle = "example";
        m.telegramHandle = "example_tg";
    }

    /// @dev No creator tax: the all-zero block `createLaunch` and `reconfigureLaunch` read as "none".
    function _noTax() internal pure returns (TaxParams memory t) {}

    function _params(bytes32 salt, LegParams[] memory legs) internal pure returns (LaunchParamsV2 memory p) {
        p.name = "Launch";
        p.symbol = "LNCH";
        p.metadataURI = "ipfs://example";
        p.userSalt = salt;
        p.totalSupply = TOTAL_SUPPLY;
        p.seedSupply = SEED_SUPPLY;
        p.allocationRecipient = ALLOCATION;
        p.creator = CREATOR;
        p.launchOperator = OPERATOR;
        p.launchSteward = STEWARD;
        p.integrator = INTEGRATOR;
        p.integratorBps = 1_000;
        p.creatorBps = 7_000;
        p.protocolBps = 2_000;
        p.schedule = ScheduleParams({
            preset: Preset.FairLaunch,
            initialFeeBips: 0,
            finalFeeBips: 0,
            decaySeconds: 0,
            enabled: false,
            startDelaySeconds: 120
        });
        p.legs = legs;
        p.listing = _metadata();
    }

    function _oneCL(bytes32 salt, address quoteToken) internal view returns (LaunchParamsV2 memory) {
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _clLeg(_token(salt), quoteToken, 10_000);
        return _params(salt, legs);
    }

    function _clAndBin(bytes32 salt, address quoteToken) internal view returns (LaunchParamsV2 memory) {
        LegParams[] memory legs = new LegParams[](2);
        legs[0] = _clLeg(_token(salt), quoteToken, 6_000);
        legs[1] = _binLeg(quoteToken, 4_000, BinShape.Linear, 10);
        return _params(salt, legs);
    }

    function _launch(LaunchParamsV2 memory p) internal returns (LaunchResultV2 memory) {
        return _launchWithValue(p, kit.launchFeeWei() + p.integratorLaunchFeeWei);
    }

    function _launchWithValue(LaunchParamsV2 memory p, uint256 value) internal returns (LaunchResultV2 memory r) {
        vm.deal(LAUNCHER, LAUNCHER.balance + value);
        vm.prank(LAUNCHER);
        r = kit.createLaunch{value: value}(p);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function _clKey(address token, LegParams memory leg) internal view returns (PoolKey memory key) {
        (key,,) = kit.computeLegKey(token, leg);
    }

    function _clProtocolFee(bytes32 poolId) internal view returns (uint24 fee) {
        (,, fee,) = clPM.getSlot0(PoolId.wrap(poolId));
    }

    function _binProtocolFee(bytes32 poolId) internal view returns (uint24 fee) {
        (, fee,) = binPM.getSlot0(PoolId.wrap(poolId));
    }

    /*//////////////////////////////////////////////////////////////
                                 TRADES
    //////////////////////////////////////////////////////////////*/

    /// @dev Buys the launch token with `amountIn` of the quote on a CL leg.
    function _buyCL(PoolKey memory key, address token, uint256 amountIn) internal returns (BalanceDelta) {
        bool launchIs0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = !launchIs0; // pay the quote side
        uint256 value = zeroForOne && Currency.unwrap(key.currency0) == address(0) ? amountIn : 0;
        return clRouter.swap{value: value}(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev Buys the launch token with `amountIn` of the quote on a Bin leg.
    function _buyBin(PoolKey memory key, address token, uint256 amountIn) internal returns (BalanceDelta) {
        bool launchIs0 = Currency.unwrap(key.currency0) == token;
        bool swapForY = !launchIs0; // paying X (currency0) gets Y
        uint256 value = swapForY && Currency.unwrap(key.currency0) == address(0) ? amountIn : 0;
        return binSwapper.swap{value: value}(
            key,
            swapForY,
            -int128(int256(amountIn)),
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    receive() external payable {}
}
