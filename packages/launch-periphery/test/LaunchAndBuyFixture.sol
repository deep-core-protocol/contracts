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

import {LaunchpadKitV2} from "deepcore-launchpad/src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "deepcore-launchpad/src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "deepcore-launchpad/src/DeepCoreBinLPLocker.sol";
import {LaunchTokenFactory} from "deepcore-launchpad/src/LaunchTokenFactory.sol";
import {ILaunchTokenFactory} from "deepcore-launchpad/src/interfaces/ILaunchTokenFactory.sol";
import {ILaunchRegistryWriter} from "deepcore-launchpad/src/interfaces/ILaunchRegistryWriter.sol";
import {
    ILaunchpadKitV2,
    LegKind,
    BinShape,
    CLLegParams,
    BinLegParams,
    LegParams,
    ScheduleParams,
    TaxParams,
    LaunchParamsV2
} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "deepcore-launchpad/src/libraries/LaunchPresets.sol";

import {DeepCoreLaunchAndBuy} from "../src/DeepCoreLaunchAndBuy.sol";

/// @dev A Safe stand-in: a contract that accepts native value.
contract FakeSafe {
    receive() external payable {}
}

/// @dev Refuses every native transfer. Stands in for a recipient that cannot be paid.
contract NativeRefuser {
    receive() external payable {
        revert("no");
    }
}

/// @notice Real Vault, both pool managers, both position managers, Permit2, both lockers, both guards,
/// the token factory, both registries, V3 installed on both managers, the real `LaunchpadKitV2`, and
/// `DeepCoreLaunchAndBuy` on top of it.
///
/// @dev Deliberately a COPY of `packages/launchpad/test/kitv2/KitV2Fixture.sol`'s deployment rather
/// than an import of it: importing another package's test helper couples this suite to a file that
/// belongs to somebody else's build, and this package has to stand on its own in CI.
abstract contract LaunchAndBuyFixture is Test, DeployPermit2 {
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    uint24 internal constant ACTIVE_ID = 2 ** 23;
    uint16 internal constant BIN_STEP = 10;
    int24 internal constant TICK_SPACING = 60;

    uint256 internal constant INITIAL_LAUNCH_FEE = 0.001 ether;
    uint256 internal constant MAX_LAUNCH_FEE = 0.01 ether;
    uint32 internal constant NOTICE = 7 days;
    uint256 internal constant MAX_INTEGRATOR_FEE = 0.005 ether;
    uint8 internal constant MAX_LEGS = 4;
    uint16 internal constant MAX_BINS_PER_LEG = 32;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SEED_SUPPLY = 800_000_000 ether;

    /// @dev Anything at or above every preset's opening fee, so a test that is not ABOUT the fee bound
    /// does not have to restate it.
    uint24 internal constant ANY_FEE = 1_000_000;

    address internal constant CREATOR = address(0xC4EA);
    address internal constant OTHER_CREATOR = address(0xC4E2);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant STEWARD = address(0x57E3);
    address internal constant INTEGRATOR = address(0x1478);
    address internal constant ALLOCATION = address(0xA110C);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant GUARDIAN = address(0x6A4D);
    address internal constant REGISTRY_ADMIN = address(0xAD3111);
    address internal constant LAUNCHPAD_STEWARD = address(0x0B5);
    address internal constant SWEEP_SAFE = address(0x5AFE5AFE);

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
    DeepCoreLaunchAndBuy internal lab;
    address internal safe;

    MockERC20 internal quoteToken;

    /// @dev Core's own permissionless test routers, so a test can make a SECOND buy the way any
    /// stranger would - which is how "the creator got in first" is measured rather than asserted.
    CLPoolManagerRouter internal clRouter;
    BinSwapHelper internal binSwapper;

    function setUp() public virtual {
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
        binPosm =
            new BinPositionManager(IVault(address(vault)), IBinPoolManager(address(binPM)), permit2, IWETH9(address(weth)));

        safe = address(new FakeSafe());
        factory = new LaunchTokenFactory();
        clHook = new LaunchGuardHook(ICLPoolManager(address(clPM)), ILaunchTokenOrigin(address(factory)), safe, 0);
        binHook = new BinLaunchGuardHook(IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(factory)), safe, 0);
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

        lab = new DeepCoreLaunchAndBuy(ILaunchpadKitV2(address(kit)), SWEEP_SAFE);

        clRouter = new CLPoolManagerRouter(IVault(address(vault)), ICLPoolManager(address(clPM)));
        binSwapper = new BinSwapHelper(IBinPoolManager(address(binPM)), IVault(address(vault)));

        quoteToken = new MockERC20("Quote", "QUOT", 18);
        quoteToken.mint(CREATOR, 1e30);
        quoteToken.mint(OTHER_CREATOR, 1e30);
        quoteToken.mint(ATTACKER, 1e30);
        vm.prank(CREATOR);
        quoteToken.approve(address(lab), type(uint256).max);
        vm.prank(OTHER_CREATOR);
        quoteToken.approve(address(lab), type(uint256).max);
        vm.prank(ATTACKER);
        quoteToken.approve(address(lab), type(uint256).max);
        vm.prank(ATTACKER);
        quoteToken.approve(address(clRouter), type(uint256).max);
        vm.prank(ATTACKER);
        quoteToken.approve(address(binSwapper), type(uint256).max);

        vm.deal(CREATOR, 10_000 ether);
        vm.deal(OTHER_CREATOR, 10_000 ether);
        vm.deal(ATTACKER, 10_000 ether);
        vm.deal(address(this), 10_000 ether);

        cachedLaunchFee = INITIAL_LAUNCH_FEE;
        assertEq(cachedLaunchFee, kit.launchFeeWei(), "the cache must equal the live fee");
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

    /*//////////////////////////////////////////////////////////////
                               PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The token address a launch by `creator` with `salt` THROUGH `lab` produces.
    function _tokenVia(address creator, bytes32 salt) internal view returns (address) {
        return lab.predictLaunchToken(creator, salt);
    }

    function _clLeg(address token, address quote_, uint16 weightBps) internal pure returns (LegParams memory leg) {
        leg.kind = LegKind.CL;
        leg.quote = quote_;
        leg.weightBps = weightBps;
        bool is0 = uint160(token) < uint160(quote_);
        leg.cl = CLLegParams({
            tickSpacing: TICK_SPACING,
            sqrtPriceX96: SQRT_1_1,
            tickLower: is0 ? int24(60) : int24(-60_000),
            tickUpper: is0 ? int24(60_000) : int24(0)
        });
    }

    function _binLeg(address quote_, uint16 weightBps, BinShape shape, uint16 count)
        internal
        pure
        returns (LegParams memory leg)
    {
        leg.kind = LegKind.Bin;
        leg.quote = quote_;
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
        m.description = "A launch-and-buy test launch.";
        m.websiteURI = "https://example.invalid";
    }

    /// @dev Every field the kit needs, with `startDelaySeconds` at 0 - the only value this contract
    /// accepts, because it buys at the open.
    function _params(bytes32 salt, LegParams[] memory legs) internal pure returns (LaunchParamsV2 memory p) {
        p.name = "Launch";
        p.symbol = "LNCH";
        p.metadataURI = "ipfs://example";
        p.userSalt = salt;
        p.totalSupply = TOTAL_SUPPLY;
        p.seedSupply = SEED_SUPPLY;
        p.allocationRecipient = ALLOCATION;
        p.creator = address(0);
        p.launchOperator = address(0);
        p.launchSteward = address(0);
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
            startDelaySeconds: 0
        });
        p.legs = legs;
        p.listing = _metadata();
    }

    function _oneCL(address creator, bytes32 salt, address quote_) internal view returns (LaunchParamsV2 memory) {
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _clLeg(_tokenVia(creator, salt), quote_, 10_000);
        return _params(salt, legs);
    }

    function _oneBin(address quote_) internal pure returns (LaunchParamsV2 memory) {
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _binLeg(quote_, 10_000, BinShape.Linear, 10);
        return _params(bytes32("bin"), legs);
    }

    function _clAndBin(address creator, bytes32 salt, address quote_) internal view returns (LaunchParamsV2 memory) {
        LegParams[] memory legs = new LegParams[](2);
        legs[0] = _clLeg(_tokenVia(creator, salt), quote_, 6_000);
        legs[1] = _binLeg(quote_, 4_000, BinShape.Linear, 10);
        return _params(salt, legs);
    }

    function _buy(uint256 amountIn) internal pure returns (DeepCoreLaunchAndBuy.BuyParams memory b) {
        b.legIndex = 0;
        b.amountIn = amountIn;
        b.minAmountOut = 0;
        b.recipient = address(0);
        b.expectedToken = address(0);
        b.maxLaunchFeeWei = type(uint256).max;
        b.maxLpFeePips = ANY_FEE;
    }

    /// @dev The kit's protocol launch fee, cached in setUp.
    ///
    /// IT MUST NOT MAKE AN EXTERNAL CALL. Tests write `vm.prank(X); lab.launchAndBuy{value:
    /// _kitFee(p)}(...)`, and a `kit.launchFeeWei()` inside the value expression would consume the
    /// prank - the launch would then run as the TEST contract and every identity assertion in this
    /// file would be testing the wrong address. Asserted equal to the live value in `setUp`; the one
    /// test that moves the fee states its own numbers.
    uint256 internal cachedLaunchFee;

    function _kitFee(LaunchParamsV2 memory p) internal view returns (uint256) {
        return cachedLaunchFee + p.integratorLaunchFeeWei;
    }

    /*//////////////////////////////////////////////////////////////
                            A STRANGER'S BUY
    //////////////////////////////////////////////////////////////*/

    /// @dev What anybody else would do: lock the Vault through a permissionless router and swap.
    function _strangerBuyCL(PoolKey memory key, address token, uint256 amountIn, address who)
        internal
        returns (BalanceDelta)
    {
        bool launchIs0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = !launchIs0;
        uint256 value = zeroForOne && Currency.unwrap(key.currency0) == address(0) ? amountIn : 0;
        vm.prank(who);
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

    receive() external payable {}
}
