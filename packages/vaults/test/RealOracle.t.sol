// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {DeepCoreOracleHook} from "deepcore-hooks/src/oracle/DeepCoreOracleHook.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {VaultFixture} from "./VaultFixture.sol";

/// @dev The vault against the REAL price-oracle DeepCore (`packages/hooks/src/oracle`), not the mock.
contract RealOracleTest is VaultFixture {
    using CLPoolParametersHelper for bytes32;

    DeepCoreOracleHook internal hook;
    PoolKey internal okey; // t0/t1 born on the oracle hook
    PoolKey internal plain; // t0/t1 hookless, a different fee tier

    function setUp() public override {
        super.setUp();
        hook = new DeepCoreOracleHook(ICLPoolManager(address(cl)), IVault(address(vault)), SAFE, 100, 600, 16);
        okey = _key(c0, c1, address(hook));
        okey.parameters = bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(SPACING);
        cl.initialize(okey, SQRT_1_1);
        _addCL(okey, -60000, 60000, 1e22, 0);

        plain = _key(c0, c1, address(0));
        plain.fee = 500;
        cl.initialize(plain, SQRT_1_1);
        _addCL(plain, -60000, 60000, 1e22, 0);
    }

    function _floor(int24 t) internal pure returns (int24 c) {
        c = t / SPACING;
        if (t < 0 && t % SPACING != 0) c--;
        c *= SPACING;
    }

    function _history(PoolKey memory k, int24 tick, uint256 secs) internal {
        // a swap per 5 minutes, holding `tick`
        for (uint256 i; i < secs / 300; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            _swapToTick(k, tick == _tick(k) ? tick + 1 : tick);
            _swapToTick(k, tick);
        }
    }

    function test_realOracle_kindAndCreation() public {
        assertEq(hook.kind(), keccak256("deepcore.oracle.truncated-twap.v1"));
        DeepCoreManagedVault v = _create(CURATOR, okey, okey, _config(), "real");
        assertEq(address(v.oracle()), address(hook));
    }

    function test_realOracle_firstDepositWaitsForHistory_thenFollowsTwap() public {
        DeepCoreManagedVault v = _create(CURATOR, okey, okey, _config(), "real");
        _approveAll(address(v));
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreManagedVault.OracleUnreadable.selector); // HistoryTooShort inside
        v.depositInitial(1e18, 1e18, 0, ALICE, vm.getBlockTimestamp());

        _history(okey, 0, 2400);
        (int24 m0,) = hook.consult(okey.toId(), 1800);
        assertApproxEqAbs(m0, 0, 1);
        vm.prank(ALICE);
        v.depositInitial(1e18, 1e18, 0, ALICE, vm.getBlockTimestamp());
        (int24 lo, int24 hi) = v.base();
        assertEq(lo, _floor(m0) - 1000);
        assertEq(hi, _floor(m0) + 1000);

        // a FLASH move cannot rebalance: the swap wrote the pre-swap tick, the TWAP stays near 0
        vm.warp(vm.getBlockTimestamp() + 3600);
        _swapToTick(okey, 800);
        vm.expectPartialRevert(DeepCoreManagedVault.DeviationTooHigh.selector);
        v.rebalance();

        // hold the new price long enough for the clamped TWAP to follow
        _history(okey, 800, 7200);
        (int24 mean,) = hook.consult(okey.toId(), 1800);
        assertGt(mean, 700);
        v.rebalance();
        (lo, hi) = v.base();
        int24 c = _floor(mean);
        assertEq(lo, c - 1000);
        assertEq(hi, c + 1000);
    }

    /// The vault provides liquidity in a hookless pool and reads the TWAP of a sibling pool of the same pair.
    function test_siblingOracle_hooklessPoolUsesTheOraclePoolsTwap() public {
        DeepCoreManagedVault v = _create(CURATOR, plain, okey, _config(), "sib");
        _approveAll(address(v));
        _history(okey, 0, 2400);
        vm.prank(ALICE);
        v.depositInitial(1e18, 1e18, 0, ALICE, vm.getBlockTimestamp());
        (uint128 lb,) = v.positionLiquidity();
        assertGt(lb, 0);
        // the vault pool diverges from the oracle pool: rebalances refuse rather than follow
        vm.warp(vm.getBlockTimestamp() + 3600);
        _swapToTick(plain, 900);
        vm.expectPartialRevert(DeepCoreManagedVault.DeviationTooHigh.selector);
        v.rebalance();
        // withdrawals are unaffected
        uint256 bal = v.balanceOf(ALICE);
        vm.prank(ALICE);
        v.withdraw(bal, 0, 0, ALICE, vm.getBlockTimestamp());
    }
}
