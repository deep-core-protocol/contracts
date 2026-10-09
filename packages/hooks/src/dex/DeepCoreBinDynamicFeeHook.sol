// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseBinHook} from "../base/BaseBinHook.sol";
import {IBinHooks} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
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

/// @title DeepCoreBinDynamicFeeHook
/// @notice The Bin twin of `DeepCoreDynamicFeeHook`: the same fee model, roles, protocol share and
/// funds path, on a Bin pool. Read that contract's header first; only the Bin differences are here.
///
/// ############################## WHAT DIFFERS ON BIN ##############################
///
///  * THE UNIT. A Bin pool has no tick; it has `activeId`, and one bin is `binStep` basis points of
///    price. Volatility, the dead band, the cap and the surcharge are all measured in
///    `bins x binStep`, so every configuration value means the same thing it means on CL, where one
///    tick is about one basis point. `binStep` is read from the key once, at `configure`.
///  * THE DIRECTION. `swapForY` sells X (currency0) for Y and moves the active bin DOWN: the analogue
///    of CL's `zeroForOne`, which lowers the tick.
///  * MINTS ARE PRICED. Adding liquidity to the ACTIVE bin at another ratio is an implicit swap core
///    charges at the composition fee (BaseBinHook note E). Without `beforeMint`, mint-then-burn would
///    trade at the stored base fee, under the dynamic one. `beforeMint` therefore returns the dynamic
///    fee - the HIGHER of the two directions, since a mint has none - so a mint is never a cheaper
///    swap. The protocol takes no share of a composition fee: its part cannot be taken as a delta
///    there, so the whole composition fee goes to the LPs. A trader gains nothing by using that path;
///    the protocol forgoes its share on it.
///  * THE CEILING. Core refuses a Bin fee above 10%; `HARD_FEE_CAP` is exactly 10%.
///
/// Hook bitmap: beforeInitialize | afterInitialize | beforeMint | beforeSwap | afterSwap |
/// afterSwapReturnsDelta = bits 0, 1, 2, 6, 7, 11 = 0x08C7. No burn callback: it cannot trap a position.
contract DeepCoreBinDynamicFeeHook is BaseBinHook, Ownable2Step, ReentrancyGuard, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using BinPoolParametersHelper for bytes32;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Identical to `DeepCoreDynamicFeeHook.FeeConfig`; tick-denominated fields are in
    /// `bins x binStep` here (basis points of price).
    struct FeeConfig {
        uint24 baseFee;
        uint24 volSlope;
        uint24 sameSecondSlope;
        uint24 minBaseFee;
        uint24 maxBaseFee;
        uint24 maxVolSlope;
        uint24 maxSameSecondSlope;
        uint24 maxFee;
        uint32 volCap;
        uint32 decaySeconds;
        uint24 deadband;
        uint24 maxBaseFeeStep;
        uint24 maxSlopeStep;
        uint32 minTuneInterval;
        address tuner;
    }

    /// @dev One slot: the volatility and same-second references, as bin ids.
    struct PoolState {
        uint24 secId;
        uint40 secTime;
        uint24 volRefId;
        uint32 volStored;
        uint40 volTime;
    }

    struct PoolAdmin {
        address owner;
        uint16 protocolShareBps;
        uint16 binStep;
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
    /// @notice Core's Bin ceiling (`LPFeeLibrary.TEN_PERCENT_FEE`).
    uint24 public constant HARD_FEE_CAP = 100_000;
    uint16 public constant HARD_MAX_PROTOCOL_SHARE_BPS = 5_000;
    uint32 public constant MIN_DECAY_SECONDS = 600;
    uint32 public constant MAX_DECAY_SECONDS = 86_400;
    uint32 public constant MIN_TUNE_INTERVAL = 3_600;
    uint32 public constant MIN_NOTICE_SECONDS = 86_400;
    uint24 public constant HARD_MAX_MOVE = 2_000;

    uint256 private constant PENDING_CUT_SLOT = uint256(keccak256("deepcore.bindynamicfee.pendingCut")) - 1;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IVault public immutable vault;
    address public immutable protocolRecipient;
    uint24 public immutable FEE_CAP;
    uint16 public immutable MAX_PROTOCOL_SHARE_BPS;
    uint32 public immutable SHARE_NOTICE_SECONDS;
    uint32 public immutable TUNER_NOTICE_SECONDS;
    /// @notice The most one second's net move adds to volatility, in bins x binStep.
    uint24 public immutable MAX_MOVE_PER_UPDATE;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint16 private _protocolShareBps;
    uint16 private _pendingShareBps;
    uint40 private _pendingShareAt;
    bool private _lockCallbackArmed;

    mapping(PoolId => FeeConfig) private _configs;
    mapping(PoolId => PoolState) private _states;
    mapping(PoolId => PoolAdmin) private _admins;

    mapping(Currency currency => uint256) public protocolTaken;
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

    event PoolConfigured(PoolId indexed poolId, address indexed owner, uint16 protocolShareBps, uint16 binStep, FeeConfig cfg);
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

    constructor(
        IBinPoolManager poolManager_,
        IVault vault_,
        address owner_,
        address protocolRecipient_,
        uint24 feeCap_,
        uint16 initialShareBps_,
        uint16 maxShareBps_,
        uint32 shareNoticeSeconds_,
        uint32 tunerNoticeSeconds_,
        uint24 maxMovePerUpdate_
    ) BaseBinHook(poolManager_) Ownable(owner_) {
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

    receive() external payable {
        if (msg.sender != address(vault)) revert NativeNotAccepted();
    }

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_MINT | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA;
    }

    /*//////////////////////////////////////////////////////////////
                           POOL CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function configure(PoolKey calldata key, FeeConfig calldata cfg, uint16 maxProtocolShareBps) external {
        if (address(key.hooks) != address(this)) revert HookMismatch();
        if (address(key.poolManager) != address(poolManager)) revert PoolManagerMismatch();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolMustUseDynamicFee(key.fee);
        PoolId id = key.toId();
        (uint24 activeId,,) = poolManager.getSlot0(id);
        if (activeId != 0) revert PoolAlreadyInitialized();
        PoolAdmin storage a = _admins[id];
        if (a.configured) revert PoolAlreadyConfigured();
        _validate(cfg);
        uint16 share = protocolShareBps();
        if (share > maxProtocolShareBps) revert ProtocolShareAboveAccepted(share, maxProtocolShareBps);
        uint16 binStep = key.parameters.getBinStep();

        _configs[id] = cfg;
        a.owner = msg.sender;
        a.protocolShareBps = share;
        a.binStep = binStep;
        a.configured = true;
        a.tuner = cfg.tuner;
        emit PoolConfigured(id, msg.sender, share, binStep, cfg);
    }

    /// @dev The same reasons as the CL hook: 1 base outside its bounds; 2 a slope above its bound;
    /// 3 maxFee zero, above FEE_CAP, or below the highest base; 4 decay outside 600..86,400; 5 tune
    /// interval under 3,600; 6 the tuner is this contract; 7 min above max.
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

    function _beforeInitialize(address, PoolKey calldata key, uint24) internal view override returns (bytes4) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolMustUseDynamicFee(key.fee);
        if (!_admins[key.toId()].configured) revert PoolNotConfigured();
        return IBinHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint24 activeId) internal override returns (bytes4) {
        PoolId id = key.toId();
        uint40 t = uint40(block.timestamp);
        _states[id] = PoolState({secId: activeId, secTime: t, volRefId: activeId, volStored: 0, volTime: t});
        poolManager.updateDynamicLPFee(key, _configs[id].baseFee);
        return IBinHooks.afterInitialize.selector;
    }

    /// @dev An active-bin mint is an implicit swap: charge it the dynamic fee (the higher direction),
    /// never the stored base fee. Reads only; a mint does not move the volatility state.
    function _beforeMint(address, PoolKey calldata key, IBinPoolManager.MintParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, uint24)
    {
        PoolId id = key.toId();
        (uint24 activeId,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        uint40 t = uint40(block.timestamp);
        uint16 binStep = _admins[id].binStep;
        _advance(s, cfg, activeId, t, binStep);
        uint24 a = _fee(cfg, s, activeId, true, t, binStep);
        uint24 b = _fee(cfg, s, activeId, false, t, binStep);
        return (IBinHooks.beforeMint.selector, (a > b ? a : b) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _beforeSwap(address, PoolKey calldata key, bool swapForY, int128, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (uint24 activeId,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        uint16 binStep = _admins[id].binStep;
        if (_advance(s, cfg, activeId, uint40(block.timestamp), binStep)) _states[id] = s;

        uint24 fee = _fee(cfg, s, activeId, swapForY, uint40(block.timestamp), binStep);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 protocolPips = uint24((uint256(fee) * _admins[id].protocolShareBps) / BPS);
        if (protocolPips != 0) TransientSlot.setUint(PENDING_CUT_SLOT, _packCut(id, protocolPips));
        return (
            IBinHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            (fee - protocolPips) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(address, PoolKey calldata key, bool swapForY, int128 amountSpecified, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 packed = TransientSlot.getUint(PENDING_CUT_SLOT);
        if (packed == 0) return (IBinHooks.afterSwap.selector, 0);
        TransientSlot.setUint(PENDING_CUT_SLOT, 0);
        PoolId id = key.toId();
        uint24 protocolPips = _unpackCut(id, packed);

        // BinHooks.afterSwap composes (amountSpecified < 0 == swapForY) ? (specified, unspecified) : (unspecified, specified).
        bool specifiedIs0 = (amountSpecified < 0) == swapForY;
        Currency currency = specifiedIs0 ? key.currency1 : key.currency0;
        int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
        uint256 magnitude = unspecified > 0 ? uint256(int256(unspecified)) : uint256(-int256(unspecified));
        uint256 cut = (magnitude * protocolPips) / FEE_PIPS;
        if (cut == 0) return (IBinHooks.afterSwap.selector, 0);

        protocolTaken[currency] += cut;
        emit ProtocolFeeTaken(id, currency, cut);
        vault.mint(address(this), currency, cut);
        return (IBinHooks.afterSwap.selector, cut.toInt128());
    }

    function _packCut(PoolId id, uint24 pips) private pure returns (uint256) {
        return (uint256(PoolId.unwrap(id)) << 24) | pips;
    }

    function _unpackCut(PoolId id, uint256 packed) private pure returns (uint24 pips) {
        // forge-lint: disable-next-line(unsafe-typecast)
        pips = uint24(packed);
        if (packed >> 24 != (uint256(PoolId.unwrap(id)) << 24) >> 24) revert UnexpectedLockCallback();
    }

    /*//////////////////////////////////////////////////////////////
                                 THE FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev Moves are in bins x binStep (basis points of price).
    function _advance(PoolState memory s, FeeConfig storage cfg, uint24 activeId, uint40 t, uint16 binStep)
        internal
        view
        returns (bool)
    {
        if (t <= s.secTime) return false;
        uint256 move = _dist(activeId, s.volRefId) * binStep;
        if (move > cfg.deadband) {
            if (move > MAX_MOVE_PER_UPDATE) move = MAX_MOVE_PER_UPDATE;
            uint256 v = uint256(_decayed(s, cfg.decaySeconds, t)) + move;
            if (v > cfg.volCap) v = cfg.volCap;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.volStored = uint32(v);
            s.volTime = t;
            s.volRefId = activeId;
        }
        s.secId = activeId;
        s.secTime = t;
        return true;
    }

    function _decayed(PoolState memory s, uint32 decaySeconds, uint40 t) internal pure returns (uint32) {
        if (s.volStored == 0 || t < s.volTime) return s.volStored;
        uint256 elapsed = t - s.volTime;
        if (elapsed >= decaySeconds) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32((uint256(s.volStored) * (decaySeconds - elapsed)) / decaySeconds);
    }

    function _fee(FeeConfig storage cfg, PoolState memory s, uint24 activeId, bool swapForY, uint40 t, uint16 binStep)
        internal
        view
        returns (uint24)
    {
        (uint256 base, uint256 volPart, uint256 surcharge) = _parts(cfg, s, activeId, swapForY, t, binStep);
        uint256 fee = base + volPart + surcharge;
        // forge-lint: disable-next-line(unsafe-typecast)
        return fee > cfg.maxFee ? cfg.maxFee : uint24(fee);
    }

    function _parts(FeeConfig storage cfg, PoolState memory s, uint24 activeId, bool swapForY, uint40 t, uint16 binStep)
        internal
        view
        returns (uint256 base, uint256 volPart, uint256 surcharge)
    {
        base = cfg.baseFee;
        volPart = uint256(cfg.volSlope) * _decayed(s, cfg.decaySeconds, t);
        int256 d = int256(uint256(activeId)) - int256(uint256(s.secId));
        // Reversing: the active bin rose earlier this second and this swap sells X (moves it down),
        // or it fell and this swap buys X.
        bool reversing = (d > 0 && swapForY) || (d < 0 && !swapForY);
        if (reversing) surcharge = uint256(cfg.sameSecondSlope) * _dist(activeId, s.secId) * binStep;
    }

    function _dist(uint24 a, uint24 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }

    /*//////////////////////////////////////////////////////////////
                              THE TUNER
    //////////////////////////////////////////////////////////////*/

    function tune(PoolKey calldata key, uint24 baseFee, uint24 volSlope, uint24 sameSecondSlope) external {
        if (address(key.hooks) != address(this)) revert HookMismatch();
        PoolId id = key.toId();
        PoolAdmin storage a = _admins[id];
        if (a.tuner == address(0) || msg.sender != a.tuner) revert NotTuner();
        (uint24 activeId,,) = poolManager.getSlot0(id);
        if (activeId == 0) revert PoolNotInitialized();
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

    function revokeTuner(PoolId id) external {
        PoolAdmin storage a = _admins[id];
        if (a.tuner == address(0)) revert NoTuner();
        if (msg.sender != a.owner && msg.sender != a.tuner) revert NotPoolOwner();
        a.tuner = address(0);
        emit TunerRevoked(id, msg.sender);
    }

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

    function _ownerOf(PoolId id) private view returns (PoolAdmin storage a) {
        a = _admins[id];
        if (!a.configured) revert PoolNotConfigured();
        if (msg.sender != a.owner) revert NotPoolOwner();
        if (a.frozen) revert PoolFrozen();
    }

    /*//////////////////////////////////////////////////////////////
                       THE PROTOCOL SHARE (THE SAFE)
    //////////////////////////////////////////////////////////////*/

    function protocolShareBps() public view returns (uint16) {
        if (_pendingShareAt != 0 && block.timestamp >= _pendingShareAt) return _pendingShareBps;
        return _protocolShareBps;
    }

    function pendingProtocolShare() external view returns (uint16 share, uint40 effectiveAt) {
        if (_pendingShareAt == 0 || block.timestamp >= _pendingShareAt) return (0, 0);
        return (_pendingShareBps, _pendingShareAt);
    }

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

    function cancelPendingProtocolShare() external onlyOwner {
        _materialiseShare();
        if (_pendingShareAt == 0) revert NoPendingProtocolShare();
        uint16 withdrawn = _pendingShareBps;
        _pendingShareBps = 0;
        _pendingShareAt = 0;
        emit ProtocolShareIncreaseCancelled(withdrawn);
    }

    function _materialiseShare() private {
        if (_pendingShareAt != 0 && block.timestamp >= _pendingShareAt) {
            uint16 previous = _protocolShareBps;
            _protocolShareBps = _pendingShareBps;
            _pendingShareBps = 0;
            _pendingShareAt = 0;
            emit ProtocolShareChanged(previous, _protocolShareBps);
        }
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNDS
    //////////////////////////////////////////////////////////////*/

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

    function currentFee(PoolId id, bool swapForY) external view returns (uint24) {
        (uint24 total,,) = _now(id, swapForY);
        return total;
    }

    /// @notice The fee an active-bin mint would pay now (the higher direction; all to the LPs).
    function mintFee(PoolId id) external view returns (uint24) {
        (uint24 a,,) = _now(id, true);
        (uint24 b,,) = _now(id, false);
        return a > b ? a : b;
    }

    function feeParts(PoolId id, bool swapForY)
        external
        view
        returns (uint24 base, uint24 volPart, uint24 surcharge, uint24 total, uint24 lpPips, uint24 protocolPips)
    {
        if (!_admins[id].configured) revert PoolNotConfigured();
        (uint24 activeId,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        uint40 t = uint40(block.timestamp);
        uint16 binStep = _admins[id].binStep;
        _advance(s, cfg, activeId, t, binStep);
        (uint256 b, uint256 v, uint256 sc) = _parts(cfg, s, activeId, swapForY, t, binStep);
        base = _clamp(b, cfg.maxFee);
        volPart = _clamp(v, cfg.maxFee);
        surcharge = _clamp(sc, cfg.maxFee);
        (total, lpPips, protocolPips) = _now(id, swapForY);
    }

    function _now(PoolId id, bool swapForY) private view returns (uint24 total, uint24 lpPips, uint24 protocolPips) {
        PoolAdmin storage a = _admins[id];
        if (!a.configured) revert PoolNotConfigured();
        (uint24 activeId,,) = poolManager.getSlot0(id);
        FeeConfig storage cfg = _configs[id];
        PoolState memory s = _states[id];
        uint40 t = uint40(block.timestamp);
        _advance(s, cfg, activeId, t, a.binStep);
        total = _fee(cfg, s, activeId, swapForY, t, a.binStep);
        // forge-lint: disable-next-line(unsafe-typecast)
        protocolPips = uint24((uint256(total) * a.protocolShareBps) / BPS);
        lpPips = total - protocolPips;
    }

    function _clamp(uint256 v, uint24 cap) private pure returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return v > cap ? cap : uint24(v);
    }

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

    function nextTuneAt(PoolId id) external view returns (uint40) {
        uint40 last = _admins[id].lastTuneAt;
        return last == 0 ? 0 : last + _configs[id].minTuneInterval;
    }
}
