// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";

/// @dev A Pyth stand-in. Only `getPriceUnsafe` matters; the adapter calls nothing else.
contract MockPyth is IPyth {
    IPyth.Price internal _p;
    bool public reverts;

    function set(int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        _p = IPyth.Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function getPriceUnsafe(bytes32) external view override returns (IPyth.Price memory) {
        require(!reverts, "pyth down");
        return _p;
    }

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 1;
    }
}

/// @dev Exposes the internal conversion, plus the single-scale formula the adapter used before the
/// high-ratio branch existed, so the two can be compared input for input.
contract PythAdapterHarness is PythPriceBandAdapter {
    constructor(IPyth pyth_) PythPriceBandAdapter(pyth_, msg.sender) {}

    function toSqrtPriceX96(uint256 price, int32 expo, Feed memory feed) external pure returns (uint256) {
        return _toSqrtPriceX96(price, expo, feed);
    }

    /// The pre-fix body of `_toSqrtPriceX96`'s final step, verbatim.
    function singleScale(uint256 num, uint256 den) external pure returns (uint256) {
        uint256 ratioX192 = Math.mulDiv(num, 1 << 192, den);
        return Math.sqrt(ratioX192);
    }
}

contract PythPriceBandAdapterTest is Test {
    MockPyth pyth;
    PythPriceBandAdapter adapter;
    PythAdapterHarness harness;

    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));
    bytes32 constant AAPL_USD = bytes32(uint256(0xAAAA));
    address constant KEEPER = address(uint160(0xBEEF));

    uint256 constant NOW = 1_800_000_000;

    function setUp() public {
        vm.warp(NOW);
        pyth = new MockPyth();
        adapter = new PythPriceBandAdapter(IPyth(address(pyth)), address(this));
        harness = new PythAdapterHarness(IPyth(address(pyth)));
    }

    /// 18-decimal RWA token as currency0, 6-decimal USDC as currency1. AAPL at $189.50.
    function _configureAaplBase() internal {
        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: AAPL_USD,
                baseIsCurrency0: true,
                baseDecimals: 18,
                quoteDecimals: 6,
                maxConfBps: 100, // 1%
                maxPublishAge: 300
            })
        );
    }

    function _publishAapl() internal {
        // $189.50 with Pyth's usual 8-decimal exponent, and a tight 0.05% confidence.
        pyth.set(18_950_000_000, 9_475_000, -8, NOW);
    }

    /*//////////////////////////////////////////////////////////////
      THE CONVERSION. The interface warns this is what goes wrong.
    //////////////////////////////////////////////////////////////*/

    /// The number the adapter produces must be the number core would store in `slot0` for a pool
    /// genuinely trading at $189.50, derived here independently rather than copied from the
    /// implementation.
    function test_conversion_matchesAPoolTradingAtThatPrice() public {
        _configureAaplBase();
        _publishAapl();

        (uint160 got,) = adapter.refresh(POOL);

        // Independent derivation. One whole RWA token (1e18 base units) is worth 189.50 USDC,
        // i.e. 189_500_000 quote base units. So currency1-per-currency0 = 189.5e6 / 1e18.
        uint256 expected = Math.sqrt(Math.mulDiv(189_500_000, 1 << 192, 1e18));

        assertEq(uint256(got), expected, "sqrtPriceX96 must match an independent derivation");
        assertGt(uint256(got), TickMath.MIN_SQRT_RATIO);
        assertLt(uint256(got), TickMath.MAX_SQRT_RATIO);
    }

    /// The whole point of `baseIsCurrency0`. Flipping it must produce the RECIPROCAL price, not
    /// the same number — if these two ever agree, the band inverts for one of the orderings and
    /// the pool rejects every swap in one direction.
    function test_conversion_tokenOrderingInvertsTheRatio() public {
        _configureAaplBase();
        _publishAapl();
        (uint160 baseIs0,) = adapter.refresh(POOL);

        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: AAPL_USD,
                baseIsCurrency0: false, // the stablecoin sorted lower
                baseDecimals: 18,
                quoteDecimals: 6,
                maxConfBps: 100,
                maxPublishAge: 300
            })
        );
        (uint160 baseIs1,) = adapter.refresh(POOL);

        assertTrue(baseIs0 != baseIs1, "ordering must change the answer");

        // sqrt(R) * sqrt(1/R) == 1, so the product of the two X96 values is 2**192 up to the
        // rounding of two integer square roots.
        uint256 product = Math.mulDiv(uint256(baseIs0), uint256(baseIs1), 1 << 96);
        uint256 unity = 1 << 96;
        uint256 diff = product > unity ? product - unity : unity - product;
        assertLt(diff, unity / 1_000_000, "the two orderings must be reciprocals");
    }

    /// Decimals matter as much as ordering: the same human price against a 18-decimal quote is a
    /// different pool ratio than against a 6-decimal one.
    function test_conversion_quoteDecimalsChangeTheRatio() public {
        _configureAaplBase();
        _publishAapl();
        (uint160 sixDp,) = adapter.refresh(POOL);

        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: AAPL_USD,
                baseIsCurrency0: true,
                baseDecimals: 18,
                quoteDecimals: 18,
                maxConfBps: 100,
                maxPublishAge: 300
            })
        );
        (uint160 eighteenDp,) = adapter.refresh(POOL);

        // 1e12 more quote units per base unit is 1e6 more in sqrt space.
        assertApproxEqRel(uint256(eighteenDp), uint256(sixDp) * 1e6, 1e12);
    }

    /*//////////////////////////////////////////////////////////////
                        FAIL CLOSED, EVERY TIME
    //////////////////////////////////////////////////////////////*/

    /// Never refreshed reads as unavailable, which halts the pool rather than skipping the band.
    function test_failClosed_unrefreshedReadsAsZero() public {
        _configureAaplBase();
        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        assertEq(t, 0);
    }

    function test_failClosed_unconfiguredPoolCannotRefresh() public {
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceBandAdapter.FeedNotConfigured.selector, POOL)
        );
        adapter.refresh(POOL);
    }

    function test_failClosed_nonPositivePriceRejected() public {
        _configureAaplBase();
        pyth.set(-1, 1, -8, NOW);
        vm.expectRevert(abi.encodeWithSelector(PythPriceBandAdapter.NonPositivePrice.selector, int64(-1)));
        adapter.refresh(POOL);
    }

    function test_failClosed_stalePythPriceRejected() public {
        _configureAaplBase();
        pyth.set(18_950_000_000, 1, -8, NOW - 301);
        vm.expectRevert();
        adapter.refresh(POOL);
    }

    /// A wide confidence interval is Pyth saying its publishers disagree. Trading through that is
    /// exactly when a circuit breaker should not be quiet.
    function test_failClosed_wideConfidenceRejected() public {
        _configureAaplBase();
        // 2% confidence against a 1% bound.
        pyth.set(18_950_000_000, 379_000_000, -8, NOW);
        vm.expectRevert();
        adapter.refresh(POOL);
    }

    /// A reverting Pyth must not be swallowed into a zero or a stale success.
    function test_failClosed_pythRevertPropagates() public {
        _configureAaplBase();
        pyth.setReverts(true);
        vm.expectRevert();
        adapter.refresh(POOL);
    }

    /// A failed refresh leaves the PREVIOUS cache untouched — it does not zero it. Staleness is
    /// then the consumer's call, via the publish time this adapter reports.
    function test_failedRefreshLeavesThePreviousCacheIntact() public {
        _configureAaplBase();
        _publishAapl();
        (uint160 good,) = adapter.refresh(POOL);

        pyth.setReverts(true);
        vm.expectRevert();
        adapter.refresh(POOL);

        (uint160 still,) = adapter.referencePrice(POOL);
        assertEq(still, good, "a failed refresh must not corrupt the cache");
    }

    /// Removing a feed must clear the cache too. A pool still quoting a price whose source has
    /// been withdrawn is the one state that would let trading continue against nothing.
    function test_removeFeed_clearsTheCachedPrice() public {
        _configureAaplBase();
        _publishAapl();
        adapter.refresh(POOL);

        adapter.removeFeed(POOL);

        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, 0, "cache must be cleared with the feed");
        assertEq(t, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// Choosing the feed is the trust decision and is owner-only.
    function test_access_onlyOwnerConfigures() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, KEEPER));
        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: AAPL_USD,
                baseIsCurrency0: true,
                baseDecimals: 18,
                quoteDecimals: 6,
                maxConfBps: 100,
                maxPublishAge: 300
            })
        );
    }

    /// Executing it is not. Anyone may refresh, and cannot influence the outcome.
    function test_access_refreshIsPermissionless() public {
        _configureAaplBase();
        _publishAapl();

        vm.prank(KEEPER);
        (uint160 byKeeper,) = adapter.refresh(POOL);

        (uint160 byOwner,) = adapter.refresh(POOL);
        assertEq(byKeeper, byOwner, "the caller cannot change the answer");
    }

    function test_config_rejectsNonsense() public {
        PythPriceBandAdapter.Feed memory f = PythPriceBandAdapter.Feed({
            priceId: AAPL_USD,
            baseIsCurrency0: true,
            baseDecimals: 18,
            quoteDecimals: 6,
            maxConfBps: 0,
            maxPublishAge: 300
        });
        vm.expectRevert();
        adapter.configureFeed(POOL, f);

        f.maxConfBps = 10_000; // 100% is not a bound
        vm.expectRevert();
        adapter.configureFeed(POOL, f);

        f.maxConfBps = 100;
        f.maxPublishAge = 0;
        vm.expectRevert();
        adapter.configureFeed(POOL, f);
    }

    /*//////////////////////////////////////////////////////////////
                              GAS BUDGET
    //////////////////////////////////////////////////////////////*/

    /// `referencePrice` runs inside a Vault lock, reached by `staticcall` under
    /// `MarketHoursModule.PRICE_ORACLE_GAS_LIMIT` (200,000). Exceeding that budget makes the
    /// oracle read as unavailable and halts the pool, so its cost is a correctness property, not
    /// an optimisation.
    ///
    /// This measures the WHOLE external call — dispatch, calldata, the SLOAD and ABI-encoding the
    /// return — because that is what the module actually pays. The bound is a fraction of the real
    /// budget rather than a round number: what matters is the enormous margin, since the storage
    /// layout puts `sqrtPriceX96` and `publishTime` in one slot and there is nothing else to read.
    /// Audit B L-1: the cached price used to be served at any age. A consumer configured with
    /// `maxPriceAge == 0` then had no staleness check at all.
    function test_FIX_referencePrice_failsClosedOnceTheCacheIsOlderThanMaxPublishAge() public {
        _configureAaplBase();
        _publishAapl();
        adapter.refresh(POOL);
        (uint160 fresh, uint64 at) = adapter.referencePrice(POOL);
        assertGt(fresh, 0, "fresh cache is served");

        vm.warp(uint256(at) + 300); // exactly maxPublishAge: still served
        (uint160 edge,) = adapter.referencePrice(POOL);
        assertEq(edge, fresh);

        vm.warp(uint256(at) + 301); // one second past: unavailable, with no transaction
        (uint160 stale, uint64 staleAt) = adapter.referencePrice(POOL);
        assertEq(stale, 0, "stale cache must read as unavailable");
        assertEq(staleAt, 0);
    }

    function test_referencePrice_fitsTheModulesGasBudget() public {
        _configureAaplBase();
        _publishAapl();
        adapter.refresh(POOL);

        adapter.referencePrice(POOL); // warm the slot, as a real second swap would find it
        uint256 before = gasleft();
        adapter.referencePrice(POOL);
        uint256 warm = before - gasleft();

        emit log_named_uint("referencePrice gas, warm slot", warm);
        emit log_named_uint("PRICE_ORACLE_GAS_LIMIT", 200_000);

        // Two orders of magnitude of headroom. A regression that added a loop or an external call
        // would blow through this long before it reached the module's real cap.
        assertLt(warm, 20_000, "must stay far inside PRICE_ORACLE_GAS_LIMIT");
    }

    /// The cold case is the one the module actually hits on the first swap of a block.
    function test_referencePrice_coldReadAlsoFits() public {
        _configureAaplBase();
        _publishAapl();
        adapter.refresh(POOL);

        uint256 before = gasleft();
        adapter.referencePrice(POOL);
        uint256 cold = before - gasleft();

        emit log_named_uint("referencePrice gas, cold slot", cold);
        assertLt(cold, 30_000, "a cold read must still fit the budget with room to spare");
    }

    /// The reported timestamp is Pyth's, not the refresh time. A cache written now from an old
    /// price is an old price, and the consumer's staleness window must see that.
    function test_reportsPythPublishTimeNotRefreshTime() public {
        _configureAaplBase();
        uint256 published = NOW - 120;
        pyth.set(18_950_000_000, 1, -8, published);

        vm.warp(NOW + 30);
        adapter.refresh(POOL);

        (, uint64 reported) = adapter.referencePrice(POOL);
        assertEq(uint256(reported), published, "must report Pyth's publish time");
    }

    /*//////////////////////////////////////////////////////////////
      RANGE. Every price core can represent is priced; every price it
      cannot is refused with an error that names this adapter.
    //////////////////////////////////////////////////////////////*/

    function _configure(bool baseIs0, uint8 baseDecimals, uint8 quoteDecimals) internal {
        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: AAPL_USD,
                baseIsCurrency0: baseIs0,
                baseDecimals: baseDecimals,
                quoteDecimals: quoteDecimals,
                maxConfBps: 100,
                maxPublishAge: 300
            })
        );
    }

    /// conf 0 so the confidence bound never interferes with a range test.
    function _publishRaw(uint256 price, int32 expo) internal {
        pyth.set(int64(uint64(price)), 0, expo, NOW);
    }

    /// Independent reimplementation of the rational, for fuzzing against the adapter.
    function _ratio(uint256 price, int32 expo, uint8 bd, uint8 qd, bool baseIs0)
        internal
        pure
        returns (uint256 num, uint256 den)
    {
        num = price;
        den = 1;
        if (qd >= bd) num *= 10 ** uint256(qd - bd);
        else den *= 10 ** uint256(bd - qd);
        if (expo >= 0) num *= 10 ** uint256(uint32(expo));
        else den *= 10 ** uint256(uint32(-expo));
        if (!baseIs0) (num, den) = (den, num);
    }

    function _feed(bool baseIs0, uint8 bd, uint8 qd) internal pure returns (PythPriceBandAdapter.Feed memory) {
        return PythPriceBandAdapter.Feed({
            priceId: AAPL_USD,
            baseIsCurrency0: baseIs0,
            baseDecimals: bd,
            quoteDecimals: qd,
            maxConfBps: 100,
            maxPublishAge: 300
        });
    }

    /// THE REPORTED BUG, pinned. A 0-decimal security token (ERC-3643-style) at a human price of 100
    /// against an 18-decimal stablecoin: R = 1e20 >= 2**64, sqrtPriceX96 = 1e10 * 2**96, comfortably
    /// inside core's range. The pre-fix single-scale formula cannot compute it and reverts with
    /// OpenZeppelin's generic `MathOverflowedMulDiv()` (0x227bc153) — observed against the unfixed
    /// adapter's `refresh` before this test was written. The adapter must now price it exactly.
    function test_REPRO_representableHighRatioWasUnpriceable() public {
        PythAdapterHarness h = harness;

        // The old formula: generic library error, no adapter selector, no cause.
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        h.singleScale(100e18, 1);

        _configure(true, 0, 18);
        _publishRaw(100, 0);
        (uint160 got,) = adapter.refresh(POOL);
        assertEq(uint256(got), 1e10 << 96, "R = 1e20 must give exactly 1e10 * 2**96");
    }

    /// Same pool ratio reached through the other token ordering: stablecoin as currency0, so the
    /// rational is swapped. R = 1e36 / 1e16 = 1e20 again.
    function test_highRatio_invertedOrientationIsPriced() public {
        _configure(false, 36, 0);
        _publishRaw(1e16, 0);
        (uint160 got,) = adapter.refresh(POOL);
        assertEq(uint256(got), 1e10 << 96);
    }

    /// Two ratios either side of 2**64 take different code paths and must stay ordered and
    /// adjacent. The one below must be bit-identical to the pre-fix formula.
    function test_branchBoundary_continuousAndLowSideUnchanged() public {
        PythAdapterHarness h = harness;
        _configure(true, 0, 0);

        // R = 18446744073709551610 = 2**64 - 6
        _publishRaw(1_844_674_407_370_955_161, 1);
        (uint160 below,) = adapter.refresh(POOL);
        assertEq(uint256(below), h.singleScale(18_446_744_073_709_551_610, 1), "low side must be unchanged");

        // R = 18446744073709551620 = 2**64 + 4: the old formula overflows here.
        vm.expectRevert(Math.MathOverflowedMulDiv.selector);
        h.singleScale(18_446_744_073_709_551_620, 1);

        _publishRaw(1_844_674_407_370_955_162, 1);
        (uint160 above,) = adapter.refresh(POOL);
        assertEq(uint256(above), 340_282_366_920_938_463_500_268_095_570_597_380_096);
        assertLt(uint256(below), uint256(above), "monotonic across the branch");
        assertApproxEqRel(uint256(below), uint256(above), 1);
    }

    /// UPPER LIMIT, baseIsCurrency0 = true. num = price * 1e20, den = 1. Boundary prices found by
    /// bisection offline against the TickMath constants.
    function test_upperLimit_baseIsCurrency0_justInsideAndJustOutside() public {
        _configure(true, 0, 18);

        _publishRaw(3_402_567_868_363_880_940, 2);
        (uint160 inside,) = adapter.refresh(POOL);
        assertEq(uint256(inside), 1_461_446_703_485_210_103_135_564_080_088_006_363_106_114_535_424);
        assertLe(uint256(inside), TickMath.MAX_SQRT_RATIO);

        _publishRaw(3_402_567_868_363_880_941, 2);
        uint256 outside = 1_461_446_703_485_210_103_350_320_516_994_574_857_566_156_750_848;
        assertGt(outside, TickMath.MAX_SQRT_RATIO);
        vm.expectRevert(abi.encodeWithSelector(PythPriceBandAdapter.PriceOutOfRange.selector, outside));
        adapter.refresh(POOL);
    }

    /// UPPER LIMIT, baseIsCurrency0 = false. After the swap num = 1e57, den = price, so the ratio
    /// FALLS as the price rises and the boundary is approached from the other side.
    function test_upperLimit_inverted_justInsideAndJustOutside() public {
        _configure(false, 36, 9);

        _publishRaw(2_938_956_807_585_584_839, -30);
        (uint160 inside,) = adapter.refresh(POOL);
        assertEq(uint256(inside), 1_461_446_703_485_210_103_213_532_627_543_526_419_600_137_781_248);
        assertLe(uint256(inside), TickMath.MAX_SQRT_RATIO);

        _publishRaw(2_938_956_807_585_584_838, -30);
        uint256 outside = 1_461_446_703_485_210_103_462_166_207_273_781_025_219_836_641_280;
        vm.expectRevert(abi.encodeWithSelector(PythPriceBandAdapter.PriceOutOfRange.selector, outside));
        adapter.refresh(POOL);
    }

    /// LOWER LIMIT, baseIsCurrency0 = true. num = price, den = 1e57. Unchanged by the fix (the low
    /// branch), pinned so it stays that way.
    function test_lowerLimit_baseIsCurrency0_justInsideAndJustOutside() public {
        _configure(true, 36, 9);

        _publishRaw(2_938_956_808_774_311_201, -30);
        (uint160 inside,) = adapter.refresh(POOL);
        assertEq(uint256(inside), TickMath.MIN_SQRT_RATIO, "lands exactly on MIN_SQRT_RATIO");

        _publishRaw(2_938_956_808_774_311_200, -30);
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceBandAdapter.PriceOutOfRange.selector, uint256(TickMath.MIN_SQRT_RATIO) - 1)
        );
        adapter.refresh(POOL);
    }

    /// LOWER LIMIT, baseIsCurrency0 = false. num = 1, den = price * 1e20.
    function test_lowerLimit_inverted_justInsideAndJustOutside() public {
        _configure(false, 0, 18);

        _publishRaw(3_402_567_866_987_636_788, 2);
        (uint160 inside,) = adapter.refresh(POOL);
        assertEq(uint256(inside), TickMath.MIN_SQRT_RATIO);

        _publishRaw(3_402_567_866_987_636_789, 2);
        vm.expectRevert(
            abi.encodeWithSelector(PythPriceBandAdapter.PriceOutOfRange.selector, uint256(TickMath.MIN_SQRT_RATIO) - 1)
        );
        adapter.refresh(POOL);
    }

    /// A ratio so small its root floors to zero is already attributable: PriceOutOfRange(0).
    /// num = 1, den = 1e66.
    function test_lowerLimit_rootFloorsToZeroIsAttributable() public {
        _configure(true, 36, 0);
        _publishRaw(1, -30);
        vm.expectRevert(abi.encodeWithSelector(PythPriceBandAdapter.PriceOutOfRange.selector, uint256(0)));
        adapter.refresh(POOL);
    }

    /// The 2**130 overflow guard. num = price * 1e21, den = 1. Just below it the ratio is still
    /// computed (and refused by the TickMath check); at it, refused before computing.
    function test_ratioGuard_justBelowAndAt2Pow130() public {
        _configure(true, 0, 21);

        _publishRaw(1_361_129_467_683_753_853, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythPriceBandAdapter.PriceOutOfRange.selector,
                uint256(2_923_003_274_661_805_835_490_932_704_716_283_019_509_903_654_912)
            )
        );
        adapter.refresh(POOL);

        _publishRaw(1_361_129_467_683_753_854, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PythPriceBandAdapter.RatioUnrepresentable.selector, uint256(1_361_129_467_683_753_854e21), uint256(1)
            )
        );
        adapter.refresh(POOL);
    }

    /// The largest ratio the configuration space allows, via the inverted orientation.
    /// num = 1e36 * 1e30 = 1e66, den = 1.
    function test_ratioGuard_invertedExtremeIsAttributable() public {
        _configure(false, 36, 0);
        _publishRaw(1, -30);
        vm.expectRevert(abi.encodeWithSelector(PythPriceBandAdapter.RatioUnrepresentable.selector, uint256(1e66), 1));
        adapter.refresh(POOL);
        vm.expectRevert(abi.encodeWithSelector(PythPriceBandAdapter.RatioUnrepresentable.selector, uint256(1e66), 1));
        adapter.previewRefresh(POOL);
    }

    /// The guard can never refuse a representable price: any R >= 2**130 has
    /// sqrt(R) * 2**96 >= 2**161 > MAX_SQRT_RATIO. Derived from the constant, not assumed.
    function test_ratioGuard_sitsStrictlyBeyondCoreRange() public pure {
        uint256 maxWholeRoot = (uint256(TickMath.MAX_SQRT_RATIO) >> 96) + 1; // > sqrt(R_max)
        assertLe(maxWholeRoot * maxWholeRoot, uint256(1) << 130);
        assertLt(uint256(TickMath.MAX_SQRT_RATIO), uint256(1) << 161);
    }

    /// An out-of-range price never reaches the cache: the previous good reference survives.
    function test_failClosed_outOfRangeLeavesPreviousCacheIntact() public {
        _configure(true, 0, 21);
        _publishRaw(1, 0); // R = 1e21, in range
        (uint160 good, uint64 goodAt) = adapter.refresh(POOL);

        vm.warp(NOW + 10);
        pyth.set(int64(uint64(1_361_129_467_683_753_854)), 0, 0, NOW + 10);
        vm.expectRevert();
        adapter.refresh(POOL);

        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, good);
        assertEq(t, goodAt);
    }

    /// NO BEHAVIOUR CHANGE for anything the old formula could compute. The branch condition is
    /// exactly the old overflow condition: where the old formula succeeded the new output is
    /// bit-identical; where it reverted, it reverted with the generic library error.
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: legacy.fuzz.runs = 4096
    function testFuzz_conversion_bitIdenticalWhereverOldFormulaSucceeded(
        uint64 rawPrice,
        int32 rawExpo,
        uint8 bd,
        uint8 qd,
        bool baseIs0
    ) public view {
        PythAdapterHarness h = harness;
        uint256 price = bound(uint256(rawPrice), 1, uint256(uint64(type(int64).max)));
        int32 expo = int32(bound(int256(rawExpo), -30, 12));
        bd = uint8(bound(bd, 0, 36));
        qd = uint8(bound(qd, 0, 36));

        (uint256 num, uint256 den) = _ratio(price, expo, bd, qd, baseIs0);

        try h.singleScale(num, den) returns (uint256 old) {
            assertEq(h.toSqrtPriceX96(price, expo, _feed(baseIs0, bd, qd)), old, "in-range output changed");
            assertLt(num >> 64, den, "old formula succeeded, so R < 2**64");
        } catch (bytes memory err) {
            assertEq(bytes4(err), Math.MathOverflowedMulDiv.selector, "old formula's only failure");
            assertGe(num >> 64, den, "old formula overflowed exactly when R >= 2**64");
        }
    }

    /// `refresh` either writes an in-range price or reverts with one of the adapter's own range
    /// errors. Never a library panic, over the whole configuration space, both orientations.
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: legacy.fuzz.runs = 4096
    function testFuzz_refresh_neverRevertsUnattributably(
        uint64 rawPrice,
        int32 rawExpo,
        uint8 bd,
        uint8 qd,
        bool baseIs0
    ) public {
        uint256 price = bound(uint256(rawPrice), 1, uint256(uint64(type(int64).max)));
        int32 expo = int32(bound(int256(rawExpo), -30, 12));
        bd = uint8(bound(bd, 0, 36));
        qd = uint8(bound(qd, 0, 36));

        _configure(baseIs0, bd, qd);
        _publishRaw(price, expo);

        try adapter.refresh(POOL) returns (uint160 sqrtPriceX96, uint64) {
            assertGe(uint256(sqrtPriceX96), TickMath.MIN_SQRT_RATIO);
            assertLe(uint256(sqrtPriceX96), TickMath.MAX_SQRT_RATIO);
            (uint160 cached,) = adapter.referencePrice(POOL);
            assertEq(cached, sqrtPriceX96);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == PythPriceBandAdapter.PriceOutOfRange.selector
                    || sel == PythPriceBandAdapter.RatioUnrepresentable.selector,
                "refresh reverted with something other than a named range error"
            );
            (uint160 cached,) = adapter.referencePrice(POOL);
            assertEq(cached, 0, "nothing may be cached on a refused price");
        }
    }

    /// Independent check on the reduced-scale branch, which the old formula cannot cross-check:
    /// the two orientations are reciprocals, so sqrt(R) * sqrt(1/R) * 2**192 == 2**192 up to the
    /// flooring of each side (at most 2**33 units on the reduced branch, 1 unit otherwise).
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: legacy.fuzz.runs = 4096
    function testFuzz_conversion_orientationsAreReciprocal(uint64 rawPrice, int32 rawExpo, uint8 bd, uint8 qd)
        public
        view
    {
        PythAdapterHarness h = harness;
        uint256 price = bound(uint256(rawPrice), 1, uint256(uint64(type(int64).max)));
        int32 expo = int32(bound(int256(rawExpo), -30, 12));
        bd = uint8(bound(bd, 0, 36));
        qd = uint8(bound(qd, 0, 36));

        uint256 s0;
        uint256 s1;
        try h.toSqrtPriceX96(price, expo, _feed(true, bd, qd)) returns (uint256 v) {
            s0 = v;
        } catch {
            return; // R >= 2**130 on this side
        }
        try h.toSqrtPriceX96(price, expo, _feed(false, bd, qd)) returns (uint256 v) {
            s1 = v;
        } catch {
            return;
        }
        vm.assume(s0 != 0 && s1 != 0);

        uint256 unity = 1 << 96;
        uint256 product = Math.mulDiv(s0, s1, unity);
        assertLe(product, unity, "both sides floor, so the product cannot exceed 2**192");
        // s = S - e with 0 <= e < eMax, where eMax is 2**33 on the reduced branch (s >= 2**128)
        // and 1 on the single-scale branch. S0 * S1 = 2**192, so
        // 2**192 - s0 * s1 <= e0 * S1 + e1 * S0, plus one unit for the mulDiv floor.
        uint256 e0 = s0 >= (uint256(1) << 128) ? (uint256(1) << 33) : 1;
        uint256 e1 = s1 >= (uint256(1) << 128) ? (uint256(1) << 33) : 1;
        uint256 maxDeficit = Math.mulDiv(e0, s1 + e1, unity) + Math.mulDiv(e1, s0 + e0, unity) + 2;
        assertGe(product + maxDeficit, unity, "orientations must be reciprocals");
    }
}
