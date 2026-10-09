// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {DeepCoreLPLocker} from "../../src/DeepCoreLPLocker.sol";
import {LockParams} from "../../src/interfaces/IDeepCoreLPLocker.sol";

/// @dev A token that taxes 1% of every `transfer` except into the Vault - the shape that can still be
/// seeded and swapped (the Vault credits balance deltas, so a tax on the way IN would fail settlement)
/// but delivers less than the Vault sends on the way OUT, including fee collection into the locker.
contract FeeOnTransferToken is MockERC20 {
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

/// @dev The three issuer powers a Robinhood `Stock` token has that matter to a locker: a global pause,
/// a per-address block, and `adminBurn` from any holder.
contract PausableStockToken is MockERC20 {
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

/// @notice Real core + periphery, no mocks: `Vault`, `CLPoolManager`, `CLPositionManager`, Permit2.
abstract contract LockerFixture is Test, Deployers, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;

    Vault internal vault;
    CLPoolManager internal poolManager;
    CLPositionManager internal posm;
    IAllowanceTransfer internal permit2;
    CLPoolManagerRouter internal router;
    WETH internal weth;
    DeepCoreLPLocker internal locker;

    address internal constant PROTOCOL = address(0x9807);
    address internal constant CREATOR = address(0xC4EA);
    address internal constant INTEGRATOR = address(0x1478);
    address internal constant ATTACKER = address(0xBAD);

    /// @dev The owner's numbers, CLAUDE.md "Kit fees: decided by the owner, 2026-09-13".
    uint16 internal constant MIN_PROTOCOL_BPS = 2_000;
    uint16 internal constant MAX_PROTOCOL_BPS = 5_000;
    uint16 internal constant MAX_INTEGRATOR_BPS = 2_000;

    int24 internal constant TICK_SPACING = 60;
    uint128 internal constant LIQUIDITY = 1_000 ether;

    function _deployCore() internal {
        (vault, poolManager) = createFreshManager();
        router = new CLPoolManagerRouter(vault, poolManager);
        permit2 = IAllowanceTransfer(deployPermit2());
        weth = new WETH();
        ICLPositionDescriptor descriptor = new CLPositionDescriptorOffChain("https://deepcore.example/positions/");
        posm = new CLPositionManager(vault, poolManager, permit2, 100_000, descriptor, IWETH9(address(weth)));
        locker = new DeepCoreLPLocker(posm, PROTOCOL, MIN_PROTOCOL_BPS, MAX_PROTOCOL_BPS, MAX_INTEGRATOR_BPS);
    }

    function _sorted(address a, address b) internal pure returns (Currency c0, Currency c1) {
        (c0, c1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }

    function _key(Currency c0, Currency c1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });
    }

    function _initPool(address tokenA, address tokenB) internal returns (PoolKey memory key) {
        (Currency c0, Currency c1) = _sorted(tokenA, tokenB);
        key = _key(c0, c1);
        poolManager.initialize(key, SQRT_RATIO_1_1);
    }

    /// @dev Grants the position manager and the router everything they need from `address(this)`.
    function _approveAll(address token) internal {
        MockERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(posm), type(uint160).max, type(uint48).max);
        MockERC20(token).approve(address(router), type(uint256).max);
    }

    /// @dev Mints a position to `address(this)` through the real position manager.
    function _mint(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 tokenId)
    {
        tokenId = posm.nextTokenId();
        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                tickLower,
                tickUpper,
                uint256(liquidity),
                type(uint128).max,
                type(uint128).max,
                address(this),
                bytes("")
            )
        );
        plan.add(Actions.SETTLE_PAIR, abi.encode(key.currency0, key.currency1));
        if (key.currency0.isNative()) {
            plan.add(Actions.SWEEP, abi.encode(key.currency0, address(this)));
            posm.modifyLiquidities{value: 10_000 ether}(plan.encode(), block.timestamp);
        } else {
            posm.modifyLiquidities(plan.encode(), block.timestamp);
        }
    }

    function _mintFullRange(PoolKey memory key) internal returns (uint256) {
        return _mint(key, -60_000, 60_000, LIQUIDITY);
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
        // The owner's example lock: creator 6000 / integrator 2000 / protocol 2000.
        return _params(6_000, 2_000, 2_000);
    }

    function _lock(uint256 tokenId, LockParams memory p) internal {
        posm.safeTransferFrom(address(this), address(locker), tokenId, abi.encode(p));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint256 value = (zeroForOne && key.currency0.isNative()) ? uint256(amountSpecified < 0 ? -amountSpecified : amountSpecified) : 0;
        return router.swap{value: value}(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    /// @dev Swap both ways so both currencies accrue fees.
    function _trade(PoolKey memory key, uint256 amount) internal {
        _swap(key, true, -int256(amount));
        _swap(key, false, -int256(amount));
    }

    receive() external payable {}
}
