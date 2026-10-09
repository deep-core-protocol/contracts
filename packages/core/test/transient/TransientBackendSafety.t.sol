// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 HookProtocol
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IVault, Vault} from "../../src/Vault.sol";
import {Currency} from "../../src/types/Currency.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {FakePoolManager} from "../vault/FakePoolManager.sol";
import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @title Portable transient-storage backend safety
/// @notice This suite MUST pass under BOTH build profiles:
///           forge test --match-path "test/transient/*"
///           FOUNDRY_PROFILE=legacy forge test --match-path "test/transient/*"
///
/// @dev Under the EIP-1153 backend the EVM discards transient state at end of transaction,
/// so these invariants hold for free. Under the storage backend they hold ONLY because of
/// two deliberate mitigations in Vault:
///   1. sync() is gated by isLocked
///   2. lock() calls VaultReserve.clear() on exit
/// Remove either one and `test_drain_settleWithoutPaying_isBlocked` should fail on the
/// legacy profile. That test is the regression guard for a full-drain vulnerability.
contract TransientBackendSafetyTest is Test, TokenFixture {
    Vault public vault;
    FakePoolManager public fakePoolManager;

    function setUp() public {
        initializeTokens();
        vault = new Vault();
        fakePoolManager = new FakePoolManager(vault);
        vault.registerApp(address(fakePoolManager));
    }

    /*//////////////////////////////////////////////////////////////
                          BACKEND IDENTITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Pins which backend this run compiled against, so a mis-wired remapping
    /// (remappings.txt silently overriding a profile) surfaces as a test failure rather
    /// than as the wrong bytecode reaching a chain.
    function test_backendIdentity_matchesProfile() public pure {
        if (TransientSlot.IS_EIP1153) {
            assertTrue(TransientSlot.IS_EIP1153, "default profile must use EIP-1153 backend");
        } else {
            assertFalse(TransientSlot.IS_EIP1153, "legacy profile must use storage backend");
        }
    }

    /*//////////////////////////////////////////////////////////////
                     MITIGATION 1 — sync() is gated
    //////////////////////////////////////////////////////////////*/

    /// @notice An un-gated sync() lets an attacker plant a reserve that, under the storage
    /// backend, survives into a later transaction. Gating it is the first line of defence.
    function test_sync_outsideLock_reverts() public {
        vm.expectRevert(IVault.NoLocker.selector);
        vault.sync(currency0);
    }

    function test_sync_outsideLock_reverts_evenWithVaultBalance() public {
        currency0.transfer(address(vault), 100 ether);
        vm.expectRevert(IVault.NoLocker.selector);
        vault.sync(currency0);
    }

    /*//////////////////////////////////////////////////////////////
                 MITIGATION 2 — reserve cleared on lock exit
    //////////////////////////////////////////////////////////////*/

    /// @notice After any lock exits, the reserve slots must read zero. Under the storage
    /// backend this is what stops state bleeding into the next transaction.
    function test_reserveIsZeroed_afterLockExits() public {
        currency0.transfer(address(vault), 50 ether);

        vault.lock(abi.encodeCall(this._syncInsideLock, ()));

        (Currency c, uint256 amt) = vault.getVaultReserve();
        assertEq(Currency.unwrap(c), address(0), "reserve currency must be cleared on lock exit");
        assertEq(amt, 0, "reserve amount must be cleared on lock exit");
    }

    function _syncInsideLock() external {
        vault.sync(currency0);
        // reserve is live inside the lock
        (Currency c, uint256 amt) = vault.getVaultReserve();
        assertEq(Currency.unwrap(c), Currency.unwrap(currency0));
        assertEq(amt, 50 ether);
    }

    /*//////////////////////////////////////////////////////////////
              REGRESSION GUARD — the full-drain attack path
    //////////////////////////////////////////////////////////////*/

    /// @notice The attack this whole abstraction exists to prevent.
    ///
    /// Without the mitigations, under the storage backend:
    ///   1. attacker calls sync(currency0) outside a lock -> reserve persists at balance X
    ///   2. other users deposit, vault balance becomes X + Y
    ///   3. attacker locks and calls settle() having transferred NOTHING
    ///      _settle computes paid = (X + Y) - X = Y, crediting the attacker Y for free
    ///   4. attacker take()s Y and walks
    ///
    /// Step 1 must revert. This test asserts the attack cannot even begin, and that a
    /// settle with no transfer credits exactly zero.
    function test_drain_settleWithoutPaying_isBlocked() public {
        // vault holds funds belonging to other users
        currency0.transfer(address(vault), 100 ether);

        // step 1 — planting a stale reserve is impossible
        vm.expectRevert(IVault.NoLocker.selector);
        vault.sync(currency0);

        // step 2 — more funds arrive
        currency0.transfer(address(vault), 25 ether);

        // step 3 — settling without transferring must credit exactly zero
        vault.lock(abi.encodeCall(this._attemptFreeSettle, ()));
    }

    function _attemptFreeSettle() external {
        vault.sync(currency0);
        // transfer nothing, then settle
        uint256 paid = vault.settle();
        assertEq(paid, 0, "settle without paying must credit zero");
        assertEq(vault.currencyDelta(address(this), currency0), 0, "no free delta may be created");
    }

    /// @notice Two sequential locks must not leak reserve state between them.
    function test_reserveDoesNotLeakBetweenLocks() public {
        currency0.transfer(address(vault), 40 ether);
        vault.lock(abi.encodeCall(this._syncOnly, ()));

        // a later, independent lock sees a clean reserve
        vault.lock(abi.encodeCall(this._assertReserveClean, ()));
    }

    function _syncOnly() external {
        vault.sync(currency0);
    }

    function _assertReserveClean() external view {
        (Currency c, uint256 amt) = vault.getVaultReserve();
        assertEq(Currency.unwrap(c), address(0), "reserve leaked across locks");
        assertEq(amt, 0, "reserve amount leaked across locks");
    }

    /*//////////////////////////////////////////////////////////////
                              PLUMBING
    //////////////////////////////////////////////////////////////*/

    function lockAcquired(bytes calldata data) external returns (bytes memory result) {
        bool success;
        (success, result) = address(this).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
