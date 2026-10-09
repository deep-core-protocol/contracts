/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IPriceBandOracle} from "../interfaces/IPriceBandOracle.sol";

/// @title ManualPriceBandOracle
/// @notice A minimal, self-custodied `IPriceBandOracle`: a reference price per pool, published
/// on-chain by the issuer or by keepers the issuer designates.
///
/// @dev ############################ WHAT THIS IS FOR ############################
///
/// This is the REFERENCE implementation and the fallback for an issuer who already knows what the
/// asset is worth - because a transfer agent, a fund administrator, a primary venue or their own
/// market-making desk tells them - and simply needs somewhere to publish it. It is deliberately
/// the dumbest thing that can work: a mapping, an owner, a publisher set, and events.
///
/// It verifies nothing. It reports what its publishers wrote into it. An issuer with a real feed
/// should write a thin adapter that implements `IPriceBandOracle` over that feed instead - the
/// whole point of the interface is that this contract is replaceable.
///
/// Nothing here is legal advice, and a price published here is not a valuation, a NAV, a mark, an
/// official closing price, or a representation that any trade near it is fair or lawful. See
/// `IPriceBandOracle`.
///
/// ####################### THE UNIT. GET THIS WRONG AND THE BAND INVERTS. #######################
///
/// `sqrtPriceX96` is in the POOL's units:
///
///     sqrt(currency1 per 1 currency0, each in its own smallest unit) * 2**96
///
/// The same number `ICLPoolManager.getSlot0` returns. It is not a USD price and it depends on
/// which of the pair's two tokens sorted lower. A publisher converting from a human price must do
/// the decimals and the ordering itself; the safest way to confirm is to read the live pool's
/// `getSlot0` and check the published value is the same order of magnitude.
///
/// This contract cannot check that for you - it does not know the pool's tokens - so it applies
/// the only check it can: the value must be inside the range core can represent at all.
///
/// ############################ DESIGN NOTES ############################
///
///  * The whole read is ONE storage slot, deliberately. `MarketHoursModule` calls this inside a
///    Vault lock under a hard gas cap; an implementation that loops, or that calls out to
///    something that loops, gets denied by that cap and takes the pool's trading with it.
///
///  * `updatedAt` is stamped by this contract, not supplied by the publisher, so a stale price
///    cannot be re-dated without re-publishing it. The consumer enforces its own staleness window
///    against that stamp.
///
///  * `clearReference` publishes "no price", which the consumer reads as oracle-unavailable and
///    which therefore STOPS TRADING on any pool whose band is enabled. That is a halt lever
///    reachable from the feed side, and it should be understood as one: a publisher key is a key
///    that can stop the market. It cannot start one that the calendar or a halt has stopped, and
///    it can never block an LP exit.
///
///  * A PUBLISHER KEY ALSO MOVES THE BAND, and that is the more dangerous power of the two.
///    `MarketHoursModule` defines the band as a ratio to whatever this contract reports, so
///    whoever moves the reference moves the band with it. Unbounded, that makes the publisher
///    role a complete bypass of the price band rather than a feed into it: set the reference
///    high enough and the swap the band refused a block ago is suddenly "in band".
///
///    Every other fast key in this design only ever RESTRICTS - a guardian may halt but not
///    resume, an issuer may close a day but cannot touch the widths. The publisher is the one
///    fast key that LOOSENS, so it is the one that needs a bound.
///
///    `maxPublisherDeviationBps` is that bound: a publisher may move a pool's reference by at
///    most that much, in PRICE terms, measured against `anchor` - the last non-zero price, which
///    survives `clearReference` precisely so that clearing is not a way around it. Beyond the
///    bound the move belongs to the owner, which on a live chain is a timelock.
///
///    Be clear about what this does and does not buy. It does NOT make a compromised publisher
///    harmless: a key that may move 10% per update, with no interval configured, can still walk
///    the reference anywhere over enough transactions. What it buys is TIME and VISIBILITY - the
///    walk is bounded per step, every step emits `ReferencePriceSet`, and the owner can revoke
///    the key or re-anchor while it is happening. Set `minPublisherInterval` on a live deployment
///    to make the walk slow enough to actually respond to; the default of 0 does not.
///
///  * Ownership is `Ownable2Step`, and on a live chain the owner should be a timelock or multisig.
///    Publishers are deliberately NOT timelocked - a reference price that arrives six hours late
///    is not a reference price - which is why the publisher role can only write prices, cannot
///    appoint anyone, and cannot move a price further than the owner has allowed.
contract ManualPriceBandOracle is IPriceBandOracle, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is neither the owner nor a designated publisher
    error NotPublisher(address caller);

    /// @notice The zero address cannot be a publisher
    error ZeroAddress();

    /// @notice Batch arguments had mismatched lengths
    error LengthMismatch(uint256 poolIdsLength, uint256 pricesLength);

    /// @notice A price outside the range core can represent as a pool price.
    /// @dev Not a claim that the price is wrong, only that it is not a price this pool type could
    /// ever trade at, which is the one sanity check this contract is in a position to make.
    error PriceOutOfRange(uint160 sqrtPriceX96);

    /// @notice A publisher tried to move the reference further than `maxPublisherDeviationBps`.
    /// @dev The owner is exempt. Deviation is measured in PRICE terms against `anchor`, not
    /// against the currently published value - see `_priceDeviationBps`.
    error DeviationTooLarge(
        PoolId poolId, uint160 anchor, uint160 attempted, uint256 deviationBps, uint256 maxBps
    );

    /// @notice A publisher tried to move the reference again before `minPublisherInterval` elapsed.
    error UpdateTooSoon(PoolId poolId, uint64 earliest);

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every published reference, and on every clearing (`sqrtPriceX96 == 0`)
    event ReferencePriceSet(PoolId indexed poolId, address indexed by, uint160 sqrtPriceX96, uint64 updatedAt);

    /// @notice Emitted when a publisher is designated or removed
    event PublisherSet(address indexed publisher, bool allowed);

    /// @notice Emitted when the owner changes the limits that apply to publishers.
    /// @dev Emitted from the constructor with the defaults, so the bounds a deployment starts
    /// life with are on-chain history rather than something a reader has to infer.
    event PublisherBoundsSet(uint256 maxDeviationBps, uint64 minUpdateInterval);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @param sqrtPriceX96 The reference, in the pool's units. 0 means "no price".
    /// @param updatedAt Stamped by this contract when the price was written.
    /// @param anchor The last NON-ZERO price published for this pool. This is the value a
    ///        publisher's next move is measured against, and it deliberately SURVIVES
    ///        `clearReference`. If the bound were measured against `sqrtPriceX96`, a publisher
    ///        could clear the pool to zero and then republish anything at all as a "first"
    ///        price - which is the exact bypass this bound exists to close.
    /// @param anchorAt When `anchor` was last written. `minPublisherInterval` is measured from
    ///        here, so clearing a price does not reset a publisher's rate limit either.
    struct Reference {
        uint160 sqrtPriceX96;
        uint64 updatedAt;
        uint160 anchor;
        uint64 anchorAt;
    }

    /// @notice The register. A pool that has never been published reads back as `(0, 0)`, which
    /// the consumer treats as unavailable.
    /// @dev Layout is load-bearing. `sqrtPriceX96 + updatedAt` is 224 bits and shares one slot;
    /// `anchor + anchorAt` is another 224 and shares the next. `referencePrice` - the hot read,
    /// made inside a Vault lock under a hard gas cap - touches only the first slot, so the bound
    /// added here costs the consumer nothing.
    mapping(PoolId poolId => Reference) internal _references;

    /// @notice Accounts permitted to publish prices, and to do nothing else.
    mapping(address publisher => bool) public isPublisher;

    /// @notice The largest single move, in PRICE bps, a publisher may make to a pool's reference.
    /// @dev The owner is exempt: on a live chain the owner is a timelock, and a re-anchor that
    /// has sat in a timelock is a deliberate act with a public notice period, which is precisely
    /// what this bound is asking for.
    uint256 public maxPublisherDeviationBps;

    /// @notice Minimum seconds between two publisher moves on the same pool. 0 disables it.
    /// @dev Clearing a price is NOT rate limited - see `clearReference`. Stopping must never
    /// have to wait.
    uint64 public minPublisherInterval;

    /// @notice Default publisher move limit: 1000 bps = a 10% price move per update.
    /// @dev A real default rather than a permissive one. A deployment that never calls
    /// `setPublisherBounds` is still bounded.
    uint256 internal constant DEFAULT_MAX_DEVIATION_BPS = 1000;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Fixed-point scale for the sqrt-space ratio. 1e9 keeps the squaring well inside
    /// uint256 while leaving nine digits of precision, far more than a bps comparison needs.
    uint256 private constant RATIO_SCALE = 1e9;

    /// @dev Reject before squaring above 4x in sqrt space, i.e. 16x in price. Any configured
    /// bound this large has stopped being a bound, and the clamp is what keeps `sqrtRatio *
    /// sqrtRatio` provably inside uint256.
    uint256 private constant RATIO_CLAMP = 4 * RATIO_SCALE;

    /// @param initialOwner Ownership seat. On a live chain this should be a timelock or multisig.
    constructor(address initialOwner) Ownable(initialOwner) {
        maxPublisherDeviationBps = DEFAULT_MAX_DEVIATION_BPS;
        emit PublisherBoundsSet(DEFAULT_MAX_DEVIATION_BPS, 0);
    }

    modifier onlyPublisher() {
        if (msg.sender != owner() && !isPublisher[msg.sender]) revert NotPublisher(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Designate or remove a publisher. Owner only.
    function setPublisher(address publisher, bool allowed) external onlyOwner {
        if (publisher == address(0)) revert ZeroAddress();
        isPublisher[publisher] = allowed;
        emit PublisherSet(publisher, allowed);
    }

    /// @notice Set the limits that apply to publishers. Owner only; the owner itself is exempt.
    /// @param maxDeviationBps Largest single PRICE move a publisher may make, in bps against the
    ///        pool's `anchor`. Setting this very large re-opens the bypass it exists to close -
    ///        it is deliberately not capped, because the owner is a timelock and this is its
    ///        decision to make, but it is the decision to make carefully.
    /// @param minUpdateInterval Seconds a publisher must wait between moves on the same pool.
    ///        0 disables the rate limit. Clearing a price is never rate limited.
    function setPublisherBounds(uint256 maxDeviationBps, uint64 minUpdateInterval) external onlyOwner {
        maxPublisherDeviationBps = maxDeviationBps;
        minPublisherInterval = minUpdateInterval;
        emit PublisherBoundsSet(maxDeviationBps, minUpdateInterval);
    }

    /**
     * @notice Permanently disabled. Reverts for every caller.
     *
     * @dev CLAUDE.md § "Deployed and unfixable" makes this the house rule for every contract
     * deployed from here on, and `MerkleEpochDistributor` is the reference. The reason applies
     * with more force here than almost anywhere, because the owner is the only check on the one
     * fast key in this design that LOOSENS the band.
     *
     *   * `setPublisher` is the only way to REVOKE a publisher. After a renounce, a compromised
     *     publisher key can never be removed, and it keeps walking the reference — and with it the
     *     band — by up to `maxPublisherDeviationBps` per update for the life of the contract.
     *   * `setPublisherBounds` is the only way to set `minPublisherInterval`. A deployment
     *     renounced at the default of 0 can never be rate limited, which is the exact condition
     *     under which the per-update bound stops meaning anything.
     *   * The owner is the only seat exempt from the bound. A genuine re-anchor beyond it — a
     *     split, a redenomination — would have no route except a public walk of in-bound steps.
     *
     * `transferOwnership` is itself `onlyOwner`, so none of this is recoverable.
     *
     * The bounded form of the same intent already exists and is unaffected: an owner who wants out
     * transfers to the address that should have it. `Ownable2Step` means that cannot land somewhere
     * unreachable by typo.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev An oracle holds nothing by design, so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Publish the reference price for one pool.
    /// @param sqrtPriceX96 The reference in the pool's units. Must be in core's representable
    ///        range; use `clearReference` to withdraw a price rather than passing 0 here, so that
    ///        "no price" is always an explicit act.
    function setReferencePrice(PoolId poolId, uint160 sqrtPriceX96) external onlyPublisher {
        _setReference(poolId, sqrtPriceX96);
    }

    /// @notice Publish reference prices for several pools at once.
    /// @dev Bounded by the calldata arrays the caller pays for; no growable set is iterated.
    function setReferencePrices(PoolId[] calldata poolIds, uint160[] calldata sqrtPricesX96)
        external
        onlyPublisher
    {
        if (poolIds.length != sqrtPricesX96.length) {
            revert LengthMismatch(poolIds.length, sqrtPricesX96.length);
        }
        for (uint256 i = 0; i < poolIds.length; ++i) {
            _setReference(poolIds[i], sqrtPricesX96[i]);
        }
    }

    /// @notice Withdraw the reference price for a pool.
    /// @dev Understand what this does: on any pool with `bandEnabled`, the consumer reads a
    /// missing reference as oracle-unavailable and REJECTS EVERY SWAP. This is a market stop
    /// operated from the price side. It never blocks an LP exit.
    function clearReference(PoolId poolId) external onlyPublisher {
        // `uint64` seconds runs to the year 584 billion. The cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 clearedAt = uint64(block.timestamp);

        // Field-by-field, NOT a whole-struct assignment. Overwriting the struct would also zero
        // `anchor`/`anchorAt`, and a publisher could then clear a pool and republish any price at
        // all as an unbounded "first" publication. The anchor is what the next move is measured
        // against, so it has to outlive the clearing.
        Reference storage ref = _references[poolId];
        ref.sqrtPriceX96 = 0;
        ref.updatedAt = clearedAt;

        emit ReferencePriceSet(poolId, msg.sender, 0, clearedAt);
    }

    function _setReference(PoolId poolId, uint160 sqrtPriceX96) private {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO || sqrtPriceX96 > TickMath.MAX_SQRT_RATIO) {
            revert PriceOutOfRange(sqrtPriceX96);
        }

        Reference storage ref = _references[poolId];
        uint160 anchor = ref.anchor;

        // The owner is exempt; a publisher is not. `anchor == 0` means this pool has genuinely
        // never had a price, so there is nothing to measure a deviation against and the first
        // publication is necessarily unbounded. Note that `clearReference` does NOT reset the
        // anchor, so "clear it and republish anything" is not a way back into this branch.
        if (anchor != 0 && msg.sender != owner()) {
            uint64 interval = minPublisherInterval;
            if (interval != 0) {
                uint256 earliest = uint256(ref.anchorAt) + uint256(interval);
                // forge-lint: disable-next-line(unsafe-typecast)
                if (block.timestamp < earliest) revert UpdateTooSoon(poolId, uint64(earliest));
            }

            uint256 deviationBps = _priceDeviationBps(sqrtPriceX96, anchor);
            uint256 maxBps = maxPublisherDeviationBps;
            if (deviationBps > maxBps) {
                revert DeviationTooLarge(poolId, anchor, sqrtPriceX96, deviationBps, maxBps);
            }
        }

        // `uint64` seconds runs to the year 584 billion. The cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 updatedAt = uint64(block.timestamp);
        ref.sqrtPriceX96 = sqrtPriceX96;
        ref.updatedAt = updatedAt;
        ref.anchor = sqrtPriceX96;
        ref.anchorAt = updatedAt;
        emit ReferencePriceSet(poolId, msg.sender, sqrtPriceX96, updatedAt);
    }

    /// @dev Deviation between two sqrt-space prices, expressed in PRICE bps.
    ///
    /// Measured on the PRICE, not on the sqrt, because that is the number an operator thinks in:
    /// a 5% move in `sqrtPriceX96` is a ~10.25% move in price, and a bound that quietly meant the
    /// latter while reading as the former is exactly the kind of unit confusion this file's
    /// header warns about.
    ///
    /// Symmetric by construction: the larger of the two is always the numerator, so a halving and
    /// a doubling both report the same distance. That is the right semantic for a price - "10%
    /// away" should not depend on which way you travelled.
    function _priceDeviationBps(uint160 newSqrtPriceX96, uint160 anchorSqrtPriceX96)
        private
        pure
        returns (uint256)
    {
        uint256 hi = newSqrtPriceX96 >= anchorSqrtPriceX96 ? newSqrtPriceX96 : anchorSqrtPriceX96;
        uint256 lo = newSqrtPriceX96 >= anchorSqrtPriceX96 ? anchorSqrtPriceX96 : newSqrtPriceX96;

        // `lo` cannot be zero: the caller has already rejected anything below MIN_SQRT_RATIO, and
        // this is only reached when `anchor != 0`.
        uint256 sqrtRatio = (hi * RATIO_SCALE) / lo;

        // Bail out before squaring. Anything this far out is rejected by any sane bound anyway,
        // and returning max keeps `sqrtRatio * sqrtRatio` provably inside uint256 below.
        if (sqrtRatio >= RATIO_CLAMP) return type(uint256).max;

        uint256 priceRatio = (sqrtRatio * sqrtRatio) / RATIO_SCALE;
        return ((priceRatio - RATIO_SCALE) * BPS_DENOMINATOR) / RATIO_SCALE;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The raw record for a pool
    function referenceRecord(PoolId poolId) external view returns (Reference memory) {
        return _references[poolId];
    }

    /// @notice The value a publisher's next move on this pool is measured against, and the
    /// earliest timestamp at which they may make it.
    /// @dev `anchor == 0` means the pool has never been published and the next write is
    /// unbounded. Exposed so an operator can see what the bound will allow BEFORE sending a
    /// transaction that reverts.
    function publisherBoundsFor(PoolId poolId)
        external
        view
        returns (uint160 anchor, uint64 earliestUpdate, uint256 maxDeviationBps)
    {
        Reference storage ref = _references[poolId];
        anchor = ref.anchor;
        // forge-lint: disable-next-line(unsafe-typecast)
        earliestUpdate = anchor == 0 ? 0 : uint64(uint256(ref.anchorAt) + uint256(minPublisherInterval));
        maxDeviationBps = maxPublisherDeviationBps;
    }

    /// @inheritdoc IPriceBandOracle
    function referencePrice(PoolId poolId) external view override returns (uint160 sqrtPriceX96, uint64 updatedAt) {
        Reference storage r = _references[poolId];
        return (r.sqrtPriceX96, r.updatedAt);
    }
}
