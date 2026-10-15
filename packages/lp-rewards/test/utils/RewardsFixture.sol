// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {LiquidityRewardsModule} from "../../src/LiquidityRewardsModule.sol";
import {IDeepCoreLiquidityRewards} from "../../src/interfaces/IDeepCoreLiquidityRewards.sol";
import {RewardsHookHarness} from "./RewardsHarness.sol";

/// @dev The position manager's surface the tests drive. The contract itself is the real periphery one,
/// deployed from this package's artifact (`test/utils/PosmArtifact.sol`).
interface IPosm {
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address spender, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Real core + real periphery position manager + Permit2, and the rewards hook on one pool.
abstract contract RewardsFixture is Test, Deployers, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    // periphery Actions
    uint8 internal constant CL_INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant CL_DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant CL_MINT_POSITION = 0x02;
    uint8 internal constant CL_BURN_POSITION = 0x03;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;
    IAllowanceTransfer internal permit2;
    IPosm internal posm;
    WETH internal weth;
    RewardsHookHarness internal hook;

    MockERC20 internal tA;
    MockERC20 internal tB;
    MockERC20 internal rwd;
    PoolKey internal key;
    PoolId internal id;

    address internal SAFE = makeAddr("safe");
    address internal CREATOR = makeAddr("creator");
    address internal LP1 = makeAddr("lp1");
    address internal LP2 = makeAddr("lp2");
    address internal STRANGER = makeAddr("stranger");
    address internal REFUND = makeAddr("refund");

    int24 internal constant SPACING = 10;
    uint64 internal constant RECYCLE = 90 days;
    uint64 internal constant RECLAIM = 30 days;
    uint16 internal constant FEE_BPS = 100;
    uint16 internal constant MAX_FEE_BPS = 300;
    uint32 internal constant NOTICE = 7 days;
    uint256 internal constant T0 = 1_700_000_000;

    function setUp() public virtual {
        vm.warp(T0);
        (vault, manager) = createFreshManager();
        router = new CLPoolManagerRouter(vault, manager);
        permit2 = IAllowanceTransfer(deployPermit2());
        weth = new WETH();
        address desc = deployCode(
            "CLPositionDescriptorOffChain.sol:CLPositionDescriptorOffChain", abi.encode("https://deepcore.example/p/")
        );
        posm = IPosm(
            deployCode(
                "CLPositionManager.sol:CLPositionManager",
                abi.encode(address(vault), address(manager), address(permit2), uint256(100_000), desc, address(weth))
            )
        );
        hook = _deployHook(_minEligible());

        tA = new MockERC20("A", "A", 18);
        tB = new MockERC20("B", "B", 18);
        rwd = new MockERC20("Reward", "RWD", 18);
        (MockERC20 lo, MockERC20 hi) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);
        key = PoolKey({
            currency0: Currency.wrap(address(lo)),
            currency1: Currency.wrap(address(hi)),
            hooks: IHooks(address(hook)),
            poolManager: manager,
            fee: 3000,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(SPACING)
        });
        id = key.toId();

        _approveLp(LP1);
        _approveLp(LP2);
        tA.mint(address(this), 1e30);
        tB.mint(address(this), 1e30);
        tA.approve(address(router), type(uint256).max);
        tB.approve(address(router), type(uint256).max);
        rwd.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        rwd.approve(address(hook), type(uint256).max);

        _configure(_rewardList(Currency.wrap(address(rwd))), _minWidth());
        manager.initialize(key, SQRT_RATIO_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                             OVERRIDABLE
    //////////////////////////////////////////////////////////////*/

    function _minEligible() internal view virtual returns (uint128) {
        return 1_000;
    }

    function _minWidth() internal view virtual returns (uint24) {
        return 0;
    }

    function _params(uint128 minEligible) internal view returns (LiquidityRewardsModule.ModuleParams memory) {
        return LiquidityRewardsModule.ModuleParams({
            owner: SAFE,
            positionManager: address(posm),
            protocolFeeRecipient: SAFE,
            initialFeeBps: FEE_BPS,
            maxFeeBps: MAX_FEE_BPS,
            feeNoticeSeconds: NOTICE,
            recycleDelay: RECYCLE,
            reclaimDelay: RECLAIM,
            minEligibleLiquidity: minEligible
        });
    }

    function _deployHook(uint128 minEligible) internal returns (RewardsHookHarness) {
        return new RewardsHookHarness(manager, _params(minEligible));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _rewardList(Currency t) internal pure returns (Currency[] memory a) {
        a = new Currency[](1);
        a[0] = t;
    }

    function _configure(Currency[] memory tokens, uint24 minWidth) internal {
        vm.prank(CREATOR);
        hook.configureRewards(key, IDeepCoreLiquidityRewards.RewardsConfig({rewardTokens: tokens, minWidthTicks: minWidth}));
    }

    function _approveLp(address lp) internal {
        tA.mint(lp, 1e30);
        tB.mint(lp, 1e30);
        vm.startPrank(lp);
        tA.approve(address(permit2), type(uint256).max);
        tB.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tA), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(address(tB), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _plan2(uint8 a0, bytes memory p0, uint8 a1, bytes memory p1) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(a0, a1);
        bytes[] memory params = new bytes[](2);
        params[0] = p0;
        params[1] = p1;
        return abi.encode(actions, params);
    }

    function _mintNft(address lp, int24 lo, int24 hi, uint128 liquidity) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        bytes memory payload = _plan2(
            CL_MINT_POSITION,
            abi.encode(key, lo, hi, uint256(liquidity), type(uint128).max, type(uint128).max, lp, bytes("")),
            SETTLE_PAIR,
            abi.encode(key.currency0, key.currency1)
        );
        vm.prank(lp);
        posm.modifyLiquidities(payload, block.timestamp);
    }

    function _increaseNft(address lp, uint256 tokenId, uint128 liquidity, bytes memory hookData) internal {
        bytes memory payload = _plan2(
            CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, hookData),
            SETTLE_PAIR,
            abi.encode(key.currency0, key.currency1)
        );
        vm.prank(lp);
        posm.modifyLiquidities(payload, block.timestamp);
    }

    function _decreaseNft(address caller, uint256 tokenId, uint128 liquidity, bytes memory hookData) internal {
        bytes memory payload = _plan2(
            CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), hookData),
            TAKE_PAIR,
            abi.encode(key.currency0, key.currency1, caller)
        );
        vm.prank(caller);
        posm.modifyLiquidities(payload, block.timestamp);
    }

    function _burnNft(address caller, uint256 tokenId, bytes memory hookData) internal {
        bytes memory payload = _plan2(
            CL_BURN_POSITION,
            abi.encode(tokenId, uint128(0), uint128(0), hookData),
            TAKE_PAIR,
            abi.encode(key.currency0, key.currency1, caller)
        );
        vm.prank(caller);
        posm.modifyLiquidities(payload, block.timestamp);
    }

    /// @dev A position owned by the core test router (sender = router), driven by this contract.
    function _modifyDirect(int24 lo, int24 hi, int256 delta, bytes32 salt, bytes memory hookData) internal {
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: delta, salt: salt}),
            hookData
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev Swaps toward `target` until the pool's tick is at it (price limit = the tick's price).
    function _swapToTick(int24 target) internal {
        (, int24 cur,,) = manager.getSlot0(id);
        if (cur == target) return;
        bool zeroForOne = target < cur;
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e30),
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(target)
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _start(uint256 amount, uint32 duration) internal {
        vm.prank(CREATOR);
        hook.startStream(key, Currency.wrap(address(rwd)), amount, duration, REFUND);
    }

    function _nftKey(uint256 tokenId, int24 lo, int24 hi)
        internal
        view
        returns (IDeepCoreLiquidityRewards.PositionKey memory)
    {
        return IDeepCoreLiquidityRewards.PositionKey({sender: address(posm), tickLower: lo, tickUpper: hi, salt: bytes32(tokenId)});
    }

    function _directKey(int24 lo, int24 hi, bytes32 salt) internal view returns (IDeepCoreLiquidityRewards.PositionKey memory) {
        return IDeepCoreLiquidityRewards.PositionKey({sender: address(router), tickLower: lo, tickUpper: hi, salt: salt});
    }

    function _earned0(IDeepCoreLiquidityRewards.PositionKey memory k) internal view returns (uint256) {
        uint256[] memory e = hook.earned(id, k);
        return e.length == 0 ? 0 : e[0];
    }

    function _claim(address caller, IDeepCoreLiquidityRewards.PositionKey memory k, address to) internal returns (uint256) {
        vm.prank(caller);
        uint256[] memory a = hook.claim(id, k, to);
        return a[0];
    }

    function _net(uint256 gross) internal pure returns (uint256) {
        return gross - gross * FEE_BPS / 10_000;
    }

    /// @dev Every ledger the hook keeps for `token` summed: must equal `totalOwed` and never exceed the balance.
    function _ledger(Currency token, address[] memory creditors) internal view returns (uint256 sum) {
        IDeepCoreLiquidityRewards.StreamView[] memory ss = hook.streams(id);
        for (uint256 i; i < ss.length; ++i) {
            if (Currency.unwrap(ss[i].token) == Currency.unwrap(token)) {
                (uint128 und, uint128 accrued,,,,) = hook.streamRaw(id, i);
                sum += uint256(und) + accrued;
            }
        }
        for (uint256 i; i < creditors.length; ++i) {
            sum += hook.credit(creditors[i], token);
        }
        sum += hook.protocolOwed(token);
    }
}
