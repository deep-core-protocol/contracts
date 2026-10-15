// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {DeepCoreFeeGate} from "deepcore-launchpad/src/fees/DeepCoreFeeGate.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {DeepCoreVaultFactory} from "../src/DeepCoreVaultFactory.sol";
import {VaultFixture} from "./VaultFixture.sol";

contract DeepCoreVaultFactoryTest is VaultFixture {
    function _params() internal view returns (DeepCoreManagedVault.VaultParams memory) {
        return DeepCoreManagedVault.VaultParams({key: key, oracleKey: key, config: _config()});
    }

    function test_constructor_refusesForeignImplementationAndCaps() public {
        DeepCoreManagedVault other = new DeepCoreManagedVault(address(0xBEEF), ICLPoolManager(address(cl)));
        vm.expectRevert(DeepCoreVaultFactory.ImplementationMismatch.selector);
        new DeepCoreVaultFactory(address(other), SAFE, SAFE, 1, 10, NOTICE, 1000, 2000);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        DeepCoreManagedVault i2 = new DeepCoreManagedVault(predicted, ICLPoolManager(address(cl)));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreVaultFactory.PerformanceFeeAboveCap.selector, 2001, 2000));
        new DeepCoreVaultFactory(address(i2), SAFE, SAFE, 1, 10, NOTICE, 1000, 2001);
    }

    function test_createVault_chargesFeeRefundsSurplusAndRegisters() public {
        uint256 bal = ALICE.balance;
        vm.prank(ALICE);
        address v = factory.createVault{value: 1 ether}(_params(), "a");
        assertEq(bal - ALICE.balance, CREATE_FEE);
        assertTrue(factory.isVault(v));
        assertEq(factory.vaultCount(), 2);
        assertEq(factory.vaultAt(1), v);
        assertEq(factory.predictVault(ALICE, "a"), v);
        assertEq(factory.vaultsOfPool(key.toId()).length, 2);
        assertEq(factory.vaults(0, 10).length, 2);
        assertEq(factory.vaults(5, 10).length, 0);
        assertEq(DeepCoreManagedVault(payable(v)).curator(), ALICE);
        assertEq(factory.protocolFeesOwed(), 2 * CREATE_FEE);
    }

    function test_createVault_underpaidAndSaltReuseRefused() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.InsufficientFee.selector, CREATE_FEE, CREATE_FEE - 1));
        factory.createVault{value: CREATE_FEE - 1}(_params(), "a");
        vm.prank(ALICE);
        factory.createVault{value: CREATE_FEE}(_params(), "a");
        vm.prank(ALICE);
        vm.expectRevert(); // clone address taken
        factory.createVault{value: CREATE_FEE}(_params(), "a");
        // the same salt from another creator is a different address
        vm.prank(BOB);
        address vb = factory.createVault{value: CREATE_FEE}(_params(), "a");
        assertEq(vb, factory.predictVault(BOB, "a"));
    }

    function test_ownerPaysTheFeeLikeAnyone() public {
        vm.deal(SAFE, 1 ether);
        vm.prank(SAFE);
        vm.expectPartialRevert(DeepCoreFeeGate.InsufficientFee.selector);
        factory.createVault(_params(), "s");
    }

    function test_performanceFee_frozenPerVault_increaseNoticed_decreaseNow() public {
        assertEq(factory.performanceFeeBps(), PERF_BPS);
        vm.prank(SAFE);
        factory.setPerformanceFee(1_500);
        assertEq(factory.performanceFeeBps(), PERF_BPS, "increase waits");
        (uint16 nb, uint64 at) = factory.pendingPerformanceFee();
        assertEq(nb, 1_500);
        assertEq(at, block.timestamp + NOTICE);
        vm.warp(vm.getBlockTimestamp() + NOTICE);
        assertEq(factory.performanceFeeBps(), 1_500, "applies by itself");
        vm.prank(ALICE);
        address v = factory.createVault{value: CREATE_FEE}(_params(), "late");
        assertEq(DeepCoreManagedVault(payable(v)).performanceFeeBps(), 1_500);
        assertEq(mv.performanceFeeBps(), PERF_BPS, "existing vault unchanged");
        vm.prank(SAFE);
        factory.setPerformanceFee(500);
        assertEq(factory.performanceFeeBps(), 500, "decrease is immediate");
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreVaultFactory.PerformanceFeeAboveCap.selector, 2001, 2000));
        factory.setPerformanceFee(2001);
    }

    function test_performanceFee_cancelAndOwnerOnly() public {
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreVaultFactory.NoPendingPerformanceFee.selector);
        factory.cancelPendingPerformanceFee();
        vm.prank(SAFE);
        factory.setPerformanceFee(2_000);
        vm.prank(SAFE);
        factory.cancelPendingPerformanceFee();
        (uint16 nb,) = factory.pendingPerformanceFee();
        assertEq(nb, 0);
        vm.warp(vm.getBlockTimestamp() + NOTICE);
        assertEq(factory.performanceFeeBps(), PERF_BPS);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        factory.setPerformanceFee(0);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        factory.cancelPendingPerformanceFee();
    }

    function test_creationFee_houseRules() public {
        vm.prank(SAFE);
        factory.setFee(CREATE_FEE * 2);
        assertEq(factory.feeWei(), CREATE_FEE);
        vm.warp(vm.getBlockTimestamp() + NOTICE);
        assertEq(factory.feeWei(), CREATE_FEE * 2);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFeeGate.FeeAboveCap.selector, CREATE_FEE * 11, CREATE_FEE * 10));
        factory.setFee(CREATE_FEE * 11);
    }

    /// forge's test EVM does not enforce EIP-170; this does. The vault is the binding one (~24.1 KB).
    function test_EIP170_runtimeSizes() public view {
        assertLe(address(impl).code.length, 24_576, "vault implementation");
        assertLe(address(factory).code.length, 24_576, "factory");
        assertLe(address(mv).code.length, 100, "a vault is a 45-byte clone");
    }

    function test_renounceReverts() public {
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreFeeGate.RenounceDisabled.selector);
        factory.renounceOwnership();
    }

    function test_flush_permissionlessToSafeOnly() public {
        uint256 s = SAFE.balance;
        vm.prank(STRANGER);
        factory.flushProtocolFees();
        assertEq(SAFE.balance - s, CREATE_FEE);
        vm.expectRevert(DeepCoreFeeGate.NothingToFlush.selector);
        factory.flushProtocolFees();
    }

    function test_rescueERC20_ownerOnly() public {
        MockERC20 stray = new MockERC20("S", "S", 18);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreVaultFactory.NothingToRescue.selector, address(stray)));
        factory.rescueERC20(address(stray), SAFE);
        stray.mint(address(factory), 5);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        factory.rescueERC20(address(stray), STRANGER);
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreVaultFactory.RescueToZero.selector);
        factory.rescueERC20(address(stray), address(0));
        vm.prank(SAFE);
        factory.rescueERC20(address(stray), BOB);
        assertEq(stray.balanceOf(BOB), 5);
    }

    function test_ownerCannotReachAVault() public {
        _seed(mv, ALICE, 1e18);
        // the factory exposes no function that calls a vault after creation; the vault has no owner
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreManagedVault.NotCurator.selector);
        mv.claimCuratorFees(SAFE);
        vm.prank(address(factory));
        vm.expectRevert(DeepCoreManagedVault.AlreadyInitialized.selector);
        mv.initialize(_params(), SAFE, SAFE, 0);
    }
}
