/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";

import {IDeepCoreOracle} from "deepcore-hooks/src/oracle/IDeepCoreOracle.sol";

/// @title DeepCoreManagedVault - a managed concentrated-liquidity vault on one DeepCore CL pool
/// @notice Design of record: docs/products/managed-vaults.md. One EIP-1167 clone per vault, created and
/// initialized in one transaction by `DeepCoreVaultFactory`.
///
/// WHAT IT HOLDS. Two positions it owns itself in DeepCore's CL pool manager (salt 0 = base, salt 1 =
/// limit), idle balances of the pool's two currencies, and fee credits. Shares are ERC-20 and own both
/// positions and the idle balances PRO RATA. No price ever enters the share maths.
///
/// HOW IT IS RUN. Anyone may `rebalance` (re-centre the base around the oracle's TWAP and put the
/// remainder in a single-sided limit position; never a swap) when the cooldown has passed, the TWAP has
/// drifted past the frozen threshold and spot is within `maxDeviation` of the TWAP. Anyone may `harvest`
/// (collect fees, book the frozen performance fees, compound the rest when the same guard passes).
///
/// WITHDRAW ALWAYS WORKS. `withdraw` burns shares, removes the pro-rata liquidity and pays out. It reads
/// no oracle and no cooldown; there is no pause; keys whose hook can act on a removal are refused at
/// initialization; core lets removals through while a pool manager is paused; idle balances saturate.
///
/// ROLES. No owner, no pause, no upgrade, no `delegatecall`. Every strategy value and both fees are frozen
/// at initialization. The curator (the creator) receives the curator fee and can hand that role on, two
/// step; nothing else. Protocol fees go only to the frozen `protocolFeeRecipient` (the Safe).
contract DeepCoreManagedVault is ERC20, ReentrancyGuard, ILockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice A position's range. `lower == upper` means no position.
    struct Range {
        int24 lower;
        int24 upper;
    }

    /// @notice The strategy, frozen at creation. Widths and thresholds are in ticks.
    struct Config {
        int24 baseHalfWidth;
        int24 limitWidth;
        int24 maxDeviation;
        int24 rebalanceThreshold;
        uint32 twapWindow;
        uint32 cooldown;
        uint16 curatorFeeBps;
    }

    struct VaultParams {
        PoolKey key;
        /// The pool whose hook supplies the TWAP: the vault's own pool, or a sibling pool of the same pair.
        PoolKey oracleKey;
        Config config;
    }

    struct DepositData {
        address payer;
        uint256 shares;
        uint256 supply;
        uint256 max0;
        uint256 max1;
        uint256 idle0;
        uint256 idle1;
        uint256 value;
    }

    struct InitialData {
        address payer;
        uint128 liquidity;
        uint256 max0;
        uint256 max1;
        uint256 value;
    }

    struct WithdrawData {
        uint256 shares;
        uint256 supply;
        uint256 idle0;
        uint256 idle1;
    }

    struct RebalanceData {
        uint256 idle0;
        uint256 idle1;
        uint160 sqrtPriceX96;
        int24 spotTick;
        Range newBase;
    }

    struct HarvestData {
        uint256 idle0;
        uint256 idle1;
        bool compound;
        uint160 sqrtPriceX96;
    }

    /// @dev Running totals of one lock. `net` is the sum of every core delta (settled once at the end).
    struct Acc {
        int256 net0;
        int256 net1;
        uint256 principal0;
        uint256 principal1;
        uint256 fee0;
        uint256 fee1;
        uint256 hold0;
        uint256 hold1;
    }

    /*//////////////////////////////////////////////////////////////
                             EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event Initialized(
        PoolId indexed poolId, PoolId indexed oraclePoolId, address indexed curator, uint16 performanceFeeBps, Config config
    );
    event Deposit(address indexed sender, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Rebalanced(
        address indexed caller, int24 twapTick, int24 spotTick, int24 baseLower, int24 baseUpper, int24 limitLower, int24 limitUpper
    );
    event Harvested(uint256 fee0, uint256 fee1, uint256 protocol0, uint256 protocol1, uint256 curator0, uint256 curator1, bool compounded);
    event Snapshot(uint256 total0, uint256 total1, uint256 supply, uint160 sqrtPriceX96);
    event ProtocolFeesFlushed(address indexed to, uint256 amount0, uint256 amount1);
    event CuratorFeesClaimed(address indexed curator, address indexed to, uint256 amount0, uint256 amount1);
    event CuratorTransferStarted(address indexed previous, address indexed next);
    event CuratorTransferred(address indexed previous, address indexed next);
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error WrongPoolManager();
    error CurrencyMismatch();
    error HookCanTrapLiquidity(uint16 bitmap);
    error PoolNotInitialized();
    error OracleKindMismatch();
    error OracleUnreadable();
    error InvalidConfig(uint8 reason);
    error FeeAboveCap(uint16 bps);
    error Expired(uint256 deadline);
    error ZeroShares();
    error VaultEmpty();
    error VaultNotEmpty();
    error BelowMinimum(uint256 amount, uint256 minimum);
    error AboveMaximum(uint256 amount, uint256 maximum);
    error WrongValue(uint256 expected, uint256 sent);
    error FeeOnTransferUnsupported(uint256 expected, uint256 received);
    error DeviationTooHigh(int24 spotTick, int24 twapTick);
    error CooldownActive(uint256 readyAt);
    error NoDrift();
    error NothingToManage();
    error NothingToHarvest();
    error NothingToFlush();
    error NothingToClaim();
    error NothingToSweep();
    error NotCurator();
    error NotPendingCurator();
    error NotVault(address caller);
    error NotLocker(address locker);
    error NativeNotAccepted();
    error SharesToVault();
    error UnexpectedDelta();
    error ReadDuringExecution();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant BPS = 10_000;
    /// @notice The performance fee a vault can ever be born with (20% of harvested fees).
    uint16 public constant ABSOLUTE_MAX_PERFORMANCE_FEE_BPS = 2_000;
    /// @notice The curator fee a creator may choose (20% of harvested fees).
    uint16 public constant MAX_CURATOR_FEE_BPS = 2_000;
    /// @notice Shares minted to `DEAD` at the first deposit and never burned: the inflation defence.
    uint256 public constant DEAD_SHARES = 1_000;
    /// @notice The first deposit must mint at least this much liquidity (dead fraction <= 0.1%).
    uint256 public constant MIN_INITIAL_SHARES = 1_000_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant ORACLE_KIND = keccak256("deepcore.oracle.truncated-twap.v1");
    /// @notice Gas forwarded to the oracle; its answer must be exactly two words.
    uint256 public constant ORACLE_GAS = 300_000;

    int24 public constant MAX_WIDTH = 400_000;
    int24 public constant MAX_DEVIATION = 2_000;
    uint32 public constant MIN_TWAP_WINDOW = 600;
    uint32 public constant MAX_TWAP_WINDOW = 86_400;
    uint32 public constant MIN_COOLDOWN = 600;
    uint32 public constant MAX_COOLDOWN = 7 days;

    /// @dev Parameter bits a key may not set: before/after remove liquidity (4, 5), after-add and
    /// after-remove returns-delta (12, 13). A hook with any of them could block or tax a withdrawal.
    uint16 public constant FORBIDDEN_HOOK_BITS = (1 << 4) | (1 << 5) | (1 << 12) | (1 << 13);

    bytes32 internal constant BASE_SALT = bytes32(0);
    bytes32 internal constant LIMIT_SALT = bytes32(uint256(1));

    uint8 internal constant ACTION_DEPOSIT = 1;
    uint8 internal constant ACTION_INITIAL = 2;
    uint8 internal constant ACTION_WITHDRAW = 3;
    uint8 internal constant ACTION_REBALANCE = 4;
    uint8 internal constant ACTION_HARVEST = 5;
    uint8 internal constant ACTION_REDEEM = 6;

    /*//////////////////////////////////////////////////////////////
                         IMMUTABLES (shared by clones)
    //////////////////////////////////////////////////////////////*/

    /// @notice The only address that may initialize a clone.
    address public immutable FACTORY;
    IVault public immutable VAULT;
    ICLPoolManager public immutable CL_POOL_MANAGER;

    /*//////////////////////////////////////////////////////////////
                         PER-CLONE STATE (frozen)
    //////////////////////////////////////////////////////////////*/

    bool private _initialized;
    PoolKey internal _key;
    PoolKey internal _oracleKey;
    PoolId public poolId;
    PoolId public oraclePoolId;
    IDeepCoreOracle public oracle;
    Config internal _config;
    int24 public tickSpacing;
    uint16 public performanceFeeBps;
    address public protocolFeeRecipient;

    /*//////////////////////////////////////////////////////////////
                         PER-CLONE STATE (mutable)
    //////////////////////////////////////////////////////////////*/

    address public curator;
    address public pendingCurator;
    Range public base;
    Range public limit;
    uint64 public lastRebalanceAt;
    uint256 public protocolOwed0;
    uint256 public protocolOwed1;
    uint256 public curatorOwed0;
    uint256 public curatorOwed1;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param factory The factory that will create clones of this implementation (its address is known
    /// before it is deployed: CreateX).
    constructor(address factory, ICLPoolManager clPoolManager) ERC20("", "") {
        if (factory == address(0) || address(clPoolManager) == address(0)) revert ZeroAddress();
        FACTORY = factory;
        CL_POOL_MANAGER = clPoolManager;
        VAULT = clPoolManager.vault();
        _initialized = true; // the implementation itself can never be initialized
    }

    /// @notice Called once, by the factory, in the transaction that creates the clone. Validates every
    /// frozen value.
    function initialize(VaultParams calldata p, address curator_, address recipient_, uint16 performanceFeeBps_)
        external
    {
        if (msg.sender != FACTORY) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        if (curator_ == address(0) || recipient_ == address(0)) revert ZeroAddress();
        if (performanceFeeBps_ > ABSOLUTE_MAX_PERFORMANCE_FEE_BPS) revert FeeAboveCap(performanceFeeBps_);
        if (p.config.curatorFeeBps > MAX_CURATOR_FEE_BPS) revert FeeAboveCap(p.config.curatorFeeBps);

        PoolKey memory key = p.key;
        PoolKey memory okey = p.oracleKey;
        if (address(key.poolManager) != address(CL_POOL_MANAGER) || address(okey.poolManager) != address(CL_POOL_MANAGER))
        {
            revert WrongPoolManager();
        }
        if (Currency.unwrap(key.currency0) != Currency.unwrap(okey.currency0)
            || Currency.unwrap(key.currency1) != Currency.unwrap(okey.currency1))
        {
            revert CurrencyMismatch();
        }
        uint16 bitmap = uint16(uint256(key.parameters));
        if (bitmap & FORBIDDEN_HOOK_BITS != 0) revert HookCanTrapLiquidity(bitmap);
        PoolId id = key.toId();
        (uint160 sqrtP,,,) = CL_POOL_MANAGER.getSlot0(id);
        if (sqrtP == 0) revert PoolNotInitialized();

        address o = address(okey.hooks);
        (bool ok, bytes32 kindWord) = _staticWord(o, abi.encodeCall(IDeepCoreOracle.kind, ()));
        if (!ok || kindWord != ORACLE_KIND) revert OracleKindMismatch();
        (bool ok2, bytes32 minWord) = _staticWord(o, abi.encodeCall(IDeepCoreOracle.ORACLE_MIN_WINDOW_SECONDS, ()));
        if (!ok2 || uint256(minWord) > type(uint32).max) revert OracleUnreadable();

        int24 s = key.parameters.getTickSpacing();
        _validateConfig(p.config, s, uint32(uint256(minWord)));

        _key = key;
        _oracleKey = okey;
        poolId = id;
        oraclePoolId = okey.toId();
        oracle = IDeepCoreOracle(o);
        _config = p.config;
        tickSpacing = s;
        performanceFeeBps = performanceFeeBps_;
        protocolFeeRecipient = recipient_;
        curator = curator_;
        emit Initialized(id, oraclePoolId, curator_, performanceFeeBps_, p.config);
    }

    /// @notice Native arrives only from the core Vault, during this contract's own `take`.
    receive() external payable {
        if (msg.sender != address(VAULT)) revert NativeNotAccepted();
    }

    /*//////////////////////////////////////////////////////////////
                              ERC-20 SHARES
    //////////////////////////////////////////////////////////////*/

    function name() public pure override returns (string memory) {
        return "DeepCore Managed Vault Share";
    }

    function symbol() public pure override returns (string memory) {
        return "dcVAULT";
    }

    /// @dev Shares sent to the vault itself would own value no one can withdraw.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) revert SharesToVault();
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSITORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy `shares` pro rata: the matching fraction of both positions' liquidity and of the idle
    /// balances, every amount rounded UP, at most `max0` / `max1`. For a native currency0 send at least
    /// `max0`; the surplus is refunded.
    function deposit(uint256 shares, uint256 max0, uint256 max1, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _checkDeadline(deadline);
        if (to == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();
        _checkValue();
        uint256 supply = totalSupply();
        (uint256 idle0, uint256 idle1) = _idleExcludingValue();
        if (supply == 0 || _isEmpty(idle0, idle1)) revert VaultEmpty();

        bytes memory ret = VAULT.lock(
            abi.encode(
                ACTION_DEPOSIT,
                abi.encode(
                    DepositData({
                        payer: msg.sender,
                        shares: shares,
                        supply: supply,
                        max0: max0,
                        max1: max1,
                        idle0: idle0,
                        idle1: idle1,
                        value: msg.value
                    })
                )
            )
        );
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amount0, amount1);
        _refundValue(amount0);
        _snapshot();
    }

    /// @notice The first deposit (or the first into a vault that holds nothing): places the base range
    /// around the TWAP, fitting as much of `max0` / `max1` as the range takes at spot. Mints one share per
    /// unit of liquidity (and `DEAD_SHARES` of them to `DEAD` when the supply is zero).
    function depositInitial(uint256 max0, uint256 max1, uint256 minShares, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        _checkDeadline(deadline);
        if (to == address(0)) revert ZeroAddress();
        _checkValue();
        uint256 supply = totalSupply();
        (uint256 idle0, uint256 idle1) = _idleExcludingValue();
        if (supply != 0 && !_isEmpty(idle0, idle1)) revert VaultNotEmpty();

        (int24 twap, int24 spotTick, uint160 sqrtP) = _guardedPrices();
        Range memory nb = _baseRange(twap);
        uint256 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtRatioAtTick(nb.lower), TickMath.getSqrtRatioAtTick(nb.upper), _less1(max0), _less1(max1)
        );
        if (liq > uint256(uint128(type(int128).max))) liq = uint256(uint128(type(int128).max));
        uint256 floor = supply == 0 ? MIN_INITIAL_SHARES + DEAD_SHARES : MIN_INITIAL_SHARES;
        if (liq < floor) revert BelowMinimum(liq, floor);

        base = nb;
        limit = Range(0, 0);
        lastRebalanceAt = uint64(block.timestamp);
        bytes memory ret = VAULT.lock(
            abi.encode(
                ACTION_INITIAL,
                abi.encode(
                    InitialData({payer: msg.sender, liquidity: uint128(liq), max0: max0, max1: max1, value: msg.value})
                )
            )
        );
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));

        if (supply == 0) {
            _mint(DEAD, DEAD_SHARES);
            shares = liq - DEAD_SHARES;
        } else {
            // Shares that exist in an empty vault own nothing; they keep at most 0.1% of what comes in.
            shares = liq > supply * 999 ? liq : supply * 999;
        }
        if (shares < minShares) revert BelowMinimum(shares, minShares);
        _mint(to, shares);
        emit Rebalanced(msg.sender, twap, spotTick, nb.lower, nb.upper, 0, 0);
        emit Deposit(msg.sender, to, shares, amount0, amount1);
        _refundValue(amount0);
        _snapshot();
    }

    /// @notice Burn `shares` and receive the matching fraction of both positions and the idle balances,
    /// rounded DOWN, at least `min0` / `min1`. Reads no oracle and no cooldown; nothing can pause it.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _checkDeadline(deadline);
        if (to == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        (uint256 idle0, uint256 idle1) = _idle();
        _burn(msg.sender, shares);

        bytes memory ret = VAULT.lock(
            abi.encode(
                ACTION_WITHDRAW, abi.encode(WithdrawData({shares: shares, supply: supply, idle0: idle0, idle1: idle1}))
            )
        );
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
        if (amount0 < min0) revert BelowMinimum(amount0, min0);
        if (amount1 < min1) revert BelowMinimum(amount1, min1);
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
        if (amount0 != 0) _key.currency0.transfer(to, amount0);
        if (amount1 != 0) _key.currency1.transfer(to, amount1);
        _snapshot();
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONLESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone: re-centre the base around the TWAP and place the remainder as the limit position.
    /// Refused unless the cooldown has passed, spot is within `maxDeviation` of the TWAP, and the TWAP has
    /// drifted at least `rebalanceThreshold` from the base centre (or there is no base).
    function rebalance() external nonReentrant {
        if (totalSupply() == 0) revert NothingToManage();
        uint256 readyAt = uint256(lastRebalanceAt) + _config.cooldown;
        if (block.timestamp < readyAt) revert CooldownActive(readyAt);
        (int24 twap, int24 spotTick, uint160 sqrtP) = _guardedPrices();
        Range memory nb = _baseRange(twap);
        Range memory b = base;
        if (_liquidityOf(b, BASE_SALT) != 0) {
            if (nb.lower == b.lower && nb.upper == b.upper) revert NoDrift();
            if (_abs(int256(twap) - (int256(b.lower) + int256(b.upper)) / 2) < uint256(uint24(_config.rebalanceThreshold))) {
                revert NoDrift();
            }
        }
        (uint256 idle0, uint256 idle1) = _idle();
        bytes memory ret = VAULT.lock(
            abi.encode(
                ACTION_REBALANCE,
                abi.encode(RebalanceData({idle0: idle0, idle1: idle1, sqrtPriceX96: sqrtP, spotTick: spotTick, newBase: nb}))
            )
        );
        Range memory nl = abi.decode(ret, (Range));
        base = nb;
        limit = nl;
        lastRebalanceAt = uint64(block.timestamp);
        emit Rebalanced(msg.sender, twap, spotTick, nb.lower, nb.upper, nl.lower, nl.upper);
        _snapshot();
    }

    /// @notice Anyone: collect the positions' fees, book the frozen performance fees and keep the rest for
    /// holders. When the TWAP guard passes, the idle balances are also added to the current base range.
    /// Never reverts for an oracle reason.
    function harvest() external nonReentrant {
        if (_liquidityOf(base, BASE_SALT) == 0 && _liquidityOf(limit, LIMIT_SALT) == 0) revert NothingToHarvest();
        (bool ok,, uint160 sqrtP) = _tryGuardedPrices();
        (uint256 idle0, uint256 idle1) = _idle();
        uint256 p0 = protocolOwed0;
        uint256 p1 = protocolOwed1;
        uint256 c0 = curatorOwed0;
        uint256 c1 = curatorOwed1;
        bytes memory ret = VAULT.lock(
            abi.encode(
                ACTION_HARVEST, abi.encode(HarvestData({idle0: idle0, idle1: idle1, compound: ok, sqrtPriceX96: sqrtP}))
            )
        );
        (uint256 f0, uint256 f1) = abi.decode(ret, (uint256, uint256));
        emit Harvested(
            f0, f1, protocolOwed0 - p0, protocolOwed1 - p1, curatorOwed0 - c0, curatorOwed1 - c1, ok
        );
        _snapshot();
    }

    /// @notice Anyone: pay the protocol's credit to the frozen recipient (the Safe).
    function flushProtocolFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        amount0 = protocolOwed0;
        amount1 = protocolOwed1;
        if (amount0 == 0 && amount1 == 0) revert NothingToFlush();
        protocolOwed0 = 0;
        protocolOwed1 = 0;
        address to = protocolFeeRecipient;
        emit ProtocolFeesFlushed(to, amount0, amount1);
        if (amount0 != 0) _key.currency0.transfer(to, amount0);
        if (amount1 != 0) _key.currency1.transfer(to, amount1);
    }

    /// @notice Anyone: recover value sent here by mistake. ERC-6909 claims are redeemed through this
    /// vault's own lock first. In a pool currency the result is idle, i.e. the holders'; any other
    /// currency (native included, when the pool has none) goes whole to the frozen recipient.
    function sweep(Currency currency) external nonReentrant returns (uint256 amount) {
        uint256 claims = VAULT.balanceOf(address(this), currency);
        if (claims != 0) VAULT.lock(abi.encode(ACTION_REDEEM, abi.encode(currency, claims)));
        if (currency == _key.currency0 || currency == _key.currency1) {
            if (claims == 0) revert NothingToSweep();
            emit Swept(currency, address(this), claims);
            _snapshot();
            return claims;
        }
        amount = currency.balanceOfSelf();
        if (amount == 0) revert NothingToSweep();
        address to = protocolFeeRecipient;
        emit Swept(currency, to, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                CURATOR
    //////////////////////////////////////////////////////////////*/

    function claimCuratorFees(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (msg.sender != curator) revert NotCurator();
        if (to == address(0)) revert ZeroAddress();
        amount0 = curatorOwed0;
        amount1 = curatorOwed1;
        if (amount0 == 0 && amount1 == 0) revert NothingToClaim();
        curatorOwed0 = 0;
        curatorOwed1 = 0;
        emit CuratorFeesClaimed(msg.sender, to, amount0, amount1);
        if (amount0 != 0) _key.currency0.transfer(to, amount0);
        if (amount1 != 0) _key.currency1.transfer(to, amount1);
    }

    /// @notice Nominate a new curator (it must accept). `address(0)` withdraws a nomination.
    function transferCurator(address next) external {
        if (msg.sender != curator) revert NotCurator();
        pendingCurator = next;
        emit CuratorTransferStarted(msg.sender, next);
    }

    function acceptCurator() external {
        if (msg.sender != pendingCurator) revert NotPendingCurator();
        emit CuratorTransferred(curator, msg.sender);
        curator = msg.sender;
        pendingCurator = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function oraclePoolKey() external view returns (PoolKey memory) {
        return _oracleKey;
    }

    function config() external view returns (Config memory) {
        return _config;
    }

    /// @notice The live liquidity of both positions, read from core.
    function positionLiquidity() external view returns (uint128 baseLiquidity, uint128 limitLiquidity) {
        return (_liquidityOf(base, BASE_SALT), _liquidityOf(limit, LIMIT_SALT));
    }

    /// @notice What the vault holds for its shareholders, at spot: both positions' principal plus idle.
    /// Excludes fees not yet collected (a `harvest` books them).
    /// Reverts while any vault function is executing (read-only reentrancy: mid-withdraw the balance has
    /// not left yet while the shares are already burned).
    function totalAmounts() public view returns (uint256 total0, uint256 total1) {
        if (_reentrancyGuardEntered()) revert ReadDuringExecution();
        return _totalAmounts();
    }

    function _totalAmounts() internal view returns (uint256 total0, uint256 total1) {
        (uint160 sqrtP,,,) = CL_POOL_MANAGER.getSlot0(poolId);
        (total0, total1) = _idle();
        (uint256 a0, uint256 a1) = _amountsOf(base, BASE_SALT, sqrtP);
        (uint256 b0, uint256 b1) = _amountsOf(limit, LIMIT_SALT, sqrtP);
        total0 += a0 + b0;
        total1 += a1 + b1;
    }

    /*//////////////////////////////////////////////////////////////
                               VAULT LOCK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILockCallback
    /// @dev Only the core Vault, and only inside a lock THIS contract opened (`getLocker`). Every opener is
    /// `nonReentrant`.
    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(VAULT)) revert NotVault(msg.sender);
        address locker = VAULT.getLocker();
        if (locker != address(this)) revert NotLocker(locker);
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_DEPOSIT) return _lockDeposit(abi.decode(payload, (DepositData)));
        if (action == ACTION_INITIAL) return _lockInitial(abi.decode(payload, (InitialData)));
        if (action == ACTION_WITHDRAW) return _lockWithdraw(abi.decode(payload, (WithdrawData)));
        if (action == ACTION_REBALANCE) return _lockRebalance(abi.decode(payload, (RebalanceData)));
        if (action == ACTION_HARVEST) return _lockHarvest(abi.decode(payload, (HarvestData)));
        (Currency currency, uint256 amount) = abi.decode(payload, (Currency, uint256));
        VAULT.burn(address(this), currency, amount);
        VAULT.take(currency, address(this), amount);
        return "";
    }

    function _lockDeposit(DepositData memory d) private returns (bytes memory) {
        Acc memory acc;
        _addShare(acc, base, BASE_SALT, d.shares, d.supply);
        _addShare(acc, limit, LIMIT_SALT, d.shares, d.supply);
        uint256 pay0 = acc.principal0 + FullMath.mulDivRoundingUp(d.idle0 + acc.hold0, d.shares, d.supply);
        uint256 pay1 = acc.principal1 + FullMath.mulDivRoundingUp(d.idle1 + acc.hold1, d.shares, d.supply);
        if (pay0 > d.max0) revert AboveMaximum(pay0, d.max0);
        if (pay1 > d.max1) revert AboveMaximum(pay1, d.max1);
        if (pay0 == 0 && pay1 == 0) revert ZeroShares();
        _pull(_key.currency0, d.payer, pay0, d.value);
        _pull(_key.currency1, d.payer, pay1, 0);
        _settleAll(acc);
        return abi.encode(pay0, pay1);
    }

    function _lockInitial(InitialData memory d) private returns (bytes memory) {
        Acc memory acc;
        _modifyInto(acc, base, BASE_SALT, int256(uint256(d.liquidity)));
        uint256 pay0 = acc.principal0;
        uint256 pay1 = acc.principal1;
        if (pay0 > d.max0) revert AboveMaximum(pay0, d.max0);
        if (pay1 > d.max1) revert AboveMaximum(pay1, d.max1);
        _pull(_key.currency0, d.payer, pay0, d.value);
        _pull(_key.currency1, d.payer, pay1, 0);
        _settleAll(acc);
        return abi.encode(pay0, pay1);
    }

    function _lockWithdraw(WithdrawData memory d) private returns (bytes memory) {
        Acc memory acc;
        _removeShare(acc, base, BASE_SALT, d.shares, d.supply);
        _removeShare(acc, limit, LIMIT_SALT, d.shares, d.supply);
        uint256 out0 = acc.principal0 + FullMath.mulDiv(d.idle0 + acc.hold0, d.shares, d.supply);
        uint256 out1 = acc.principal1 + FullMath.mulDiv(d.idle1 + acc.hold1, d.shares, d.supply);
        _settleAll(acc);
        return abi.encode(out0, out1);
    }

    function _lockRebalance(RebalanceData memory d) private returns (bytes memory) {
        Acc memory acc;
        Range memory b = base;
        Range memory l = limit;
        uint128 lb = _liquidityOf(b, BASE_SALT);
        uint128 ll = _liquidityOf(l, LIMIT_SALT);
        if (lb != 0) _modifyInto(acc, b, BASE_SALT, -int256(uint256(lb)));
        if (ll != 0) _modifyInto(acc, l, LIMIT_SALT, -int256(uint256(ll)));
        uint256 avail0 = d.idle0 + acc.principal0 + acc.hold0;
        uint256 avail1 = d.idle1 + acc.principal1 + acc.hold1;

        // Base: as much as fits the new range at spot.
        acc.principal0 = 0;
        acc.principal1 = 0;
        uint256 liq = LiquidityAmounts.getLiquidityForAmounts(
            d.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(d.newBase.lower),
            TickMath.getSqrtRatioAtTick(d.newBase.upper),
            _less1(avail0),
            _less1(avail1)
        );
        liq = _capLiquidity(liq);
        if (liq != 0) _modifyInto(acc, d.newBase, BASE_SALT, int256(liq));
        avail0 -= acc.principal0;
        avail1 -= acc.principal1;

        // Limit: the remainder, single-sided next to spot.
        Range memory nl;
        bool sellZero = FullMath.mulDiv(FullMath.mulDiv(avail0, d.sqrtPriceX96, FixedPoint96.Q96), d.sqrtPriceX96, FixedPoint96.Q96)
            >= avail1;
        nl = _limitRange(d.spotTick, sellZero);
        if (nl.lower < nl.upper) {
            uint160 sa = TickMath.getSqrtRatioAtTick(nl.lower);
            uint160 sb = TickMath.getSqrtRatioAtTick(nl.upper);
            uint256 lq = sellZero
                ? LiquidityAmounts.getLiquidityForAmount0(sa, sb, _less1(avail0))
                : LiquidityAmounts.getLiquidityForAmount1(sa, sb, _less1(avail1));
            lq = _capLiquidity(lq);
            if (lq != 0) _modifyInto(acc, nl, LIMIT_SALT, int256(lq));
            else nl = Range(0, 0);
        } else {
            nl = Range(0, 0);
        }
        _settleAll(acc);
        return abi.encode(nl);
    }

    function _lockHarvest(HarvestData memory d) private returns (bytes memory) {
        Acc memory acc;
        Range memory b = base;
        if (_liquidityOf(b, BASE_SALT) != 0) _modifyInto(acc, b, BASE_SALT, 0);
        Range memory l = limit;
        if (_liquidityOf(l, LIMIT_SALT) != 0) _modifyInto(acc, l, LIMIT_SALT, 0);
        uint256 fee0 = acc.fee0;
        uint256 fee1 = acc.fee1;
        uint256 hold0 = acc.hold0;
        uint256 hold1 = acc.hold1;
        if (d.compound && b.lower < b.upper) {
            uint256 liq = LiquidityAmounts.getLiquidityForAmounts(
                d.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(b.lower),
                TickMath.getSqrtRatioAtTick(b.upper),
                _less1(d.idle0 + hold0),
                _less1(d.idle1 + hold1)
            );
            liq = _capLiquidity(liq);
            if (liq != 0) _modifyInto(acc, b, BASE_SALT, int256(liq));
        }
        _settleAll(acc);
        return abi.encode(fee0, fee1);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Adds `ceil(L * shares / supply)` to a live position (rounded against the depositor).
    function _addShare(Acc memory acc, Range memory r, bytes32 salt, uint256 shares, uint256 supply) private {
        uint128 l = _liquidityOf(r, salt);
        if (l == 0) return;
        uint256 dl = FullMath.mulDivRoundingUp(l, shares, supply);
        _modifyInto(acc, r, salt, int256(_capLiquidity(dl)));
    }

    /// @dev Removes `floor(L * shares / supply)` from a live position (rounded against the withdrawer).
    function _removeShare(Acc memory acc, Range memory r, bytes32 salt, uint256 shares, uint256 supply) private {
        uint128 l = _liquidityOf(r, salt);
        if (l == 0) return;
        uint256 dl = FullMath.mulDiv(l, shares, supply);
        if (dl == 0) return;
        _modifyInto(acc, r, salt, -int256(dl));
    }

    /// @dev One `modifyLiquidity`; accumulates the net delta, the principal moved (paid in for an add,
    /// taken out for a removal) and the fees collected, which are booked at once.
    function _modifyInto(Acc memory acc, Range memory r, bytes32 salt, int256 liquidityDelta) private {
        (BalanceDelta delta, BalanceDelta feeDelta) = CL_POOL_MANAGER.modifyLiquidity(
            _key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: r.lower, tickUpper: r.upper, liquidityDelta: liquidityDelta, salt: salt
            }),
            ""
        );
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        int128 f0 = feeDelta.amount0();
        int128 f1 = feeDelta.amount1();
        if (f0 < 0 || f1 < 0) revert UnexpectedDelta();
        acc.net0 += d0;
        acc.net1 += d1;
        if (liquidityDelta > 0) {
            // principal paid = fee - delta, never negative for an add
            if (d0 > f0 || d1 > f1) revert UnexpectedDelta();
            acc.principal0 += uint256(int256(f0) - int256(d0));
            acc.principal1 += uint256(int256(f1) - int256(d1));
        } else {
            if (d0 < f0 || d1 < f1) revert UnexpectedDelta();
            acc.principal0 += uint256(int256(d0) - int256(f0));
            acc.principal1 += uint256(int256(d1) - int256(f1));
        }
        _book(acc, uint256(uint128(f0)), uint256(uint128(f1)));
    }

    /// @dev Credits the frozen performance and curator fees out of collected LP fees; the rest is the
    /// holders' (it becomes idle when the lock settles).
    function _book(Acc memory acc, uint256 f0, uint256 f1) private {
        if (f0 == 0 && f1 == 0) return;
        uint256 p0 = f0 * performanceFeeBps / BPS;
        uint256 p1 = f1 * performanceFeeBps / BPS;
        uint16 cb = _config.curatorFeeBps;
        uint256 c0 = f0 * cb / BPS;
        uint256 c1 = f1 * cb / BPS;
        protocolOwed0 += p0;
        protocolOwed1 += p1;
        curatorOwed0 += c0;
        curatorOwed1 += c1;
        acc.fee0 += f0;
        acc.fee1 += f1;
        acc.hold0 += f0 - p0 - c0;
        acc.hold1 += f1 - p1 - c1;
    }

    function _settleAll(Acc memory acc) private {
        _settle(_key.currency0, acc.net0);
        _settle(_key.currency1, acc.net1);
    }

    /// @dev Pays what this contract owes the core Vault for one currency, or takes what it is owed.
    function _settle(Currency currency, int256 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(-amount);
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
            VAULT.take(currency, address(this), uint256(amount));
        }
    }

    /// @dev Pulls `amount` from `payer` (measured: fee-on-transfer refused). Native was sent with the call.
    function _pull(Currency currency, address payer, uint256 amount, uint256 value) private {
        if (currency.isNative()) {
            if (value < amount) revert WrongValue(amount, value);
            return;
        }
        if (amount == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(payer, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransferUnsupported(amount, received);
    }

    function _checkValue() private view {
        if (msg.value != 0 && !_key.currency0.isNative()) revert WrongValue(0, msg.value);
    }

    function _refundValue(uint256 used0) private {
        if (msg.value > used0) _key.currency0.transfer(msg.sender, msg.value - used0);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired(deadline);
    }

    /// @dev Balances held for shareholders: everything above the fee credits, saturating at zero (so a
    /// negative rebase can never make a withdrawal revert).
    function _idle() internal view returns (uint256 idle0, uint256 idle1) {
        idle0 = _sat(_key.currency0.balanceOfSelf(), protocolOwed0 + curatorOwed0);
        idle1 = _sat(_key.currency1.balanceOfSelf(), protocolOwed1 + curatorOwed1);
    }

    /// @dev `_idle` without the native just sent with this call (it is not the vault's yet).
    function _idleExcludingValue() private view returns (uint256 idle0, uint256 idle1) {
        (idle0, idle1) = _idle();
        if (msg.value != 0) idle0 = _sat(idle0, msg.value);
    }

    function _isEmpty(uint256 idle0, uint256 idle1) private view returns (bool) {
        return idle0 == 0 && idle1 == 0 && _liquidityOf(base, BASE_SALT) == 0 && _liquidityOf(limit, LIMIT_SALT) == 0;
    }

    function _liquidityOf(Range memory r, bytes32 salt) internal view returns (uint128) {
        if (r.lower >= r.upper) return 0;
        return CL_POOL_MANAGER.getLiquidity(poolId, address(this), r.lower, r.upper, salt);
    }

    function _amountsOf(Range memory r, bytes32 salt, uint160 sqrtP) private view returns (uint256, uint256) {
        uint128 l = _liquidityOf(r, salt);
        if (l == 0) return (0, 0);
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(r.lower), TickMath.getSqrtRatioAtTick(r.upper), l
        );
    }

    /// @dev The TWAP and spot, refused unless the oracle answers and spot is within `maxDeviation`.
    function _guardedPrices() private view returns (int24 twap, int24 spotTick, uint160 sqrtP) {
        bool ok;
        (ok, twap) = _readOracle();
        if (!ok) revert OracleUnreadable();
        (sqrtP, spotTick,,) = CL_POOL_MANAGER.getSlot0(poolId);
        if (_abs(int256(spotTick) - int256(twap)) > uint256(uint24(_config.maxDeviation))) {
            revert DeviationTooHigh(spotTick, twap);
        }
    }

    function _tryGuardedPrices() private view returns (bool ok, int24 twap, uint160 sqrtP) {
        (ok, twap) = _readOracle();
        int24 spotTick;
        (sqrtP, spotTick,,) = CL_POOL_MANAGER.getSlot0(poolId);
        if (ok && _abs(int256(spotTick) - int256(twap)) > uint256(uint24(_config.maxDeviation))) ok = false;
    }

    /// @dev `consult(oraclePoolId, twapWindow)` by staticcall: capped gas, exactly 64 bytes, a valid tick.
    /// Copies at most 64 bytes of return data, so an oracle cannot grief with a large answer.
    function _readOracle() private view returns (bool ok, int24 twap) {
        bytes memory cd = abi.encodeCall(IDeepCoreOracle.consult, (oraclePoolId, _config.twapWindow));
        address o = address(oracle);
        bool success;
        uint256 size;
        int256 word0;
        uint256 gasCap = ORACLE_GAS;
        assembly ("memory-safe") {
            let out := mload(0x40)
            success := staticcall(gasCap, o, add(cd, 0x20), mload(cd), out, 0x40)
            size := returndatasize()
            word0 := mload(out)
        }
        if (!success || size != 64) return (false, 0);
        if (word0 < TickMath.MIN_TICK || word0 > TickMath.MAX_TICK) return (false, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, int24(word0));
    }

    /// @dev A single-word static read (`kind`, `ORACLE_MIN_WINDOW_SECONDS`), capped like `consult`.
    function _staticWord(address target, bytes memory cd) private view returns (bool ok, bytes32 word) {
        if (target.code.length == 0) return (false, bytes32(0));
        uint256 size;
        uint256 gasCap = ORACLE_GAS;
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(gasCap, target, add(cd, 0x20), mload(cd), out, 0x20)
            size := returndatasize()
            word := mload(out)
        }
        if (size != 32) ok = false;
    }

    /// @dev `[c - W, c + W]` with `c` the TWAP aligned down to the spacing, clamped to the usable ticks.
    function _baseRange(int24 twap) internal view returns (Range memory r) {
        int24 s = tickSpacing;
        int24 c = _floorTick(twap, s);
        int24 w = _config.baseHalfWidth;
        int24 minU = (TickMath.MIN_TICK / s) * s;
        int24 maxU = (TickMath.MAX_TICK / s) * s;
        r.lower = c - w < minU ? minU : c - w;
        r.upper = c + w > maxU ? maxU : c + w;
    }

    /// @dev Single-sided range next to spot: above it to sell currency0, below it to sell currency1.
    function _limitRange(int24 spotTick, bool sellZero) private view returns (Range memory r) {
        int24 s = tickSpacing;
        int24 f = _floorTick(spotTick, s);
        int24 w = _config.limitWidth;
        int24 minU = (TickMath.MIN_TICK / s) * s;
        int24 maxU = (TickMath.MAX_TICK / s) * s;
        if (sellZero) {
            r.lower = f + s;
            r.upper = r.lower + w > maxU ? maxU : r.lower + w;
        } else {
            r.upper = f;
            r.lower = f - w < minU ? minU : f - w;
        }
        if (r.lower >= r.upper) r = Range(0, 0);
    }

    function _validateConfig(Config calldata c, int24 s, uint32 oracleMinWindow) private pure {
        if (c.baseHalfWidth < s || c.baseHalfWidth > MAX_WIDTH || c.baseHalfWidth % s != 0) revert InvalidConfig(1);
        if (c.limitWidth < s || c.limitWidth > MAX_WIDTH || c.limitWidth % s != 0) revert InvalidConfig(2);
        int24 maxDev = c.baseHalfWidth / 2 < MAX_DEVIATION ? c.baseHalfWidth / 2 : MAX_DEVIATION;
        if (c.maxDeviation < 1 || c.maxDeviation > maxDev) revert InvalidConfig(3);
        if (c.rebalanceThreshold < 0 || c.rebalanceThreshold > c.baseHalfWidth) revert InvalidConfig(4);
        uint32 minWindow = oracleMinWindow > MIN_TWAP_WINDOW ? oracleMinWindow : MIN_TWAP_WINDOW;
        if (c.twapWindow < minWindow || c.twapWindow > MAX_TWAP_WINDOW) revert InvalidConfig(5);
        if (c.cooldown < MIN_COOLDOWN || c.cooldown > MAX_COOLDOWN) revert InvalidConfig(6);
    }

    function _snapshot() private {
        (uint160 sqrtP,,,) = CL_POOL_MANAGER.getSlot0(poolId);
        (uint256 t0, uint256 t1) = _totalAmounts();
        emit Snapshot(t0, t1, totalSupply(), sqrtP);
    }

    function _floorTick(int24 t, int24 s) private pure returns (int24) {
        int24 c = t / s;
        if (t < 0 && t % s != 0) c--;
        return c * s;
    }

    function _capLiquidity(uint256 l) private pure returns (uint256) {
        uint256 cap = uint256(uint128(type(int128).max));
        return l > cap ? cap : l;
    }

    function _less1(uint256 x) private pure returns (uint256) {
        return x == 0 ? 0 : x - 1;
    }

    function _sat(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }
}
