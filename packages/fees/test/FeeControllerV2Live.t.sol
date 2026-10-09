// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";

/**
 * END TO END, WITH REAL TRANSACTIONS AND NO MOCKS.
 *
 * The unit tests around this one use a `MockProtocolFees` that records calls. Useful, and not
 * proof of anything: a mock agrees with whatever I assumed when I wrote it, and every bug found
 * in this contract so far has been a WRONG ASSUMPTION about what core does — dynamic-fee pools
 * being exempt, `setProtocolFee` being unreachable, `collectProtocolFees` admitting only the
 * controller. A mock would have happily confirmed all three.
 *
 * So this test wires the real thing:
 *
 *     Vault -> registerApp -> CLPoolManager -> setProtocolFeeController(V2)
 *          -> initialize a pool  (core staticcalls V2 and STAMPS the fee)
 *          -> add liquidity
 *          -> a real swap        (core takes the protocol fee off the input)
 *          -> sweep()            (permissionless; real tokens reach the treasury)
 *
 * Every assertion below is read back off the deployed contracts rather than assumed.
 *
 * WHY NOT A MAINNET FORK, which would be better still: Robinhood Chain blocks carry none of the
 * Cancun header fields — no `excessBlobGas`, no `blobGasUsed`, not even `baseFeePerGas`. anvil
 * 1.8.1 refuses to serve calls against such a fork ("Excess blob gas not set") and
 * `--hardfork cancun` does not change it. Confirmed by reading a live block header. So the
 * closest available thing to live is this: the real contracts, the real EVM, real transactions,
 * on a local chain.
 */
contract FeeControllerV2LiveTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    Vault vault;
    CLPoolManager poolManager;
    CLPoolManagerRouter router;
    DeepCoreProtocolFeeControllerV2 controller;

    address governance = makeAddr("governanceSafe");
    address guardian = makeAddr("opsGuardian");
    address trader = makeAddr("trader");
    /// Nobody. Calls `sweep` to prove it needs no role.
    address stranger = makeAddr("stranger");

    PoolKey key;
    uint24 constant LP_FEE = 3000; // 0.30%
    int24 constant TICK_SPACING = 60;

    function setUp() public {
        initializeTokens();

        vault = new Vault();
        poolManager = new CLPoolManager(vault);
        // The gate that makes the whole model enforceable: an unregistered manager can move
        // nothing against the Vault.
        vault.registerApp(address(poolManager));
        router = new CLPoolManagerRouter(vault, poolManager);

        controller = new DeepCoreProtocolFeeControllerV2(governance, guardian);

        // `setProtocolFeeController` is onlyOwner on the manager; this test's deployer owns it.
        poolManager.setProtocolFeeController(controller);
        assertEq(address(poolManager.protocolFeeController()), address(controller));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: LP_FEE,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    /* ===================================================================== */

    /// The pool is STAMPED at initialize. This is the moment the fee is decided, for life.
    function test_Live_PoolIsBornWithTheProtocolFee() public {
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));

        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(key.toId());

        assertEq(lpFee, LP_FEE, "lp fee");
        // 999 pips in each direction, packed low-12 / high-12.
        assertEq(protocolFee & 0xFFF, 999, "zeroForOne");
        assertEq(protocolFee >> 12, 999, "oneForZero");
        assertEq(protocolFee, controller.protocolFeeForPool(key), "must match what the controller said");
    }

    /// The whole money path, end to end, with a real swap moving real tokens.
    function test_Live_SwapAccruesAndSweepReachesTheTreasury() public {
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));
        _addLiquidity();

        assertEq(poolManager.protocolFeesAccrued(currency0), 0, "nothing before the swap");

        BalanceDelta delta = _swap(true, 1 ether);

        uint256 accrued = poolManager.protocolFeesAccrued(currency0);
        assertGt(accrued, 0, "the swap must have accrued a protocol fee");

        /* 999 pips of what ACTUALLY swapped, not of what was requested. The liquidity here sits
           in a narrow range, so an exact-input swap stops at the edge of it and consumes less
           than asked — which is exactly why this asserts against the delta the pool reports
           rather than against the number handed to the router. Getting that wrong the first time
           made a correct contract look broken by 40%. */
        uint256 paid = uint256(uint128(-delta.amount0()));
        uint256 expected = (paid * 999) / 1_000_000;
        assertApproxEqAbs(accrued, expected, 1, "fee should be 0.0999% of the amount actually swapped");

        console.log("requested ", uint256(1 ether));
        console.log("paid      ", paid);
        console.log("accrued   ", accrued);
        console.log("expected  ", expected);

        // The accounting lives on the manager; the TOKENS are still in the Vault.
        assertEq(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(poolManager)),
            0,
            "tokens must not be sitting on the manager"
        );

        /* SWEEP. Called by a stranger with no role of any kind, which is the point. */
        uint256 before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(governance);
        vm.prank(stranger);
        uint256 swept = controller.sweep(address(poolManager), currency0);

        assertEq(swept, accrued, "sweep must move the whole accrued balance");
        assertEq(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(governance) - before,
            accrued,
            "the treasury must actually receive the tokens"
        );
        assertEq(poolManager.protocolFeesAccrued(currency0), 0, "accrual must be cleared");
    }

    /// Both directions accrue, in their own currency.
    function test_Live_BothDirectionsAccrueSeparately() public {
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));
        _addLiquidity();

        _swap(true, 1 ether);
        _swap(false, 1 ether);

        assertGt(poolManager.protocolFeesAccrued(currency0), 0, "currency0");
        assertGt(poolManager.protocolFeesAccrued(currency1), 0, "currency1");

        // One sweep per currency — the keeper job has to iterate.
        vm.startPrank(stranger);
        controller.sweep(address(poolManager), currency0);
        controller.sweep(address(poolManager), currency1);
        vm.stopPrank();

        assertEq(poolManager.protocolFeesAccrued(currency0), 0);
        assertEq(poolManager.protocolFeesAccrued(currency1), 0);
    }

    /// Sweeping an empty currency reverts, so a scheduled job that simulates first pays nothing.
    function test_Live_SweepOnEmptyRevertsRatherThanBurningGas() public {
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreProtocolFeeControllerV2.NothingToCollect.selector, address(poolManager), currency0
            )
        );
        vm.prank(stranger);
        controller.sweep(address(poolManager), currency0);
    }

    /// A pool created while the fee was zero, brought up to policy afterwards — against the
    /// real manager, which is the only thing that can confirm `setProtocolFee` is reachable.
    function test_Live_SyncPoolToPolicyRepricesALivePool() public {
        // Turn fees off, create the pool, turn them back on: the pool is stranded at zero.
        vm.prank(governance);
        controller.setFeesDisabled(true);
        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));

        (,, uint24 born,) = poolManager.getSlot0(key.toId());
        assertEq(born, 0, "born unpriced");

        vm.prank(governance);
        controller.setFeesDisabled(false);

        // Still zero — core never re-reads the controller.
        (,, uint24 stillZero,) = poolManager.getSlot0(key.toId());
        assertEq(stillZero, 0, "core does not re-read the controller");

        vm.prank(governance);
        controller.syncPoolToPolicy(address(poolManager), key);

        (,, uint24 fixed_,) = poolManager.getSlot0(key.toId());
        assertEq(fixed_ & 0xFFF, 999, "repriced to policy");
    }

    /// The guardian's power, exercised against a real pool.
    function test_Live_GuardianCanStopNewPoolsAccruing() public {
        vm.prank(guardian);
        controller.emergencyDisableFees();

        poolManager.initialize(key, TickMath.getSqrtRatioAtTick(0));
        (,, uint24 protocolFee,) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, 0, "a pool born during an incident pays nothing");
    }

    /* ===================================================================== */

    function _addLiquidity() internal {
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountSpecified, // negative == exact input
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }
}

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
