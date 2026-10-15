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
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";

import {OrdersFeeBase} from "./base/OrdersFeeBase.sol";

/// @title DeepCoreDCA - scheduled swaps (dollar-cost averaging) through ONE DeepCore pool the user names
/// @notice Design of record: docs/products/dca.md.
///
/// A user escrows `slices x (amountPerSlice + tipPerSlice)` of the input currency and a schedule. Any address
/// may execute a due slice: this contract swaps exactly `amountPerSlice` exact-input through the plan's own
/// pool (CL or Bin, the key fixed at creation - an executor chooses nothing), checks the output against the
/// user's price bound ON CHAIN, pays the user (the recipient) straight from the Vault, and pays the executor
/// the slice's tip in the input currency.
///
/// THE PRICE BOUND. `minPriceX96` is the least output per unit of input the user accepts, Q96, net of the
/// protocol and integrator fees: a slice whose net output is below `amountPerSlice x minPriceX96 / 2^96`
/// reverts and simply waits. It is the whole of the slice's sandwich protection; a slice runs at a
/// predictable time, so an executor or a searcher can move price to the bound first. The bound is the user's
/// to set; the SDK proposes one from spot.
///
/// FEES (owner decision of record, 2026-10-12, CONFIRM): protocol bps (default 10, immutable cap 50) and the
/// plan's integrator bps (at most 10) on each slice's gross output, frozen at creation; the tip is the user's.
///
/// No admin path reaches a plan's escrow: only the plan's owner can cancel, any time, and every unit of
/// remaining escrow goes back. Fee-on-transfer input is refused (measured). A full fill is required: a slice
/// the pool cannot fill whole reverts.
contract DeepCoreDCA is OrdersFeeBase, ILockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    struct Plan {
        address owner;
        address recipient;
        bool zeroForOne;
        uint16 feeBps;
        uint16 integratorBps;
        address integrator;
        uint32 interval;
        uint32 slicesLeft;
        uint64 nextAt;
        uint64 deadline;
        uint128 amountPerSlice;
        uint128 tipPerSlice;
        uint256 minPriceX96;
        PoolKey key;
    }

    struct CreateParams {
        PoolKey key;
        bool zeroForOne;
        uint128 amountPerSlice;
        uint128 tipPerSlice;
        uint32 slices;
        uint32 interval;
        uint64 startAt; // 0 = now
        uint64 deadline;
        uint256 minPriceX96;
        address recipient;
        address integrator;
        uint16 integratorBps;
    }

    event PlanCreated(
        uint256 indexed planId,
        address indexed owner,
        bytes32 indexed poolId,
        bool zeroForOne,
        uint128 amountPerSlice,
        uint128 tipPerSlice,
        uint32 slices,
        uint32 interval,
        uint64 startAt,
        uint64 deadline,
        uint256 minPriceX96,
        address recipient,
        uint16 feeBps,
        address integrator,
        uint16 integratorBps
    );
    event SliceExecuted(
        uint256 indexed planId, address indexed executor, uint256 amountIn, uint256 grossOut, uint256 netOut, uint256 tip, uint32 slicesLeft
    );
    event PlanCancelled(uint256 indexed planId, address indexed owner, address to, uint256 refund);

    error WrongPoolManager();
    error ZeroAmount();
    error BadSchedule();
    error WrongValue(uint256 expected, uint256 sent);
    error FeeOnTransferUnsupported(uint256 expected, uint256 received);
    error UnknownPlan();
    error NotOwner();
    error NotDue(uint64 nextAt);
    error Expired(uint64 deadline);
    error BelowMinOut(uint256 netOut, uint256 minOut);
    error PartialFill(uint256 spent, uint256 amountIn);
    error UnexpectedDelta();
    error NotVault(address caller);
    error NotLocker(address locker);
    error NativeNotAccepted();

    uint32 public constant MIN_INTERVAL = 60;
    uint32 public constant MAX_SLICES = 10_000;

    IVault public immutable VAULT;
    ICLPoolManager public immutable CL_POOL_MANAGER;
    IBinPoolManager public immutable BIN_POOL_MANAGER;

    uint256 public nextPlanId = 1;
    mapping(uint256 => Plan) internal _plans;

    constructor(
        ICLPoolManager clPoolManager,
        IBinPoolManager binPoolManager,
        address owner_,
        address protocolFeeRecipient_,
        uint16 initialFeeBps,
        uint16 maxFeeBps_,
        uint32 noticeSeconds_
    ) OrdersFeeBase(owner_, protocolFeeRecipient_, initialFeeBps, maxFeeBps_, noticeSeconds_) {
        if (address(clPoolManager) == address(0) || address(binPoolManager) == address(0)) revert ZeroAddress();
        IVault v = clPoolManager.vault();
        if (address(binPoolManager.vault()) != address(v)) revert WrongPoolManager();
        VAULT = v;
        CL_POOL_MANAGER = clPoolManager;
        BIN_POOL_MANAGER = binPoolManager;
    }

    /// @notice Native arrives only from the Vault (it never does: outputs go straight to recipients).
    receive() external payable {
        if (msg.sender != address(VAULT)) revert NativeNotAccepted();
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER OF A PLAN
    //////////////////////////////////////////////////////////////*/

    function create(CreateParams calldata p) external payable nonReentrant returns (uint256 planId) {
        address manager = address(p.key.poolManager);
        if (manager != address(CL_POOL_MANAGER) && manager != address(BIN_POOL_MANAGER)) revert WrongPoolManager();
        if (p.amountPerSlice == 0 || p.minPriceX96 == 0) revert ZeroAmount();
        if (p.amountPerSlice > uint128(type(int128).max)) revert ZeroAmount();
        if (p.recipient == address(0)) revert ZeroAddress();
        uint64 startAt = p.startAt == 0 ? uint64(block.timestamp) : p.startAt;
        if (
            p.slices == 0 || p.slices > MAX_SLICES || p.interval < MIN_INTERVAL || startAt < block.timestamp
                || p.deadline <= startAt
        ) revert BadSchedule();
        _checkIntegrator(p.integrator, p.integratorBps);

        Currency inCurrency = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        uint256 escrow = uint256(p.slices) * (uint256(p.amountPerSlice) + p.tipPerSlice);
        _pull(inCurrency, escrow);
        totalOwed[inCurrency] += escrow;

        planId = nextPlanId++;
        uint16 feeBps = protocolFeeBps();
        Plan storage s = _plans[planId];
        s.owner = msg.sender;
        s.recipient = p.recipient;
        s.zeroForOne = p.zeroForOne;
        s.feeBps = feeBps;
        s.integratorBps = p.integratorBps;
        s.integrator = p.integrator;
        s.interval = p.interval;
        s.slicesLeft = p.slices;
        s.nextAt = startAt;
        s.deadline = p.deadline;
        s.amountPerSlice = p.amountPerSlice;
        s.tipPerSlice = p.tipPerSlice;
        s.minPriceX96 = p.minPriceX96;
        s.key = p.key;
        emit PlanCreated(
            planId,
            msg.sender,
            keccak256(abi.encode(p.key)),
            p.zeroForOne,
            p.amountPerSlice,
            p.tipPerSlice,
            p.slices,
            p.interval,
            startAt,
            p.deadline,
            p.minPriceX96,
            p.recipient,
            feeBps,
            p.integrator,
            p.integratorBps
        );
    }

    /// @notice The plan's owner, any time: every unit of remaining escrow (slices and tips) to `to`.
    function cancel(uint256 planId, address to) external nonReentrant returns (uint256 refund) {
        if (to == address(0)) revert ZeroAddress();
        Plan storage s = _plans[planId];
        if (s.owner == address(0)) revert UnknownPlan();
        if (s.owner != msg.sender) revert NotOwner();
        Currency inCurrency = s.zeroForOne ? s.key.currency0 : s.key.currency1;
        refund = uint256(s.slicesLeft) * (uint256(s.amountPerSlice) + s.tipPerSlice);
        delete _plans[planId];
        totalOwed[inCurrency] -= refund;
        emit PlanCancelled(planId, msg.sender, to, refund);
        if (refund != 0) inCurrency.transfer(to, refund);
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone: run the plan's next slice if it is due. Pays the caller the slice's tip.
    function execute(uint256 planId) external nonReentrant returns (uint256 netOut) {
        (SwapPlan memory sp, uint256 tip, uint32 left) = _consumeSlice(planId);
        (uint256 grossOut, uint256 fees) = abi.decode(VAULT.lock(abi.encode(sp)), (uint256, uint256));
        // The fee units were taken to this contract inside the lock; credit them.
        Currency outCurrency = sp.zeroForOne ? sp.key.currency1 : sp.key.currency0;
        (uint256 protocolFee, uint256 integratorFee, uint256 net) =
            _chargeFees(outCurrency, grossOut, sp.feeBps, sp.integrator, sp.integratorBps);
        if (protocolFee + integratorFee != fees) revert UnexpectedDelta();
        netOut = net;

        emit SliceExecuted(planId, msg.sender, sp.amountIn, grossOut, net, tip, left);
        if (tip != 0) (sp.zeroForOne ? sp.key.currency0 : sp.key.currency1).transfer(msg.sender, tip);
    }

    /// @dev Schedule checks, then effects: the slice is consumed before any external call.
    function _consumeSlice(uint256 planId) private returns (SwapPlan memory sp, uint256 tip, uint32 left) {
        Plan storage s = _plans[planId];
        if (s.owner == address(0)) revert UnknownPlan();
        if (block.timestamp < s.nextAt) revert NotDue(s.nextAt);
        if (block.timestamp > s.deadline) revert Expired(s.deadline);

        sp.key = s.key;
        sp.zeroForOne = s.zeroForOne;
        sp.amountIn = s.amountPerSlice;
        sp.minOut = FullMath.mulDiv(s.amountPerSlice, s.minPriceX96, 1 << 96);
        sp.recipient = s.recipient;
        sp.feeBps = s.feeBps;
        sp.integratorBps = s.integratorBps;
        sp.integrator = s.integrator;
        tip = s.tipPerSlice;

        left = s.slicesLeft - 1;
        Currency inCurrency = sp.zeroForOne ? sp.key.currency0 : sp.key.currency1;
        totalOwed[inCurrency] -= uint256(sp.amountIn) + tip;
        if (left == 0) {
            delete _plans[planId];
        } else {
            s.slicesLeft = left;
            s.nextAt = uint64(block.timestamp) + s.interval;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return _plans[planId];
    }

    /// @notice Whether `execute(planId)` would pass its schedule checks now (it can still fail its price bound).
    function isDue(uint256 planId) external view returns (bool) {
        Plan storage s = _plans[planId];
        return s.owner != address(0) && block.timestamp >= s.nextAt && block.timestamp <= s.deadline;
    }

    /// @notice The least net output the next slice accepts.
    function minOutPerSlice(uint256 planId) external view returns (uint256) {
        Plan storage s = _plans[planId];
        return FullMath.mulDiv(s.amountPerSlice, s.minPriceX96, 1 << 96);
    }

    /*//////////////////////////////////////////////////////////////
                               VAULT LOCK
    //////////////////////////////////////////////////////////////*/

    struct SwapPlan {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint256 minOut;
        address recipient;
        uint16 feeBps;
        uint16 integratorBps;
        address integrator;
    }

    /// @inheritdoc ILockCallback
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault(msg.sender);
        address locker = VAULT.getLocker();
        if (locker != address(this)) revert NotLocker(locker);
        SwapPlan memory s = abi.decode(data, (SwapPlan));

        BalanceDelta delta;
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 specified = -int128(s.amountIn);
        if (address(s.key.poolManager) == address(BIN_POOL_MANAGER)) {
            delta = BIN_POOL_MANAGER.swap(s.key, s.zeroForOne, specified, "");
        } else {
            delta = CL_POOL_MANAGER.swap(
                s.key,
                ICLPoolManager.SwapParams({
                    zeroForOne: s.zeroForOne,
                    amountSpecified: specified,
                    sqrtPriceLimitX96: s.zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                }),
                ""
            );
        }
        (Currency inCurrency, Currency outCurrency) =
            s.zeroForOne ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
        int128 inDelta = s.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = s.zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta > 0 || outDelta < 0) revert UnexpectedDelta();
        uint256 spent = uint256(uint128(-inDelta));
        if (spent != s.amountIn) revert PartialFill(spent, s.amountIn);
        uint256 grossOut = uint256(uint128(outDelta));

        uint256 fees = grossOut * s.feeBps / BPS + grossOut * s.integratorBps / BPS;
        uint256 net = grossOut - fees;
        if (net < s.minOut) revert BelowMinOut(net, s.minOut);

        if (inCurrency.isNative()) {
            // forge-lint: disable-next-line(unused-return)
            VAULT.settle{value: spent}();
        } else {
            VAULT.sync(inCurrency);
            IERC20(Currency.unwrap(inCurrency)).safeTransfer(address(VAULT), spent);
            // forge-lint: disable-next-line(unused-return)
            VAULT.settle();
        }
        if (fees != 0) VAULT.take(outCurrency, address(this), fees);
        if (net != 0) VAULT.take(outCurrency, s.recipient, net);
        return abi.encode(grossOut, fees);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

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
}
