/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {OrdersFeeBase} from "./base/OrdersFeeBase.sol";

/// @title DeepCoreRangeOrders - limit orders on DeepCore CL pools, as single-tick-spacing range positions
/// @notice Design of record: docs/products/limit-orders.md. A manager contract, NOT a DeepCore (hook), so it
/// serves every CL pool on the shared core whose key cannot trap a removal, launch pools included.
///
/// HOW AN ORDER WORKS. A sell of currency0 rests ABOVE the price as liquidity in `[tickLower, tickLower +
/// tickSpacing)` that holds only currency0; when the pool's tick reaches `tickUpper` the position holds only
/// currency1 and the order is filled. A sell of currency1 rests BELOW the price and is filled when the tick
/// drops under `tickLower`. Orders at the same pool, level and side share one core position, an EPOCH; anyone
/// may `execute` a crossed epoch, which removes the whole position and pays the executor the tips the epoch's
/// makers escrowed. Each maker then `withdraw`s its pro-rata share of the proceeds.
///
/// A FILL CAN BE MISSED: if price crosses the level and comes back before anyone executes, the position
/// converts back. This is the manager design's defining limit.
///
/// FEES (owner decision of record, 2026-10-12, CONFIRM): the protocol fee (bps, frozen per order) and the
/// order's integrator bps are charged on the CONVERTED principal only - the output-token principal an order
/// produced - whether it leaves through `withdraw` after a fill or through `cancel` while price sits inside
/// the range. An untouched order cancels free. LP swap fees the position earned are the maker's, uncharged.
/// Resting orders pay no launch-guard fee and no creator tax (they are makers); the conservative default
/// the design recommends is to allow them on launch pools and charge only this fill fee.
///
/// LAUNCH POOLS ARE REFUSED (owner decision, 2026-10-13: "restrict them"). A resting order is a maker: on a
/// launch pool it would sell without paying the launch guard's trade fee or the creator tax. `place` refuses
/// a key whose hook is one of the launch guards named at construction (`isLaunchGuard`, no setter), OR whose
/// parameters carry one of the three bitmaps a DeepCore CL launch guard has ever had (0x0041, 0x08C1, 0x0CC1;
/// the SDK tells guard generations apart the same way). The bitmap rule also covers a guard redeployed at a
/// new address; its cost is that a stranger's hook with an identical bitmap is refused too. WHAT IT CANNOT
/// DETECT: a future guard generation at a new address with a NEW bitmap. That needs a new deployment of this
/// contract, and belongs on the checklist of any guard release. Orders already resting are never touched.
///
/// WHAT IT REFUSES. A key whose manager is not the immutable `CL_POOL_MANAGER`; a key whose parameters set
/// before/after-remove-liquidity or any add/remove returns-delta (a hook that can block or tax a removal can
/// trap an order); a level already in range; fee-on-transfer tokens (measured); native sent by anyone but the
/// Vault. No admin path reaches an order, an epoch, proceeds or tips.
contract DeepCoreRangeOrders is OrdersFeeBase, ILockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;

    struct Epoch {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        bool zeroForOne; // true: the epoch sells currency0 (rests above price)
        bool filled;
        /// Before the fill: the position's liquidity. After: the liquidity not yet withdrawn.
        uint128 liquidity;
        uint128 liquidityAtFill;
        /// Output-currency principal the fill produced.
        uint256 proceeds;
        /// LP fees booked per unit of liquidity, Q128.
        uint256 acc0X128;
        uint256 acc1X128;
        /// Units held for this epoch's makers (booked LP fees, and proceeds after the fill).
        uint256 held0;
        uint256 held1;
        /// Input-currency tips escrowed by the epoch's live orders.
        uint256 tipTotal;
    }

    struct Order {
        address maker;
        uint64 epochId;
        uint16 feeBps;
        uint16 integratorBps;
        address integrator;
        uint128 liquidity;
        uint128 tip;
        uint256 snap0X128;
        uint256 snap1X128;
    }

    struct PlaceParams {
        PoolKey key;
        int24 tickLower;
        bool zeroForOne;
        uint256 amountIn;
        uint128 tip;
        address integrator;
        uint16 integratorBps;
    }

    event EpochOpened(
        uint256 indexed epochId, PoolId indexed poolId, int24 tickLower, int24 tickUpper, bool zeroForOne
    );
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed epochId,
        address indexed maker,
        uint256 amountIn,
        uint128 liquidity,
        uint128 tip,
        uint16 feeBps,
        address integrator,
        uint16 integratorBps
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker, address to, uint256 amount0, uint256 amount1);
    event EpochFilled(uint256 indexed epochId, address indexed executor, uint256 proceeds, uint256 tip);
    event OrderWithdrawn(uint256 indexed orderId, address indexed maker, address to, uint256 amount0, uint256 amount1);

    error WrongPoolManager();
    error HookCanTrapLiquidity(uint16 bitmap);
    error LaunchPoolNotSupported(address hook);
    error TooManyLaunchGuards();
    error PoolNotInitialized();
    error LevelNotAligned(int24 tickLower, int24 tickSpacing);
    error LevelOutOfBounds(int24 tickLower);
    error OrderInRange(int24 tick, int24 tickLower);
    error ZeroAmount();
    error LiquidityOutOfBounds();
    error WrongValue(uint256 expected, uint256 sent);
    error FeeOnTransferUnsupported(uint256 expected, uint256 received);
    error NotMaker();
    error UnknownOrder();
    error UnknownEpoch();
    error NotCrossed();
    error EpochAlreadyFilled();
    error EpochNotFilled();
    error EmptyEpoch();
    error NotVault(address caller);
    error NotLocker(address locker);
    error NativeNotAccepted();
    error UnexpectedDelta();

    /// @dev Parameters bits a key may not set: before/after remove (4, 5), after-add and after-remove
    /// returns-delta (12, 13).
    uint16 public constant FORBIDDEN_HOOK_BITS = (1 << 4) | (1 << 5) | (1 << 12) | (1 << 13);
    uint256 private constant Q128 = 1 << 128;

    /// @dev The bitmaps of every DeepCore CL launch-guard generation: first (LP-fee override), creator tax,
    /// quote-fee-at-source.
    uint16 internal constant GUARD_BITMAP_V1 = 0x0041;
    uint16 internal constant GUARD_BITMAP_TAX = 0x08C1;
    uint16 internal constant GUARD_BITMAP_QF = 0x0CC1;
    uint256 public constant MAX_LAUNCH_GUARDS = 16;

    IVault public immutable VAULT;
    ICLPoolManager public immutable CL_POOL_MANAGER;
    /// @notice Launch guards named at construction. Written once; there is no setter.
    mapping(address => bool) public isLaunchGuard;

    uint256 public nextEpochId = 1;
    uint256 public nextOrderId = 1;

    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => Order) internal _orders;
    mapping(uint256 => PoolKey) internal _epochKeys;
    /// @dev keccak256(poolId, tickLower, zeroForOne) => the epoch new orders join (0 = none).
    mapping(bytes32 => uint256) internal _openEpoch;

    constructor(
        ICLPoolManager clPoolManager,
        address owner_,
        address protocolFeeRecipient_,
        uint16 initialFeeBps,
        uint16 maxFeeBps_,
        uint32 noticeSeconds_,
        address[] memory launchGuards
    ) OrdersFeeBase(owner_, protocolFeeRecipient_, initialFeeBps, maxFeeBps_, noticeSeconds_) {
        if (address(clPoolManager) == address(0)) revert ZeroAddress();
        if (launchGuards.length > MAX_LAUNCH_GUARDS) revert TooManyLaunchGuards();
        CL_POOL_MANAGER = clPoolManager;
        VAULT = clPoolManager.vault();
        for (uint256 i; i < launchGuards.length; ++i) {
            if (launchGuards[i] == address(0)) revert ZeroAddress();
            isLaunchGuard[launchGuards[i]] = true;
        }
    }

    /// @notice Native arrives only from the Vault, during this contract's own `take`.
    receive() external payable {
        if (msg.sender != address(VAULT)) revert NativeNotAccepted();
    }

    /*//////////////////////////////////////////////////////////////
                                 MAKER
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a limit order. `amountIn` of the sold currency becomes out-of-range liquidity; `tip` (same
    /// currency) is escrowed for whoever executes the fill. Any unused remainder of `amountIn` (rounding) is
    /// refunded in the same call. For native, send exactly `amountIn + tip`.
    function place(PlaceParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 orderId, uint256 epochId, uint128 liquidity)
    {
        PoolId poolId;
        int24 tickUpper;
        (poolId, tickUpper, liquidity) = _validatePlace(p);
        Currency inCurrency = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        _pull(inCurrency, p.amountIn + p.tip);

        epochId = _joinOrOpen(p, poolId, tickUpper);
        Epoch storage e = _epochs[epochId];
        uint256 principalIn = _addToEpoch(e, p, tickUpper, liquidity, epochId);

        e.liquidity += liquidity;
        e.tipTotal += p.tip;
        totalOwed[inCurrency] += p.tip;
        orderId = _record(p, e, epochId, liquidity);

        uint256 refund = p.amountIn - principalIn;
        if (refund != 0) inCurrency.transfer(msg.sender, refund);
    }

    /// @notice Cancel an unfilled order: its liquidity leaves the pool and everything it holds is paid to `to`,
    /// with its share of the LP fees and its tip. Converted principal (the output currency, while price sits
    /// inside the range) pays the frozen protocol and integrator fees; an untouched order pays nothing.
    function cancel(uint256 orderId, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (to == address(0)) revert ZeroAddress();
        Order memory o = _orders[orderId];
        if (o.maker == address(0)) revert UnknownOrder();
        if (o.maker != msg.sender) revert NotMaker();
        Epoch storage e = _epochs[o.epochId];
        if (e.filled) revert EpochAlreadyFilled();
        PoolKey memory key = _epochKeys[o.epochId];

        (uint256 principal0, uint256 principal1) = _removeAndBook(e, key, o.liquidity, o.epochId);
        // `_removeAndBook` put the LP fees in `held`; the principal arrived and is paid out here.
        (uint256 share0, uint256 share1) = _feeShare(e, o);
        e.held0 -= share0;
        e.held1 -= share1;
        e.liquidity -= o.liquidity;
        e.tipTotal -= o.tip;
        delete _orders[orderId];
        totalOwed[key.currency0] -= share0;
        totalOwed[key.currency1] -= share1;

        // Converted principal is the output side; the tip comes back in the input side.
        if (e.zeroForOne) {
            totalOwed[key.currency0] -= o.tip;
            (,, principal1) = _chargeFees(key.currency1, principal1, o.feeBps, o.integrator, o.integratorBps);
            amount0 = principal0 + share0 + o.tip;
            amount1 = principal1 + share1;
        } else {
            totalOwed[key.currency1] -= o.tip;
            (,, principal0) = _chargeFees(key.currency0, principal0, o.feeBps, o.integrator, o.integratorBps);
            amount0 = principal0 + share0;
            amount1 = principal1 + share1 + o.tip;
        }
        if (e.liquidity == 0) _retireDust(e, key);

        emit OrderCancelled(orderId, msg.sender, to, amount0, amount1);
        if (amount0 != 0) key.currency0.transfer(to, amount0);
        if (amount1 != 0) key.currency1.transfer(to, amount1);
    }

    /// @notice After the fill: pay the maker's pro-rata share of the proceeds, net of the frozen protocol and
    /// integrator fees, plus its share of LP fees, to `to`.
    function withdraw(uint256 orderId, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (to == address(0)) revert ZeroAddress();
        Order memory o = _orders[orderId];
        if (o.maker == address(0)) revert UnknownOrder();
        if (o.maker != msg.sender) revert NotMaker();
        Epoch storage e = _epochs[o.epochId];
        if (!e.filled) revert EpochNotFilled();
        PoolKey memory key = _epochKeys[o.epochId];

        uint256 principal = FullMath.mulDiv(e.proceeds, o.liquidity, e.liquidityAtFill);
        (uint256 share0, uint256 share1) = _feeShare(e, o);
        Currency outCurrency = e.zeroForOne ? key.currency1 : key.currency0;
        if (e.zeroForOne) {
            e.held1 -= principal;
        } else {
            e.held0 -= principal;
        }
        e.held0 -= share0;
        e.held1 -= share1;
        e.liquidity -= o.liquidity;
        delete _orders[orderId];

        totalOwed[outCurrency] -= principal;
        totalOwed[key.currency0] -= share0;
        totalOwed[key.currency1] -= share1;
        (,, uint256 net) = _chargeFees(outCurrency, principal, o.feeBps, o.integrator, o.integratorBps);
        if (e.zeroForOne) {
            amount0 = share0;
            amount1 = net + share1;
        } else {
            amount0 = net + share0;
            amount1 = share1;
        }
        if (e.liquidity == 0) _retireDust(e, key);

        emit OrderWithdrawn(orderId, msg.sender, to, amount0, amount1);
        if (amount0 != 0) key.currency0.transfer(to, amount0);
        if (amount1 != 0) key.currency1.transfer(to, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone: fill a crossed epoch. Removes the whole position and pays the caller the epoch's tips.
    function execute(uint256 epochId) external nonReentrant returns (uint256 proceeds, uint256 tip) {
        Epoch storage e = _epochs[epochId];
        if (e.tickUpper == e.tickLower) revert UnknownEpoch();
        if (e.filled) revert EpochAlreadyFilled();
        if (e.liquidity == 0) revert EmptyEpoch();
        if (!_isCrossed(e)) revert NotCrossed();
        return _execute(epochId, e);
    }

    /// @notice Anyone: fill every epoch in the list that is crossed and fillable; skips the rest.
    function executeMany(uint256[] calldata epochIds) external nonReentrant returns (uint256 filled) {
        for (uint256 i; i < epochIds.length; ++i) {
            Epoch storage e = _epochs[epochIds[i]];
            if (e.tickUpper == e.tickLower || e.filled || e.liquidity == 0 || !_isCrossed(e)) continue;
            _execute(epochIds[i], e);
            ++filled;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether `place` refuses this key as a launch pool (by guard address or by guard bitmap).
    function isLaunchPool(PoolKey calldata key) public view returns (bool) {
        uint16 bitmap = uint16(uint256(key.parameters));
        return bitmap == GUARD_BITMAP_V1 || bitmap == GUARD_BITMAP_TAX || bitmap == GUARD_BITMAP_QF
            || isLaunchGuard[address(key.hooks)];
    }

    function isCrossed(uint256 epochId) external view returns (bool) {
        Epoch storage e = _epochs[epochId];
        if (e.tickUpper == e.tickLower || e.filled || e.liquidity == 0) return false;
        return _isCrossed(e);
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function epochKey(uint256 epochId) external view returns (PoolKey memory) {
        return _epochKeys[epochId];
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function openEpochOf(PoolId poolId, int24 tickLower, bool zeroForOne) external view returns (uint256) {
        return _openEpoch[keccak256(abi.encode(poolId, tickLower, zeroForOne))];
    }

    /*//////////////////////////////////////////////////////////////
                               VAULT LOCK
    //////////////////////////////////////////////////////////////*/

    struct ModifyPlan {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    /// @inheritdoc ILockCallback
    /// @dev Only the Vault, and only for a lock THIS contract opened (`getLocker`), as in
    /// `DeepCoreLaunchAndBuy`. No persistent in-flight flag (CLAUDE.md, the lock-exit invariant).
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault(msg.sender);
        address locker = VAULT.getLocker();
        if (locker != address(this)) revert NotLocker(locker);
        ModifyPlan memory m = abi.decode(data, (ModifyPlan));
        (BalanceDelta delta, BalanceDelta feeDelta) = CL_POOL_MANAGER.modifyLiquidity(
            m.key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: m.tickLower,
                tickUpper: m.tickUpper,
                liquidityDelta: m.liquidityDelta,
                salt: m.salt
            }),
            ""
        );
        _settle(m.key.currency0, delta.amount0());
        _settle(m.key.currency1, delta.amount1());
        return abi.encode(delta.amount0(), delta.amount1(), feeDelta.amount0(), feeDelta.amount1());
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _execute(uint256 epochId, Epoch storage e) private returns (uint256 proceeds, uint256 tip) {
        PoolKey memory key = _epochKeys[epochId];
        uint128 liq = e.liquidity;
        (uint256 principal0, uint256 principal1) = _removeAndBook(e, key, liq, epochId);
        // Fully converted, or it was not a fill: the sold side must be empty.
        if (e.zeroForOne ? principal0 != 0 : principal1 != 0) revert NotCrossed();
        proceeds = e.zeroForOne ? principal1 : principal0;
        Currency outCurrency = e.zeroForOne ? key.currency1 : key.currency0;
        Currency inCurrency = e.zeroForOne ? key.currency0 : key.currency1;

        if (e.zeroForOne) e.held1 += proceeds;
        else e.held0 += proceeds;
        totalOwed[outCurrency] += proceeds;
        e.proceeds = proceeds;
        e.liquidityAtFill = liq;
        e.filled = true;
        bytes32 slot = keccak256(abi.encode(e.poolId, e.tickLower, e.zeroForOne));
        if (_openEpoch[slot] == epochId) delete _openEpoch[slot];

        tip = e.tipTotal;
        e.tipTotal = 0;
        totalOwed[inCurrency] -= tip;
        emit EpochFilled(epochId, msg.sender, proceeds, tip);
        if (tip != 0) inCurrency.transfer(msg.sender, tip);
    }

    function _validatePlace(PlaceParams calldata p)
        private
        view
        returns (PoolId poolId, int24 tickUpper, uint128 liquidity)
    {
        if (address(p.key.poolManager) != address(CL_POOL_MANAGER)) revert WrongPoolManager();
        uint16 bitmap = uint16(uint256(p.key.parameters));
        if (bitmap & FORBIDDEN_HOOK_BITS != 0) revert HookCanTrapLiquidity(bitmap);
        if (isLaunchPool(p.key)) revert LaunchPoolNotSupported(address(p.key.hooks));
        if (p.amountIn == 0) revert ZeroAmount();
        _checkIntegrator(p.integrator, p.integratorBps);

        int24 spacing = p.key.parameters.getTickSpacing();
        if (p.tickLower % spacing != 0) revert LevelNotAligned(p.tickLower, spacing);
        tickUpper = p.tickLower + spacing;
        if (p.tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert LevelOutOfBounds(p.tickLower);

        PoolKey memory key = p.key;
        poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = CL_POOL_MANAGER.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        if (p.zeroForOne ? tick >= p.tickLower : tick < tickUpper) revert OrderInRange(tick, p.tickLower);

        liquidity = _liquidityFor(p.tickLower, tickUpper, p.zeroForOne, p.amountIn);
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert LiquidityOutOfBounds();
    }

    function _joinOrOpen(PlaceParams calldata p, PoolId poolId, int24 tickUpper) private returns (uint256 epochId) {
        bytes32 slot = keccak256(abi.encode(poolId, p.tickLower, p.zeroForOne));
        epochId = _openEpoch[slot];
        if (epochId != 0) return epochId;
        epochId = nextEpochId++;
        _openEpoch[slot] = epochId;
        Epoch storage fresh = _epochs[epochId];
        fresh.poolId = poolId;
        fresh.tickLower = p.tickLower;
        fresh.tickUpper = tickUpper;
        fresh.zeroForOne = p.zeroForOne;
        _epochKeys[epochId] = p.key;
        emit EpochOpened(epochId, poolId, p.tickLower, tickUpper, p.zeroForOne);
    }

    /// @dev Adds the order's liquidity to the epoch's position and books the LP fees the add collected for
    /// the liquidity already there. Returns the principal core charged.
    function _addToEpoch(Epoch storage e, PlaceParams calldata p, int24 tickUpper, uint128 liquidity, uint256 epochId)
        private
        returns (uint256 principalIn)
    {
        PoolKey memory key = p.key;
        (int128 owed0, int128 owed1, int128 fee0, int128 fee1) =
            _modify(key, p.tickLower, tickUpper, int256(uint256(liquidity)), epochId);
        // Core reports principal + the fees the existing position collected. Adding out-of-range liquidity
        // owes principal in the sold currency only, never more than was supplied.
        (int128 owedIn, int128 feeIn) = p.zeroForOne ? (owed0, fee0) : (owed1, fee1);
        (int128 owedOther, int128 feeOther) = p.zeroForOne ? (owed1, fee1) : (owed0, fee0);
        int256 principal = int256(feeIn) - int256(owedIn);
        if (owedOther != feeOther || principal <= 0 || uint256(principal) > p.amountIn) revert UnexpectedDelta();
        principalIn = uint256(principal);
        _bookFees(e, key, fee0, fee1);
    }

    function _record(PlaceParams calldata p, Epoch storage e, uint256 epochId, uint128 liquidity)
        private
        returns (uint256 orderId)
    {
        orderId = nextOrderId++;
        uint16 feeBps = protocolFeeBps();
        _orders[orderId] = Order({
            maker: msg.sender,
            epochId: uint64(epochId),
            feeBps: feeBps,
            integratorBps: p.integratorBps,
            integrator: p.integrator,
            liquidity: liquidity,
            tip: p.tip,
            snap0X128: e.acc0X128,
            snap1X128: e.acc1X128
        });
        emit OrderPlaced(orderId, epochId, msg.sender, p.amountIn, liquidity, p.tip, feeBps, p.integrator, p.integratorBps);
    }

    /// @dev Removes `liquidity` from the epoch's position, books the LP fees collected for the liquidity that
    /// was there, and returns the principal that came out (taken to this contract).
    function _removeAndBook(Epoch storage e, PoolKey memory key, uint128 liquidity, uint256 epochId)
        private
        returns (uint256 principal0, uint256 principal1)
    {
        (int128 d0, int128 d1, int128 fee0, int128 fee1) =
            _modify(key, e.tickLower, e.tickUpper, -int256(uint256(liquidity)), epochId);
        if (d0 < fee0 || d1 < fee1) revert UnexpectedDelta();
        _bookFees(e, key, fee0, fee1);
        principal0 = uint256(uint128(d0)) - uint256(uint128(fee0));
        principal1 = uint256(uint128(d1)) - uint256(uint128(fee1));
    }

    function _isCrossed(Epoch storage e) private view returns (bool) {
        (, int24 tick,,) = CL_POOL_MANAGER.getSlot0(e.poolId);
        return e.zeroForOne ? tick >= e.tickUpper : tick < e.tickLower;
    }

    function _modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta, uint256 epochId)
        private
        returns (int128 d0, int128 d1, int128 fee0, int128 fee1)
    {
        bytes memory ret = VAULT.lock(
            abi.encode(
                ModifyPlan({
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDelta,
                    salt: bytes32(epochId)
                })
            )
        );
        (d0, d1, fee0, fee1) = abi.decode(ret, (int128, int128, int128, int128));
        if (fee0 < 0 || fee1 < 0) revert UnexpectedDelta();
    }

    /// @dev Pays what this contract owes the Vault for one currency, or takes what it is owed, to itself.
    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isNative()) {
                // forge-lint: disable-next-line(unused-return)
                VAULT.settle{value: owed}();
            } else {
                VAULT.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransfer(address(VAULT), owed);
                // forge-lint: disable-next-line(unused-return)
                VAULT.settle();
            }
        } else if (amount > 0) {
            VAULT.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    /// @dev Books LP fees a modification collected into the epoch's per-liquidity accumulators. The fees were
    /// earned by the liquidity in the position BEFORE the modification. With none there (impossible for a core
    /// position, kept for safety), they are protocol credit rather than unowned balance.
    function _bookFees(Epoch storage e, PoolKey memory key, int128 fee0, int128 fee1) private {
        uint256 f0 = uint256(uint128(fee0));
        uint256 f1 = uint256(uint128(fee1));
        if (f0 == 0 && f1 == 0) return;
        uint128 liq = e.liquidity;
        totalOwed[key.currency0] += f0;
        totalOwed[key.currency1] += f1;
        if (liq == 0) {
            protocolOwed[key.currency0] += f0;
            protocolOwed[key.currency1] += f1;
            return;
        }
        e.held0 += f0;
        e.held1 += f1;
        e.acc0X128 += FullMath.mulDiv(f0, Q128, liq);
        e.acc1X128 += FullMath.mulDiv(f1, Q128, liq);
    }

    function _feeShare(Epoch storage e, Order memory o) private view returns (uint256 share0, uint256 share1) {
        share0 = FullMath.mulDiv(e.acc0X128 - o.snap0X128, o.liquidity, Q128);
        share1 = FullMath.mulDiv(e.acc1X128 - o.snap1X128, o.liquidity, Q128);
        // Floors cannot exceed what was booked; capped anyway so rounding can never block an exit.
        if (share0 > e.held0) share0 = e.held0;
        if (share1 > e.held1) share1 = e.held1;
    }

    /// @dev When the last order of an epoch leaves, rounding dust it still holds becomes protocol credit, so
    /// no unit is left with no path out.
    function _retireDust(Epoch storage e, PoolKey memory key) private {
        uint256 h0 = e.held0;
        uint256 h1 = e.held1;
        if (h0 != 0) {
            e.held0 = 0;
            protocolOwed[key.currency0] += h0;
        }
        if (h1 != 0) {
            e.held1 = 0;
            protocolOwed[key.currency1] += h1;
        }
    }

    function _pull(Currency currency, uint256 amount) private {
        if (currency.isNative()) {
            if (msg.value != amount) revert WrongValue(amount, msg.value);
            return;
        }
        if (msg.value != 0) revert WrongValue(0, msg.value);
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransferUnsupported(amount, received);
    }

    /// @dev Liquidity an out-of-range single-sided amount buys, rounded down (core rounds the amount it
    /// charges up, so the charge never exceeds `amount`).
    function _liquidityFor(int24 tickLower, int24 tickUpper, bool zeroForOne, uint256 amount)
        private
        pure
        returns (uint128)
    {
        uint160 sa = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sb = TickMath.getSqrtRatioAtTick(tickUpper);
        uint256 l;
        if (zeroForOne) {
            uint256 intermediate = FullMath.mulDiv(sa, sb, FixedPoint96.Q96);
            l = FullMath.mulDiv(amount, intermediate, sb - sa);
        } else {
            l = FullMath.mulDiv(amount, FixedPoint96.Q96, sb - sa);
        }
        if (l > type(uint128).max) return 0;
        return uint128(l);
    }
}
