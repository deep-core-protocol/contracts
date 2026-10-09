// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IPriceBandOracle} from "../src/interfaces/IPriceBandOracle.sol";
import {ChainlinkPriceBandAdapter} from "../src/oracles/ChainlinkPriceBandAdapter.sol";
import {ChainlinkCrossPriceBandAdapter} from "../src/oracles/ChainlinkCrossPriceBandAdapter.sol";

import {MockAggregator, MockSequencerFeed, PRICE_ORACLE_GAS_LIMIT} from "./ChainlinkPriceBandAdapter.t.sol";

contract StrayToken is ERC20 {
    constructor() ERC20("Stray", "STRAY") {
        _mint(msg.sender, 1e24);
    }
}

/// The two-feed adapter: a stock priced in dollars, paired with a quote that is NOT worth a dollar
/// (the native currency). Every expected value here is derived independently of the contract.
contract ChainlinkCrossPriceBandAdapterTest is Test {
    MockAggregator stockFeed; // NVDA / USD, 8 decimals
    MockAggregator nativeFeed; // ETH / USD, 8 decimals
    MockSequencerFeed sequencer;
    ChainlinkCrossPriceBandAdapter adapter; // sequencer feed configured
    ChainlinkCrossPriceBandAdapter bare; // no sequencer feed

    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));
    PoolId constant OTHER_POOL = PoolId.wrap(bytes32(uint256(2)));
    address constant KEEPER = address(uint160(0xBEEF));
    address constant STRANGER = address(uint160(0xBAD));

    uint256 constant NOW = 1_800_000_000;
    uint32 constant GRACE = 3600;
    uint32 constant STOCK_HEARTBEAT = 1 days;
    uint32 constant NATIVE_HEARTBEAT = 1 hours;
    int256 constant NVDA = 230_00000000; // $230.00
    int256 constant ETH = 2_500_00000000; // $2,500.00

    function setUp() public {
        vm.warp(NOW);
        stockFeed = new MockAggregator(8, "NVDA / USD");
        nativeFeed = new MockAggregator(8, "ETH / USD");
        sequencer = new MockSequencerFeed(0, NOW - 10 days);
        adapter = new ChainlinkCrossPriceBandAdapter(address(sequencer), GRACE, address(this));
        bare = new ChainlinkCrossPriceBandAdapter(address(0), 0, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// A stock/native pool: native is address(0), always currency0, so the stock is currency1.
    function _feed() internal view returns (ChainlinkCrossPriceBandAdapter.CrossFeed memory) {
        return ChainlinkCrossPriceBandAdapter.CrossFeed({
            quoteAggregator: address(nativeFeed),
            baseHeartbeat: STOCK_HEARTBEAT,
            quoteHeartbeat: NATIVE_HEARTBEAT,
            baseIsCurrency0: false,
            baseDecimals: 18,
            quoteDecimals: 18,
            baseFeedDecimals: 8,
            baseAggregator: address(stockFeed),
            quoteFeedDecimals: 8
        });
    }

    function _configure() internal {
        adapter.configureFeed(POOL, _feed());
    }

    function _publish() internal {
        stockFeed.set(NVDA, NOW);
        nativeFeed.set(ETH, NOW);
    }

    function _ready() internal {
        _configure();
        _publish();
        adapter.refresh(POOL);
    }

    /*//////////////////////////////////////////////////////////////
                    THE CONVERSION: the part that goes wrong
    //////////////////////////////////////////////////////////////*/

    /// Native is currency0 and the stock is currency1, both 18 decimals. One NVDA is 230 / 2500 ETH,
    /// so currency1 per currency0 (NVDA per ETH) is 2500 / 230.
    function test_conversion_stockAgainstNative_matchesIndependentArithmetic() public {
        _configure();
        _publish();
        (uint160 got,,) = adapter.refresh(POOL);
        uint256 expected = Math.sqrt(Math.mulDiv(2500, 1 << 192, 230));
        assertEq(uint256(got), expected, "NVDA per ETH = 2500 / 230");
        assertGt(uint256(got), TickMath.MIN_SQRT_RATIO);
        assertLt(uint256(got), TickMath.MAX_SQRT_RATIO);
    }

    /// The same two prices with the base as currency0 (a wrapped quote that sorts higher): quote per
    /// base is 230 / 2500, the reciprocal. If the two cases agreed the direction flag would be dead.
    function test_conversion_directionFlagInvertsTheRatio() public {
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        f.baseIsCurrency0 = true;
        adapter.configureFeed(POOL, f);
        _publish();
        (uint160 got,,) = adapter.refresh(POOL);
        assertEq(uint256(got), Math.sqrt(Math.mulDiv(230, 1 << 192, 2500)), "ETH per NVDA = 230 / 2500");

        adapter.configureFeed(OTHER_POOL, _feed());
        (uint160 inverted,,) = adapter.refresh(OTHER_POOL);
        // sqrt(a/b) * sqrt(b/a) == 2**192, to within the two roundings.
        assertApproxEqRel(uint256(got) * uint256(inverted), uint256(1) << 192, 1e6, "the two directions are reciprocal");
    }

    /// THE REASON THIS CONTRACT EXISTS. The one-feed adapter, pointed at the same stock feed with the
    /// native currency as quote, prices one ETH as one dollar: its reference is wrong by the ETH price.
    function test_theOneFeedAdapterIsWrongByTheNativePrice() public {
        ChainlinkPriceBandAdapter single = new ChainlinkPriceBandAdapter(address(0), 0, address(this));
        single.configureFeed(
            POOL,
            ChainlinkPriceBandAdapter.Feed({
                aggregator: address(stockFeed),
                baseIsCurrency0: false,
                baseDecimals: 18,
                quoteDecimals: 18,
                feedDecimals: 8,
                heartbeat: STOCK_HEARTBEAT
            })
        );
        _publish();
        (uint160 wrong,) = single.refresh(POOL);
        bare.configureFeed(POOL, _feed());
        (uint160 right,,) = bare.refresh(POOL);
        // price = sqrtPrice squared. right / wrong (as prices) must be the ETH price, 2500.
        uint256 ratio = Math.mulDiv(uint256(right) * uint256(right), 1e6, uint256(wrong) * uint256(wrong));
        assertApproxEqRel(ratio, 2500e6, 1e12, "the one-feed reference is off by the native price");
    }

    /// Token decimals: a stock token with 8 decimals against an 18-decimal native currency.
    function test_conversion_tokenDecimalsChangeTheRatio() public {
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        f.baseDecimals = 8;
        adapter.configureFeed(POOL, f);
        _publish();
        (uint160 got,,) = adapter.refresh(POOL);
        // 1 NVDA (1e8 units) = 230/2500 ETH = 0.092e18 wei  =>  NVDA units per wei = 1e8 * 2500 / (230 * 1e18)
        uint256 expected = Math.sqrt(Math.mulDiv(2500 * 1e8, 1 << 192, 230 * 1e18));
        assertEq(uint256(got), expected);
    }

    /// Feed decimals are divided out leg by leg: an 18-decimal stock feed and an 8-decimal native feed
    /// reporting the same dollar prices give the same reference.
    function test_conversion_feedDecimalsAreDividedOutPerLeg() public {
        _configure();
        _publish();
        (uint160 base,,) = adapter.refresh(POOL);

        MockAggregator stock18 = new MockAggregator(18, "NVDA / USD");
        stock18.set(230e18, NOW);
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        f.baseAggregator = address(stock18);
        f.baseFeedDecimals = 18;
        adapter.configureFeed(OTHER_POOL, f);
        (uint160 got,,) = adapter.refresh(OTHER_POOL);
        assertEq(uint256(got), uint256(base));
    }

    /// A very large ratio takes the 2**126 branch; it must agree with exact arithmetic there too.
    function test_conversion_highRatioBranch() public {
        // A 0-decimal base token worth $1e9 against an 18-decimal quote worth $1: ratio 1e27 > 2**64.
        MockAggregator big = new MockAggregator(8, "BIG / USD");
        MockAggregator one = new MockAggregator(8, "ONE / USD");
        big.set(1e9 * 1e8, NOW);
        one.set(1e8, NOW);
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        f.baseAggregator = address(big);
        f.quoteAggregator = address(one);
        f.baseIsCurrency0 = true;
        f.baseDecimals = 0;
        f.quoteDecimals = 18;
        adapter.configureFeed(POOL, f);
        (uint160 got,,) = adapter.refresh(POOL);
        uint256 expected = Math.sqrt(Math.mulDiv(1e27, 1 << 126, 1)) << 33;
        assertEq(uint256(got), expected);
    }

    /// Both answers at their caps with every decimals value at its cap must not overflow.
    function testFuzz_conversion_neverOverflowsInsideTheBounds(
        uint256 baseAnswer,
        uint256 quoteAnswer,
        uint8 baseDec,
        uint8 quoteDec,
        uint8 baseFeedDec,
        uint8 quoteFeedDec,
        bool baseIs0
    ) public {
        baseAnswer = bound(baseAnswer, 1, 1e36);
        quoteAnswer = bound(quoteAnswer, 1, 1e36);
        baseDec = uint8(bound(baseDec, 0, 18));
        quoteDec = uint8(bound(quoteDec, 0, 18));
        baseFeedDec = uint8(bound(baseFeedDec, 0, 18));
        quoteFeedDec = uint8(bound(quoteFeedDec, 0, 18));

        MockAggregator a = new MockAggregator(baseFeedDec, "A / USD");
        MockAggregator b = new MockAggregator(quoteFeedDec, "B / USD");
        a.set(int256(baseAnswer), NOW);
        b.set(int256(quoteAnswer), NOW);
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        f.baseAggregator = address(a);
        f.quoteAggregator = address(b);
        f.baseDecimals = baseDec;
        f.quoteDecimals = quoteDec;
        f.baseFeedDecimals = baseFeedDec;
        f.quoteFeedDecimals = quoteFeedDec;
        f.baseIsCurrency0 = baseIs0;
        bare.configureFeed(POOL, f);

        // Either a price inside core's range, or one of the two "cannot be represented" errors:
        // never a panic (0x11 overflow / 0x12 division by zero).
        try bare.refresh(POOL) returns (uint160 p, uint64, uint64) {
            assertGe(uint256(p), TickMath.MIN_SQRT_RATIO);
            assertLe(uint256(p), TickMath.MAX_SQRT_RATIO);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == ChainlinkCrossPriceBandAdapter.RatioUnrepresentable.selector
                    || sel == ChainlinkCrossPriceBandAdapter.PriceOutOfRange.selector,
                "only the two range errors are acceptable"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                    TWO LEGS, TWO CLOCKS, AND THE OLDER ONE WINS
    //////////////////////////////////////////////////////////////*/

    function test_updatedAtIsTheOlderLeg() public {
        _configure();
        stockFeed.set(NVDA, NOW - 6 hours); // the stock printed at the close
        nativeFeed.set(ETH, NOW - 5 minutes);
        (, uint64 baseAt, uint64 quoteAt) = adapter.refresh(POOL);
        assertEq(baseAt, NOW - 6 hours);
        assertEq(quoteAt, NOW - 5 minutes);
        (uint160 p, uint64 updatedAt) = adapter.referencePrice(POOL);
        assertGt(p, 0);
        assertEq(updatedAt, NOW - 6 hours, "the staler leg is what the consumer measures against");

        // And the other way round.
        stockFeed.set(NVDA, NOW - 1 minutes);
        nativeFeed.set(ETH, NOW - 30 minutes);
        adapter.refresh(POOL);
        (, updatedAt) = adapter.referencePrice(POOL);
        assertEq(updatedAt, NOW - 30 minutes);
    }

    function test_failClosed_refreshRejectsAStaleStockLeg() public {
        _configure();
        stockFeed.set(NVDA, NOW - STOCK_HEARTBEAT - 1);
        nativeFeed.set(ETH, NOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.AnswerTooOld.selector,
                address(stockFeed),
                NOW - STOCK_HEARTBEAT - 1,
                STOCK_HEARTBEAT,
                NOW
            )
        );
        adapter.refresh(POOL);
    }

    function test_failClosed_refreshRejectsAStaleNativeLeg() public {
        _configure();
        stockFeed.set(NVDA, NOW);
        nativeFeed.set(ETH, NOW - NATIVE_HEARTBEAT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.AnswerTooOld.selector,
                address(nativeFeed),
                NOW - NATIVE_HEARTBEAT - 1,
                NATIVE_HEARTBEAT,
                NOW
            )
        );
        adapter.refresh(POOL);
    }

    /// The cache dies when the NATIVE leg outlives its (short) heartbeat, although the stock leg, with
    /// its day-long heartbeat, is still fine. One clock for both would have kept serving it.
    function test_failClosed_cacheAgesOutOnTheShorterHeartbeat() public {
        _ready();
        (uint160 p,) = adapter.referencePrice(POOL);
        assertGt(p, 0);

        vm.warp(NOW + NATIVE_HEARTBEAT);
        (p,) = adapter.referencePrice(POOL);
        assertGt(p, 0, "exactly at the heartbeat is still inside it");

        vm.warp(NOW + NATIVE_HEARTBEAT + 1);
        uint64 at;
        (p, at) = adapter.referencePrice(POOL);
        assertEq(p, 0, "the native leg is stale: no reference");
        assertEq(at, 0);
    }

    /// And when the stock leg is the one that dies first.
    function test_failClosed_cacheAgesOutOnTheStockLeg() public {
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        f.baseHeartbeat = 10 minutes;
        f.quoteHeartbeat = 1 days;
        adapter.configureFeed(POOL, f);
        _publish();
        adapter.refresh(POOL);
        vm.warp(NOW + 10 minutes + 1);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
    }

    /// A round stamped in the future must not buy the cache extra life.
    function test_futureTimestampIsClampedToNow() public {
        _configure();
        stockFeed.set(NVDA, NOW + 1 days);
        nativeFeed.set(ETH, NOW + 1 days);
        (, uint64 baseAt, uint64 quoteAt) = adapter.refresh(POOL);
        assertEq(baseAt, NOW);
        assertEq(quoteAt, NOW);
        vm.warp(NOW + NATIVE_HEARTBEAT + 1);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0, "it aged out on the real clock");
    }

    /*//////////////////////////////////////////////////////////////
                              FAIL CLOSED
    //////////////////////////////////////////////////////////////*/

    function test_failClosed_unconfiguredPoolReadsAsZeroAndCannotRefresh() public {
        (uint160 p, uint64 at) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        assertEq(at, 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.FeedNotConfigured.selector, POOL));
        adapter.refresh(POOL);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.FeedNotConfigured.selector, POOL));
        adapter.previewRefresh(POOL);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.FeedNotConfigured.selector, POOL));
        adapter.feedDescriptions(POOL);
    }

    function test_failClosed_configuredButNeverRefreshedReadsAsZero() public {
        _configure();
        _publish();
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
    }

    function test_failClosed_eitherLegNonPositiveIsRejected() public {
        _configure();
        stockFeed.set(0, NOW);
        nativeFeed.set(ETH, NOW);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.NonPositiveAnswer.selector, address(stockFeed), int256(0))
        );
        adapter.refresh(POOL);

        stockFeed.set(NVDA, NOW);
        nativeFeed.set(-1, NOW);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.NonPositiveAnswer.selector, address(nativeFeed), int256(-1))
        );
        adapter.refresh(POOL);
    }

    function test_failClosed_incompleteRoundOnEitherLegIsRejected() public {
        _configure();
        stockFeed.set(NVDA, NOW);
        nativeFeed.setRound(7, ETH, NOW, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.IncompleteRound.selector, address(nativeFeed), uint80(7))
        );
        adapter.refresh(POOL);
    }

    function test_failClosed_answerAboveTheCapIsRejected() public {
        _configure();
        stockFeed.set(int256(1e36 + 1), NOW);
        nativeFeed.set(ETH, NOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.AnswerOutOfRange.selector, address(stockFeed), uint256(1e36 + 1)
            )
        );
        adapter.refresh(POOL);
    }

    function test_failClosed_decimalsChangingUnderEitherProxyIsRejected() public {
        _configure();
        _publish();
        nativeFeed.setDecimals(18);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.DecimalsChanged.selector, address(nativeFeed), uint8(8), uint8(18)
            )
        );
        adapter.refresh(POOL);
    }

    function test_failedRefreshLeavesThePreviousCacheIntact() public {
        _ready();
        (uint160 before,) = adapter.referencePrice(POOL);
        nativeFeed.setReverts(true);
        vm.expectRevert();
        adapter.refresh(POOL);
        (uint160 afterwards,) = adapter.referencePrice(POOL);
        assertEq(afterwards, before);
    }

    function test_view_neverRevertsEvenWhenBothAggregatorsDo() public {
        _ready();
        stockFeed.setReverts(true);
        nativeFeed.setReverts(true);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertGt(p, 0, "the hot path reads the cache, not the aggregators");
    }

    function test_reconfiguringDropsTheCache() public {
        _ready();
        adapter.configureFeed(POOL, _feed());
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0, "nothing computed from the earlier pair may be served");
    }

    function test_removeFeed_clearsEverything() public {
        _ready();
        adapter.removeFeed(POOL);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        assertEq(adapter.feedFor(POOL).baseAggregator, address(0));
        assertEq(adapter.cachedReference(POOL).sqrtPriceX96, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               SEQUENCER
    //////////////////////////////////////////////////////////////*/

    function test_sequencer_downBlocksRefreshAndTheView() public {
        _ready();
        sequencer.set(1, NOW);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        vm.expectRevert(ChainlinkCrossPriceBandAdapter.SequencerDown.selector);
        adapter.refresh(POOL);
    }

    function test_sequencer_insideGraceIsRejectedEvenWithAFreshCache() public {
        _ready();
        sequencer.set(0, NOW - 60);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.SequencerGracePeriod.selector, NOW - 60, GRACE, NOW)
        );
        adapter.refresh(POOL);
    }

    function test_sequencer_unreadableFeedIsNotUp() public {
        _ready();
        sequencer.setReverts(true);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        vm.expectRevert(ChainlinkCrossPriceBandAdapter.SequencerFeedUnreadable.selector);
        adapter.refresh(POOL);
        (bool enabled, bool ok,) = adapter.sequencerStatus();
        assertTrue(enabled);
        assertFalse(ok);
    }

    function test_sequencerUnset_pricesFlowAndItSaysSo() public {
        bare.configureFeed(POOL, _feed());
        _publish();
        bare.refresh(POOL);
        (uint160 p,) = bare.referencePrice(POOL);
        assertGt(p, 0);
        assertFalse(bare.sequencerCheckEnabled());
        (bool enabled, bool ok,) = bare.sequencerStatus();
        assertFalse(enabled);
        assertTrue(ok);
    }

    function test_constructor_gracePeriodMustMatchTheFeed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.InvalidGracePeriod.selector, address(0), uint32(1))
        );
        new ChainlinkCrossPriceBandAdapter(address(0), 1, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.InvalidGracePeriod.selector, address(sequencer), uint32(0)
            )
        );
        new ChainlinkCrossPriceBandAdapter(address(sequencer), 0, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.InvalidGracePeriod.selector, address(sequencer), uint32(24 hours + 1)
            )
        );
        new ChainlinkCrossPriceBandAdapter(address(sequencer), 24 hours + 1, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS: what the owner can and cannot do
    //////////////////////////////////////////////////////////////*/

    function test_access_onlyOwnerConfiguresAndRemoves() public {
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        adapter.configureFeed(POOL, f);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        adapter.removeFeed(POOL);
    }

    /// Anyone may refresh, and all it can write is what the two aggregators report.
    function test_access_refreshIsPermissionlessAndWritesOnlyTheFeedsAnswer() public {
        _configure();
        _publish();
        vm.prank(KEEPER);
        (uint160 byKeeper,,) = adapter.refresh(POOL);
        vm.prank(STRANGER);
        (uint160 byStranger,,) = adapter.refresh(POOL);
        assertEq(byKeeper, byStranger);
        (uint160 preview,,) = adapter.previewRefresh(POOL);
        assertEq(preview, byKeeper);
    }

    function test_renounceOwnership_isDisabled() public {
        vm.expectRevert(ChainlinkCrossPriceBandAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(this));
    }

    function test_ownershipIsTwoStep() public {
        adapter.transferOwnership(KEEPER);
        assertEq(adapter.owner(), address(this), "nothing moves until the new owner accepts");
        assertEq(adapter.pendingOwner(), KEEPER);
        vm.prank(KEEPER);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), KEEPER);
    }

    /// Funds can never be stuck: no receive, no fallback, and a stray ERC-20 leaves through the owner.
    function test_custody_refusesNativeAndRescuesAStrayToken() public {
        (bool ok,) = address(adapter).call{value: 1}("");
        assertFalse(ok, "no receive and no fallback");

        StrayToken t = new StrayToken();
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.NothingToRescue.selector, address(t)));
        adapter.rescueERC20(address(t), KEEPER);

        t.transfer(address(adapter), 5e18);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        adapter.rescueERC20(address(t), STRANGER);
        vm.expectRevert(ChainlinkCrossPriceBandAdapter.RescueToZero.selector);
        adapter.rescueERC20(address(t), address(0));

        adapter.rescueERC20(address(t), KEEPER);
        assertEq(t.balanceOf(KEEPER), 5e18);
        assertEq(t.balanceOf(address(adapter)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_config_rejectsBadInputs() public {
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = _feed();

        f.baseAggregator = address(0);
        vm.expectRevert(ChainlinkCrossPriceBandAdapter.ZeroAddress.selector);
        adapter.configureFeed(POOL, f);

        f = _feed();
        f.quoteAggregator = address(0);
        vm.expectRevert(ChainlinkCrossPriceBandAdapter.ZeroAddress.selector);
        adapter.configureFeed(POOL, f);

        f = _feed();
        f.quoteAggregator = f.baseAggregator;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.SameAggregator.selector, address(stockFeed))
        );
        adapter.configureFeed(POOL, f);

        f = _feed();
        f.baseDecimals = 19;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.InvalidDecimals.selector, uint8(19), uint8(18))
        );
        adapter.configureFeed(POOL, f);

        f = _feed();
        f.quoteFeedDecimals = 19;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.InvalidFeedDecimals.selector, uint8(19)));
        adapter.configureFeed(POOL, f);

        f = _feed();
        f.baseHeartbeat = 0;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.InvalidHeartbeat.selector, uint32(0)));
        adapter.configureFeed(POOL, f);

        f = _feed();
        f.quoteHeartbeat = 7 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkCrossPriceBandAdapter.InvalidHeartbeat.selector, uint32(7 days + 1))
        );
        adapter.configureFeed(POOL, f);

        // The decimals configured must be the decimals the aggregator reports, for each leg.
        f = _feed();
        f.baseFeedDecimals = 18;
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkCrossPriceBandAdapter.DecimalsChanged.selector, address(stockFeed), uint8(18), uint8(8)
            )
        );
        adapter.configureFeed(POOL, f);

        // An address with no code is not an aggregator.
        f = _feed();
        f.quoteAggregator = address(uint160(0x1234));
        vm.expectRevert();
        adapter.configureFeed(POOL, f);
    }

    function test_operatorViews() public {
        _ready();
        ChainlinkCrossPriceBandAdapter.CrossFeed memory f = adapter.feedFor(POOL);
        assertEq(f.baseAggregator, address(stockFeed));
        assertEq(f.quoteAggregator, address(nativeFeed));
        assertEq(f.baseHeartbeat, STOCK_HEARTBEAT);
        assertEq(f.quoteHeartbeat, NATIVE_HEARTBEAT);
        ChainlinkCrossPriceBandAdapter.Cached memory c = adapter.cachedReference(POOL);
        assertGt(c.sqrtPriceX96, 0);
        assertEq(c.baseUpdatedAt, NOW);
        assertEq(c.quoteUpdatedAt, NOW);
        (string memory base, string memory quote) = adapter.feedDescriptions(POOL);
        assertEq(base, "NVDA / USD");
        assertEq(quote, "ETH / USD");
    }

    /*//////////////////////////////////////////////////////////////
                 THE HOT PATH FITS THE CONSUMER'S GAS BUDGET
    //////////////////////////////////////////////////////////////*/

    function test_referencePrice_fitsTheModulesGasBudget() public {
        _ready();
        // Cold: the consumer calls this once per swap, from a fresh transaction's access list.
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = address(adapter).staticcall{gas: PRICE_ORACLE_GAS_LIMIT}(
            abi.encodeCall(IPriceBandOracle.referencePrice, (POOL))
        );
        uint256 used = before - gasleft();
        assertTrue(ok);
        assertEq(ret.length, 64, "exactly the two values the consumer expects");
        assertLt(used, PRICE_ORACLE_GAS_LIMIT / 4, "well inside the budget, sequencer read included");
    }
}
