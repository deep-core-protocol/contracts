// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IPriceBandOracle} from "../src/interfaces/IPriceBandOracle.sol";
import {MarketHoursModule} from "../src/modules/MarketHoursModule.sol";
import {AggregatorV3Interface, ChainlinkPriceBandAdapter} from "../src/oracles/ChainlinkPriceBandAdapter.sol";

/// @dev `PRICE_ORACLE_GAS_LIMIT` (`src/modules/MarketHoursModule.sol:235`).
/// Restated here rather than imported because Solidity will not read a constant off an abstract
/// contract's type. `test_gasLimitMatchesTheModule` pins the two together so this cannot drift.
uint256 constant PRICE_ORACLE_GAS_LIMIT = 200_000;

/*//////////////////////////////////////////////////////////////
                              MOCKS
//////////////////////////////////////////////////////////////*/

/// @dev A Chainlink aggregator stand-in. Every field of a round is settable, including the
/// malformed combinations a real feed produces when it malfunctions.
contract MockAggregator is AggregatorV3Interface {
    uint80 internal _roundId = 1;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;
    uint80 internal _answeredInRound = 1;
    uint8 internal _decimals;
    string internal _description;

    bool public reverts;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _startedAt = updatedAt_;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
    }

    /// @dev A proxy repointed at an aggregator with a different scale. The adapter must notice.
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function decimals() external view override returns (uint8) {
        require(!reverts, "aggregator down");
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(!reverts, "aggregator down");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}

/// @dev A Chainlink L2 sequencer-uptime feed. `answer` is 0 for up, 1 for down; `startedAt` is
/// when the current status began, which is what the grace period is measured from.
contract MockSequencerFeed is AggregatorV3Interface {
    int256 internal _answer; // 0 = up
    uint256 internal _startedAt;
    bool public reverts;

    /// @dev Turns the feed into a gas bomb mid-test, which is the only way to cache a price while
    /// the feed is healthy and then read it while the feed is hostile.
    bool public bomb;

    constructor(int256 answer_, uint256 startedAt_) {
        _answer = answer_;
        _startedAt = startedAt_;
    }

    function set(int256 answer_, uint256 startedAt_) external {
        _answer = answer_;
        _startedAt = startedAt_;
    }

    function setReverts(bool v) external {
        reverts = v;
    }

    function setBomb(bool v) external {
        bomb = v;
    }

    function decimals() external pure override returns (uint8) {
        return 0;
    }

    function description() external pure override returns (string memory) {
        return "L2 Sequencer Uptime Status Feed";
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "uptime feed down");
        if (bomb) {
            uint256 acc;
            for (uint256 i = 0; i < type(uint256).max; ++i) {
                acc = uint256(keccak256(abi.encode(acc, gasleft())));
            }
            return (1, int256(acc), acc, acc, 1);
        }
        return (1, _answer, _startedAt, _startedAt, 1);
    }
}

/// @dev Returns three words where five are required. The `returndatasize` check must catch it
/// BEFORE any of it is decoded as a status.
contract ShortReturnSequencerFeed {
    fallback() external {
        assembly ("memory-safe") {
            return(0, 0x60)
        }
    }
}

/// @dev Burns every wei of gas it is given. The bounded staticcall must contain it.
contract GasBombSequencerFeed {
    fallback() external {
        uint256 acc;
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, gasleft())));
        }
        assembly ("memory-safe") {
            mstore(0, acc)
            return(0, 0xa0)
        }
    }
}

/// @dev Reproduces exactly what `MarketHoursModule._queryPriceOracle` does: a `staticcall` under
/// `PRICE_ORACLE_GAS_LIMIT` with a `returndatasize` check before anything is copied.
///
/// Measuring against this rather than against `gasleft()` deltas is the point — it is the real
/// budget, applied the real way, so "fits the budget" is demonstrated rather than estimated.
contract ModuleGasHarness {
    function query(IPriceBandOracle oracle, PoolId poolId)
        external
        view
        returns (bool callOk, uint160 sqrtPriceX96, uint64 updatedAt, uint256 gasUsed)
    {
        bytes memory callData = abi.encodeCall(IPriceBandOracle.referencePrice, (poolId));
        uint256 gasBudget = PRICE_ORACLE_GAS_LIMIT;
        uint256 returnSize = 0x40;
        uint256 before = gasleft();

        assembly ("memory-safe") {
            let out := mload(0x40)
            let ok := staticcall(gasBudget, oracle, add(callData, 0x20), mload(callData), out, returnSize)
            if and(ok, eq(returndatasize(), returnSize)) {
                callOk := 1
                sqrtPriceX96 := and(mload(out), 0xffffffffffffffffffffffffffffffffffffffff)
                updatedAt := and(mload(add(out, 0x20)), 0xffffffffffffffff)
            }
        }

        gasUsed = before - gasleft();
    }
}

/// @dev The smallest concrete `MarketHoursModule` there can be, existing for one reason: so the
/// budget restated at the top of this file is pinned to the module's own constant rather than to a
/// copy of it that could drift.
contract GasLimitPin is MarketHoursModule {
    function _marketAdmin() internal pure override returns (address) {
        return address(0);
    }

    function _requireOwnPoolKey(PoolKey calldata) internal pure override {}
}

/*//////////////////////////////////////////////////////////////
                               TESTS
//////////////////////////////////////////////////////////////*/

contract ChainlinkPriceBandAdapterTest is Test {
    MockAggregator aggregator;
    MockSequencerFeed sequencer;
    ChainlinkPriceBandAdapter adapter; // sequencer feed CONFIGURED
    ChainlinkPriceBandAdapter bare; // sequencer feed ABSENT
    ModuleGasHarness harness;

    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));
    PoolId constant OTHER_POOL = PoolId.wrap(bytes32(uint256(2)));
    address constant KEEPER = address(uint160(0xBEEF));

    uint256 constant NOW = 1_800_000_000;
    uint32 constant GRACE = 3600;
    uint32 constant HEARTBEAT = 3600;

    /// AAPL at $189.50 on an 8-decimal feed.
    int256 constant AAPL_ANSWER = 18_950_000_000;
    uint8 constant FEED_DECIMALS = 8;

    function setUp() public {
        vm.warp(NOW);
        aggregator = new MockAggregator(FEED_DECIMALS, "AAPL / USD");
        // Up, and up for far longer than the grace period.
        sequencer = new MockSequencerFeed(0, NOW - 10 days);
        adapter = new ChainlinkPriceBandAdapter(address(sequencer), GRACE, address(this));
        bare = new ChainlinkPriceBandAdapter(address(0), 0, address(this));
        harness = new ModuleGasHarness();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// 18-decimal RWA token as currency0, 6-decimal USDC as currency1.
    function _aaplBase() internal view returns (ChainlinkPriceBandAdapter.Feed memory) {
        return ChainlinkPriceBandAdapter.Feed({
            aggregator: address(aggregator),
            baseIsCurrency0: true,
            baseDecimals: 18,
            quoteDecimals: 6,
            feedDecimals: FEED_DECIMALS,
            heartbeat: HEARTBEAT
        });
    }

    function _configure() internal {
        adapter.configureFeed(POOL, _aaplBase());
    }

    function _publish() internal {
        aggregator.set(AAPL_ANSWER, NOW);
    }

    /*//////////////////////////////////////////////////////////////
      THE CONVERSION. The interface warns this is what goes wrong.
    //////////////////////////////////////////////////////////////*/

    /// The number the adapter produces must be the number core would store in `slot0` for a pool
    /// genuinely trading at $189.50, derived here from first principles rather than copied from
    /// the implementation.
    function test_conversion_matchesAPoolTradingAtThatPrice() public {
        _configure();
        _publish();

        (uint160 got,) = adapter.refresh(POOL);

        // One whole RWA token is 1e18 base units and is worth 189.50 USDC, i.e. 189_500_000 quote
        // base units. So currency1-per-currency0 = 189.5e6 / 1e18.
        uint256 expected = Math.sqrt(Math.mulDiv(189_500_000, 1 << 192, 1e18));

        assertEq(uint256(got), expected, "sqrtPriceX96 must match an independent derivation");
        assertGt(uint256(got), TickMath.MIN_SQRT_RATIO);
        assertLt(uint256(got), TickMath.MAX_SQRT_RATIO);
    }

    /// THE INVERTED CASE, checked against a real `sqrtPriceX96` derived independently.
    ///
    /// The stablecoin sorted lower, so currency0 is 6-decimal USDC and currency1 is the 18-decimal
    /// RWA token. One USDC base unit (1e-6 of a dollar) buys `1e18 / (189.5 * 1e6)` RWA base units.
    /// That rational is written out below without touching the adapter's own decomposition — if the
    /// adapter returned the non-inverted number instead, this assertion is what catches it, and the
    /// interface says getting it backwards rejects every swap in one direction.
    function test_conversion_invertedDirectionMatchesARealSqrtPrice() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.baseIsCurrency0 = false;
        adapter.configureFeed(POOL, f);
        _publish();

        (uint160 got,) = adapter.refresh(POOL);

        // R = 1e18 RWA base units / (189.5 * 1e6 USDC base units)
        //   = (1e18 * 1e8) / (18_950_000_000 * 1e6)   [clearing the feed's 8 decimals]
        uint256 num = 1e18 * 1e8;
        uint256 den = uint256(AAPL_ANSWER) * 1e6;
        uint256 expected = Math.sqrt(Math.mulDiv(num, 1 << 192, den));

        assertEq(uint256(got), expected, "inverted sqrtPriceX96 must match an independent derivation");

        // And it must be the reciprocal of the other ordering, not a repeat of it.
        adapter.configureFeed(POOL, _aaplBase());
        (uint160 nonInverted,) = adapter.refresh(POOL);
        assertTrue(got != nonInverted, "ordering must change the answer");
        assertGt(uint256(got), uint256(nonInverted), "a cheap currency0 must price above a dear one");
    }

    /// An exact power of two has an exact integer square root, so this pins the low-ratio branch
    /// to a value with no rounding at all: R = 2**40 => sqrtPriceX96 = 2**20 * 2**96 = 2**116.
    function test_conversion_exactValue_lowRatioBranch() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.feedDecimals = 0;
        f.baseDecimals = 18;
        f.quoteDecimals = 18;
        aggregator.setDecimals(0);
        adapter.configureFeed(POOL, f);
        aggregator.set(int256(uint256(1) << 40), NOW);

        (uint160 got,) = adapter.refresh(POOL);
        assertEq(uint256(got), uint256(1) << 116, "R = 2**40 must give exactly 2**116");
    }

    /// The high-ratio branch, which the 2**192 scale cannot reach at all: R = 2**70 is above the
    /// 2**64 point where `mulDiv(num, 2**192, den)` overflows, and core represents it fine.
    /// Expected sqrtPriceX96 = 2**35 * 2**96 = 2**131, exactly.
    function test_conversion_exactValue_highRatioBranch() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.feedDecimals = 0;
        f.baseDecimals = 18;
        f.quoteDecimals = 18;
        aggregator.setDecimals(0);
        adapter.configureFeed(POOL, f);
        aggregator.set(int256(uint256(1) << 70), NOW);

        (uint160 got,) = adapter.refresh(POOL);
        assertEq(uint256(got), uint256(1) << 131, "R = 2**70 must give exactly 2**131");
        assertLt(uint256(got), TickMath.MAX_SQRT_RATIO);
    }

    /// The branch boundary must not be a discontinuity. Two ratios a hair either side of 2**64
    /// take different code paths and must still be ordered and adjacent.
    function test_conversion_branchBoundaryIsContinuous() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.feedDecimals = 0;
        f.baseDecimals = 18;
        f.quoteDecimals = 18;
        aggregator.setDecimals(0);
        adapter.configureFeed(POOL, f);

        aggregator.set(int256((uint256(1) << 64) - 1), NOW);
        (uint160 below,) = adapter.refresh(POOL);

        aggregator.set(int256(uint256(1) << 64), NOW);
        (uint160 atBoundary,) = adapter.refresh(POOL);

        assertLe(uint256(below), uint256(atBoundary), "must be monotonic across the branch");
        // sqrt(2**64) * 2**96 = 2**128, exactly, on the reduced-scale path.
        assertEq(uint256(atBoundary), uint256(1) << 128);
        // One unit of R apart, so the two square roots differ by far less than one part in 1e12.
        assertApproxEqRel(uint256(below), uint256(atBoundary), 1e6);
    }

    /// Decimals matter as much as ordering: the same human price against an 18-decimal quote is a
    /// different pool ratio than against a 6-decimal one.
    function test_conversion_quoteDecimalsChangeTheRatio() public {
        _configure();
        _publish();
        (uint160 sixDp,) = adapter.refresh(POOL);

        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.quoteDecimals = 18;
        adapter.configureFeed(POOL, f);
        (uint160 eighteenDp,) = adapter.refresh(POOL);

        // 1e12 more quote units per base unit is 1e6 more in sqrt space.
        assertApproxEqRel(uint256(eighteenDp), uint256(sixDp) * 1e6, 1e12);
    }

    /// A feed reporting 18 decimals instead of 8 is the same price, so the pool ratio must be
    /// identical — this is the check that the feed's own scale is divided out rather than folded
    /// into the answer.
    function test_conversion_feedDecimalsAreDividedOut() public {
        _configure();
        _publish();
        (uint160 eightDp,) = adapter.refresh(POOL);

        MockAggregator big = new MockAggregator(18, "AAPL / USD");
        big.set(189_500_000_000_000_000_000, NOW); // $189.50 at 18 decimals
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.aggregator = address(big);
        f.feedDecimals = 18;
        adapter.configureFeed(OTHER_POOL, f);
        (uint160 eighteenDp,) = adapter.refresh(OTHER_POOL);

        assertEq(uint256(eightDp), uint256(eighteenDp), "feed scale must not reach the pool ratio");
    }

    /*//////////////////////////////////////////////////////////////
                        FAIL CLOSED, EVERY TIME
    //////////////////////////////////////////////////////////////*/

    function test_failClosed_unconfiguredPoolReadsAsZero() public view {
        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, 0);
        assertEq(t, 0);
    }

    function test_failClosed_unconfiguredPoolCannotRefresh() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.FeedNotConfigured.selector, POOL));
        adapter.refresh(POOL);
    }

    function test_failClosed_configuredButNeverRefreshedReadsAsZero() public {
        _configure();
        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, 0, "a configured feed is not a cached price");
        assertEq(t, 0);
    }

    function test_failClosed_zeroAnswerRejected() public {
        _configure();
        aggregator.set(0, NOW);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.NonPositiveAnswer.selector, int256(0)));
        adapter.refresh(POOL);
    }

    function test_failClosed_negativeAnswerRejected() public {
        _configure();
        aggregator.set(-1, NOW);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.NonPositiveAnswer.selector, int256(-1)));
        adapter.refresh(POOL);
    }

    /// `updatedAt == 0` is Chainlink's marker for a round that never completed. Its answer is not
    /// a price, and it must be rejected BEFORE the answer is even looked at.
    function test_failClosed_incompleteRoundRejected() public {
        _configure();
        aggregator.setRound(7, AAPL_ANSWER, NOW, 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.IncompleteRound.selector, uint80(7)));
        adapter.refresh(POOL);
    }

    function test_failClosed_staleAnswerRejectedAtRefresh() public {
        _configure();
        aggregator.set(AAPL_ANSWER, NOW - HEARTBEAT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceBandAdapter.AnswerTooOld.selector, NOW - HEARTBEAT - 1, HEARTBEAT, NOW
            )
        );
        adapter.refresh(POOL);
    }

    /// The half that makes the whole thing fail closed: if nobody refreshes, the cache ages out on
    /// its own and the pool halts. Nothing needs to happen for this to trigger.
    function test_failClosed_cacheAgesOutWithNoFurtherAction() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        vm.warp(NOW + HEARTBEAT);
        (uint160 stillGood,) = adapter.referencePrice(POOL);
        assertGt(stillGood, 0, "exactly at the heartbeat is still fresh");

        vm.warp(NOW + HEARTBEAT + 1);
        (uint160 aged, uint64 t) = adapter.referencePrice(POOL);
        assertEq(aged, 0, "one second past the heartbeat must read as unavailable");
        assertEq(t, 0);
    }

    /// A tightened heartbeat must bite immediately, without waiting for a refresh. The view reads
    /// the policy from the feed config for exactly this reason.
    function test_failClosed_shorteningTheHeartbeatTakesEffectAtOnce() public {
        _configure();
        _publish();
        adapter.refresh(POOL);
        vm.warp(NOW + 1000);
        (uint160 fresh,) = adapter.referencePrice(POOL);
        assertGt(fresh, 0);

        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.heartbeat = 60;
        adapter.configureFeed(POOL, f);

        (uint160 nowStale,) = adapter.referencePrice(POOL);
        assertEq(nowStale, 0, "a shortened heartbeat must apply to the price already cached");
    }

    /// A failed refresh leaves the PREVIOUS cache untouched rather than zeroing it. Staleness is
    /// then decided by the round timestamp the adapter reports, not by the failure.
    function test_failedRefreshLeavesThePreviousCacheIntact() public {
        _configure();
        _publish();
        (uint160 good,) = adapter.refresh(POOL);

        aggregator.setReverts(true);
        vm.expectRevert();
        adapter.refresh(POOL);

        (uint160 still,) = adapter.referencePrice(POOL);
        assertEq(still, good, "a failed refresh must not corrupt the cache");
    }

    /// Removing a feed must clear the cache too. A pool still quoting a price whose source has
    /// been withdrawn is the one state that would let trading continue against nothing.
    function test_removeFeed_clearsTheCachedPrice() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        adapter.removeFeed(POOL);

        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, 0, "cache must be cleared with the feed");
        assertEq(t, 0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.FeedNotConfigured.selector, POOL));
        adapter.refresh(POOL);
    }

    /// A Chainlink proxy repointed at an aggregator with a different scale would make every
    /// conversion wrong by a power of ten. Caught live, not trusted from configuration time.
    function test_failClosed_decimalsChangingUnderTheProxyIsRejected() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        aggregator.setDecimals(18);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceBandAdapter.DecimalsChanged.selector, uint8(8), uint8(18))
        );
        adapter.refresh(POOL);
    }

    /// The view NEVER reverts. Whatever is wrong, the answer is `(0, 0)`.
    function test_view_neverRevertsEvenWhenTheAggregatorIs() public {
        _configure();
        _publish();
        adapter.refresh(POOL);
        aggregator.setReverts(true);

        // The view does not touch the aggregator at all — that is the point of caching — so this
        // succeeds and reports the cached round.
        (uint160 p,) = adapter.referencePrice(POOL);
        assertGt(p, 0);

        vm.warp(NOW + HEARTBEAT + 1);
        (uint160 aged,) = adapter.referencePrice(POOL);
        assertEq(aged, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        THE L2 SEQUENCER CHECK
    //////////////////////////////////////////////////////////////*/

    function test_sequencer_downBlocksRefreshAndTheView() public {
        _configure();
        _publish();
        adapter.refresh(POOL); // cached while the sequencer was up

        sequencer.set(1, NOW); // down as of now

        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerDown.selector);
        adapter.refresh(POOL);

        (uint160 p, uint64 t) = adapter.referencePrice(POOL);
        assertEq(p, 0, "a fresh cache must not be served while the sequencer is down");
        assertEq(t, 0);
    }

    /// THE SHARP CASE. An outage shorter than the heartbeat leaves the cache looking perfectly
    /// fresh at restart, so staleness alone does NOT cover the restart burst. The grace period is
    /// the only thing that does.
    function test_sequencer_justRecoveredInsideGraceIsRejectedEvenWithAFreshCache() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        // Ten minutes pass; the outage was shorter than the one-hour heartbeat.
        uint256 restart = NOW + 600;
        vm.warp(restart);
        sequencer.set(0, restart); // up again, as of this instant

        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0, "the cache is fresh, but the sequencer only just came back");

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceBandAdapter.SequencerGracePeriod.selector, restart, GRACE, restart
            )
        );
        adapter.refresh(POOL);

        // One second before the grace elapses: still refused.
        vm.warp(restart + GRACE - 1);
        (uint160 stillRefused,) = adapter.referencePrice(POOL);
        assertEq(stillRefused, 0);

        // The instant it elapses, the price is served again — assuming it is still inside the
        // heartbeat, which here it is not, so refresh a current round first.
        vm.warp(restart + GRACE);
        aggregator.set(AAPL_ANSWER, restart + GRACE);
        adapter.refresh(POOL);
        (uint160 served,) = adapter.referencePrice(POOL);
        assertGt(served, 0, "grace elapsed, price flows again");
    }

    /// An uptime round that has never been initialised reports `startedAt == 0`. That is not a
    /// claim the sequencer came up at the epoch, and must not be read as one.
    function test_sequencer_uninitialisedRoundIsUnreadable() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        sequencer.set(0, 0);
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerFeedUnreadable.selector);
        adapter.refresh(POOL);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
    }

    /// A status this contract does not understand is not evidence of uptime.
    function test_sequencer_unknownStatusIsTreatedAsDown() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        sequencer.set(2, NOW - 10 days);
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerDown.selector);
        adapter.refresh(POOL);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0);
    }

    function test_sequencer_revertingFeedIsUnreadableNotUp() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        sequencer.setReverts(true);
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerFeedUnreadable.selector);
        adapter.refresh(POOL);
        (uint160 p,) = adapter.referencePrice(POOL);
        assertEq(p, 0, "an unreadable uptime feed must fail closed");
    }

    /// Deployed against an address that is not a contract on this chain — the exact mistake a
    /// copy-pasted deployment script makes. A staticcall to an EOA succeeds with empty returndata,
    /// which would decode as "answer 0, sequencer up" if the size were not checked first.
    function test_sequencer_eoaFeedIsUnreadableNotUp() public {
        ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(address(0xDEAD), GRACE, address(this));
        a.configureFeed(POOL, _aaplBase());
        _publish();
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerFeedUnreadable.selector);
        a.refresh(POOL);
    }

    function test_sequencer_wrongShapeIsUnreadableNotUp() public {
        ShortReturnSequencerFeed shortFeed = new ShortReturnSequencerFeed();
        ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(address(shortFeed), GRACE, address(this));
        a.configureFeed(POOL, _aaplBase());
        _publish();
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerFeedUnreadable.selector);
        a.refresh(POOL);
    }

    /// A hostile or broken uptime feed must not be able to consume the budget the module allowed
    /// us. The staticcall is bounded, so the view still returns — unavailable — well inside it.
    function test_sequencer_gasBombIsContainedAndTheViewStillFits() public {
        // A healthy feed first, so there is a real cached price for the bomb to sit in front of —
        // otherwise the view short-circuits on the empty cache and never reaches the staticcall.
        _configure();
        _publish();
        adapter.refresh(POOL);
        (uint160 healthy,) = adapter.referencePrice(POOL);
        assertGt(healthy, 0);

        sequencer.setBomb(true);

        (bool callOk, uint160 p,, uint256 gasUsed) = harness.query(IPriceBandOracle(address(adapter)), POOL);
        assertTrue(callOk, "the view must return, not be killed by the feed");
        assertEq(p, 0, "an unreadable feed reads as unavailable");
        emit log_named_uint("view gas with a gas-bomb uptime feed", gasUsed);
        // The bomb consumes its whole 50,000-gas allowance and no more. The bound is what keeps a
        // repointed proxy from taking the pool's trading with it.
        assertGt(gasUsed, 50_000, "the bomb must actually have run");
        assertLt(gasUsed, PRICE_ORACLE_GAS_LIMIT / 2, "and must still leave the module room");

        // The same containment through `refresh`, where it surfaces as a named error.
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerFeedUnreadable.selector);
        adapter.refresh(POOL);
    }

    /// The standalone deployment case: an uptime feed that is a bomb from the first block.
    function test_sequencer_gasBombAtDeployTimeStillAnswers() public {
        GasBombSequencerFeed bombFeed = new GasBombSequencerFeed();
        ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(address(bombFeed), GRACE, address(this));
        a.configureFeed(POOL, _aaplBase());
        _publish();

        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerFeedUnreadable.selector);
        a.refresh(POOL);

        (bool callOk, uint160 p,,) = harness.query(IPriceBandOracle(address(a)), POOL);
        assertTrue(callOk);
        assertEq(p, 0);
    }

    /*//////////////////////////////////////////////////////////////
                   THE SEQUENCER FEED NOT BEING SET
    //////////////////////////////////////////////////////////////*/

    /// Deploying without an uptime feed is supported, and the contract says so rather than
    /// pretending the sequencer was checked.
    function test_sequencerUnset_isDeclaredNotAssumed() public {
        vm.expectEmit(false, false, false, false);
        emit ChainlinkPriceBandAdapter.SequencerCheckAbsent();
        ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(address(0), 0, address(this));

        assertEq(a.sequencerUptimeFeed(), address(0));
        assertEq(a.sequencerGracePeriod(), 0);
        assertFalse(a.sequencerCheckEnabled(), "the getter must report the check as absent");

        (bool enabled, bool ok, uint256 upSince) = a.sequencerStatus();
        assertFalse(enabled);
        assertTrue(ok, "no check means nothing blocks a price - that is the documented weakening");
        assertEq(upSince, 0);
    }

    function test_sequencerUnset_pricesFlowWithNoUptimeCheck() public {
        bare.configureFeed(POOL, _aaplBase());
        _publish();
        (uint160 refreshed,) = bare.refresh(POOL);
        (uint160 read,) = bare.referencePrice(POOL);
        assertEq(read, refreshed);
        assertGt(read, 0);
    }

    /// And a configured deployment emits the other event, so the two postures are distinguishable
    /// by topic rather than by decoding arguments.
    function test_sequencerConfigured_emitsTheOtherEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ChainlinkPriceBandAdapter.SequencerUptimeFeedConfigured(address(sequencer), GRACE);
        new ChainlinkPriceBandAdapter(address(sequencer), GRACE, address(this));
    }

    /// The pair cannot disagree: a grace period with no feed is a lie, and a feed with no grace is
    /// the L2 check silently disabled — the exact state this contract refuses to have.
    function test_constructor_gracePeriodMustMatchTheFeed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceBandAdapter.InvalidGracePeriod.selector, address(0), GRACE)
        );
        new ChainlinkPriceBandAdapter(address(0), GRACE, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceBandAdapter.InvalidGracePeriod.selector, address(sequencer), uint32(0)
            )
        );
        new ChainlinkPriceBandAdapter(address(sequencer), 0, address(this));

        // A units mistake — milliseconds — is caught rather than silently halting for 41 days.
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceBandAdapter.InvalidGracePeriod.selector, address(sequencer), uint32(3_600_000)
            )
        );
        new ChainlinkPriceBandAdapter(address(sequencer), 3_600_000, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_access_onlyOwnerConfigures() public {
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, KEEPER));
        adapter.configureFeed(POOL, _aaplBase());
    }

    function test_access_onlyOwnerRemoves() public {
        _configure();
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, KEEPER));
        adapter.removeFeed(POOL);
    }

    /// Executing the decision is not privileged. Anyone may refresh, and cannot influence it.
    function test_access_refreshIsPermissionless() public {
        _configure();
        _publish();

        vm.prank(KEEPER);
        (uint160 byKeeper,) = adapter.refresh(POOL);
        (uint160 byOwner,) = adapter.refresh(POOL);
        assertEq(byKeeper, byOwner, "the caller cannot change the answer");
    }

    /**
     * `renounceOwnership` is on the house's permanent do-not-call list (CLAUDE.md § "Deployed and
     * unfixable"), and here it would strand every pool this adapter serves: nobody could repoint a
     * deprecated aggregator, so each pool would run out its heartbeat and halt with no recovery.
     *
     * FAILS AGAINST STOCK OZ: without the override the first call succeeds and `owner()` becomes
     * zero.
     */
    function test_renounceOwnership_isDisabled() public {
        vm.expectRevert(ChainlinkPriceBandAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();

        // Not merely gated on the owner — there is no caller for whom it works.
        vm.prank(KEEPER);
        vm.expectRevert(ChainlinkPriceBandAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();

        assertEq(adapter.owner(), address(this), "ownership must survive the attempt");

        // The bounded form of the same intent still works, and is two-step.
        adapter.transferOwnership(KEEPER);
        assertEq(adapter.owner(), address(this), "step one must not move ownership");
        vm.prank(KEEPER);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), KEEPER);

        vm.prank(KEEPER);
        vm.expectRevert(ChainlinkPriceBandAdapter.RenounceDisabled.selector);
        adapter.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_config_rejectsZeroAggregator() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.aggregator = address(0);
        vm.expectRevert(ChainlinkPriceBandAdapter.ZeroAddress.selector);
        adapter.configureFeed(POOL, f);
    }

    /// `heartbeat` is the only thing that ages a cached reference out, and on a chain with no
    /// uptime feed it is the only thing that makes the adapter fail closed at all. Both ends are
    /// bounded: zero would halt every pool, and a heartbeat of months would stop being a bound.
    function test_config_rejectsHeartbeatAtEitherExtreme() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.heartbeat = 0;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.InvalidHeartbeat.selector, uint32(0)));
        adapter.configureFeed(POOL, f);

        f.heartbeat = uint32(7 days) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkPriceBandAdapter.InvalidHeartbeat.selector, uint32(uint256(7 days) + 1)
            )
        );
        adapter.configureFeed(POOL, f);

        // Exactly at the ceiling is accepted; the bound is a mistake filter, not a policy.
        f.heartbeat = uint32(7 days);
        adapter.configureFeed(POOL, f);
        assertEq(adapter.feedFor(POOL).heartbeat, uint32(7 days));
    }

    function test_config_rejectsAbsurdDecimals() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.baseDecimals = 37;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceBandAdapter.InvalidDecimals.selector, uint8(37), uint8(6))
        );
        adapter.configureFeed(POOL, f);

        f = _aaplBase();
        f.feedDecimals = 37;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.InvalidFeedDecimals.selector, uint8(37)));
        adapter.configureFeed(POOL, f);
    }

    /// A configured `feedDecimals` that disagrees with the aggregator is a typo that would price
    /// the pool wrong by a power of ten. Caught at configuration time, not at the first swap.
    function test_config_rejectsDecimalsThatDisagreeWithTheFeed() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.feedDecimals = 18;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkPriceBandAdapter.DecimalsChanged.selector, uint8(18), uint8(8))
        );
        adapter.configureFeed(POOL, f);
    }

    /// The `decimals()` call also proves the address is a contract answering the ABI, so an
    /// aggregator address off by a character cannot sit in storage looking configured.
    function test_config_rejectsAnAggregatorThatIsNotAContract() public {
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.aggregator = address(0xC0FFEE);
        vm.expectRevert();
        adapter.configureFeed(POOL, f);
    }

    /*//////////////////////////////////////////////////////////////
                    THE TIMESTAMP IS THE FEED'S OWN
    //////////////////////////////////////////////////////////////*/

    /// The property the whole fail-closed design rests on. A cache written now from an old round
    /// is an old price, and the consumer's staleness window must see it as one.
    function test_reportsTheRoundTimestampNotTheRefreshTime() public {
        _configure();
        uint256 roundAt = NOW - 1200;
        aggregator.set(AAPL_ANSWER, roundAt);

        vm.warp(NOW + 30);
        (, uint64 fromRefresh) = adapter.refresh(POOL);
        (, uint64 fromView) = adapter.referencePrice(POOL);

        assertEq(uint256(fromRefresh), roundAt, "refresh must report the round timestamp");
        assertEq(uint256(fromView), roundAt, "the view must report the round timestamp");
        assertTrue(fromView != uint64(block.timestamp), "never block.timestamp");
    }

    /*//////////////////////////////////////////////////////////////
                          PREVIEW / OPERATOR VIEWS
    //////////////////////////////////////////////////////////////*/

    /// A keeper simulates before it sends (CLAUDE.md § Automation). `previewRefresh` must give the
    /// same answer and the same errors, so the simulation is a free read of every guard.
    function test_previewRefresh_agreesWithRefreshAndWithItsErrors() public {
        _configure();
        _publish();
        (uint160 previewed, uint64 previewedAt) = adapter.previewRefresh(POOL);
        (uint160 actual, uint64 actualAt) = adapter.refresh(POOL);
        assertEq(previewed, actual);
        assertEq(previewedAt, actualAt);

        sequencer.set(1, NOW);
        vm.expectRevert(ChainlinkPriceBandAdapter.SequencerDown.selector);
        adapter.previewRefresh(POOL);
    }

    function test_operatorViews() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        ChainlinkPriceBandAdapter.Feed memory f = adapter.feedFor(POOL);
        assertEq(f.aggregator, address(aggregator));
        assertEq(f.heartbeat, HEARTBEAT);
        assertEq(adapter.feedDescription(POOL), "AAPL / USD");

        ChainlinkPriceBandAdapter.Cached memory c = adapter.cachedReference(POOL);
        assertGt(c.sqrtPriceX96, 0);
        assertEq(uint256(c.roundUpdatedAt), NOW);

        (bool enabled, bool ok,) = adapter.sequencerStatus();
        assertTrue(enabled);
        assertTrue(ok);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceBandAdapter.FeedNotConfigured.selector, OTHER_POOL));
        adapter.feedDescription(OTHER_POOL);
    }

    /*//////////////////////////////////////////////////////////////
                              GAS BUDGET
    //////////////////////////////////////////////////////////////*/

    /// `referencePrice` runs inside a Vault lock, reached by `staticcall` under
    /// `PRICE_ORACLE_GAS_LIMIT`. Exceeding it makes the oracle read as
    /// unavailable and halts the pool, so its cost is a correctness property, not an optimisation.
    ///
    /// Measured through a harness that reproduces the module's own call exactly — same gas cap,
    /// same `returndatasize` check — so this demonstrates the budget rather than estimating it.
    ///
    /// WHAT IS AND IS NOT MEASURED. The refresh that precedes each read has already warmed the
    /// adapter's account, its two storage slots and the uptime feed's account, so these are WARM
    /// figures and are labelled as such; this forge-std has no cheatcode to cool them again. The
    /// cold delta is bounded and countable rather than mysterious: at most two cold account
    /// accesses (the adapter and the uptime feed, 2,600 each) plus four cold storage reads (this
    /// adapter's two and the uptime feed's two, 2,100 each) — under 14,000 gas. Every threshold
    /// below leaves far more headroom than that, so a genuinely cold read is covered by the same
    /// bound.
    function test_referencePrice_fitsTheModulesGasBudget() public {
        _configure();
        _publish();
        adapter.refresh(POOL);

        (bool callOk, uint160 p, uint64 t, uint256 gasUsed) =
            harness.query(IPriceBandOracle(address(adapter)), POOL);

        assertTrue(callOk, "the module must be able to read this oracle at all");
        assertGt(p, 0);
        assertEq(uint256(t), NOW);

        emit log_named_uint("referencePrice gas, uptime feed CONFIGURED (warm)", gasUsed);
        emit log_named_uint("PRICE_ORACLE_GAS_LIMIT", PRICE_ORACLE_GAS_LIMIT);

        // A quarter of the budget, which leaves room for every cold access enumerated above and
        // then some. A regression that added a loop or a second external call would blow through
        // this long before it reached the module's real cap.
        assertLt(gasUsed, PRICE_ORACLE_GAS_LIMIT / 4, "must fit with wide margin");
    }

    /// The budget this file measures against must be the module's actual one.
    function test_gasLimitMatchesTheModule() public {
        GasLimitPin pin = new GasLimitPin();
        assertEq(
            PRICE_ORACLE_GAS_LIMIT,
            pin.PRICE_ORACLE_GAS_LIMIT(),
            "the restated budget has drifted from MarketHoursModule"
        );
    }

    /// Without an uptime feed the view is two SLOADs and nothing else. The difference between this
    /// figure and the one above is exactly what the L2 check costs a trader per swap.
    function test_referencePrice_fitsTheBudgetWithoutAnUptimeFeed() public {
        bare.configureFeed(POOL, _aaplBase());
        _publish();
        bare.refresh(POOL);

        (bool callOk,,, uint256 gasUsed) = harness.query(IPriceBandOracle(address(bare)), POOL);
        assertTrue(callOk);
        emit log_named_uint("referencePrice gas, uptime feed ABSENT (warm)", gasUsed);
        assertLt(gasUsed, PRICE_ORACLE_GAS_LIMIT / 10);
    }

    /// The unavailable paths must be cheap too. A halted pool still pays for this read on every
    /// swap it rejects, and a rejection that ran the budget out would be indistinguishable to the
    /// module from a broken oracle.
    function test_referencePrice_unavailablePathsAreAlsoCheap() public {
        // Never configured: the earliest exit, one SLOAD.
        (bool ok1,,, uint256 unconfigured) = harness.query(IPriceBandOracle(address(adapter)), OTHER_POOL);
        assertTrue(ok1);
        emit log_named_uint("referencePrice gas, pool not configured", unconfigured);

        // Configured, cached, then aged out.
        _configure();
        _publish();
        adapter.refresh(POOL);
        vm.warp(NOW + HEARTBEAT + 1);
        (bool ok2, uint160 p,, uint256 aged) = harness.query(IPriceBandOracle(address(adapter)), POOL);
        assertTrue(ok2);
        assertEq(p, 0);
        emit log_named_uint("referencePrice gas, cache aged out", aged);

        assertLt(unconfigured, PRICE_ORACLE_GAS_LIMIT / 10);
        assertLt(aged, PRICE_ORACLE_GAS_LIMIT / 10);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// Over any plausible price and any plausible pair of token decimals, the conversion must
    /// produce a representable price, must never revert, and must NEVER INVERT THE BAND: the two
    /// token orderings must be reciprocals of each other, and a higher feed price must always mean
    /// a higher `sqrtPriceX96` when the base token is currency0.
    ///
    /// Inversion is the failure the interface singles out, and it is not detectable from a single
    /// value — only from the relationship between values. Hence both properties here.
    function testFuzz_conversionIsRepresentableAndNeverInverts(
        uint256 answer,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint8 feedDecimalsSeed
    ) public {
        // Prices from 1e-4 to 1e8 in human terms, which spans both fixed-point branches.
        answer = bound(answer, 1e4, 1e16);
        baseDecimals = uint8(bound(baseDecimals, 6, 18));
        quoteDecimals = uint8(bound(quoteDecimals, 6, 18));
        uint8 feedDecimals = [uint8(6), uint8(8), uint8(18)][bound(feedDecimalsSeed, 0, 2)];

        MockAggregator agg = new MockAggregator(feedDecimals, "FUZZ / USD");
        // Keep the human price in range whatever the feed's own scale is.
        agg.set(int256(answer * (10 ** uint256(feedDecimals)) / 1e8), NOW);

        ChainlinkPriceBandAdapter.Feed memory f = ChainlinkPriceBandAdapter.Feed({
            aggregator: address(agg),
            baseIsCurrency0: true,
            baseDecimals: baseDecimals,
            quoteDecimals: quoteDecimals,
            feedDecimals: feedDecimals,
            heartbeat: HEARTBEAT
        });
        adapter.configureFeed(POOL, f);
        (uint160 forward,) = adapter.refresh(POOL);

        f.baseIsCurrency0 = false;
        adapter.configureFeed(POOL, f);
        (uint160 inverse,) = adapter.refresh(POOL);

        // Representable at both orderings.
        assertGe(uint256(forward), TickMath.MIN_SQRT_RATIO);
        assertLe(uint256(forward), TickMath.MAX_SQRT_RATIO);
        assertGe(uint256(inverse), TickMath.MIN_SQRT_RATIO);
        assertLe(uint256(inverse), TickMath.MAX_SQRT_RATIO);

        // sqrt(R) * sqrt(1/R) == 1, so the product of the two X96 values is 2**192 up to the
        // rounding of two integer square roots. If the adapter ever returned the same number for
        // both orderings — the classic inversion bug — this fails immediately.
        uint256 product = Math.mulDiv(uint256(forward), uint256(inverse), 1 << 96);
        assertApproxEqRel(product, uint256(1) << 96, 1e9, "the two orderings must be reciprocals");
    }

    /// Monotonicity, checked separately because it is the property a sign error breaks while
    /// reciprocity still holds.
    function testFuzz_higherPriceMeansHigherSqrtPrice(uint256 lowAnswer, uint256 delta) public {
        lowAnswer = bound(lowAnswer, 1e4, 1e14);
        delta = bound(delta, 1, 1e14);

        _configure();

        aggregator.set(int256(lowAnswer), NOW);
        (uint160 low,) = adapter.refresh(POOL);

        aggregator.set(int256(lowAnswer + delta), NOW);
        (uint160 high,) = adapter.refresh(POOL);

        assertGe(uint256(high), uint256(low), "base as currency0: price up must mean sqrtPrice up");

        // And strictly the other way round when the base token is currency1.
        ChainlinkPriceBandAdapter.Feed memory f = _aaplBase();
        f.baseIsCurrency0 = false;
        adapter.configureFeed(POOL, f);

        aggregator.set(int256(lowAnswer), NOW);
        (uint160 invLow,) = adapter.refresh(POOL);
        aggregator.set(int256(lowAnswer + delta), NOW);
        (uint160 invHigh,) = adapter.refresh(POOL);

        assertLe(uint256(invHigh), uint256(invLow), "base as currency1: price up must mean sqrtPrice down");
    }

    /// Whatever the round looks like, the view answers in exactly two words and never reverts.
    /// That is rule 3 of the interface, and it is what the module's `returndatasize` check enforces
    /// on the other side.
    function testFuzz_viewNeverRevertsWhateverTheRoundWas(int256 answer, uint64 roundAt, uint64 warpTo)
        public
    {
        _configure();
        aggregator.set(answer, roundAt);
        try adapter.refresh(POOL) {} catch {}

        vm.warp(bound(uint256(warpTo), NOW, NOW + 365 days));

        (bool callOk, uint160 p,, uint256 gasUsed) = harness.query(IPriceBandOracle(address(adapter)), POOL);
        assertTrue(callOk, "the view must always answer in two words");
        assertLt(gasUsed, PRICE_ORACLE_GAS_LIMIT / 4);
        if (p != 0) {
            assertGe(uint256(p), TickMath.MIN_SQRT_RATIO);
            assertLe(uint256(p), TickMath.MAX_SQRT_RATIO);
        }
    }
}
