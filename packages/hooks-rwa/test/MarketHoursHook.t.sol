// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {MarketHoursModule} from "../src/modules/MarketHoursModule.sol";
import {IPriceBandOracle} from "../src/interfaces/IPriceBandOracle.sol";
import {ManualPriceBandOracle} from "../src/oracles/ManualPriceBandOracle.sol";

import {
    ConfigurablePriceOracle,
    RevertingPriceOracle,
    GasBombPriceOracle,
    ReturnBombPriceOracle,
    ShortReturnPriceOracle
} from "./mocks/PriceBandOracleMocks.sol";

/// @title MarketHoursHookTest
/// @notice Exercises the calendar, the halt and the price band in isolation, on the standalone
/// hook. The composition with the compliance gate is tested separately in `StockPairHook.t.sol`.
contract MarketHoursHookTest is Test, Deployers, TokenFixture {
    using LPFeeLibrary for uint24;

    Vault vault;
    CLPoolManager poolManager;
    MarketHoursHook hook;
    ManualPriceBandOracle priceOracle;
    CLPoolManagerRouter router;

    PoolKey key;
    PoolId poolId;

    address constant ISSUER = address(0x155);
    address constant GUARDIAN = address(0x6DA);
    address constant TRADER = address(0x7AD);
    address constant STRANGER = address(0x57A);

    uint24 constant STATIC_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 6000;
    int256 constant LIQUIDITY = 1000 ether;

    /// @dev 2024-01-01 00:00:00 UTC. A Monday - asserted, not assumed, in
    /// `test_calendar_weekdayArithmeticIsAnchoredToTheEpoch`.
    uint256 constant MONDAY_MIDNIGHT = 1_704_067_200;
    /// @dev 14:30 UTC, the UTC image of a 09:30 New York open during standard time.
    uint24 constant OPEN = 52_200;
    /// @dev 21:00 UTC.
    uint24 constant CLOSE = 75_600;
    /// @dev Monday..Friday, bit 0 = Sunday.
    uint8 constant WEEKDAYS = uint8((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5));

    /// @dev +/- 5%.
    uint32 constant BAND_PPM = 50_000;

    function setUp() public {
        vm.warp(MONDAY_MIDNIGHT + 16 hours); // inside Monday's session

        (vault, poolManager) = createFreshManager();
        hook = new MarketHoursHook(poolManager, address(this));
        priceOracle = new ManualPriceBandOracle(address(this));
        router = new CLPoolManagerRouter(vault, poolManager);

        initializeTokens();
        mint(1_000_000 ether);

        key = _key(STATIC_FEE);
        poolId = key.toId();

        hook.configureMarket(key, _defaultSettings());
        hook.setMarketGuardian(GUARDIAN);
        priceOracle.setReferencePrice(poolId, SQRT_RATIO_1_1);

        poolManager.initialize(key, SQRT_RATIO_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyPosition(key, _liquidityParams(LIQUIDITY), ZERO_BYTES);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: fee,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });
    }

    function _defaultSettings() internal view returns (MarketHoursModule.MarketSettings memory) {
        return MarketHoursModule.MarketSettings({
            issuer: ISSUER,
            oracle: IPriceBandOracle(address(priceOracle)),
            maxUpPpm: BAND_PPM,
            maxDownPpm: BAND_PPM,
            maxPriceAge: 1 days,
            openSecondOfDay: OPEN,
            closeSecondOfDay: CLOSE,
            weekdayMask: WEEKDAYS,
            sessionEnabled: true,
            bandEnabled: true,
            gateLiquidity: false
        });
    }

    function _liquidityParams(int256 liquidityDelta)
        internal
        pure
        returns (ICLPoolManager.ModifyLiquidityParams memory)
    {
        return ICLPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: liquidityDelta,
            salt: 0
        });
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    function _expectHookRevert(bytes4 hookFn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookFn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _currentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    function _setSettings(MarketHoursModule.MarketSettings memory settings) internal {
        hook.configureMarket(key, settings);
    }

    /// @dev Move the clock AND the feed. The calendar tests step days at a time, and a reference
    /// older than `maxPriceAge` is an oracle outage, which correctly stops the pool - so a bare
    /// `vm.warp` past the staleness window makes every swap after it revert in `afterSwap` for a
    /// reason that has nothing to do with the calendar under test. Staleness is exercised
    /// deliberately, and on its own, in `test_priceOracle_stalePriceFailsClosed`.
    ///
    /// Republished at the pool's starting price rather than its current one, so the band stays
    /// anchored exactly where `setUp` put it and the only variable moving is the date.
    function _warpAndRepublish(uint256 timestamp) internal {
        vm.warp(timestamp);
        priceOracle.setReferencePrice(poolId, SQRT_RATIO_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                         THE TRADING CALENDAR
    //////////////////////////////////////////////////////////////*/

    /// @notice The weekday arithmetic is `(dayIndex + 4) % 7`, which is only correct because Unix
    /// day 0 was a Thursday. Anchored here against a date anyone can check.
    function test_calendar_weekdayArithmeticIsAnchoredToTheEpoch() public view {
        assertEq(hook.dayIndexOf(0), 0);
        assertEq(hook.weekdayOf(0), 4, "1970-01-01 was a Thursday");

        uint32 monday = hook.dayIndexOf(MONDAY_MIDNIGHT);
        assertEq(hook.weekdayOf(monday), 1, "2024-01-01 was a Monday");
        assertEq(hook.weekdayOf(monday + 5), 6, "and that Saturday");
        assertEq(hook.weekdayOf(monday + 6), 0, "and that Sunday");
    }

    function test_calendar_tradesInsideTheSessionOnly() public {
        // Inside: 16:00 on a Monday.
        _swap(true, -1 ether);

        // One second before the open.
        vm.warp(MONDAY_MIDNIGHT + OPEN - 1);
        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.MarketClosed.selector, poolId, block.timestamp)
        );
        _swap(true, -1 ether);

        // At the open, inclusive.
        vm.warp(MONDAY_MIDNIGHT + OPEN);
        _swap(true, -1 ether);

        // At the close, exclusive.
        vm.warp(MONDAY_MIDNIGHT + CLOSE - 1);
        _swap(true, -1 ether);

        vm.warp(MONDAY_MIDNIGHT + CLOSE);
        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.MarketClosed.selector, poolId, block.timestamp)
        );
        _swap(true, -1 ether);
    }

    function test_calendar_weekendIsClosed() public {
        // Saturday, mid-session-hours.
        _warpAndRepublish(MONDAY_MIDNIGHT + 5 days + 16 hours);
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp));
        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.MarketClosed.selector, poolId, block.timestamp)
        );
        _swap(true, -1 ether);

        // Sunday.
        _warpAndRepublish(MONDAY_MIDNIGHT + 6 days + 16 hours);
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp));

        // Next Monday trades again.
        _warpAndRepublish(MONDAY_MIDNIGHT + 7 days + 16 hours);
        assertTrue(hook.isSessionOpenAt(poolId, block.timestamp));
        _swap(true, -1 ether);
    }

    function test_calendar_holidayClosesATradingDay() public {
        uint32 tuesday = hook.dayIndexOf(MONDAY_MIDNIGHT + 1 days);
        uint32[] memory days_ = new uint32[](1);
        days_[0] = tuesday;

        vm.prank(ISSUER);
        hook.setHolidays(poolId, days_);

        _warpAndRepublish(MONDAY_MIDNIGHT + 1 days + 16 hours);
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp));
        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.MarketClosed.selector, poolId, block.timestamp)
        );
        _swap(true, -1 ether);

        // Wednesday is untouched.
        _warpAndRepublish(MONDAY_MIDNIGHT + 2 days + 16 hours);
        _swap(true, -1 ether);

        // Clearing the override puts Tuesday back.
        vm.prank(ISSUER);
        hook.clearDayOverrides(poolId, days_);
        _warpAndRepublish(MONDAY_MIDNIGHT + 1 days + 16 hours);
        assertTrue(hook.isSessionOpenAt(poolId, block.timestamp));
    }

    /// @notice An override REPLACES the weekday mask rather than intersecting with it, which is
    /// how a special session on an otherwise-closed day is scheduled.
    function test_calendar_specialSessionOpensAnOtherwiseClosedDay() public {
        uint32 saturday = hook.dayIndexOf(MONDAY_MIDNIGHT + 5 days);
        uint32[] memory days_ = new uint32[](1);
        days_[0] = saturday;

        _warpAndRepublish(MONDAY_MIDNIGHT + 5 days + 15 hours);
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp));

        vm.prank(ISSUER);
        hook.setSpecialSessions(poolId, days_, uint24(14 hours), uint24(16 hours));

        assertTrue(hook.isSessionOpenAt(poolId, block.timestamp), "15:00 is inside 14:00-16:00");
        _swap(true, -1 ether);

        _warpAndRepublish(MONDAY_MIDNIGHT + 5 days + 17 hours);
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp), "17:00 is outside it");
    }

    /// @notice A half-day: the override narrows the window on a day that would otherwise be full.
    function test_calendar_halfDayNarrowsTheWindow() public {
        uint32 monday = hook.dayIndexOf(MONDAY_MIDNIGHT);
        uint32[] memory days_ = new uint32[](1);
        days_[0] = monday;

        vm.prank(ISSUER);
        hook.setSpecialSessions(poolId, days_, OPEN, uint24(18 hours));

        vm.warp(MONDAY_MIDNIGHT + 17 hours);
        assertTrue(hook.isSessionOpenAt(poolId, block.timestamp));

        vm.warp(MONDAY_MIDNIGHT + 19 hours);
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp), "closed early");
    }

    /// @notice A session that wraps past midnight is attributed to the day it OPENED on, so the
    /// weekday mask and the overrides are read for that day and not for the day the clock is in.
    function test_calendar_sessionWrappingPastMidnight() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.openSecondOfDay = uint24(22 hours);
        settings.closeSecondOfDay = uint24(4 hours);
        _setSettings(settings);

        // Monday 23:00 - inside the session that opened on Monday.
        assertTrue(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 23 hours));
        // Tuesday 02:00 - still inside Monday's session.
        assertTrue(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 1 days + 2 hours));
        // Tuesday 05:00 - Monday's session closed, Tuesday's has not opened.
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 1 days + 5 hours));
        // Saturday 02:00 - inside FRIDAY's session, because Friday is a trading day.
        assertTrue(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 5 days + 2 hours));
        // Sunday 02:00 - Saturday is not a trading day, so nothing opened to wrap into it.
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 6 days + 2 hours));
        // Monday 02:00 - Sunday is not a trading day either.
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 7 days + 2 hours));

        vm.warp(MONDAY_MIDNIGHT + 1 days + 2 hours);
        _swap(true, -1 ether);
    }

    /// @notice A holiday on the day a wrapping session OPENS closes the whole wrapped session,
    /// including the part that falls on the following calendar day.
    function test_calendar_holidayOnTheOpeningDayClosesTheWrappedTail() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.openSecondOfDay = uint24(22 hours);
        settings.closeSecondOfDay = uint24(4 hours);
        _setSettings(settings);

        uint32[] memory days_ = new uint32[](1);
        days_[0] = hook.dayIndexOf(MONDAY_MIDNIGHT);
        vm.prank(ISSUER);
        hook.setHolidays(poolId, days_);

        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 23 hours), "Monday evening closed");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 1 days + 2 hours), "and its tail");
    }

    function test_calendar_disabledSessionMeans24_7() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.sessionEnabled = false;
        _setSettings(settings);

        _warpAndRepublish(MONDAY_MIDNIGHT + 6 days + 3 hours); // Sunday, 03:00
        assertTrue(hook.isSessionOpenAt(poolId, block.timestamp));
        _swap(true, -1 ether);
    }

    function test_calendar_ambiguousWindowIsRejected() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.openSecondOfDay = OPEN;
        settings.closeSecondOfDay = OPEN;
        vm.expectRevert(
            abi.encodeWithSelector(MarketHoursModule.InvalidSessionWindow.selector, OPEN, OPEN)
        );
        _setSettings(settings);

        settings = _defaultSettings();
        settings.closeSecondOfDay = uint24(86_400);
        vm.expectRevert(
            abi.encodeWithSelector(MarketHoursModule.InvalidSessionWindow.selector, OPEN, uint24(86_400))
        );
        _setSettings(settings);

        settings = _defaultSettings();
        settings.weekdayMask = 0;
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.EmptyWeekdayMask.selector));
        _setSettings(settings);
    }

    /// Bit 7 names no weekday. `0x80` used to pass the `mask == 0` check and configure a pool that
    /// could never trade; `0xFF` stored a number the calendar never enforces as written.
    function test_calendar_reservedWeekdayBitIsRejectedByConfigureMarket() public {
        uint8[3] memory bad = [uint8(0x80), uint8(0xFF), uint8(0x81)];
        for (uint256 i = 0; i < bad.length; ++i) {
            MarketHoursModule.MarketSettings memory settings = _defaultSettings();
            settings.weekdayMask = bad[i];
            vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, bad[i]));
            _setSettings(settings);

            // Refused on a disabled session too: a reserved bit is meaningless in every mode, and
            // storing it would let the nonsense survive until somebody enabled the session.
            settings.sessionEnabled = false;
            vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, bad[i]));
            _setSettings(settings);
        }

        // A zero mask on a DISABLED session still means "no schedule" and is still accepted.
        MarketHoursModule.MarketSettings memory disabled = _defaultSettings();
        disabled.weekdayMask = 0;
        disabled.sessionEnabled = false;
        _setSettings(disabled);

        // Every day of the week, all seven valid bits, is accepted and trades on every day.
        MarketHoursModule.MarketSettings memory everyDay = _defaultSettings();
        everyDay.weekdayMask = 0x7F;
        _setSettings(everyDay);
        assertEq(hook.marketConfig(poolId).weekdayMask, 0x7F);
        for (uint256 d = 0; d < 7; ++d) {
            assertTrue(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + d * 1 days + OPEN), "0x7F trades every day");
        }
    }

    /// The same rule on the issuer's un-timelocked lever, which is the more reachable of the two.
    function test_calendar_reservedWeekdayBitIsRejectedBySetSessionHours() public {
        vm.startPrank(ISSUER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, uint8(0x80)));
        hook.setSessionHours(poolId, 0x80, OPEN, CLOSE);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, uint8(0xFF)));
        hook.setSessionHours(poolId, 0xFF, OPEN, CLOSE);
        // Zero keeps its own, more specific error.
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.EmptyWeekdayMask.selector));
        hook.setSessionHours(poolId, 0, OPEN, CLOSE);

        hook.setSessionHours(poolId, 0x7F, OPEN, CLOSE);
        vm.stopPrank();

        assertEq(hook.marketConfig(poolId).weekdayMask, 0x7F);
        vm.warp(MONDAY_MIDNIGHT + 6 days + 16 hours); // Sunday, in session
        assertTrue(hook.isTradable(poolId), "0x7F includes Sunday");
    }

    /// The property the guard exists for, over every possible mask and through both entry points:
    /// a mask that is ACCEPTED always yields at least one weekday on which the pool is actually in
    /// session, and a mask is REFUSED only if it is zero or sets a reserved bit - so the fix
    /// neither lets a dead calendar through nor rejects a live one.
    function testFuzz_calendar_anyAcceptedMaskHasATradingWeekday(uint8 mask, bool viaIssuer) public {
        bool accepted;
        if (viaIssuer) {
            vm.prank(ISSUER);
            try hook.setSessionHours(poolId, mask, OPEN, CLOSE) {
                accepted = true;
            } catch {}
        } else {
            MarketHoursModule.MarketSettings memory settings = _defaultSettings();
            settings.weekdayMask = mask;
            try hook.configureMarket(key, settings) {
                accepted = true;
            } catch {}
        }

        bool shouldAccept = mask != 0 && (mask & 0x80) == 0;
        assertEq(accepted, shouldAccept, "refused exactly the empty and reserved-bit masks");
        if (!accepted) return;

        assertEq(hook.marketConfig(poolId).weekdayMask, mask, "stored mask is the enforced mask");

        // Seven consecutive days cover every weekday exactly once.
        uint256 openDays;
        for (uint256 d = 0; d < 7; ++d) {
            uint256 inSession = MONDAY_MIDNIGHT + d * 1 days + OPEN;
            bool open = hook.isSessionOpenAt(poolId, inSession);
            // The weekday of `MONDAY_MIDNIGHT + d days` is (1 + d) % 7, 0 = Sunday.
            assertEq(open, ((mask >> ((1 + d) % 7)) & 1) == 1, "each set bit is exactly one open weekday");
            if (open) {
                ++openDays;
                vm.warp(inSession);
                assertTrue(hook.isTradable(poolId), "and the view a router reads agrees");
            }
        }
        assertGt(openDays, 0, "an accepted mask always has a trading weekday");
    }

    /// @notice The DST lever. The issuer holds it because a schedule change that queues behind a
    /// governance timelock arrives after the session it describes.
    function test_calendar_issuerCanRecutTheScheduleWithoutGovernance() public {
        vm.warp(MONDAY_MIDNIGHT + 13 hours + 45 minutes); // 13:45 - before the 14:30 open
        assertFalse(hook.isSessionOpenAt(poolId, block.timestamp));

        vm.prank(ISSUER);
        hook.setSessionHours(poolId, WEEKDAYS, uint24(13 hours + 30 minutes), uint24(20 hours));

        assertTrue(hook.isSessionOpenAt(poolId, block.timestamp), "summer time");
        _swap(true, -1 ether);
    }

    function test_calendar_strangerCannotTouchTheSchedule() public {
        uint32[] memory days_ = new uint32[](1);
        days_[0] = 0;

        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, STRANGER));
        hook.setSessionHours(poolId, WEEKDAYS, OPEN, CLOSE);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, STRANGER));
        hook.setHolidays(poolId, days_);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, STRANGER));
        hook.setSpecialSessions(poolId, days_, OPEN, CLOSE);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, STRANGER));
        hook.clearDayOverrides(poolId, days_);
        vm.stopPrank();

        // The guardian is a HALT key, not an operating key.
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, GUARDIAN));
        hook.setSessionHours(poolId, WEEKDAYS, OPEN, CLOSE);
    }

    /*//////////////////////////////////////////////////////////////
                                THE HALT
    //////////////////////////////////////////////////////////////*/

    function test_halt_issuerCanHaltAndResume() public {
        vm.prank(ISSUER);
        hook.halt(poolId, "news pending");
        assertFalse(hook.isTradable(poolId));

        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.TradingHalted.selector, poolId)
        );
        _swap(true, -1 ether);

        vm.prank(ISSUER);
        hook.resume(poolId);
        _swap(true, -1 ether);
    }

    /// @notice The asymmetry. The guardian may stop the market and may never start it.
    function test_halt_guardianCanHaltButNotResume() public {
        vm.prank(GUARDIAN);
        hook.halt(poolId, "feed anomaly");
        assertFalse(hook.isTradable(poolId));

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, GUARDIAN));
        hook.resume(poolId);

        assertFalse(hook.isTradable(poolId), "still halted");

        // Only a party with standing to reopen can reopen.
        vm.prank(ISSUER);
        hook.resume(poolId);
        assertTrue(hook.isTradable(poolId));
    }

    function test_halt_strangerCannotHalt() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotHaltAuthority.selector, STRANGER));
        hook.halt(poolId, "");
    }

    /// @notice Reconfiguring a halted market must not quietly reopen it. Reopening is its own call
    /// with its own event, so "the market reopened" is never a side effect of something else.
    function test_halt_survivesReconfiguration() public {
        vm.prank(ISSUER);
        hook.halt(poolId, "pending");

        _setSettings(_defaultSettings());
        assertTrue(hook.marketConfig(poolId).halted, "still halted after configureMarket");
        assertFalse(hook.isTradable(poolId));
    }

    /// @notice A halt stops trading. It must never stop an LP getting their capital back.
    function test_halt_neverBlocksAnExit() public {
        vm.prank(ISSUER);
        hook.halt(poolId, "indefinite");

        // Also close the market and kill the price oracle, so every stop is on at once.
        vm.warp(MONDAY_MIDNIGHT + 6 days); // Sunday
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(address(new RevertingPriceOracle()));
        _setSettings(settings);

        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        router.modifyPosition(key, _liquidityParams(-LIQUIDITY), ZERO_BYTES);
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), before0);
    }

    /// @notice `gateLiquidity` is off by default, so a halt does not freeze inventory unless the
    /// issuer asked for that.
    function test_halt_gateLiquidityIsOptIn() public {
        vm.prank(ISSUER);
        hook.halt(poolId, "");
        router.modifyPosition(key, _liquidityParams(1 ether), ZERO_BYTES); // permitted

        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.gateLiquidity = true;
        _setSettings(settings);

        _expectHookRevert(
            ICLHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(MarketHoursModule.TradingHalted.selector, poolId)
        );
        router.modifyPosition(key, _liquidityParams(1 ether), ZERO_BYTES);

        // ...and removal is STILL open, even with the gate on.
        router.modifyPosition(key, _liquidityParams(-1 ether), ZERO_BYTES);
    }

    function test_guardian_onlyOwnerCanAppointOne() public {
        vm.prank(ISSUER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketAdmin.selector, ISSUER));
        hook.setMarketGuardian(STRANGER);

        hook.setMarketGuardian(address(0)); // disabling the role is legal
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotHaltAuthority.selector, GUARDIAN));
        hook.halt(poolId, "");
    }

    /*//////////////////////////////////////////////////////////////
                            THE PRICE BAND
    //////////////////////////////////////////////////////////////*/

    function test_band_smallSwapInsideTheBandIsAccepted() public {
        _swap(true, -1 ether);
        (bool active, uint256 lower, uint256 upper) = hook.priceBand(poolId);
        assertTrue(active);
        assertEq(lower, 950_000);
        assertEq(upper, 1_050_000);
    }

    /// @notice The headline behaviour: a swap that would PRINT outside the band reverts.
    function test_band_swapThatPrintsBelowTheBandReverts() public {
        // ~11% down: comfortably through the 5% lower edge.
        _expectHookRevert(ICLHooks.afterSwap.selector, _bandBreachReason(true, -60 ether));
        _swap(true, -60 ether);

        // The pool is untouched: the revert unwound the whole swap.
        assertEq(_currentSqrtPrice(), SQRT_RATIO_1_1);
    }

    function test_band_swapThatPrintsAboveTheBandReverts() public {
        _expectHookRevert(ICLHooks.afterSwap.selector, _bandBreachReason(false, -60 ether));
        _swap(false, -60 ether);
        assertEq(_currentSqrtPrice(), SQRT_RATIO_1_1);
    }

    /// @notice THE RECOVERY PATH, and the reason the band is usable at all.
    ///
    /// The reference gaps to 4x overnight. The pool now sits far BELOW its own band. Without the
    /// converging exception every swap would revert, including the arbitrage that fixes it, and
    /// the safety control would have permanently bricked the pool.
    function test_band_convergingSwapIsAllowedWhileOutsideTheBand() public {
        priceOracle.setReferencePrice(poolId, SQRT_RATIO_4_1); // reference gaps up 4x

        (bool wouldRevert,) = hook.previewPriceBand(poolId, true, _currentSqrtPrice());
        assertTrue(wouldRevert, "a price-decreasing swap here diverges");

        // Diverging further down: refused.
        _expectHookRevert(ICLHooks.afterSwap.selector, _bandBreachReason(true, -1 ether));
        _swap(true, -1 ether);

        // Converging upward, still below the band at the end: permitted.
        _swap(false, -60 ether);
        assertGt(_currentSqrtPrice(), SQRT_RATIO_1_1, "the pool moved toward the reference");
    }

    /// @notice ...and once inside, the band binds again in both directions.
    function test_band_bindsAgainOnceInsideTheBand() public {
        priceOracle.setReferencePrice(poolId, SQRT_RATIO_4_1);
        _swap(false, -60 ether); // converge, still out of band

        priceOracle.setReferencePrice(poolId, _currentSqrtPrice()); // reference catches up
        _swap(false, -1 ether); // small move: fine
        _expectHookRevert(ICLHooks.afterSwap.selector, _bandBreachReason(false, -60 ether));
        _swap(false, -60 ether);
    }

    function test_band_disabledMeansNoOracleCallAndNoLimit() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.bandEnabled = false;
        settings.oracle = IPriceBandOracle(address(new RevertingPriceOracle()));
        _setSettings(settings);

        // A reverting oracle would stop everything if it were consulted. It is not.
        _swap(true, -60 ether);
    }

    function test_band_cannotBeEnabledWithoutAnOracle() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(address(0));
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.BandEnabledWithoutOracle.selector));
        _setSettings(settings);
    }

    function test_band_downBandWiderThanOneHundredPercentIsRejected() public {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.maxDownPpm = 1_000_001;
        vm.expectRevert(
            abi.encodeWithSelector(MarketHoursModule.InvalidBandWidth.selector, uint32(1_000_001))
        );
        _setSettings(settings);
    }

    /*//////////////////////////////////////////////////////////////
                 PRICE ORACLE FAILURE MODES - ALL CLOSED
    //////////////////////////////////////////////////////////////*/

    function test_priceOracle_revertingFailsClosed() public {
        _expectOracleUnavailable(address(new RevertingPriceOracle()));
    }

    function test_priceOracle_gasBombFailsClosed() public {
        _expectOracleUnavailable(address(new GasBombPriceOracle()));
    }

    function test_priceOracle_returnBombFailsClosed() public {
        _expectOracleUnavailable(address(new ReturnBombPriceOracle()));
    }

    function test_priceOracle_shortReturnFailsClosed() public {
        _expectOracleUnavailable(address(new ShortReturnPriceOracle()));
    }

    function test_priceOracle_notAContractFailsClosed() public {
        _expectOracleUnavailable(address(0xFEED));
    }

    function test_priceOracle_zeroPriceFailsClosed() public {
        ConfigurablePriceOracle configurable = new ConfigurablePriceOracle();
        configurable.set(0, uint64(block.timestamp));
        _expectOracleUnavailable(address(configurable));
    }

    function test_priceOracle_stalePriceFailsClosed() public {
        ConfigurablePriceOracle configurable = new ConfigurablePriceOracle();
        uint64 stamp = uint64(block.timestamp);
        configurable.set(SQRT_RATIO_1_1, stamp);

        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(address(configurable));
        settings.maxPriceAge = 3600;
        _setSettings(settings);

        _swap(true, -1 ether); // fresh

        vm.warp(block.timestamp + 3601);
        _expectHookRevert(
            ICLHooks.afterSwap.selector,
            abi.encodeWithSelector(
                MarketHoursModule.ReferencePriceStale.selector, stamp, uint32(3600), block.timestamp
            )
        );
        _swap(true, -1 ether);
    }

    /// @notice A reference dated in the future is treated as fresh. Publication clocks and block
    /// timestamps disagree by seconds routinely, and halting a market over that is the wrong
    /// failure to choose.
    function test_priceOracle_futureDatedReferenceIsTreatedAsFresh() public {
        ConfigurablePriceOracle configurable = new ConfigurablePriceOracle();
        configurable.set(SQRT_RATIO_1_1, uint64(block.timestamp + 600));

        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(address(configurable));
        settings.maxPriceAge = 60;
        _setSettings(settings);

        _swap(true, -1 ether);
    }

    function test_priceOracle_zeroMaxAgeDisablesTheFreshnessCheck() public {
        ConfigurablePriceOracle configurable = new ConfigurablePriceOracle();
        configurable.set(SQRT_RATIO_1_1, 1); // the epoch, essentially

        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(address(configurable));
        settings.maxPriceAge = 0;
        _setSettings(settings);

        _swap(true, -1 ether);
    }

    /// @notice A non-canonical return must not smuggle bits into the narrow fields. The oracle
    /// returns a `updatedAt` whose high bits are all set; masked, it is ancient and therefore
    /// stale, and the swap must be refused.
    function test_priceOracle_dirtyReturnBitsAreMasked() public {
        ConfigurablePriceOracle configurable = new ConfigurablePriceOracle();
        configurable.setRaw(
            bytes32(uint256(SQRT_RATIO_1_1)), bytes32(type(uint256).max << 64 | uint256(1))
        );

        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(address(configurable));
        settings.maxPriceAge = 3600;
        _setSettings(settings);

        _expectHookRevert(
            ICLHooks.afterSwap.selector,
            abi.encodeWithSelector(
                MarketHoursModule.ReferencePriceStale.selector, uint64(1), uint32(3600), block.timestamp
            )
        );
        _swap(true, -1 ether);
    }

    /// @notice Clearing the reference from the feed side stops the market, and still cannot trap
    /// an LP.
    function test_priceOracle_clearingTheReferenceStopsTradingButNotExits() public {
        priceOracle.clearReference(poolId);

        _expectHookRevert(
            ICLHooks.afterSwap.selector,
            abi.encodeWithSelector(
                MarketHoursModule.PriceOracleUnavailable.selector, address(priceOracle), poolId
            )
        );
        _swap(true, -1 ether);

        router.modifyPosition(key, _liquidityParams(-LIQUIDITY), ZERO_BYTES);
    }

    /*//////////////////////////////////////////////////////////////
                        PREVIEW / BAND ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    /// @notice `previewPriceBand` must agree with what `afterSwap` actually does, or every router
    /// pre-flighting a trade against it is lying to users.
    function testFuzz_previewPriceBand_agreesWithEnforcement(int128 amountIn, bool zeroForOne) public {
        int256 amount = -int256(bound(int256(amountIn), 1, 200 ether));

        (uint160 quoted,) = _quote(zeroForOne, amount);
        (bool wouldRevert, bytes memory reason) = hook.previewPriceBand(poolId, zeroForOne, quoted);

        if (wouldRevert) {
            _expectHookRevert(ICLHooks.afterSwap.selector, reason);
            _swap(zeroForOne, amount);
        } else {
            _swap(zeroForOne, amount);
            assertEq(_currentSqrtPrice(), quoted, "the quote matched the print");
        }
    }

    /// @notice The band edges are exact. A price ratio at the edge is inside; one PPM beyond is
    /// outside. Checked directly on the preview, which shares the arithmetic with enforcement.
    function test_band_edgesAreExact() public view {
        // sqrt(1.05) * 2**96, computed off-chain and asserted to land at 1_050_000 PPM.
        uint160 justInsideUpper = _sqrtRatioForPpm(1_049_900);
        uint160 justOutsideUpper = _sqrtRatioForPpm(1_050_100);

        (bool insideReverts,) = hook.previewPriceBand(poolId, false, justInsideUpper);
        assertFalse(insideReverts, "1.0499x is inside a +5% band");

        (bool outsideReverts,) = hook.previewPriceBand(poolId, false, justOutsideUpper);
        assertTrue(outsideReverts, "1.0501x is outside it");
    }

    /*//////////////////////////////////////////////////////////////
                        LIFECYCLE / REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_rejectsUnconfiguredPool() public {
        PoolKey memory other = _key(STATIC_FEE + 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(MarketHoursModule.MarketNotConfigured.selector, other.toId()),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(other, SQRT_RATIO_1_1);
    }

    function test_initialize_rejectsDynamicFeePool() public {
        PoolKey memory dynamicKey = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketHoursHook.PoolMustUseStaticFee.selector, LPFeeLibrary.DYNAMIC_FEE_FLAG
            )
        );
        hook.configureMarket(dynamicKey, _defaultSettings());
    }

    function test_configureMarket_rejectsForeignKeysAndZeroIssuer() public {
        PoolKey memory foreign = _key(STATIC_FEE);
        foreign.hooks = IHooks(address(0xF00));
        vm.expectRevert(abi.encodeWithSelector(MarketHoursHook.HookMismatch.selector, address(0xF00)));
        hook.configureMarket(foreign, _defaultSettings());

        foreign = _key(STATIC_FEE);
        foreign.poolManager = ICLPoolManager(address(0xF01));
        vm.expectRevert(abi.encodeWithSelector(MarketHoursHook.PoolManagerMismatch.selector, address(0xF01)));
        hook.configureMarket(foreign, _defaultSettings());

        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.issuer = address(0);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.MarketZeroAddress.selector));
        _setSettings(settings);
    }

    function test_configureMarket_onlyOwner() public {
        vm.prank(ISSUER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketAdmin.selector, ISSUER));
        hook.configureMarket(key, _defaultSettings());
    }

    function test_registrationBitmap() public view {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        assertEq(bitmap, uint16(1 | 4 | 64 | 128), "beforeInitialize|beforeAdd|beforeSwap|afterSwap");
        assertEq(bitmap & uint16(0xFC00), 0, "no delta or reserved bits");
        // beforeRemoveLiquidity (bit 4) is deliberately NOT registered: nothing in this hook may
        // ever block an exit, so core is never even given the chance to ask.
        assertEq(bitmap & uint16(16), 0, "no beforeRemoveLiquidity");
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _expectOracleUnavailable(address badOracle) internal {
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.oracle = IPriceBandOracle(badOracle);
        _setSettings(settings);

        _expectHookRevert(
            ICLHooks.afterSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.PriceOracleUnavailable.selector, badOracle, poolId)
        );
        _swap(true, -1 ether);

        // The exit is unaffected by any of it.
        router.modifyPosition(key, _liquidityParams(-1 ether), ZERO_BYTES);
    }

    /// @dev Simulate a swap and report the price it would end at, then roll the state back.
    function _quote(bool zeroForOne, int256 amountSpecified) internal returns (uint160 endPrice, bool ok) {
        uint256 snapshot = vm.snapshotState();
        MarketHoursModule.MarketSettings memory settings = _defaultSettings();
        settings.bandEnabled = false;
        _setSettings(settings);
        _swap(zeroForOne, amountSpecified);
        endPrice = _currentSqrtPrice();
        ok = true;
        vm.revertToState(snapshot);
    }

    function _bandBreachReason(bool zeroForOne, int256 amountSpecified) internal returns (bytes memory) {
        (uint160 endPrice,) = _quote(zeroForOne, amountSpecified);
        (, bytes memory reason) = hook.previewPriceBand(poolId, zeroForOne, endPrice);
        require(reason.length != 0, "expected a breach");
        return reason;
    }

    /// @dev The `sqrtPriceX96` whose squared ratio against the 1:1 reference is `ppm`.
    function _sqrtRatioForPpm(uint256 ppm) internal pure returns (uint160) {
        // sqrt(ppm / 1e6) * 2**96, via integer sqrt on a scaled value.
        uint256 scaled = (ppm << 192) / 1_000_000;
        return uint160(_sqrt(scaled));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
