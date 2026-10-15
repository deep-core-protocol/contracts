// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseCLHook} from "../base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @title DeepCoreDynamicFeeHook
/// @notice A dynamic fee for ordinary concentrated-liquidity pools on DeepCore, with a share of every
/// swap's fee for the protocol. Design of record: `docs/products/dynamic-fee-deepcore.md`, with ONE
/// owner-approved change: the protocol share (owner, 2026-09-29, "build dynamic fee hook with
/// protocol revenue"), which the design had left out.
///
/// ############################## THE FEE ##############################
///
///   fee = baseFee + volSlope * vol + surcharge        clamped to maxFee (<= FEE_CAP <= 10%)
///
/// All in pips (1,000,000 = 100%). `vol` is the net price move, in ticks, seen at the start of a
/// later second beyond a dead band, decaying linearly to zero over `decaySeconds` by the clock
/// alone: no trade resets a timer, so the fee cannot be held high for the price of gas. The
/// surcharge is paid only by a trade that REVERSES a move made earlier in the same second (the
/// back leg of a sandwich, an arbitrage against a large trade); the trade that made the move, and
/// any in the same direction, pays none. One violent move counts at most `MAX_MOVE_PER_UPDATE`.
///
/// ############################## THE PROTOCOL SHARE ##############################
///
/// Of the fee a swap pays, the protocol takes `protocolShareBps` of it and the liquidity providers
/// keep the rest: the trader pays the SAME total either way. Mechanically:
///   * `beforeSwap` returns the LP part as the pool's fee override: `lpPips = fee - protocolPips`,
///     with `protocolPips = floor(fee * share / 10,000)` (the rounding pip stays with the LPs);
///   * `afterSwap` takes `floor(|unspecified amount| * protocolPips / 1e6)` as a hook delta on the
///     unspecified currency (the output of an exact-input swap, the input of an exact-output one),
///     and settles it with ONE `vault.mint` of ERC-6909 claims to this contract. It is charged on
///     the amount the pool actually traded, so a partial fill is charged only what filled.
///   The two parts are on different bases (the LP fee on the input, the protocol's on the
///   unspecified side), so their sum equals `fee` in value, not to the wei; routers quote the
///   unspecified amount net of the protocol part, which core already reports that way.
///
/// The share for a pool is FROZEN when the pool is configured: the Safe may change the share for
/// pools configured later, inside the immutable `MAX_PROTOCOL_SHARE_BPS`; an increase takes effect
/// only after the immutable notice, a decrease at once, and nothing is ever retroactive. A creator
/// can also bound what it accepts (`configure`'s `maxProtocolShareBps`).
///
/// ############################## FUNDS ##############################
///
/// Value that can reach this contract: the protocol's vault claims (every swap with a cut), and
/// anything sent by mistake (an ERC-20, native forced in, ERC-6909 claims minted to it). Exactly
/// ONE path out for all of it: `flushProtocolFees(currency)`, permissionless, which redeems the
/// claims and pays the WHOLE balance of that currency to the immutable `protocolRecipient`. So
/// nothing can be stuck and no key can redirect anything. No `fallback`; `receive` accepts only the
/// vault (redeemed native). ERC-721 and ERC-1155 have no path in (no receiver hooks).
///
/// ############################## ROLES ##############################
///
///   owner (the Safe, Ownable2Step, renounce reverts): the protocol share for NEW pools, inside the
///     immutable cap, increases behind notice. Nothing else: it cannot touch a pool, its fee, its
///     share once configured, liquidity, or the funds (which only ever go to the recipient).
///   poolOwner (whoever configured the pool; not ours): propose a tuner (in force after
///     `TUNER_NOTICE_SECONDS`), revoke it at once, freeze for ever, transfer two-step. No setter.
///   tuner (appointed by the pool owner): `tune` the three parameters inside the pool's fixed
///     bounds, by at most a step, at most once per `minTuneInterval`. Nobody is exempt.
///   anyone: `flushProtocolFees`.
///
/// Hook bitmap: beforeInitialize | afterInitialize | beforeSwap | afterSwap | afterSwapReturnsDelta
/// = bits 0, 1, 6, 7, 11 = 0x08C3. No liquidity callback, so it can never trap a position.
contract DeepCoreDynamicFeeHook is BaseCLHook, Ownable2Step, ReentrancyGuard, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice A pool's fee terms. The three parameters move only through `tune`; everything else
    /// is fixed when the pool is configured.
    struct FeeConfig {
        uint24 baseFee; // pips; the fee with no volatility and no surcharge
        uint24 volSlope; // pips per tick of volatility
        uint24 sameSecondSlope; // pips per tick reversed within the second
        uint24 minBaseFee; // bounds for `tune`, fixed
        uint24 maxBaseFee;
        uint24 maxVolSlope;
        uint24 maxSameSecondSlope;
        uint24 maxFee; // the clamp, <= FEE_CAP
        uint32 volCap; // ticks
        uint32 decaySeconds; // 600 .. 86,400
        uint24 deadband; // ticks; a net move no larger than this is not volatility
        uint24 maxBaseFeeStep; // the most one `tune` may move baseFee
        uint24 maxSlopeStep; // ... each slope
        uint32 minTuneInterval; // >= 3,600 s between tunes
        address tuner; // may be zero: parameters fixed for ever
    }

    /// @dev One slot: the volatility and same-second references.
    struct PoolState {
        int24 secTick; // pool tick at the first swap of the current second
        uint40 secTime; // that second
        int24 volRefTick; // the tick the last COUNTED move was measured from
        uint32 volStored; // volatility at `volTime`, ticks
        uint40 volTime;
    }

    /// @dev Who may do what on a pool, and its frozen share.
    struct PoolAdmin {
        address owner;
        uint16 protocolShareBps; // frozen at configure
        bool configured;
        bool frozen;
        address pendingOwner;
        address tuner;
        uint40 lastTuneAt;
        address pendingTuner;
        uint40 tunerEffectiveAt;
    }

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant FEE_PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;
    /// @notice No deployment may set `FEE_CAP` above 10%, under both pool types' core maximum.
    uint24 public constant HARD_FEE_CAP = 100_000;
    /// @notice No deployment may let the protocol take more than half of a swap's fee.
    uint16 public constant HARD_MAX_PROTOCOL_SHARE_BPS = 5_000;
    uint32 public constant MIN_DECAY_SECONDS = 600;
    uint32 public constant MAX_DECAY_SECONDS = 86_400;
    uint32 public constant MIN_TUNE_INTERVAL = 3_600;
    uint32 public constant MIN_NOTICE_SECONDS = 86_400;
    uint24 public constant HARD_MAX_MOVE = 2_000;

    /// @dev The protocol's pips of the swap in flight, from `beforeSwap` to `afterSwap`: transient
    /// on Cancun, a storage slot zeroed by `afterSwap` on the legacy backend.
    uint256 private constant PENDING_CUT_SLOT = uint256(keccak256("deepcore.dynamicfee.pendingCut")) - 1;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IVault public immutable vault;
    /// @notice The only address protocol revenue can ever reach (the Safe).
    address public immutable protocolRecipient;
    /// @notice The highest `maxFee` any pool may configure.
    uint24 public immutable FEE_CAP;
    /// @notice The highest protocol share the owner may ever set.
    uint16 public immutable MAX_PROTOCOL_SHARE_BPS;
    /// @notice How long an increase of the protocol share waits before it applies to new pools.
    uint32 public immutable SHARE_NOTICE_SECONDS;
    /// @notice How long a proposed tuner waits before it may accept.
    uint32 public immutable TUNER_NOTICE_SECONDS;
    /// @notice The most one second's net move adds to volatility.
    uint24 public immutable MAX_MOVE_PER_UPDATE;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint16 private _protocolShareBps;
    uint16 private _pendingShareBps;
    uint40 private _pendingShareAt;
    /// @dev Set only across this contract's own `vault.lock` call.
    bool private _lockCallbackArmed;

    mapping(PoolId => FeeConfig) private _configs;
    mapping(PoolId => PoolState) private _states;
    mapping(PoolId => PoolAdmin) private _admins;

    /// @notice Protocol revenue taken, per currency. Monotone; the swap path alone writes it.
    mapping(Currency currency => uint256) public protocolTaken;
    /// @notice Paid out to the recipient, per currency (includes anything sent by mistake).
    mapping(Currency currency => uint256) public protocolFlushed;

    /*//////////////////////////////////////////////////////////////
                             ERRORS AND EVENTS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidDeployment(uint8 reason);
    error HookMismatch();
    error PoolManagerMismatch();
    error PoolMustUseDynamicFee(uint24 fee);
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error PoolAlreadyConfigured();
    error PoolNotConfigured();
    error InvalidConfig(uint8 reason);
    error ProtocolShareAboveAccepted(uint16 share, uint16 accepted);
    error ProtocolShareAboveCap(uint16 share, uint16 cap);
    error NoPendingProtocolShare();
    error NotPoolOwner();
    error NotPendingPoolOwner();
    error NotTuner();
    error NotPendingTuner();
    error TunerNoticeNotElapsed(uint40 effectiveAt);
    error NoTuner();
    error PoolFrozen();
    error TuneTooSoon(uint40 earliest);
    error OutOfBounds(uint8 field, uint24 value);
    error StepTooLarge(uint8 field, uint24 current, uint24 value, uint24 maxStep);
    error NothingToFlush(Currency currency);
    error NativeNotAccepted();
    error UnexpectedLockCallback();
    error RenounceDisabled();

    event PoolConfigured(PoolId indexed poolId, address indexed owner, uint16 protocolShareBps, FeeConfig cfg);
    event Tuned(PoolId indexed poolId, address indexed tuner, uint24 baseFee, uint24 volSlope, uint24 sameSecondSlope);
    event TunerProposed(PoolId indexed poolId, address indexed tuner, uint40 effectiveAt);
    event TunerProposalCancelled(PoolId indexed poolId);
    event TunerAccepted(PoolId indexed poolId, address indexed tuner);
    event TunerRevoked(PoolId indexed poolId, address indexed by);
    event Frozen(PoolId indexed poolId);
    event PoolOwnershipTransferStarted(PoolId indexed poolId, address indexed from, address indexed to);
    event PoolOwnershipTransferred(PoolId indexed poolId, address indexed from, address indexed to);
    event ProtocolFeeTaken(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event ProtocolFeesFlushed(Currency indexed currency, address indexed recipient, uint256 amount);
    event ProtocolShareChanged(uint16 previous, uint16 current);
    event ProtocolShareIncreaseScheduled(uint16 current, uint16 next, uint40 effectiveAt);
    event ProtocolShareIncreaseCancelled(uint16 withdrawn);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param poolManager_ DeepCore's CL pool manager; `vault_` must be its vault.
    /// @param owner_ The Safe. Its only power is the protocol share for pools configured later.
    /// @param protocolRecipient_ The Safe. Immutable: every unit of revenue goes here and nowhere else.
    constructor(
        ICLPoolManager poolManager_,
        IVault vault_,
        address owner_,
        address protocolRecipient_,
        uint24 feeCap_,
        uint16 initialShareBps_,
        uint16 maxShareBps_,
        uint32 shareNoticeSeconds_,
        uint32 tunerNoticeSeconds_,
        uint24 maxMovePerUpdate_
    ) BaseCLHook(poolManager_) Ownable(owner_) {
        if (address(vault_) == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        if (address(poolManager_.vault()) != address(vault_)) revert InvalidDeployment(1);
        if (feeCap_ == 0 || feeCap_ > HARD_FEE_CAP) revert InvalidDeployment(2);
        if (maxShareBps_ > HARD_MAX_PROTOCOL_SHARE_BPS || initialShareBps_ > maxShareBps_) revert InvalidDeployment(3);
        if (shareNoticeSeconds_ < MIN_NOTICE_SECONDS || tunerNoticeSeconds_ < MIN_NOTICE_SECONDS) revert InvalidDeployment(4);
        if (maxMovePerUpdate_ == 0 || maxMovePerUpdate_ > HARD_MAX_MOVE) revert InvalidDeployment(5);
        vault = vault_;
        protocolRecipient = protocolRecipient_;
        FEE_CAP = feeCap_;
        MAX_PROTOCOL_SHARE_BPS = maxShareBps_;
        SHARE_NOTICE_SECONDS = shareNoticeSeconds_;
        TUNER_NOTICE_SECONDS = tunerNoticeSeconds_;
        MAX_MOVE_PER_UPDATE = maxMovePerUpdate_;
        _protocolShareBps = initialShareBps_;
        emit ProtocolShareChanged(0, initialShareBps_);
    }

    /// @notice Native reaches this contract only as redeemed vault claims.
    receive() external payable {
        if (msg.sender != address(vault)) revert NativeNotAccepted();
    }

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA;
    }

    /*//////////////////////////////////////////////////////////////
                           POOL CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Write a pool's fee terms before it is initialized. The first caller owns them.
    /// @param maxProtocolShareBps The highest protocol share the caller accepts; the share in force
    /// now is frozen into the pool, and this call reverts if it is higher.
    function configure(PoolKey calldata key, FeeConfig calldata cfg, uint16 maxProtocolShareBps) external {
        if (address(key.hooks) != address(this)) revert HookMismatch();
        if (address(key.poolManager) != address(poolManager)) revert PoolManagerMismatch();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolMustUseDynamicFee(key.fee);
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 != 0) revert PoolAlreadyInitialized();
        PoolAdmin storage a = _admins[id];
        if (a.configured) revert PoolAlreadyConfigured();
        _validate(cfg);
        uint16 share = protocolShareBps();
        if (share > maxProtocolShareBps) revert ProtocolShareAboveAccepted(share, maxProtocolShareBps);

        _configs[id] = cfg;
        a.owner = msg.sender;
        a.protocolShareBps = share;
        a.configured = true;
        a.tuner = cfg.tuner;
        emit PoolConfigured(id, msg.sender, share, cfg);
    }

    /// @dev Reasons: 1 base outside its bounds; 2 a slope above its bound; 3 maxFee zero, above
    /// FEE_CAP, or below the highest base; 4 decay outside 600..86,400; 5 tune interval under 3,600;
    /// 6 the tuner is this contract; 7 min above max.
    function _validate(FeeConfig calldata cfg) internal view {
        if (cfg.minBaseFee > cfg.maxBaseFee) revert InvalidConfig(7);
        if (cfg.baseFee < cfg.minBaseFee || cfg.baseFee > cfg.maxBaseFee) revert InvalidConfig(1);
        if (cfg.volSlope > cfg.maxVolSlope || cfg.sameSecondSlope > cfg.maxSameSecondSlope) revert InvalidConfig(2);
        if (cfg.maxFee == 0 || cfg.maxFee > FEE_CAP || cfg.maxBaseFee > cfg.maxFee) revert InvalidConfig(3);
        if (cfg.decaySeconds < MIN_DECAY_SECONDS || cfg.decaySeconds > MAX_DECAY_SECONDS) revert InvalidConfig(4);
        if (cfg.minTuneInterval < MIN_TUNE_INTERVAL) revert InvalidConfig(5);
        if (cfg.tuner == address(this)) revert InvalidConfig(6);
    }

    /*//////////////////////////////////////////////////////////////
                               CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolMustUseDynamicFee(key.fee);
        if (!_admins[key.toId()].configured) revert PoolNotConfigured();
        return ICLHooks.beforeInitialize.selector;
    }

    /// @dev Starts the references at the birth tick and writes the base fee as the pool's stored fee,
    /// so `getSlot0` never reports zero.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        uint40 t = uint40(block.timestamp);
        _states[id] = PoolState({secTick: tick, secTime: t, volRefTick: tick, volStored: 0, volTime: t});
        poolManager.updateDynamicLPFee(key, _configs[id].baseFee);
        return ICLHooks.afterInitialize.selector;
    }

    /// @dev Never reverts for a configured pool: one static read, bounded arithmetic, one slot write.
    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        if (_advance(s, cfg, tick, uint40(block.timestamp))) _states[id] = s;

        uint24 fee = _fee(cfg, s, tick, params.zeroForOne, uint40(block.timestamp));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 protocolPips = uint24((uint256(fee) * _admins[id].protocolShareBps) / BPS);
        if (protocolPips != 0) TransientSlot.setUint(PENDING_CUT_SLOT, _packCut(id, protocolPips));
        return (
            ICLHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            (fee - protocolPips) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Takes the protocol's part on the unspecified currency, on what the pool actually traded.
    function _afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 packed = TransientSlot.getUint(PENDING_CUT_SLOT);
        if (packed == 0) return (ICLHooks.afterSwap.selector, 0);
        TransientSlot.setUint(PENDING_CUT_SLOT, 0);
        PoolId id = key.toId();
        uint24 protocolPips = _unpackCut(id, packed);

        // Core composes the hook delta as (specified, unspecified); specified is currency0 exactly
        // when `amountSpecified < 0` and `zeroForOne` agree (same rule as `RevShareHook`).
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency currency = specifiedIs0 ? key.currency1 : key.currency0;
        int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
        uint256 magnitude = unspecified > 0 ? uint256(int256(unspecified)) : uint256(-int256(unspecified));
        // magnitude < 2^127, protocolPips < 2^17: no overflow. Floors: the rounding wei stays with the trader.
        uint256 cut = (magnitude * protocolPips) / FEE_PIPS;
        if (cut == 0) return (ICLHooks.afterSwap.selector, 0);

        protocolTaken[currency] += cut;
        emit ProtocolFeeTaken(id, currency, cut);
        vault.mint(address(this), currency, cut);
        return (ICLHooks.afterSwap.selector, cut.toInt128());
    }

    /// @dev Tags the pending cut with its pool, so `afterSwap` can never apply another pool's cut.
    function _packCut(PoolId id, uint24 pips) private pure returns (uint256) {
        return (uint256(PoolId.unwrap(id)) << 24) | pips;
    }

    function _unpackCut(PoolId id, uint256 packed) private pure returns (uint24 pips) {
        // forge-lint: disable-next-line(unsafe-typecast)
        pips = uint24(packed);
        // Unreachable: core runs `afterSwap` right after the same swap's `beforeSwap`. Fail closed.
        if (packed >> 24 != (uint256(PoolId.unwrap(id)) << 24) >> 24) revert UnexpectedLockCallback();
    }

    /*//////////////////////////////////////////////////////////////
                                 THE FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev The first swap of a new second counts the net move since the volatility reference (if
    /// beyond the dead band) and moves the same-second reference. Returns whether `s` changed.
    function _advance(PoolState memory s, FeeConfig storage cfg, int24 tick, uint40 t) internal view returns (bool) {
        if (t <= s.secTime) return false;
        uint256 move = _absDiff(tick, s.volRefTick);
        if (move > cfg.deadband) {
            if (move > MAX_MOVE_PER_UPDATE) move = MAX_MOVE_PER_UPDATE;
            uint256 v = uint256(_decayed(s, cfg.decaySeconds, t)) + move;
            if (v > cfg.volCap) v = cfg.volCap;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.volStored = uint32(v);
            s.volTime = t;
            s.volRefTick = tick;
        }
        s.secTick = tick;
        s.secTime = t;
        return true;
    }

    /// @dev Linear decay to zero over `decaySeconds`; floors toward a LOWER fee.
    function _decayed(PoolState memory s, uint32 decaySeconds, uint40 t) internal pure returns (uint32) {
        if (s.volStored == 0 || t < s.volTime) return s.volStored;
        uint256 elapsed = t - s.volTime;
        if (elapsed >= decaySeconds) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32((uint256(s.volStored) * (decaySeconds - elapsed)) / decaySeconds);
    }

    /// @dev fee = base + volSlope * vol + surcharge, clamped to maxFee. Computed in 256 bits.
    function _fee(FeeConfig storage cfg, PoolState memory s, int24 tick, bool zeroForOne, uint40 t)
        internal
        view
        returns (uint24)
    {
        (uint256 base, uint256 volPart, uint256 surcharge) = _parts(cfg, s, tick, zeroForOne, t);
        uint256 fee = base + volPart + surcharge;
        // forge-lint: disable-next-line(unsafe-typecast)
        return fee > cfg.maxFee ? cfg.maxFee : uint24(fee);
    }

    function _parts(FeeConfig storage cfg, PoolState memory s, int24 tick, bool zeroForOne, uint40 t)
        internal
        view
        returns (uint256 base, uint256 volPart, uint256 surcharge)
    {
        base = cfg.baseFee;
        volPart = uint256(cfg.volSlope) * _decayed(s, cfg.decaySeconds, t);
        int256 d = int256(tick) - int256(s.secTick);
        // A reversing trade: price rose earlier this second and this swap lowers it, or the reverse.
        bool reversing = (d > 0 && zeroForOne) || (d < 0 && !zeroForOne);
        if (reversing) surcharge = uint256(cfg.sameSecondSlope) * _absDiff(tick, s.secTick);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return d >= 0 ? uint256(d) : uint256(-d);
    }

    /*//////////////////////////////////////////////////////////////
                              THE TUNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Move the three parameters, inside the pool's fixed bounds, by at most a step each,
    /// at most once per `minTuneInterval`. The pool's tuner only; nobody is exempt.
    function tune(PoolKey calldata key, uint24 baseFee, uint24 volSlope, uint24 sameSecondSlope) external {
        if (address(key.hooks) != address(this)) revert HookMismatch();
        PoolId id = key.toId();
        PoolAdmin storage a = _admins[id];
        if (a.tuner == address(0) || msg.sender != a.tuner) revert NotTuner();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        FeeConfig storage cfg = _configs[id];
        uint40 earliest = a.lastTuneAt == 0 ? 0 : a.lastTuneAt + cfg.minTuneInterval;
        if (block.timestamp < earliest) revert TuneTooSoon(earliest);

        if (baseFee < cfg.minBaseFee || baseFee > cfg.maxBaseFee) revert OutOfBounds(1, baseFee);
        if (volSlope > cfg.maxVolSlope) revert OutOfBounds(2, volSlope);
        if (sameSecondSlope > cfg.maxSameSecondSlope) revert OutOfBounds(3, sameSecondSlope);
        _checkStep(1, cfg.baseFee, baseFee, cfg.maxBaseFeeStep);
        _checkStep(2, cfg.volSlope, volSlope, cfg.maxSlopeStep);
        _checkStep(3, cfg.sameSecondSlope, sameSecondSlope, cfg.maxSlopeStep);

        cfg.baseFee = baseFee;
        cfg.volSlope = volSlope;
        cfg.sameSecondSlope = sameSecondSlope;
        a.lastTuneAt = uint40(block.timestamp);
        emit Tuned(id, msg.sender, baseFee, volSlope, sameSecondSlope);
        poolManager.updateDynamicLPFee(key, baseFee);
    }

    function _checkStep(uint8 field, uint24 current, uint24 value, uint24 maxStep) internal pure {
        uint24 step = value > current ? value - current : current - value;
        if (step > maxStep) revert StepTooLarge(field, current, value, maxStep);
    }

    /// @notice Propose a tuner; it may accept after `TUNER_NOTICE_SECONDS`. Pool owner only.
    function proposeTuner(PoolId id, address tuner) external {
        PoolAdmin storage a = _ownerOf(id);
        if (tuner == address(0) || tuner == address(this)) revert ZeroAddress();
        uint40 effectiveAt = uint40(block.timestamp) + TUNER_NOTICE_SECONDS;
        a.pendingTuner = tuner;
        a.tunerEffectiveAt = effectiveAt;
        emit TunerProposed(id, tuner, effectiveAt);
    }

    function cancelTunerProposal(PoolId id) external {
        PoolAdmin storage a = _ownerOf(id);
        a.pendingTuner = address(0);
        a.tunerEffectiveAt = 0;
        emit TunerProposalCancelled(id);
    }

    /// @notice The proposed tuner takes the role, once the notice has passed.
    function acceptTuner(PoolId id) external {
        PoolAdmin storage a = _admins[id];
        if (a.frozen) revert PoolFrozen();
        if (a.pendingTuner == address(0) || msg.sender != a.pendingTuner) revert NotPendingTuner();
        if (block.timestamp < a.tunerEffectiveAt) revert TunerNoticeNotElapsed(a.tunerEffectiveAt);
        a.tuner = msg.sender;
        a.pendingTuner = address(0);
        a.tunerEffectiveAt = 0;
        emit TunerAccepted(id, msg.sender);
    }

    /// @notice Remove the tuner at once: the pool owner, or the tuner itself. Allowed on a frozen
    /// pool too (it only reduces power).
    function revokeTuner(PoolId id) external {
        PoolAdmin storage a = _admins[id];
        if (a.tuner == address(0)) revert NoTuner();
        if (msg.sender != a.owner && msg.sender != a.tuner) revert NotPoolOwner();
        a.tuner = address(0);
        emit TunerRevoked(id, msg.sender);
    }

    /// @notice Fix the pool's parameters for ever: removes the tuner and ends every owner power.
    function freeze(PoolId id) external {
        PoolAdmin storage a = _ownerOf(id);
        a.frozen = true;
        a.tuner = address(0);
        a.pendingTuner = address(0);
        a.tunerEffectiveAt = 0;
        a.pendingOwner = address(0);
        emit Frozen(id);
    }

    function transferPoolOwnership(PoolId id, address next) external {
        PoolAdmin storage a = _ownerOf(id);
        a.pendingOwner = next;
        emit PoolOwnershipTransferStarted(id, a.owner, next);
    }

    function acceptPoolOwnership(PoolId id) external {
        PoolAdmin storage a = _admins[id];
        if (a.frozen) revert PoolFrozen();
        if (a.pendingOwner == address(0) || msg.sender != a.pendingOwner) revert NotPendingPoolOwner();
        address previous = a.owner;
        a.owner = msg.sender;
        a.pendingOwner = address(0);
        emit PoolOwnershipTransferred(id, previous, msg.sender);
    }

    /// @dev The pool owner, on a configured pool that is not frozen.
    function _ownerOf(PoolId id) private view returns (PoolAdmin storage a) {
        a = _admins[id];
        if (!a.configured) revert PoolNotConfigured();
        if (msg.sender != a.owner) revert NotPoolOwner();
        if (a.frozen) revert PoolFrozen();
    }

    /*//////////////////////////////////////////////////////////////
                       THE PROTOCOL SHARE (THE SAFE)
    //////////////////////////////////////////////////////////////*/

    /// @notice The share frozen into pools configured NOW (an increase that has matured included).
    function protocolShareBps() public view returns (uint16) {
        if (_pendingShareAt != 0 && block.timestamp >= _pendingShareAt) return _pendingShareBps;
        return _protocolShareBps;
    }

    /// @notice A scheduled increase not yet in force, or (0, 0).
    function pendingProtocolShare() external view returns (uint16 share, uint40 effectiveAt) {
        if (_pendingShareAt == 0 || block.timestamp >= _pendingShareAt) return (0, 0);
        return (_pendingShareBps, _pendingShareAt);
    }

    /// @notice Set the share for pools configured from now on, inside `MAX_PROTOCOL_SHARE_BPS`.
    /// A decrease applies at once and withdraws any scheduled increase; an increase applies after
    /// `SHARE_NOTICE_SECONDS`. Never retroactive: a configured pool keeps its share for ever.
    function setProtocolShare(uint16 shareBps) external onlyOwner {
        if (shareBps > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareAboveCap(shareBps, MAX_PROTOCOL_SHARE_BPS);
        _materialiseShare();
        uint16 current = _protocolShareBps;
        if (shareBps <= current) {
            _pendingShareBps = 0;
            _pendingShareAt = 0;
            _protocolShareBps = shareBps;
            emit ProtocolShareChanged(current, shareBps);
        } else {
            uint40 effectiveAt = uint40(block.timestamp) + SHARE_NOTICE_SECONDS;
            _pendingShareBps = shareBps;
            _pendingShareAt = effectiveAt;
            emit ProtocolShareIncreaseScheduled(current, shareBps, effectiveAt);
        }
    }

    /// @notice Withdraw a scheduled increase that has not taken effect.
    function cancelPendingProtocolShare() external onlyOwner {
        _materialiseShare();
        if (_pendingShareAt == 0) revert NoPendingProtocolShare();
        uint16 withdrawn = _pendingShareBps;
        _pendingShareBps = 0;
        _pendingShareAt = 0;
        emit ProtocolShareIncreaseCancelled(withdrawn);
    }

    /// @dev Folds a matured increase into the current share.
    function _materialiseShare() private {
        if (_pendingShareAt != 0 && block.timestamp >= _pendingShareAt) {
            uint16 previous = _protocolShareBps;
            _protocolShareBps = _pendingShareBps;
            _pendingShareBps = 0;
            _pendingShareAt = 0;
            emit ProtocolShareChanged(previous, _protocolShareBps);
        }
    }

    /// @notice Disabled: an owner that could renounce would freeze the share at its current level.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay everything this contract holds in `currency` to the protocol recipient: the
    /// redeemed vault claims and any balance sent by mistake. Permissionless; the destination is
    /// the immutable recipient and nothing else.
    function flushProtocolFees(Currency currency) external nonReentrant returns (uint256 amount) {
        uint256 claims = vault.balanceOf(address(this), currency);
        if (claims != 0) {
            _lockCallbackArmed = true;
            vault.lock(abi.encode(currency, claims));
            _lockCallbackArmed = false;
        }
        amount = currency.balanceOfSelf();
        if (amount == 0) revert NothingToFlush(currency);
        protocolFlushed[currency] += amount;
        emit ProtocolFeesFlushed(currency, protocolRecipient, amount);
        currency.transfer(protocolRecipient, amount);
    }

    /// @inheritdoc ILockCallback
    /// @dev Reachable only through `flushProtocolFees`: the vault calls back whoever called `lock`,
    /// and the flag is set only across that call. `burn` credits +amount, `take` debits it.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault) || !_lockCallbackArmed) revert UnexpectedLockCallback();
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.burn(address(this), currency, amount);
        vault.take(currency, address(this), amount);
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The total fee a swap in this direction would pay now (LP part + protocol part).
    function currentFee(PoolId id, bool zeroForOne) external view returns (uint24) {
        (uint24 total,,) = _now(id, zeroForOne);
        return total;
    }

    /// @notice The fee a swap now would pay, split: its three terms, and who gets it.
    function feeParts(PoolId id, bool zeroForOne)
        external
        view
        returns (uint24 base, uint24 volPart, uint24 surcharge, uint24 total, uint24 lpPips, uint24 protocolPips)
    {
        if (!_admins[id].configured) revert PoolNotConfigured();
        (, int24 tick,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        uint40 t = uint40(block.timestamp);
        _advance(s, cfg, tick, t);
        (uint256 b, uint256 v, uint256 sc) = _parts(cfg, s, tick, zeroForOne, t);
        // Each term alone is clamped for display; `total` is the clamped sum the swap pays.
        base = _clamp(b, cfg.maxFee);
        volPart = _clamp(v, cfg.maxFee);
        surcharge = _clamp(sc, cfg.maxFee);
        (total, lpPips, protocolPips) = _now(id, zeroForOne);
    }

    function _now(PoolId id, bool zeroForOne) private view returns (uint24 total, uint24 lpPips, uint24 protocolPips) {
        PoolAdmin storage a = _admins[id];
        if (!a.configured) revert PoolNotConfigured();
        (, int24 tick,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        uint40 t = uint40(block.timestamp);
        _advance(s, cfg, tick, t);
        total = _fee(cfg, s, tick, zeroForOne, t);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolPips = uint24((uint256(total) * a.protocolShareBps) / BPS);
        lpPips = total - protocolPips;
    }

    function _clamp(uint256 v, uint24 cap) private pure returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return v > cap ? cap : uint24(v);
    }

    /// @notice Volatility as a swap now would see it (after decay), and when it was last counted.
    function volatility(PoolId id) external view returns (uint32 vol, uint40 volTime) {
        PoolState memory s = _states[id];
        return (_decayed(s, _configs[id].decaySeconds, uint40(block.timestamp)), s.volTime);
    }

    function getConfig(PoolId id) external view returns (FeeConfig memory) {
        return _configs[id];
    }

    function getState(PoolId id) external view returns (PoolState memory) {
        return _states[id];
    }

    function getAdmin(PoolId id) external view returns (PoolAdmin memory) {
        return _admins[id];
    }

    /// @notice When the pool's tuner may next call `tune` (0 = now).
    function nextTuneAt(PoolId id) external view returns (uint40) {
        uint40 last = _admins[id].lastTuneAt;
        return last == 0 ? 0 : last + _configs[id].minTuneInterval;
    }
}
