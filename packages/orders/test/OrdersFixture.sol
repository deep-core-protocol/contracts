// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";
import {BinTestHelper} from "infinity-core/test/pool-bin/helpers/BinTestHelper.sol";

import {DeepCoreRangeOrders} from "../src/DeepCoreRangeOrders.sol";
import {DeepCoreDCA} from "../src/DeepCoreDCA.sol";

abstract contract OrdersFixture is BinTestHelper {
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    int24 internal constant SPACING = 10;
    uint16 internal constant FEE_BPS = 10;
    uint16 internal constant MAX_FEE_BPS = 50;
    uint32 internal constant NOTICE = 7 days;

    address internal SAFE = makeAddr("safe");
    address internal ALICE = makeAddr("alice");
    address internal BOB = makeAddr("bob");
    address internal KEEPER = makeAddr("keeper");
    address internal SITE = makeAddr("site");
    address internal STRANGER = makeAddr("stranger");
    /// @dev A launch guard named to the orders contract at construction (address-list rule).
    address internal LISTED_GUARD = makeAddr("listedGuard");

    Vault internal vault;
    CLPoolManager internal cl;
    BinPoolManager internal bin;
    CLPoolManagerRouter internal router;
    BinSwapHelper internal binSwapper;
    BinLiquidityHelper internal binLiq;

    MockERC20 internal t0;
    MockERC20 internal t1;
    Currency internal c0;
    Currency internal c1;

    PoolKey internal keyCL;
    PoolKey internal keyNative; // native / t1
    PoolKey internal keyBin;

    DeepCoreRangeOrders internal orders;
    DeepCoreDCA internal dca;

    /// @dev The core test router refunds unused native to its caller.
    receive() external payable {}

    function setUp() public virtual {
        vault = new Vault();
        cl = new CLPoolManager(IVault(address(vault)));
        bin = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(cl));
        vault.registerApp(address(bin));
        router = new CLPoolManagerRouter(IVault(address(vault)), ICLPoolManager(address(cl)));
        binSwapper = new BinSwapHelper(IBinPoolManager(address(bin)), IVault(address(vault)));
        binLiq = new BinLiquidityHelper(IBinPoolManager(address(bin)), IVault(address(vault)));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        c0 = Currency.wrap(address(t0));
        c1 = Currency.wrap(address(t1));

        address[] memory guards = new address[](1);
        guards[0] = LISTED_GUARD;
        orders =
            new DeepCoreRangeOrders(ICLPoolManager(address(cl)), SAFE, SAFE, FEE_BPS, MAX_FEE_BPS, NOTICE, guards);
        dca = new DeepCoreDCA(
            ICLPoolManager(address(cl)), IBinPoolManager(address(bin)), SAFE, SAFE, FEE_BPS, MAX_FEE_BPS, NOTICE
        );

        address[6] memory people = [address(this), ALICE, BOB, KEEPER, SITE, STRANGER];
        for (uint256 i; i < people.length; ++i) {
            t0.mint(people[i], 1e30);
            t1.mint(people[i], 1e30);
            vm.deal(people[i], 1e24);
            vm.startPrank(people[i]);
            t0.approve(address(router), type(uint256).max);
            t1.approve(address(router), type(uint256).max);
            t0.approve(address(binSwapper), type(uint256).max);
            t1.approve(address(binSwapper), type(uint256).max);
            t0.approve(address(binLiq), type(uint256).max);
            t1.approve(address(binLiq), type(uint256).max);
            t0.approve(address(orders), type(uint256).max);
            t1.approve(address(orders), type(uint256).max);
            t0.approve(address(dca), type(uint256).max);
            t1.approve(address(dca), type(uint256).max);
            vm.stopPrank();
        }

        keyCL = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(cl)),
            fee: 3000,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
        cl.initialize(keyCL, SQRT_1_1);
        _addCL(keyCL, -6000, 6000, 1e21, 0);

        keyNative = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: c1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(cl)),
            fee: 3000,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
        cl.initialize(keyNative, SQRT_1_1);
        _addCL(keyNative, -6000, 6000, 1e21, 1e24);

        keyBin = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(bin)),
            fee: 3000,
            parameters: bytes32(0).setBinStep(10)
        });
        bin.initialize(keyBin, ID_ONE);
        (IBinPoolManager.MintParams memory mp,) = _getMultipleBinMintParams(ID_ONE, 1e22, 1e22, 10, 10);
        binLiq.mint(keyBin, mp, "");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addCL(PoolKey memory key, int24 lower, int24 upper, int256 liq, uint256 value) internal {
        router.modifyPosition{value: value}(
            key, ICLPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: 0}), ""
        );
    }

    /// @dev Swap on a CL pool until the price reaches `targetTick` (exact input large, price-limited).
    function _swapToTick(PoolKey memory key, int24 targetTick) internal {
        (, int24 tick,,) = cl.getSlot0(key.toId());
        if (tick == targetTick) return;
        bool zeroForOne = targetTick < tick;
        uint160 limit = TickMath.getSqrtRatioAtTick(targetTick);
        uint256 value = key.currency0.isNative() && zeroForOne ? 1e23 : 0;
        router.swap{value: value}(
            key,
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e23, sqrtPriceLimitX96: limit}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = cl.getSlot0(key.toId());
    }

    function _place(address maker, PoolKey memory key, int24 tickLower, bool zeroForOne, uint256 amount, uint128 tip)
        internal
        returns (uint256 orderId, uint256 epochId, uint128 liq)
    {
        return _placeWith(maker, key, tickLower, zeroForOne, amount, tip, address(0), 0);
    }

    function _placeWith(
        address maker,
        PoolKey memory key,
        int24 tickLower,
        bool zeroForOne,
        uint256 amount,
        uint128 tip,
        address integrator,
        uint16 integratorBps
    ) internal returns (uint256 orderId, uint256 epochId, uint128 liq) {
        bool nativeIn = zeroForOne && key.currency0.isNative();
        vm.prank(maker);
        (orderId, epochId, liq) = orders.place{value: nativeIn ? amount + tip : 0}(
            DeepCoreRangeOrders.PlaceParams({
                key: key,
                tickLower: tickLower,
                zeroForOne: zeroForOne,
                amountIn: amount,
                tip: tip,
                integrator: integrator,
                integratorBps: integratorBps
            })
        );
    }

    function _dcaParams(PoolKey memory key, bool zeroForOne, uint128 amount, uint128 tip, uint32 slices)
        internal
        view
        returns (DeepCoreDCA.CreateParams memory p)
    {
        p = DeepCoreDCA.CreateParams({
            key: key,
            zeroForOne: zeroForOne,
            amountPerSlice: amount,
            tipPerSlice: tip,
            slices: slices,
            interval: 1 hours,
            startAt: 0,
            deadline: uint64(block.timestamp + 30 days),
            minPriceX96: (uint256(1) << 96) / 2, // at least 0.5 out per 1 in
            recipient: ALICE,
            integrator: address(0),
            integratorBps: 0
        });
    }

    function _balance(Currency c, address who) internal view returns (uint256) {
        return c.balanceOf(who);
    }
}
