// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {BitMath} from "infinity-core/src/pool-cl/libraries/BitMath.sol";

import {IDeepCoreLiquidityRewards} from "./interfaces/IDeepCoreLiquidityRewards.sol";
import {RewardMath} from "./libraries/RewardMath.sol";

/// @dev The three ERC-721 reads the claim authorisation needs from the canonical CL position manager.
interface IPositionNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// @title LiquidityRewardsModule
/// @notice Streams reward tokens to in-range concentrated liquidity, per second of `block.timestamp`,
/// in proportion to each position's share of the eligible liquidity in range during those seconds.
/// Design of record: `docs/products/liquidity-rewards.md`. CL only.
///
/// @dev ##################################### THE REMOVAL RULE #####################################
/// This module runs inside `beforeRemoveLiquidity`. A revert there is an LP who cannot withdraw, so on
/// every path a liquidity callback can reach:
///   * no external call (the only external read, `getSlot0`, is in the SWAP callback),
///   * no transfer (rewards leave only through `claim`/`claimCredit`, in their own transaction),
///   * every subtraction on the mirror saturates at zero and every growth difference wraps, as core's do,
///   * every multiplication is 512-bit and saturates (`RewardMath`),
///   * no loop over anything a stranger can lengthen (at most `MAX_REWARD_TOKENS` = 3 streams).
/// If the mirror is ever wrong the damage is a mis-counted reward inside ONE pool's ledger (claims are
/// capped by that pool's `accruedUnpaid`), never locked principal and never another pool's money.
/// ##############################################################################################
///
/// HOW TIME IN RANGE IS MEASURED. Core records no time, so the module keeps its own copy of the pool's
/// liquidity map, restricted to ELIGIBLE positions (width `>= minWidthTicks`, liquidity
/// `>= MIN_ELIGIBLE_LIQUIDITY`): per-tick gross/net and a per-token `growthOutside` flipped at every
/// crossing, exactly as core does for fees, and its own tick bitmap to find crossings without calling core.
/// `growthGlobal += accrued * 2^128 / eligibleLiquidity`; a position earns
/// `liquidity * (growthInside - growthInsideLast) / 2^128`.
///
/// LEDGER, per token (`totalOwed`): for every pool, `undistributed` (funded, not yet accrued) +
/// `accruedUnpaid` (accrued, not yet claimed or credited) + every `credit` + `protocolOwed`. The balance is
/// never below it; `sweep` pays only what is above it, to the immutable protocol recipient.
abstract contract LiquidityRewardsModule is IDeepCoreLiquidityRewards, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 public constant MAX_REWARD_TOKENS = 3;
    uint32 public constant MIN_STREAM_DURATION = 1 days;
    uint32 public constant MAX_STREAM_DURATION = 365 days;
    /// @notice A top-up needs at least this much of the stream left, so a stranger's 1 wei cannot be used
    /// to re-rate a stream in its last seconds.
    uint32 public constant MIN_TOPUP_REMAINING = 1 hours;
    uint64 public constant MIN_DELAY = 30 days;
    uint64 public constant MAX_DELAY = 730 days;
    /// @notice Compile-time ceiling above the immutable cap: 3% of funded rewards.
    uint16 public constant ABSOLUTE_MAX_PROTOCOL_FEE_BPS = 300;
    /// @notice Floor on the notice a fee increase sits behind. `block.timestamp`; a sequencer may run it
    /// slightly ahead (CLAUDE.md L-2). Only the owner can schedule, inside the immutable cap.
    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;
    uint16 internal constant BPS = 10_000;
    /// @notice Domain-separated identity, read by off-chain consumers (never by an address list).
    bytes32 public constant kind = keccak256("deepcore.liquidity-rewards.cl.v1");

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    struct ModuleParams {
        address owner; // the governance Safe: the protocol fee ONLY
        address positionManager; // the canonical CLPositionManager
        address protocolFeeRecipient; // the governance Safe
        uint16 initialFeeBps;
        uint16 maxFeeBps;
        uint32 feeNoticeSeconds;
        uint64 recycleDelay;
        uint64 reclaimDelay;
        uint128 minEligibleLiquidity;
    }

    /// @notice The canonical CL position manager. Positions it holds are claimable by the NFT's owner or
    /// an address it approved, and only its removals may name a recipient in `hookData`.
    address public immutable POSITION_MANAGER;
    /// @notice The only address protocol fees and sweeps are ever paid to.
    address public immutable protocolFeeRecipient;
    uint16 public immutable maxProtocolFeeBps;
    uint32 public immutable feeNoticeSeconds;
    /// @notice A position with zero liquidity untouched this long may have its unclaimed rewards returned
    /// to the stream by anyone.
    uint64 public immutable RECYCLE_DELAY;
    /// @notice A pool with zero eligible liquidity this long without a break (or a stream finished this
    /// long ago) may have its undistributed remainder returned to the refund recipient by anyone.
    uint64 public immutable RECLAIM_DELAY;
    /// @notice A position below this liquidity is not mirrored and earns nothing: it raises the cost of
    /// filling the mirror with dust ticks every swap must cross.
    uint128 public immutable MIN_ELIGIBLE_LIQUIDITY;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    struct PoolState {
        address owner; // configured iff non-zero
        uint64 zeroSince; // when eligible liquidity last became zero; 0 while it is positive
        uint8 tokenCount;
        bool initialized;
        address pendingOwner;
        int24 tickSpacing;
        int24 lastTick; // the pool's tick after its last swap (or at initialize)
        uint24 minWidthTicks;
        uint128 eligibleLiquidity;
        uint128 mirroredTotal; // every mirrored position's liquidity, in range or not
        Currency[3] tokens;
    }

    struct Stream {
        uint128 undistributed;
        uint128 accruedUnpaid;
        uint256 rateX64;
        uint64 lastUpdate;
        uint64 periodFinish;
        uint128 fraction; // the part of growth * liquidity below one unit, carried to the next accrual
        address refundRecipient;
        uint256 storedEarned; // sum of settled, unclaimed `Position.earned` (for the dust rule only)
    }

    struct TickInfo {
        uint128 gross;
        int128 net;
        uint256[3] outside;
    }

    struct Position {
        uint128 liquidity; // the hook's record of the position's core liquidity (0 for ineligible widths)
        uint64 lastTouched;
        uint256[3] insideLast;
        uint256[3] earned;
    }

    mapping(PoolId => PoolState) internal _pools;
    mapping(PoolId => Stream[3]) internal _streams;
    mapping(PoolId => uint256[3]) internal _growth;
    mapping(PoolId => mapping(int24 => TickInfo)) internal _ticks;
    mapping(PoolId => mapping(int16 => uint256)) internal _bitmap;
    mapping(PoolId => mapping(bytes32 => Position)) internal _positions;

    /// @notice Rewards moved out of a position for `account` (a `hookData` recipient on removal, a claim whose
    /// transfer failed, a reclaim to a refund recipient), pulled with `claimCredit`.
    mapping(address account => mapping(Currency token => uint256)) public credit;
    /// @notice Every unit held for somebody, per token.
    mapping(Currency token => uint256) public totalOwed;
    /// @notice The protocol's share of funding, not yet flushed.
    mapping(Currency token => uint256) public protocolOwed;

    uint16 private _feeBps;
    uint16 private _pendingFeeBps;
    uint64 private _pendingFeeAt;

    constructor(ModuleParams memory mp) Ownable(mp.owner) {
        if (mp.positionManager == address(0) || mp.protocolFeeRecipient == address(0)) revert ZeroAddress();
        if (mp.feeNoticeSeconds < MIN_FEE_NOTICE_SECONDS || mp.feeNoticeSeconds > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(mp.feeNoticeSeconds);
        }
        if (mp.maxFeeBps > ABSOLUTE_MAX_PROTOCOL_FEE_BPS) revert FeeAboveCap(mp.maxFeeBps, ABSOLUTE_MAX_PROTOCOL_FEE_BPS);
        if (mp.initialFeeBps > mp.maxFeeBps) revert FeeAboveCap(mp.initialFeeBps, mp.maxFeeBps);
        if (mp.recycleDelay < MIN_DELAY || mp.recycleDelay > MAX_DELAY) revert InvalidDelay();
        if (mp.reclaimDelay < MIN_DELAY || mp.reclaimDelay > MAX_DELAY) revert InvalidDelay();
        if (mp.minEligibleLiquidity == 0) revert ZeroAmount();
        POSITION_MANAGER = mp.positionManager;
        protocolFeeRecipient = mp.protocolFeeRecipient;
        maxProtocolFeeBps = mp.maxFeeBps;
        feeNoticeSeconds = mp.feeNoticeSeconds;
        RECYCLE_DELAY = mp.recycleDelay;
        RECLAIM_DELAY = mp.reclaimDelay;
        MIN_ELIGIBLE_LIQUIDITY = mp.minEligibleLiquidity;
        _feeBps = mp.initialFeeBps;
        emit ProtocolFeeChanged(0, mp.initialFeeBps);
    }

    /// @dev The CL pool manager whose pools this module serves.
    function _rewardsPoolManager() internal view virtual returns (ICLPoolManager);

    /*//////////////////////////////////////////////////////////////
                         POOL CONFIGURATION (CREATOR)
    //////////////////////////////////////////////////////////////*/

    /// @notice Before the pool is initialized; the first caller owns the pool's rewards configuration.
    /// @dev First-come, as every DeepCore per-pool configuration is: a squatter gains only the right to run
    /// streams on a pool nobody else will fund; the creator picks another fee or spacing (griefing only).
    function configureRewards(PoolKey calldata key, RewardsConfig calldata cfg) external {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (address(key.poolManager) != address(_rewardsPoolManager())) revert WrongPoolManager();
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (p.owner != address(0)) revert PoolAlreadyConfigured();
        int24 spacing = key.parameters.getTickSpacing();
        if (spacing < TickMath.MIN_TICK_SPACING || spacing > TickMath.MAX_TICK_SPACING) revert WrongPoolManager();
        if (cfg.minWidthTicks > uint24(2 * uint256(int256(TickMath.MAX_TICK)))) revert MinWidthTooLarge();
        uint256 n = cfg.rewardTokens.length;
        if (n > MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        for (uint256 i; i < n; ++i) {
            Currency t = cfg.rewardTokens[i];
            for (uint256 j; j < i; ++j) {
                if (Currency.unwrap(cfg.rewardTokens[j]) == Currency.unwrap(t)) revert DuplicateRewardToken();
            }
            p.tokens[i] = t;
        }
        p.owner = msg.sender;
        p.tokenCount = uint8(n);
        p.tickSpacing = spacing;
        p.minWidthTicks = cfg.minWidthTicks;
        emit RewardsConfigured(id, msg.sender, cfg.minWidthTicks, cfg.rewardTokens);
    }

    function allowRewardToken(PoolKey calldata key, Currency token) external {
        PoolId id = key.toId();
        PoolState storage p = _onlyPoolOwner(id);
        uint8 n = p.tokenCount;
        if (n >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        for (uint256 j; j < n; ++j) {
            if (Currency.unwrap(p.tokens[j]) == Currency.unwrap(token)) revert DuplicateRewardToken();
        }
        // A new index's growth has always been zero, and so has every tick's outside value for it: the
        // mirror is consistent for it without touching a tick.
        if (p.initialized) _accrue(id, p);
        p.tokens[n] = token;
        p.tokenCount = n + 1;
        emit RewardTokenAllowed(id, token, n);
    }

    /// @notice Two-step; `address(0)` cancels a pending transfer.
    function transferPoolOwnership(PoolId id, address newOwner) external {
        PoolState storage p = _onlyPoolOwner(id);
        p.pendingOwner = newOwner;
        emit PoolOwnershipTransferStarted(id, p.owner, newOwner);
    }

    function acceptPoolOwnership(PoolId id) external {
        PoolState storage p = _pools[id];
        if (p.owner == address(0)) revert PoolNotConfigured();
        if (msg.sender != p.pendingOwner || msg.sender == address(0)) revert NotPendingPoolOwner();
        emit PoolOwnershipTransferred(id, p.owner, msg.sender);
        p.owner = msg.sender;
        p.pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                                 STREAMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool owner. Starts `token`'s stream for `duration` seconds. Anything left undistributed from an
    /// earlier stream of the token rolls into this one.
    function startStream(PoolKey calldata key, Currency token, uint256 amount, uint32 duration, address refundRecipient)
        external
        payable
        nonReentrant
    {
        PoolId id = key.toId();
        PoolState storage p = _onlyPoolOwner(id);
        if (!p.initialized) revert PoolNotInitialized();
        uint8 i = _indexOf(p, token);
        if (duration < MIN_STREAM_DURATION || duration > MAX_STREAM_DURATION) revert DurationOutOfRange();
        if (refundRecipient == address(0)) revert InvalidRefundRecipient();
        _accrue(id, p);
        Stream storage s = _streams[id][i];
        if (s.periodFinish > block.timestamp) revert StreamRunning();
        uint256 net = _fund(id, s, token, amount);
        uint64 finish = uint64(block.timestamp) + duration;
        uint256 rate = (uint256(s.undistributed) << 64) / duration;
        s.rateX64 = rate;
        s.periodFinish = finish;
        s.lastUpdate = uint64(block.timestamp);
        s.refundRecipient = refundRecipient;
        emit StreamStarted(id, token, net, rate, finish, refundRecipient);
    }

    /// @notice Pool owner. Adds `amount` and moves the finish out to `newFinish`; the new rate may not be
    /// below the old one, so nothing promised is ever stretched thinner.
    function extendStream(PoolKey calldata key, Currency token, uint256 amount, uint64 newFinish)
        external
        payable
        nonReentrant
    {
        PoolId id = key.toId();
        PoolState storage p = _onlyPoolOwner(id);
        uint8 i = _indexOf(p, token);
        _accrue(id, p);
        Stream storage s = _streams[id][i];
        uint64 finish = s.periodFinish;
        if (finish <= block.timestamp) revert NoStream();
        if (newFinish < finish) revert FinishWouldMoveIn();
        if (newFinish - block.timestamp > MAX_STREAM_DURATION) revert DurationOutOfRange();
        uint256 oldRate = s.rateX64;
        uint256 net = _fund(id, s, token, amount);
        uint256 rate = (uint256(s.undistributed) << 64) / (newFinish - block.timestamp);
        if (rate < oldRate) revert RateWouldFall();
        s.rateX64 = rate;
        s.periodFinish = newFinish;
        emit StreamExtended(id, token, net, rate, newFinish);
    }

    /// @notice Anyone. Adds to a running stream with at least `MIN_TOPUP_REMAINING` left. Raises the rate;
    /// never moves the finish.
    function topUp(PoolKey calldata key, Currency token, uint256 amount) external payable nonReentrant {
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (!p.initialized) revert PoolNotInitialized();
        uint8 i = _indexOf(p, token);
        _accrue(id, p);
        Stream storage s = _streams[id][i];
        uint64 finish = s.periodFinish;
        if (finish <= block.timestamp) revert NoStream();
        if (finish - block.timestamp < MIN_TOPUP_REMAINING) revert StreamEndsTooSoon();
        _fund(id, s, token, amount);
        uint256 rate = (uint256(s.undistributed) << 64) / (finish - block.timestamp);
        s.rateX64 = rate;
        emit StreamToppedUp(id, token, msg.sender, amount, rate);
    }

    /*//////////////////////////////////////////////////////////////
                                   LPs
    //////////////////////////////////////////////////////////////*/

    /// @notice Pays a position's rewards to `to`. Position-manager positions: the NFT's owner or an approved
    /// address. Any other position: its `sender` itself. A token whose transfer fails (paused, blacklisted)
    /// is credited to `to` instead, so one bad token never blocks the others.
    function claim(PoolId id, PositionKey calldata k, address to)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (to == address(0)) revert ZeroAddress();
        PoolState storage p = _pools[id];
        if (!p.initialized) revert PoolNotInitialized();
        _authorise(k);
        bytes32 pid = CLPosition.calculatePositionKey(k.sender, k.tickLower, k.tickUpper, k.salt);
        Position storage pos = _positions[id][pid];
        _accrue(id, p);
        uint256 m = _mirrored(pos.liquidity);
        if (m != 0) _settle(id, p, pos, k.tickLower, k.tickUpper, m);

        uint8 n = p.tokenCount;
        amounts = new uint256[](n);
        bool any;
        for (uint256 i; i < n; ++i) {
            uint256 pay = _takeEarned(_streams[id][i], pos, i);
            if (pay == 0) continue;
            amounts[i] = pay;
            any = true;
        }
        if (!any) revert NothingToClaim();
        pos.lastTouched = uint64(block.timestamp);

        for (uint256 i; i < n; ++i) {
            uint256 pay = amounts[i];
            if (pay == 0) continue;
            Currency token = p.tokens[i];
            totalOwed[token] -= pay;
            if (_tryPay(token, to, pay)) {
                emit RewardsClaimed(id, pid, to, token, pay);
            } else {
                totalOwed[token] += pay;
                credit[to][token] += pay;
                emit RewardsCredited(id, pid, to, token, pay);
            }
        }
    }

    /// @notice Pays `msg.sender`'s credit in `token` to `to`.
    function claimCredit(Currency token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = credit[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        credit[msg.sender][token] = 0;
        totalOwed[token] -= amount;
        emit CreditClaimed(msg.sender, token, to, amount);
        token.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             PERMISSIONLESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone. A position with zero liquidity, untouched for `RECYCLE_DELAY`, returns its unclaimed
    /// rewards to the pool's streams (a running stream's rate rises; its finish does not move).
    function recycle(PoolId id, PositionKey calldata k) external nonReentrant {
        PoolState storage p = _pools[id];
        if (!p.initialized) revert PoolNotInitialized();
        bytes32 pid = CLPosition.calculatePositionKey(k.sender, k.tickLower, k.tickUpper, k.salt);
        Position storage pos = _positions[id][pid];
        if (pos.liquidity != 0) revert PositionStillActive();
        uint64 earliest = pos.lastTouched + RECYCLE_DELAY;
        if (block.timestamp < earliest) revert RecycleTooSoon(earliest);
        _accrue(id, p);
        bool any;
        uint8 n = p.tokenCount;
        for (uint256 i; i < n; ++i) {
            Stream storage s = _streams[id][i];
            uint256 moved = _takeEarned(s, pos, i);
            if (moved == 0) continue;
            any = true;
            s.undistributed = RewardMath.satAdd128(s.undistributed, moved);
            uint64 finish = s.periodFinish;
            if (finish > block.timestamp) {
                s.rateX64 = (uint256(s.undistributed) << 64) / (finish - block.timestamp);
            }
            emit Recycled(id, pid, p.tokens[i], moved);
        }
        if (!any) revert NothingToRecycle();
    }

    /// @notice Anyone. Returns `token`'s undistributed remainder to the stream's refund recipient (as credit)
    /// once the pool has had zero eligible liquidity for `RECLAIM_DELAY` without a break, or once the stream
    /// finished at least `RECLAIM_DELAY` ago. Ends the stream. When no position is mirrored at all, rounding
    /// dust left in `accruedUnpaid` goes with it.
    function reclaim(PoolId id, Currency token) external nonReentrant returns (uint256 amount) {
        PoolState storage p = _pools[id];
        if (!p.initialized) revert PoolNotInitialized();
        uint8 i = _indexOf(p, token);
        _accrue(id, p);
        Stream storage s = _streams[id][i];
        uint64 finish = s.periodFinish;
        bool dead = p.eligibleLiquidity == 0 && p.zeroSince != 0 && block.timestamp >= p.zeroSince + RECLAIM_DELAY;
        bool over = finish <= block.timestamp && block.timestamp >= uint256(finish) + RECLAIM_DELAY;
        if (!dead && !over) {
            uint64 a = p.eligibleLiquidity == 0 && p.zeroSince != 0 ? p.zeroSince + RECLAIM_DELAY : type(uint64).max;
            uint64 b = finish + RECLAIM_DELAY;
            revert ReclaimTooSoon(a < b ? a : b);
        }
        address r = s.refundRecipient;
        if (r == address(0)) revert NothingToReclaim();
        amount = s.undistributed;
        s.undistributed = 0;
        if (p.mirroredTotal == 0) {
            uint256 dust = RewardMath.satSub(s.accruedUnpaid, s.storedEarned);
            if (dust != 0) {
                s.accruedUnpaid -= uint128(dust);
                amount += dust;
            }
        }
        if (amount == 0) revert NothingToReclaim();
        s.rateX64 = 0;
        if (finish > block.timestamp) s.periodFinish = uint64(block.timestamp);
        credit[r][token] += amount;
        emit Reclaimed(id, token, r, amount);
    }

    /// @notice Anyone. Pays the protocol's credit in `token` to the immutable recipient.
    function flushProtocolFees(Currency token) external nonReentrant returns (uint256 amount) {
        amount = protocolOwed[token];
        if (amount == 0) revert NothingToFlush();
        protocolOwed[token] = 0;
        totalOwed[token] -= amount;
        emit ProtocolFeesFlushed(token, protocolFeeRecipient, amount);
        token.transfer(protocolFeeRecipient, amount);
    }

    /// @notice Anyone. Pays whatever the hook holds ABOVE every ledger (misdirected tokens, forced native) to
    /// the immutable protocol recipient. It can never reach a stream, a position's rewards, a credit or a fee.
    function sweep(Currency token) external nonReentrant returns (uint256 amount) {
        uint256 bal = token.balanceOfSelf();
        uint256 owed = totalOwed[token];
        amount = bal > owed ? bal - owed : 0;
        if (amount == 0) revert NothingToSweep();
        emit Swept(token, protocolFeeRecipient, amount);
        token.transfer(protocolFeeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER: THE PROTOCOL FEE ONLY
    //////////////////////////////////////////////////////////////*/

    /// @notice The share of every NEW funding taken for the protocol. Nothing funded is ever re-priced.
    function protocolFeeBps() public view returns (uint16) {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) return _pendingFeeBps;
        return _feeBps;
    }

    function pendingProtocolFee() external view returns (uint16 newFeeBps, uint64 effectiveAt) {
        effectiveAt = _pendingFeeAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        newFeeBps = _pendingFeeBps;
    }

    /// @notice `<=` the fee in force applies now and cancels a pending increase; `>` applies
    /// `feeNoticeSeconds` later by itself.
    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > maxProtocolFeeBps) revert FeeAboveCap(newFeeBps, maxProtocolFeeBps);
        _materialiseFee();
        uint16 current = _feeBps;
        if (newFeeBps <= current) {
            _clearPendingFee();
            _feeBps = newFeeBps;
            emit ProtocolFeeChanged(current, newFeeBps);
        } else {
            uint64 at = uint64(block.timestamp) + feeNoticeSeconds;
            _pendingFeeBps = newFeeBps;
            _pendingFeeAt = at;
            emit ProtocolFeeIncreaseScheduled(current, newFeeBps, at);
        }
    }

    function cancelPendingProtocolFee() external onlyOwner {
        _materialiseFee();
        if (_pendingFeeAt == 0) revert NoPendingFee();
        _clearPendingFee();
    }

    /// @notice Disabled: an owner that could renounce would freeze the fee where it stands forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function poolOwner(PoolId id) external view returns (address) {
        return _pools[id].owner;
    }

    function pendingPoolOwner(PoolId id) external view returns (address) {
        return _pools[id].pendingOwner;
    }

    function poolConfig(PoolId id)
        external
        view
        returns (bool initialized, int24 tickSpacing, int24 lastTick, uint24 minWidthTicks, uint128 mirroredTotal)
    {
        PoolState storage p = _pools[id];
        return (p.initialized, p.tickSpacing, p.lastTick, p.minWidthTicks, p.mirroredTotal);
    }

    function rewardTokens(PoolId id) external view returns (Currency[] memory out) {
        PoolState storage p = _pools[id];
        out = new Currency[](p.tokenCount);
        for (uint256 i; i < out.length; ++i) {
            out[i] = p.tokens[i];
        }
    }

    function eligibleLiquidity(PoolId id) external view returns (uint128) {
        return _pools[id].eligibleLiquidity;
    }

    function zeroLiquiditySince(PoolId id) external view returns (uint64) {
        return _pools[id].zeroSince;
    }

    /// @notice The mirror's view of one tick (for audits: equal to core's `liquidityNet` when every position
    /// qualifies).
    function mirroredTick(PoolId id, int24 tick) external view returns (uint128 gross, int128 net) {
        TickInfo storage t = _ticks[id][tick];
        return (t.gross, t.net);
    }

    function positionOf(PoolId id, PositionKey calldata k)
        external
        view
        returns (uint128 liquidity, uint64 lastTouched, uint256[] memory storedEarned)
    {
        Position storage pos =
            _positions[id][CLPosition.calculatePositionKey(k.sender, k.tickLower, k.tickUpper, k.salt)];
        uint8 n = _pools[id].tokenCount;
        storedEarned = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            storedEarned[i] = pos.earned[i];
        }
        return (pos.liquidity, pos.lastTouched, storedEarned);
    }

    function streamOf(PoolId id, Currency token)
        external
        view
        returns (uint256 rateX64, uint64 periodFinish, uint256 undistributed, address refundRecipient)
    {
        PoolState storage p = _pools[id];
        uint8 i = _indexOf(p, token);
        StreamView memory v = _previewStream(id, p, i);
        return (v.rateX64, v.periodFinish, v.undistributed, v.refundRecipient);
    }

    function streams(PoolId id) external view returns (StreamView[] memory out) {
        PoolState storage p = _pools[id];
        out = new StreamView[](p.tokenCount);
        for (uint256 i; i < out.length; ++i) {
            out[i] = _previewStream(id, p, uint8(i));
        }
    }

    /// @notice What `claim` would pay now, per reward token (capped by the pool's accrued ledger).
    function earned(PoolId id, PositionKey calldata k) external view returns (uint256[] memory out) {
        PoolState storage p = _pools[id];
        uint8 n = p.tokenCount;
        out = new uint256[](n);
        Position storage pos =
            _positions[id][CLPosition.calculatePositionKey(k.sender, k.tickLower, k.tickUpper, k.salt)];
        uint256 m = _mirrored(pos.liquidity);
        for (uint256 i; i < n; ++i) {
            Stream storage s = _streams[id][i];
            uint256 g = _growth[id][i];
            uint256 accrued = s.accruedUnpaid;
            if (p.initialized && s.lastUpdate < block.timestamp) {
                (uint256 inc, uint256 attr,,) = _accrual(
                    s.undistributed,
                    s.rateX64,
                    s.lastUpdate,
                    s.periodFinish,
                    uint64(block.timestamp),
                    p.eligibleLiquidity,
                    s.fraction
                );
                unchecked {
                    g += inc;
                }
                accrued = RewardMath.satAdd(accrued, attr);
            }
            uint256 e = pos.earned[i];
            if (m != 0) {
                uint256 inside = _growthInside(id, k.tickLower, k.tickUpper, p.lastTick, i, g);
                unchecked {
                    e = RewardMath.satAdd(e, RewardMath.mulShr128Sat(inside - pos.insideLast[i], m));
                }
            }
            out[i] = e < accrued ? e : accrued;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    CALLBACK BODIES (called by the hook)
    //////////////////////////////////////////////////////////////*/

    /// @dev `beforeInitialize`: the one callback that may refuse, and it refuses only an unconfigured pool.
    function _rewardsOnInitialize(PoolKey calldata key, uint160 sqrtPriceX96) internal {
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (p.owner == address(0)) revert PoolNotConfigured();
        p.initialized = true;
        // the same function core uses for slot0's tick at initialize
        p.lastTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        p.zeroSince = uint64(block.timestamp);
    }

    /// @dev `afterSwap`: accrue with the liquidity in force during the swap (eligible liquidity changes only at
    /// crossings, which are applied below), then walk the mirror's bitmap from the last tick to the new one.
    /// Never reverts: saturating and wrapping arithmetic only; its cost grows with mirrored ticks crossed.
    function _rewardsOnSwap(PoolKey calldata key) internal {
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (!p.initialized) return;
        _accrue(id, p);
        (, int24 tick,,) = _rewardsPoolManager().getSlot0(id);
        int24 last = p.lastTick;
        if (tick != last) {
            if (p.mirroredTotal != 0) _cross(id, p, last, tick);
            p.lastTick = tick;
        }
    }

    /// @dev `beforeAddLiquidity` / `beforeRemoveLiquidity`. NEVER reverts (the removal rule above). `hookData`
    /// is read only on a REMOVAL made through the canonical position manager.
    function _rewardsOnModify(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        bool isAdd
    ) internal {
        PoolId id = key.toId();
        PoolState storage p = _pools[id];
        if (!p.initialized) return;
        int24 lo = params.tickLower;
        int24 hi = params.tickUpper;
        // narrower than the pool's minimum (or inverted): never mirrored, never earns, never stored
        if (int256(hi) - int256(lo) < int256(uint256(p.minWidthTicks)) || hi <= lo) return;

        bytes32 pid = CLPosition.calculatePositionKey(sender, lo, hi, params.salt);
        Position storage pos = _positions[id][pid];
        uint128 oldL = pos.liquidity;
        uint128 newL;
        int256 d = params.liquidityDelta;
        if (isAdd) {
            newL = d > 0 ? RewardMath.satAdd128(oldL, uint256(d)) : oldL;
        } else {
            // `-d` overflows only at int256.min, which no real removal carries
            uint256 abs = d >= 0 ? 0 : (d == type(int256).min ? type(uint256).max : uint256(-d));
            newL = RewardMath.satSub128(oldL, abs);
        }

        bool credits = !isAdd && sender == POSITION_MANAGER && hookData.length == 32;
        if (oldL == 0 && newL == 0 && !credits) return;

        _accrue(id, p);
        uint256 oldM = _mirrored(oldL);
        uint256 newM = _mirrored(newL);
        if (oldM != 0) _settle(id, p, pos, lo, hi, oldM);
        if (newM != oldM) {
            _applyMirror(id, p, lo, hi, int256(newM) - int256(oldM));
            if (oldM == 0) _syncInside(id, p, pos, lo, hi);
        }
        pos.liquidity = newL;
        pos.lastTouched = uint64(block.timestamp);
        if (credits) _creditFromHookData(id, p, pos, pid, hookData);
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _onlyPoolOwner(PoolId id) internal view returns (PoolState storage p) {
        p = _pools[id];
        if (p.owner == address(0)) revert PoolNotConfigured();
        if (msg.sender != p.owner) revert NotPoolOwner();
    }

    function _indexOf(PoolState storage p, Currency token) internal view returns (uint8) {
        uint8 n = p.tokenCount;
        for (uint8 i; i < n; ++i) {
            if (Currency.unwrap(p.tokens[i]) == Currency.unwrap(token)) return i;
        }
        revert TokenNotAllowed();
    }

    function _mirrored(uint128 liquidity) internal view returns (uint256) {
        return liquidity >= MIN_ELIGIBLE_LIQUIDITY ? liquidity : 0;
    }

    /// @dev Takes `amount` from the caller (balance difference, so the ledger stays solvent with a token that
    /// delivers less), books the protocol's share and adds the rest to the stream.
    function _fund(PoolId id, Stream storage s, Currency token, uint256 amount) internal returns (uint256 net) {
        if (amount == 0) revert ZeroAmount();
        uint256 received;
        if (token.isNative()) {
            if (msg.value != amount) revert NativeAmountMismatch();
            received = amount;
        } else {
            if (msg.value != 0) revert NativeNotAccepted();
            uint256 before = token.balanceOfSelf();
            IERC20(Currency.unwrap(token)).safeTransferFrom(msg.sender, address(this), amount);
            received = token.balanceOfSelf() - before;
            if (received == 0) revert ZeroAmount();
        }
        uint256 fee = received * protocolFeeBps() / BPS;
        net = received - fee;
        uint256 und = uint256(s.undistributed) + net;
        // keeps `accrued << 128` and `rate * dt` inside 256 bits on every callback path
        if (und > type(uint128).max) revert AmountTooLarge();
        s.undistributed = uint128(und);
        totalOwed[token] += received;
        if (fee != 0) {
            protocolOwed[token] += fee;
            emit ProtocolFeeTaken(id, token, fee);
        }
    }

    /// @dev Pure accrual of one stream from `last` to `nowT` with `L` eligible liquidity throughout.
    /// Returns the growth increment, the amount attributable to positions and the finish, which moves out by
    /// every second with no eligible liquidity. `attributable` is `floor((inc * L + fraction) / 2^128)` with the
    /// remainder carried in `fraction`, so over ANY number of accruals it sums to the floor of the exact
    /// total: positions, which floor `liquidity * growth` over their whole span, can never be owed more.
    function _accrual(uint256 und, uint256 rate, uint64 last, uint64 finish, uint64 nowT, uint128 L, uint128 fraction)
        internal
        pure
        returns (uint256 inc, uint256 attributable, uint64 newFinish, uint128 newFraction)
    {
        newFinish = finish;
        newFraction = fraction;
        if (last >= nowT || last >= finish) return (0, 0, newFinish, newFraction);
        if (L == 0) {
            unchecked {
                newFinish = finish + (nowT - last);
            }
            return (0, 0, newFinish, newFraction);
        }
        uint64 end = nowT < finish ? nowT : finish;
        uint256 accrued = end == finish ? und : RewardMath.mulShr64Sat(rate, end - last);
        if (accrued > und) accrued = und;
        if (accrued == 0) return (0, 0, newFinish, newFraction);
        unchecked {
            // und < 2^128 (enforced at funding), so the shift is exact and inc * L <= accrued << 128:
            // adding a fraction below 2^128 cannot pass 2^256
            inc = (accrued << 128) / L;
            uint256 sum = inc * L + fraction;
            attributable = sum >> 128;
            newFraction = uint128(sum);
        }
        if (attributable > accrued) attributable = accrued;
    }

    function _accrue(PoolId id, PoolState storage p) internal {
        uint8 n = p.tokenCount;
        if (n == 0) return;
        uint128 L = p.eligibleLiquidity;
        uint64 nowT = uint64(block.timestamp);
        for (uint256 i; i < n; ++i) {
            Stream storage s = _streams[id][i];
            uint64 last = s.lastUpdate;
            if (last >= nowT) continue;
            uint64 finish = s.periodFinish;
            (uint256 inc, uint256 attr, uint64 newFinish, uint128 fraction) =
                _accrual(s.undistributed, s.rateX64, last, finish, nowT, L, s.fraction);
            s.lastUpdate = nowT;
            s.fraction = fraction;
            if (newFinish != finish) s.periodFinish = newFinish;
            if (inc != 0) {
                unchecked {
                    _growth[id][i] += inc;
                }
            }
            if (attr != 0) {
                s.undistributed = RewardMath.satSub128(s.undistributed, attr);
                s.accruedUnpaid = RewardMath.satAdd128(s.accruedUnpaid, attr);
            }
        }
    }

    function _previewStream(PoolId id, PoolState storage p, uint8 i) internal view returns (StreamView memory v) {
        Stream storage s = _streams[id][i];
        v.token = p.tokens[i];
        v.rateX64 = s.rateX64;
        v.periodFinish = s.periodFinish;
        v.lastUpdate = s.lastUpdate;
        v.undistributed = s.undistributed;
        v.accruedUnpaid = s.accruedUnpaid;
        v.refundRecipient = s.refundRecipient;
        if (p.initialized && s.lastUpdate < block.timestamp) {
            (, uint256 attr, uint64 newFinish,) = _accrual(
                s.undistributed,
                s.rateX64,
                s.lastUpdate,
                s.periodFinish,
                uint64(block.timestamp),
                p.eligibleLiquidity,
                s.fraction
            );
            v.periodFinish = newFinish;
            v.undistributed = RewardMath.satSub(v.undistributed, attr);
            v.accruedUnpaid = RewardMath.satAdd(v.accruedUnpaid, attr);
        }
    }

    /// @dev Core's `Tick.getFeeGrowthInside`, on the mirror. Wraps by design.
    function _growthInside(PoolId id, int24 lo, int24 hi, int24 cur, uint256 i, uint256 g)
        internal
        view
        returns (uint256 inside)
    {
        uint256 lowerOut = _ticks[id][lo].outside[i];
        uint256 upperOut = _ticks[id][hi].outside[i];
        unchecked {
            uint256 below = cur >= lo ? lowerOut : g - lowerOut;
            uint256 above = cur < hi ? upperOut : g - upperOut;
            inside = g - below - above;
        }
    }

    function _settle(PoolId id, PoolState storage p, Position storage pos, int24 lo, int24 hi, uint256 m) internal {
        uint8 n = p.tokenCount;
        int24 cur = p.lastTick;
        for (uint256 i; i < n; ++i) {
            uint256 inside = _growthInside(id, lo, hi, cur, i, _growth[id][i]);
            uint256 add;
            unchecked {
                add = RewardMath.mulShr128Sat(inside - pos.insideLast[i], m);
            }
            if (add != 0) {
                pos.earned[i] = RewardMath.satAdd(pos.earned[i], add);
                Stream storage s = _streams[id][i];
                s.storedEarned = RewardMath.satAdd(s.storedEarned, add);
            }
            pos.insideLast[i] = inside;
        }
    }

    function _syncInside(PoolId id, PoolState storage p, Position storage pos, int24 lo, int24 hi) internal {
        uint8 n = p.tokenCount;
        int24 cur = p.lastTick;
        for (uint256 i; i < n; ++i) {
            pos.insideLast[i] = _growthInside(id, lo, hi, cur, i, _growth[id][i]);
        }
    }

    function _applyMirror(PoolId id, PoolState storage p, int24 lo, int24 hi, int256 d) internal {
        _updateTick(id, p, lo, d, false);
        _updateTick(id, p, hi, d, true);
        int24 cur = p.lastTick;
        if (lo <= cur && cur < hi) {
            _setEligible(p, d > 0 ? RewardMath.satAdd128(p.eligibleLiquidity, uint256(d)) : RewardMath.satSub128(p.eligibleLiquidity, uint256(-d)));
        }
        p.mirroredTotal = d > 0 ? RewardMath.satAdd128(p.mirroredTotal, uint256(d)) : RewardMath.satSub128(p.mirroredTotal, uint256(-d));
    }

    function _updateTick(PoolId id, PoolState storage p, int24 tick, int256 d, bool upper) internal {
        TickInfo storage t = _ticks[id][tick];
        uint128 g0 = t.gross;
        uint128 g1 = d > 0 ? RewardMath.satAdd128(g0, uint256(d)) : RewardMath.satSub128(g0, uint256(-d));
        if (g1 == 0) {
            if (g0 != 0) {
                delete _ticks[id][tick];
                _setBit(id, p.tickSpacing, tick, false);
            }
            return;
        }
        if (g0 == 0) {
            // core's convention: all growth before a tick was initialized happened below it
            if (tick <= p.lastTick) {
                uint8 n = p.tokenCount;
                for (uint256 i; i < n; ++i) {
                    t.outside[i] = _growth[id][i];
                }
            }
            _setBit(id, p.tickSpacing, tick, true);
        }
        t.gross = g1;
        t.net = RewardMath.satAddNet(t.net, upper ? -d : d);
    }

    function _setEligible(PoolState storage p, uint128 newL) internal {
        uint128 oldL = p.eligibleLiquidity;
        if (oldL == 0 && newL != 0) p.zeroSince = 0;
        else if (oldL != 0 && newL == 0) p.zeroSince = uint64(block.timestamp);
        p.eligibleLiquidity = newL;
    }

    function _setBit(PoolId id, int24 spacing, int24 tick, bool on) internal {
        int256 c = RewardMath.compress(tick, spacing);
        int16 word = int16(c >> 8);
        uint256 mask = uint256(1) << uint256(c & 0xff);
        uint256 w = _bitmap[id][word];
        _bitmap[id][word] = on ? w | mask : w & ~mask;
    }

    /// @dev Crosses every mirrored tick between `fromTick` and `toTick`, in core's convention: a tick T is
    /// crossed upward when `from < T <= to`, downward when `to < T <= from`. In compressed units both are
    /// the half-open range of compressed ticks between `compress(from)` and `compress(to)`.
    function _cross(PoolId id, PoolState storage p, int24 fromTick, int24 toTick) internal {
        int256 s = p.tickSpacing;
        int256 cFrom = RewardMath.compress(fromTick, s);
        int256 cTo = RewardMath.compress(toTick, s);
        if (cFrom == cTo) return;
        uint128 L = p.eligibleLiquidity;
        uint8 n = p.tokenCount;
        mapping(int16 => uint256) storage bm = _bitmap[id];
        if (cTo > cFrom) {
            int256 k = cFrom + 1;
            while (k <= cTo) {
                int256 word = k >> 8;
                uint256 masked = bm[int16(word)] & (type(uint256).max << uint256(k & 0xff));
                if (masked == 0) {
                    k = (word + 1) << 8;
                    continue;
                }
                int256 kk = (word << 8) + int256(uint256(BitMath.leastSignificantBit(masked)));
                if (kk > cTo) break;
                L = _crossTick(id, n, int24(kk * s), L, true);
                k = kk + 1;
            }
        } else {
            int256 k = cFrom;
            while (k > cTo) {
                int256 word = k >> 8;
                uint256 bit = uint256(k & 0xff);
                uint256 mask = bit == 255 ? type(uint256).max : (uint256(1) << (bit + 1)) - 1;
                uint256 masked = bm[int16(word)] & mask;
                if (masked == 0) {
                    k = (word << 8) - 1;
                    continue;
                }
                int256 kk = (word << 8) + int256(uint256(BitMath.mostSignificantBit(masked)));
                if (kk <= cTo) break;
                L = _crossTick(id, n, int24(kk * s), L, false);
                k = kk - 1;
            }
        }
        _setEligible(p, L);
    }

    function _crossTick(PoolId id, uint8 n, int24 tick, uint128 L, bool up) internal returns (uint128) {
        TickInfo storage t = _ticks[id][tick];
        for (uint256 i; i < n; ++i) {
            unchecked {
                t.outside[i] = _growth[id][i] - t.outside[i];
            }
        }
        return RewardMath.applyNet(L, t.net, up);
    }

    /// @dev On a removal through the position manager, 32 bytes of `hookData` naming a non-zero address move
    /// the position's settled rewards to that address's credit. Only the NFT's owner or an approved address
    /// can make the position manager remove, and it forwards `hookData` unchanged. Malformed data is ignored.
    function _creditFromHookData(
        PoolId id,
        PoolState storage p,
        Position storage pos,
        bytes32 pid,
        bytes calldata hookData
    ) internal {
        uint256 w = uint256(bytes32(hookData[:32]));
        if (w == 0 || w >> 160 != 0) return;
        address r = address(uint160(w));
        uint8 n = p.tokenCount;
        for (uint256 i; i < n; ++i) {
            uint256 moved = _takeEarned(_streams[id][i], pos, i);
            if (moved == 0) continue;
            Currency token = p.tokens[i];
            credit[r][token] = RewardMath.satAdd(credit[r][token], moved);
            emit RewardsCredited(id, pid, r, token, moved);
        }
    }

    /// @dev Moves a position's settled rewards in token `i` out of its pool's accrued ledger; returns what
    /// actually moved (capped by that ledger, so a mis-counted position can never reach other money).
    function _takeEarned(Stream storage s, Position storage pos, uint256 i) internal returns (uint256 moved) {
        uint256 amt = pos.earned[i];
        if (amt == 0) return 0;
        pos.earned[i] = 0;
        s.storedEarned = RewardMath.satSub(s.storedEarned, amt);
        uint128 acc = s.accruedUnpaid;
        moved = amt < acc ? amt : acc;
        s.accruedUnpaid = acc - uint128(moved);
    }

    function _authorise(PositionKey calldata k) internal view {
        if (k.sender == POSITION_MANAGER) {
            uint256 tokenId = uint256(k.salt);
            address holder;
            try IPositionNFT(POSITION_MANAGER).ownerOf(tokenId) returns (address o) {
                holder = o;
            } catch {
                revert NotPositionOwner();
            }
            if (msg.sender == holder) return;
            if (IPositionNFT(POSITION_MANAGER).isApprovedForAll(holder, msg.sender)) return;
            if (IPositionNFT(POSITION_MANAGER).getApproved(tokenId) == msg.sender) return;
            revert NotPositionOwner();
        }
        if (msg.sender != k.sender) revert NotPositionOwner();
    }

    /// @dev A transfer that reports failure instead of reverting, copying at most 32 bytes of return data.
    function _tryPay(Currency token, address to, uint256 amount) internal returns (bool ok) {
        if (token.isNative()) {
            assembly ("memory-safe") {
                ok := call(gas(), to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        address t = Currency.unwrap(token);
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 rsize;
        uint256 rword;
        assembly ("memory-safe") {
            ok := call(gas(), t, 0, add(data, 0x20), mload(data), 0, 0x20)
            rsize := returndatasize()
            rword := mload(0)
        }
        if (!ok) return false;
        if (rsize == 0) return t.code.length != 0;
        return rsize >= 32 && rword == 1;
    }

    function _materialiseFee() private {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) {
            uint16 next = _pendingFeeBps;
            emit ProtocolFeeChanged(_feeBps, next);
            _feeBps = next;
            _pendingFeeBps = 0;
            _pendingFeeAt = 0;
        }
    }

    function _clearPendingFee() private {
        uint64 at = _pendingFeeAt;
        if (at == 0) return;
        emit PendingProtocolFeeCancelled(_pendingFeeBps, at);
        _pendingFeeBps = 0;
        _pendingFeeAt = 0;
    }
}
