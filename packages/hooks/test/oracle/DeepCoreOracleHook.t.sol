// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BaseCLHook} from "../../src/base/BaseCLHook.sol";
import {DeepCoreOracleHook} from "../../src/oracle/DeepCoreOracleHook.sol";
import {OracleBehaviour} from "./OracleBehaviour.sol";

/// @dev Mints ERC-6909 claims to any address, as a stranger's own vault lock would.
contract ClaimsMinter is ILockCallback {
    IVault internal immutable vault;

    constructor(IVault vault_) {
        vault = vault_;
    }

    function mintTo(address to, Currency currency, uint256 amount) external {
        vault.lock(abi.encode(to, currency, amount));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (address to, Currency currency, uint256 amount) = abi.decode(data, (address, Currency, uint256));
        vault.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(vault), amount);
        vault.settle();
        vault.mint(to, currency, amount);
        return "";
    }
}

contract DeepCoreOracleHookTest is OracleBehaviour {
    using CurrencyLibrary for Currency;

    address internal constant RECIPIENT = address(0xFEE5);
    address internal constant STRANGER = address(0xBAD);

    function _deployHook(uint24 maxDelta, uint32 minWindow, uint16 initialCard) internal override returns (address) {
        return address(new DeepCoreOracleHook(manager, IVault(address(vault)), RECIPIENT, maxDelta, minWindow, initialCard));
    }

    function _keyFee() internal pure override returns (uint24) {
        return 3_000;
    }

    function _beforeInit(PoolKey memory) internal override {}

    function _hook() internal view returns (DeepCoreOracleHook) {
        return DeepCoreOracleHook(payable(address(key.hooks)));
    }

    function test_bitmap_is_0x0042() public view {
        assertEq(_hook().getHooksRegistrationBitmap(), 0x0042);
    }

    /// @dev An EXTERNAL constructor call, so `vm.expectRevert` applies to this call. With
    /// `allow_internal_expect_revert`, an expected revert on a bare `new` inside the test makes the TEST
    /// itself revert-and-pass, and every line after the first refusal silently never runs (found by a
    /// surviving mutant, 2026-10-14).
    function newOracleHook(IVault v, address r) external returns (address) {
        return address(new DeepCoreOracleHook(manager, v, r, D, MIN_WINDOW, 16));
    }

    function test_deploy_refusesAZeroRecipientOrAForeignVault() public {
        vm.expectRevert(DeepCoreOracleHook.ZeroAddress.selector);
        this.newOracleHook(IVault(address(vault)), address(0));
        vm.expectRevert(DeepCoreOracleHook.VaultMismatch.selector);
        this.newOracleHook(IVault(address(0x1234)), RECIPIENT);
        DeepCoreOracleHook h = _hook();
        assertEq(h.ORACLE_MAX_TICK_DELTA(), D);
        assertEq(h.ORACLE_MIN_WINDOW_SECONDS(), MIN_WINDOW);
        assertEq(h.ORACLE_INITIAL_CARDINALITY(), INITIAL_CARD);
        assertEq(h.protocolRecipient(), RECIPIENT);
        assertEq(address(h.vault()), address(vault));
    }

    function test_swap_paysThePoolsOwnStaticFee_theHookTakesNothing() public {
        vm.warp(T0 + 5);
        vm.recordLogs();
        _moveTo(300);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24,uint16)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (,,,,, uint24 fee,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24, uint16));
                assertEq(fee, 3_000);
                seen = true;
            }
        }
        assertTrue(seen);
        assertEq(c0.balanceOf(address(_hook())), 0);
        assertEq(c1.balanceOf(address(_hook())), 0);
        assertEq(vault.balanceOf(address(_hook()), c0), 0);
        assertEq(vault.balanceOf(address(_hook()), c1), 0);
    }

    function test_callbacks_onlyThePoolManager() public {
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        _hook().afterInitialize(address(this), key, 1, 0);
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        _hook().beforeSwap(
            address(this), key, ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}), ""
        );
        vm.expectRevert(BaseCLHook.HookNotImplemented.selector);
        vm.prank(address(manager));
        _hook().beforeInitialize(address(this), key, 1);
    }

    function test_sweep_paysStraysAndClaimsToTheRecipient_permissionless() public {
        IERC20(Currency.unwrap(c0)).transfer(address(_hook()), 7 ether);
        ClaimsMinter minter = new ClaimsMinter(IVault(address(vault)));
        IERC20(Currency.unwrap(c1)).transfer(address(minter), 3 ether);
        minter.mintTo(address(_hook()), c1, 3 ether);
        assertEq(vault.balanceOf(address(_hook()), c1), 3 ether);

        vm.prank(STRANGER);
        assertEq(_hook().sweep(c0), 7 ether);
        vm.prank(STRANGER);
        assertEq(_hook().sweep(c1), 3 ether);
        assertEq(c0.balanceOf(RECIPIENT), 7 ether);
        assertEq(c1.balanceOf(RECIPIENT), 3 ether);
        assertEq(vault.balanceOf(address(_hook()), c1), 0);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreOracleHook.NothingToSweep.selector, c0));
        _hook().sweep(c0);
        assertEq(c0.balanceOf(STRANGER), 0, "the caller is never paid");
    }

    function test_sweep_forcedNativeLeaves_directNativeIsRefused() public {
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        (bool ok,) = address(_hook()).call{value: 1}("");
        assertFalse(ok, "receive refuses everyone but the vault");
        vm.deal(address(_hook()), 5); // as a selfdestruct would
        Currency native = Currency.wrap(address(0));
        assertEq(_hook().sweep(native), 5);
        assertEq(RECIPIENT.balance, 5);
    }

    function test_lockAcquired_onlyAcrossSweep() public {
        vm.expectRevert(DeepCoreOracleHook.UnexpectedLockCallback.selector);
        _hook().lockAcquired(abi.encode(c0, uint256(1)));
        vm.prank(address(vault));
        vm.expectRevert(DeepCoreOracleHook.UnexpectedLockCallback.selector);
        _hook().lockAcquired(abi.encode(c0, uint256(1)));
    }

    function test_hasNoOwner() public {
        (bool ok,) = address(_hook()).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner function exists");
    }
}
