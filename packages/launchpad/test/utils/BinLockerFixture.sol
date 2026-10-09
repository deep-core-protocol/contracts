// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";

import {BinPositionManager} from "infinity-periphery/src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {DeepCoreBinLPLocker} from "../../src/DeepCoreBinLPLocker.sol";
import {LockParams} from "../../src/interfaces/IDeepCoreLPLocker.sol";

/// @dev Taxes 1% of every `transfer` except into the Vault, so it can be swapped but delivers less than
/// the Vault sends on the way out - including the harvest into the locker.
contract BinTaxToken is MockERC20 {
    address public immutable vault;

    constructor(address vault_) MockERC20("Taxed", "TAX", 18) {
        vault = vault_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == vault) return super.transfer(to, amount);
        uint256 fee = amount / 100;
        super.transfer(address(0xdead), fee);
        return super.transfer(to, amount - fee);
    }
}

/// @dev Robinhood-stock-like issuer powers: global pause, per-address block, `adminBurn`.
contract BinPausableToken is MockERC20 {
    bool public tokenPaused;
    mapping(address => bool) public blocked;

    error TokenPaused();
    error Blocked(address account);

    constructor() MockERC20("Stock", "STK", 18) {}

    function pause(bool value) external {
        tokenPaused = value;
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _check(address from, address to) internal view {
        if (tokenPaused) revert TokenPaused();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(from, to);
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Real core + periphery, no mocks: `Vault`, `BinPoolManager`, `BinPositionManager`, Permit2.
abstract contract BinLockerFixture is Test, DeployPermit2 {
    using BinPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    Vault internal vault;
    BinPoolManager internal binPoolManager;
    BinPositionManager internal binPm;
    IAllowanceTransfer internal permit2;
    BinSwapHelper internal swapper;
    WETH internal weth;
    DeepCoreBinLPLocker internal locker;

    address internal constant PROTOCOL = address(0x9807);
    address internal constant CREATOR = address(0xC4EA);
    address internal constant INTEGRATOR = address(0x1478);
    address internal constant ATTACKER = address(0xBAD);

    /// @dev The owner's numbers, CLAUDE.md "Kit fees: decided by the owner, 2026-09-13".
    uint16 internal constant MIN_PROTOCOL_BPS = 2_000;
    uint16 internal constant MAX_PROTOCOL_BPS = 5_000;
    uint16 internal constant MAX_INTEGRATOR_BPS = 2_000;
    uint16 internal constant MAX_BINS = 64;

    uint16 internal constant BIN_STEP = 10;
    uint24 internal constant ACTIVE_ID = 2 ** 23; // price 1
    uint24 internal constant LP_FEE = 3_000; // 0.3%

    enum Shape {
        Flat,
        Linear,
        Exponential,
        Stepped
    }

    struct Leg {
        PoolKey key;
        bool launchIs0;
        uint24[] binIds;
        uint256[] shares;
    }

    function _deployCore() internal {
        vault = new Vault();
        binPoolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(binPoolManager));
        permit2 = IAllowanceTransfer(deployPermit2());
        weth = new WETH();
        binPm = new BinPositionManager(
            IVault(address(vault)), IBinPoolManager(address(binPoolManager)), permit2, IWETH9(address(weth))
        );
        swapper = new BinSwapHelper(IBinPoolManager(address(binPoolManager)), IVault(address(vault)));
        locker = new DeepCoreBinLPLocker(
            binPm, PROTOCOL, MIN_PROTOCOL_BPS, MAX_PROTOCOL_BPS, MAX_INTEGRATOR_BPS, MAX_BINS
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys two tokens and returns them with the launch token in the requested sort position.
    function _pair(bool launchIsCurrency0) internal returns (MockERC20 launch, MockERC20 quote) {
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 lo, MockERC20 hi) = address(a) < address(b) ? (a, b) : (b, a);
        (launch, quote) = launchIsCurrency0 ? (lo, hi) : (hi, lo);
        _fund(address(launch));
        _fund(address(quote));
    }

    function _fund(address token) internal {
        MockERC20(token).mint(address(this), 1e36);
        _approveAll(token);
    }

    /// @dev Grants the position manager (via Permit2) and the swap helper everything from `address(this)`.
    function _approveAll(address token) internal {
        MockERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(binPm), type(uint160).max, type(uint48).max);
        MockERC20(token).approve(address(swapper), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                 POOLS
    //////////////////////////////////////////////////////////////*/

    function _key(address launch, address quote, uint24 fee, IHooks hooks, uint16 bitmap)
        internal
        view
        returns (PoolKey memory key, bool launchIs0)
    {
        launchIs0 = launch < quote;
        (Currency c0, Currency c1) =
            launchIs0 ? (Currency.wrap(launch), Currency.wrap(quote)) : (Currency.wrap(quote), Currency.wrap(launch));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: hooks,
            poolManager: binPoolManager,
            fee: fee,
            parameters: bytes32(uint256(bitmap)).setBinStep(BIN_STEP)
        });
    }

    /// @dev Weights in 1e18, summing to exactly 1e18 (last bin takes the remainder), per kit section 7.
    function _weights(Shape s, uint256 n) internal pure returns (uint256[] memory w) {
        w = new uint256[](n);
        uint256[] memory raw = new uint256[](n);
        uint256 total;
        uint256 r = 1e18;
        for (uint256 k; k < n; ++k) {
            if (s == Shape.Flat) raw[k] = 1;
            else if (s == Shape.Linear) raw[k] = n - k;
            else if (s == Shape.Exponential) raw[k] = r;
            else raw[k] = (n + 3) / 4 - k / 4; // 4-bin tiers, decreasing
            if (s == Shape.Exponential) r = r * 9 / 10;
            total += raw[k];
        }
        uint256 sum;
        for (uint256 k; k + 1 < n; ++k) {
            w[k] = raw[k] * 1e18 / total;
            sum += w[k];
        }
        w[n - 1] = 1e18 - sum;
    }

    /// @dev Distance from the active bin of the k-th launch bin (1-based). Stepped leaves a 2-bin gap
    /// between 4-bin tiers - the declared exception to "no gaps".
    function _offset(Shape s, uint256 k) internal pure returns (uint256) {
        if (s == Shape.Stepped) return 1 + k + 2 * (k / 4);
        return 1 + k;
    }

    /// @dev Initializes the pool (if needed) and mints a token-only shape of `amount` launch tokens to `to`
    /// through the real position manager. Returns strictly increasing bin ids with the shares minted.
    function _mintShaped(PoolKey memory key, bool launchIs0, Shape s, uint256 n, uint256 amount, address to)
        internal
        returns (uint24[] memory binIds, uint256[] memory shares)
    {
        (uint24 active,,) = binPoolManager.getSlot0(_id(key));
        if (active == 0) {
            binPoolManager.initialize(key, ACTIVE_ID);
            active = ACTIVE_ID;
        }
        uint256[] memory w = _weights(s, n);
        int256[] memory deltaIds = new int256[](n);
        uint256[] memory distX = new uint256[](n);
        uint256[] memory distY = new uint256[](n);
        binIds = new uint24[](n);
        for (uint256 k; k < n; ++k) {
            // Ascending ids in both orientations: for a currency1 launch the bins sit below active, so
            // walk the shape from the far end.
            uint256 idx = launchIs0 ? k : n - 1 - k;
            int256 off = int256(_offset(s, idx));
            deltaIds[k] = launchIs0 ? off : -off;
            if (launchIs0) distX[k] = w[idx];
            else distY[k] = w[idx];
            binIds[k] = uint24(uint256(int256(uint256(active)) + deltaIds[k]));
        }

        IBinPositionManager.BinAddLiquidityParams memory p = IBinPositionManager.BinAddLiquidityParams({
            poolKey: key,
            amount0: launchIs0 ? uint128(amount) : 0,
            amount1: launchIs0 ? 0 : uint128(amount),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            activeIdDesired: active,
            idSlippage: 0,
            deltaIds: deltaIds,
            distributionX: distX,
            distributionY: distY,
            minLiquidities: new uint256[](n),
            to: to,
            hookData: ""
        });

        shares = new uint256[](n);
        uint256[] memory before = new uint256[](n);
        for (uint256 k; k < n; ++k) before[k] = binPm.balanceOf(to, _tokenId(key, binIds[k]));

        Plan memory plan = Planner.init();
        plan.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(p));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        binPm.modifyLiquidities(plan.encode(), block.timestamp);

        for (uint256 k; k < n; ++k) shares[k] = binPm.balanceOf(to, _tokenId(key, binIds[k])) - before[k];
    }

    function _launch(address launch, address quote, uint24 fee, Shape s, uint256 n, uint256 amount)
        internal
        returns (Leg memory leg)
    {
        (leg.key, leg.launchIs0) = _key(launch, quote, fee, IHooks(address(0)), 0);
        (leg.binIds, leg.shares) = _mintShaped(leg.key, leg.launchIs0, s, n, amount, address(this));
    }

    function _params(uint16 creatorBps, uint16 integratorBps, uint16 protocolBps)
        internal
        pure
        returns (LockParams memory)
    {
        return LockParams({
            creator: CREATOR,
            creatorBps: creatorBps,
            integrator: integratorBps == 0 ? address(0) : INTEGRATOR,
            integratorBps: integratorBps,
            protocolBps: protocolBps
        });
    }

    function _defaultParams() internal pure returns (LockParams memory) {
        return _params(6_000, 2_000, 2_000);
    }

    function _lock(Leg memory leg, LockParams memory p) internal returns (uint256 lockId) {
        if (!binPm.isApprovedForAll(address(this), address(locker))) binPm.approveForAll(address(locker), true);
        lockId = locker.lock(leg.key, leg.binIds, leg.shares, p);
    }

    /*//////////////////////////////////////////////////////////////
                                 TRADES
    //////////////////////////////////////////////////////////////*/

    function _swap(PoolKey memory key, bool swapForY, uint256 amountIn) internal returns (BalanceDelta) {
        // Native only ever sorts to currency0, which is paid in when swapping X for Y.
        uint256 value = swapForY && key.currency0.isNative() ? amountIn : 0;
        return swapper.swap{value: value}(
            key,
            swapForY,
            -int128(int256(amountIn)),
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev Buyers pay quote for launch tokens: price moves through the launch bins.
    function _buy(Leg memory leg, uint256 quoteIn) internal returns (BalanceDelta) {
        return _swap(leg.key, leg.launchIs0 ? false : true, quoteIn);
    }

    function _sell(Leg memory leg, uint256 launchIn) internal returns (BalanceDelta) {
        return _swap(leg.key, leg.launchIs0 ? true : false, launchIn);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }

    function _tokenId(PoolKey memory key, uint24 binId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), uint256(binId))));
    }

    /// @dev Floor of what a lock's recorded shares in bin i are worth, in bin-liquidity units.
    function _value(uint256 lockId, uint256 i) internal view returns (uint256 value, uint256 principal) {
        (uint24[] memory ids, uint256[] memory shares, uint256[] memory principals) = locker.getLockedBins(lockId);
        (,, uint256 binL, uint256 binS) = binPoolManager.getBin(locker.getLock(lockId).poolId, ids[i]);
        value = FullMath.mulDiv(shares[i], binL, binS);
        principal = principals[i];
    }

    /// @dev THE invariant, for every bin of a lock.
    function _assertPrincipalIntact(uint256 lockId) internal view {
        uint256 n = locker.getLock(lockId).binCount;
        for (uint256 i; i < n; ++i) {
            (uint256 value, uint256 principal) = _value(lockId, i);
            assertGe(value, principal, "bin value fell below principal");
        }
    }

    receive() external payable {}
}
