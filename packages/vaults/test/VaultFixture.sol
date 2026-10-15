// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {DeepCoreVaultFactory} from "../src/DeepCoreVaultFactory.sol";
import {MockOracle} from "./mocks/Mocks.sol";

abstract contract VaultFixture is Test {
    using CLPoolParametersHelper for bytes32;

    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;
    int24 internal constant SPACING = 10;
    uint256 internal constant CREATE_FEE = 0.075 ether;
    uint16 internal constant PERF_BPS = 1_000;
    uint16 internal constant CURATOR_BPS = 500;
    uint32 internal constant NOTICE = 7 days;

    address internal SAFE = makeAddr("safe");
    address internal CURATOR = makeAddr("curator");
    address internal ALICE = makeAddr("alice");
    address internal BOB = makeAddr("bob");
    address internal KEEPER = makeAddr("keeper");
    address internal STRANGER = makeAddr("stranger");

    Vault internal vault;
    CLPoolManager internal cl;
    CLPoolManagerRouter internal router;
    MockERC20 internal t0;
    MockERC20 internal t1;
    Currency internal c0;
    Currency internal c1;
    MockOracle internal oracle;

    DeepCoreManagedVault internal impl;
    DeepCoreVaultFactory internal factory;

    PoolKey internal key; // t0/t1 on the mock oracle hook
    PoolKey internal keyNative; // native/t1 on the mock oracle hook

    DeepCoreManagedVault internal mv; // the vault on `key`

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vault = new Vault();
        cl = new CLPoolManager(IVault(address(vault)));
        vault.registerApp(address(cl));
        router = new CLPoolManagerRouter(IVault(address(vault)), ICLPoolManager(address(cl)));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        c0 = Currency.wrap(address(t0));
        c1 = Currency.wrap(address(t1));
        oracle = new MockOracle();

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        impl = new DeepCoreManagedVault(predicted, ICLPoolManager(address(cl)));
        factory = new DeepCoreVaultFactory(
            address(impl), SAFE, SAFE, CREATE_FEE, CREATE_FEE * 10, NOTICE, PERF_BPS, 2_000
        );
        assertEq(address(factory), predicted, "factory address");

        address[6] memory people = [address(this), ALICE, BOB, KEEPER, STRANGER, CURATOR];
        for (uint256 i; i < people.length; ++i) {
            t0.mint(people[i], 1e30);
            t1.mint(people[i], 1e30);
            vm.deal(people[i], 1e24);
            vm.startPrank(people[i]);
            t0.approve(address(router), type(uint256).max);
            t1.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        key = _key(c0, c1, address(oracle));
        cl.initialize(key, SQRT_1_1);
        _addCL(key, -60000, 60000, 1e22, 0);

        keyNative = _key(Currency.wrap(address(0)), c1, address(oracle));
        cl.initialize(keyNative, SQRT_1_1);
        _addCL(keyNative, -60000, 60000, 1e22, 1e24);

        mv = _create(CURATOR, key, key, _config(), bytes32("v1"));
        _approveAll(address(mv));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(Currency a, Currency b, address hook) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: a,
            currency1: b,
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(cl)),
            fee: 3000,
            parameters: bytes32(0).setTickSpacing(SPACING)
        });
    }

    function _config() internal pure returns (DeepCoreManagedVault.Config memory) {
        return DeepCoreManagedVault.Config({
            baseHalfWidth: 1000,
            limitWidth: 1000,
            maxDeviation: 100,
            rebalanceThreshold: 500,
            twapWindow: 1800,
            cooldown: 3600,
            curatorFeeBps: CURATOR_BPS
        });
    }

    function _create(address creator, PoolKey memory k, PoolKey memory ok, DeepCoreManagedVault.Config memory cfg, bytes32 salt)
        internal
        returns (DeepCoreManagedVault v)
    {
        k.poolManager = IPoolManager(address(cl));
        ok.poolManager = IPoolManager(address(cl));
        vm.prank(creator);
        v = DeepCoreManagedVault(
            payable(
                factory.createVault{value: CREATE_FEE}(
                    DeepCoreManagedVault.VaultParams({key: k, oracleKey: ok, config: cfg}), salt
                )
            )
        );
    }

    function _approveAll(address spender) internal {
        address[6] memory people = [address(this), ALICE, BOB, KEEPER, STRANGER, CURATOR];
        for (uint256 i; i < people.length; ++i) {
            vm.startPrank(people[i]);
            t0.approve(spender, type(uint256).max);
            t1.approve(spender, type(uint256).max);
            vm.stopPrank();
        }
    }

    function _addCL(PoolKey memory k, int24 lower, int24 upper, int256 liq, uint256 value) internal {
        k.poolManager = IPoolManager(address(cl));
        router.modifyPosition{value: value}(
            k, ICLPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liq, salt: 0}), ""
        );
    }

    /// @dev Swap until the price reaches `targetTick`.
    function _swapToTick(PoolKey memory k, int24 targetTick) internal {
        k.poolManager = IPoolManager(address(cl));
        (uint160 sqrtP,,,) = cl.getSlot0(k.toId());
        uint160 lim = TickMath.getSqrtRatioAtTick(targetTick);
        if (sqrtP == lim) return;
        bool zeroForOne = lim < sqrtP;
        uint256 value = k.currency0.isNative() && zeroForOne ? 1e23 : 0;
        router.swap{value: value}(
            k,
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e23, sqrtPriceLimitX96: lim}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev Trade back and forth to accrue LP fees without moving the price much.
    function _churn(PoolKey memory k, uint256 rounds, int256 amount) internal {
        k.poolManager = IPoolManager(address(cl));
        for (uint256 i; i < rounds; ++i) {
            router.swap(
                k,
                ICLPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
                }),
                CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                ""
            );
            router.swap(
                k,
                ICLPoolManager.SwapParams({
                    zeroForOne: false, amountSpecified: -amount, sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
                }),
                CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                ""
            );
        }
    }

    function _tick(PoolKey memory k) internal view returns (int24 t) {
        k.poolManager = IPoolManager(address(cl));
        (, t,,) = cl.getSlot0(k.toId());
    }

    function _seed(DeepCoreManagedVault v, address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,,) = v.depositInitial(amount, amount, 0, who, block.timestamp);
    }

    function _deposit(DeepCoreManagedVault v, address who, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        vm.prank(who);
        (a0, a1) = v.deposit(shares, type(uint256).max, type(uint256).max, who, block.timestamp);
    }

    function _withdraw(DeepCoreManagedVault v, address who, uint256 shares) internal returns (uint256 a0, uint256 a1) {
        vm.prank(who);
        (a0, a1) = v.withdraw(shares, 0, 0, who, block.timestamp);
    }
}
