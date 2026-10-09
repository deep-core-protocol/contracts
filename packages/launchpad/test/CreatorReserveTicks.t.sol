// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";

import {CreatorReserve} from "../src/CreatorReserve.sol";

/// @dev The three position-manager reads `CreatorReserve` makes, and nothing else.
contract TickMockPositionManager {
    address public owner;
    PoolKey internal _key;
    mapping(uint256 => int24) public lower;
    mapping(uint256 => int24) public upper;

    function set(address owner_, PoolKey memory key_) external {
        owner = owner_;
        _key = key_;
    }

    function setRange(uint256 tokenId, int24 lo, int24 hi) external {
        lower[tokenId] = lo;
        upper[tokenId] = hi;
    }

    /// @dev The reserve checks `ownerOf(tokenId) == address(this)` from its constructor, so the
    /// caller IS the owner by construction. Avoids predicting a CREATE address.
    function ownerOf(uint256) external view returns (address) {
        return msg.sender;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (PoolKey memory, int24, int24, uint128, uint256, uint256, address)
    {
        return (_key, lower[tokenId], upper[tokenId], 0, 0, 0, address(0));
    }

    /// @dev Zero: `harvest` then skips the position-manager call, which is all these tests need.
    function getPositionLiquidity(uint256) external pure returns (uint128) {
        return 0;
    }
}

/// @dev `getSlot0` with a settable tick.
contract TickMockPoolManager {
    int24 public tick;

    function setTick(int24 t) external {
        tick = t;
    }

    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24) {
        return (1 << 96, tick, 0, 0);
    }
}

/**
 * ####### LOW: A RUNG AT `tick == tickLower` IS NOT CLEARED #######
 *
 * Core keeps a position in range for `tickLower <= tick < tickUpper` (`CLPool`). When the
 * launch token is currency1 the ladder sits below spot and sells as price falls, so a rung
 * is fully converted to quote only once `tick < tickLower`. The reserve used `<=`, harvested a
 * rung still holding unsold launch token at `tick == tickLower`, and `withdraw` pays quote only,
 * so the remainder stranded. The constructor had the mirror off-by-one: a currency0 rung with
 * `tickLower == tick` is IN range, not on the selling side.
 *
 * Every `test_FIX_*` below fails against the pre-fix comparisons. MUTATION-CHECKED: restoring
 * `<=` in `_cleared`, or `>=` in the constructor's side check, turns the matching test red.
 */
contract CreatorReserveTicksTest is Test {
    TickMockPositionManager posm;
    TickMockPoolManager pm;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;

    address constant PAYOUT = address(0xA11CE);

    function setUp() public {
        posm = new TickMockPositionManager();
        pm = new TickMockPoolManager();
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(pm)),
            fee: 3000,
            parameters: bytes32(uint256(60) << 16)
        });
    }

    /// @dev Builds a one-rung reserve over [lo, hi) at spot `tick`, the launch token on `launchSide`.
    function _build(int24 lo, int24 hi, int24 tick, bool launchIsC0) internal returns (CreatorReserve r) {
        posm.set(address(0), key);
        posm.setRange(1, lo, hi);
        pm.setTick(tick);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        r = new CreatorReserve(
            ICLPositionManager(address(posm)),
            key,
            launchIsC0 ? key.currency0 : key.currency1,
            PAYOUT,
            ids,
            4,
            72 hours
        );
    }

    /*------------------------------ launch token = currency1 ------------------------------*/

    function test_FIX_currency1RungAtTickLowerIsNotCleared() public {
        CreatorReserve r = _build(-600, -540, 0, false); // below spot: the right side for currency1
        pm.setTick(-600); // == tickLower: still in range, still holds unsold launch token
        (,,,, bool cleared) = r.rungState(0);
        assertFalse(cleared, "tick == tickLower is in range");
        assertEq(r.harvestableCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.RungNotCleared.selector, 0, int24(-600), int24(-600)));
        r.harvest(0);
        assertEq(r.harvestAll(), 0);
        assertFalse(r.rungAt(0).harvested, "harvestAll must skip it too");
    }

    function test_currency1RungOneTickBelowIsCleared() public {
        CreatorReserve r = _build(-600, -540, 0, false);
        pm.setTick(-601);
        (,,,, bool cleared) = r.rungState(0);
        assertTrue(cleared);
        assertEq(r.harvestableCount(), 1);
        r.harvest(0);
        assertTrue(r.rungAt(0).harvested);
    }

    function test_currency1RungMustSitAtOrBelowSpot() public {
        // tickUpper == tick is out of range below spot: accepted.
        _build(-600, 0, 0, false);
        // tickUpper above spot straddles it: refused.
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.RungOnTheWrongSide.selector, 0));
        this.buildExternal(-600, 60, 0, false);
    }

    /*------------------------------ launch token = currency0 ------------------------------*/

    function test_FIX_currency0RungWithTickLowerAtSpotIsRefused() public {
        // tickLower == tick: core puts the position IN range, so it already holds quote currency.
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.RungOnTheWrongSide.selector, 0));
        this.buildExternal(0, 60, 0, true);
        // One tick below the rung is out of range above: accepted.
        _build(60, 120, 59, true);
    }

    function test_currency0ClearsAtTickUpperExactly() public {
        CreatorReserve r = _build(60, 120, 0, true);
        pm.setTick(119);
        (,,,, bool cleared) = r.rungState(0);
        assertFalse(cleared);
        pm.setTick(120); // == tickUpper: out of range above, all currency1
        (,,,, cleared) = r.rungState(0);
        assertTrue(cleared);
        assertEq(r.harvestableCount(), 1);
    }

    function testFuzz_clearedMatchesCoreRange(int24 tick, bool launchIsC0) public {
        tick = int24(bound(tick, -2000, 2000));
        CreatorReserve r = launchIsC0 ? _build(60, 120, 0, true) : _build(-600, -540, 0, false);
        pm.setTick(tick);
        (int24 lo, int24 hi,,, bool cleared) = r.rungState(0);
        // Fully converted means out of core's [lo, hi) range on the far side of the sell direction.
        bool expected = launchIsC0 ? tick >= hi : tick < lo;
        assertEq(cleared, expected);
    }

    function buildExternal(int24 lo, int24 hi, int24 tick, bool launchIsC0) external returns (CreatorReserve) {
        return _build(lo, hi, tick, launchIsC0);
    }
}

/// @notice The boundary `_cleared` encodes, measured against REAL core rather than asserted: what a
/// position over [lo, hi) actually holds when `slot0.tick` sits exactly on each edge. The mock
/// suite above proves `CreatorReserve` follows the rule; this proves the rule is core's.
contract CreatorReserveCoreBoundaryTest is Test, Deployers, TokenFixture {
    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;

    int24 internal constant LO = -600;
    int24 internal constant HI = -540;

    function setUp() public {
        (vault, manager) = createFreshManager();
        router = new CLPoolManagerRouter(vault, manager);
        initializeTokens();
        mint(1e30);
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    /// @dev Fresh pool at `sqrtPriceX96` (distinct fee per call), then add liquidity over [LO, HI)
    /// and return what core charged in each currency.
    function _depositAt(uint160 sqrtPriceX96, uint24 fee) internal returns (int24 tick, int128 a0, int128 a1) {
        PoolKey memory k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: manager,
            fee: fee,
            parameters: bytes32(uint256(60) << 16)
        });
        manager.initialize(k, sqrtPriceX96);
        (, tick,,) = manager.getSlot0(k.toId());
        (BalanceDelta d,) = router.modifyPosition(
            k, ICLPoolManager.ModifyLiquidityParams({tickLower: LO, tickUpper: HI, liquidityDelta: 1e18, salt: 0}), ""
        );
        return (tick, d.amount0(), d.amount1());
    }

    /// Launch token = currency1, selling downward. At `tick == tickLower` with the price above the
    /// edge, core still holds currency1 in the position: the rung is NOT fully sold. This is the
    /// unsold remainder the pre-fix `currentTick <= tickLower` harvested and stranded.
    function test_CORE_tickAtTickLowerStillHoldsCurrency1() public {
        (int24 tick,, int128 a1) = _depositAt(TickMath.getSqrtRatioAtTick(LO) + 1e12, 3000);
        assertEq(tick, LO, "slot0.tick sits exactly on tickLower");
        assertTrue(a1 != 0, "in range: the position still holds currency1");
    }

    /// One tick lower, core holds none: `tick < tickLower` is the first fully-sold state.
    function test_CORE_tickBelowTickLowerHoldsNoCurrency1() public {
        (int24 tick,, int128 a1) = _depositAt(TickMath.getSqrtRatioAtTick(LO) - 1, 3001);
        assertEq(tick, LO - 1);
        assertEq(a1, 0, "below range: all currency0");
    }

    /// Launch token = currency0, selling upward. At `tick == tickUpper` core holds no currency0, so
    /// the non-strict `>=` there is correct, and `tick == tickUpper - 1` still holds some.
    function test_CORE_currency0SideTickAtTickUpperHoldsNoCurrency0() public {
        (int24 tick, int128 a0,) = _depositAt(TickMath.getSqrtRatioAtTick(HI), 3002);
        assertEq(tick, HI);
        assertEq(a0, 0, "at tickUpper: out of range above, all currency1");

        (tick, a0,) = _depositAt(TickMath.getSqrtRatioAtTick(HI) - 1e12, 3003);
        assertEq(tick, HI - 1);
        assertTrue(a0 != 0, "one tick below tickUpper: still holds currency0");
    }

    /// The constructor's mirror: a currency0 rung with `tickLower == tick` is in range at birth and
    /// already holds currency1, so it is not a clean sell-side rung.
    function test_CORE_currency0RungWithTickLowerAtSpotHoldsCurrency1() public {
        (int24 tick,, int128 a1) = _depositAt(TickMath.getSqrtRatioAtTick(LO) + 1e12, 3004);
        assertEq(tick, LO);
        assertTrue(a1 != 0, "tickLower == tick is in range, not above spot");
    }
}
