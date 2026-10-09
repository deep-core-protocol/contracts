// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreRegistry} from "../src/DeepCoreRegistry.sol";
import {
    IDeepCoreRegistry,
    DeepCoreMetadata,
    DeepCoreRecord,
    Verification,
    Listing,
    PermissionSource,
    RiskClass,
    PERM_AFTER_SWAP,
    PERM_BEFORE_SWAP,
    PERM_BEFORE_REMOVE_LIQUIDITY,
    PERM_BEFORE_SWAP_RETURNS_DELTA,
    PERM_ALL_ASSIGNED
} from "../src/IDeepCoreRegistry.sol";

import {HonestHook, MutableHook} from "./mocks/MockHooks.sol";
import {MockVault, MockPoolManager, NotAPoolManager} from "./mocks/MockPools.sol";

/// @title Pool attestation — unit coverage
/// @notice `SpoofAgainstCore.t.sol` proves the mechanism against real infinity-core. This file
/// drives the edge cases, which need a pool manager that can be made to misbehave in ways core
/// never would — a key filed under the wrong id, a key naming a different manager, a Vault app
/// that is not a pool manager at all.
contract PoolAttestationTest is Test {
    using PoolIdLibrary for PoolKey;

    DeepCoreRegistry internal registry;
    MockVault internal vault;
    MockPoolManager internal manager;
    MockPoolManager internal secondManager;

    address internal admin = address(0x71E10);
    address internal curator = address(0xC0A70);
    address internal guardian = address(0x69A2D);
    address internal alice = address(0xA11CE);
    address internal stranger = address(0x57A6E);

    uint16 internal constant TAME = PERM_AFTER_SWAP;
    uint16 internal constant SWAP_TAX = PERM_BEFORE_SWAP | PERM_BEFORE_SWAP_RETURNS_DELTA;

    uint160 internal _nonce;

    function setUp() public {
        vault = new MockVault();
        manager = new MockPoolManager();
        secondManager = new MockPoolManager();
        vault.registerApp(address(manager));
        vault.registerApp(address(secondManager));

        address[] memory curators = new address[](1);
        curators[0] = curator;
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        registry = new DeepCoreRegistry(admin, address(vault), curators, guardians);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _meta(string memory audit) internal pure returns (DeepCoreMetadata memory m) {
        m = DeepCoreMetadata({
            name: "Hook", description: "d", sourceURI: "ipfs://src", auditURI: audit, chainIds: new uint256[](0)
        });
    }

    function _key(address hook, uint16 bitmap, MockPoolManager m) internal returns (PoolKey memory key) {
        _nonce += 2;
        key = PoolKey({
            currency0: Currency.wrap(address(_nonce)),
            currency1: Currency.wrap(address(_nonce + 1)),
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(m)),
            fee: 3000,
            parameters: bytes32(uint256(bitmap) | (uint256(60) << 16))
        });
    }

    function _pool(address hook, uint16 bitmap) internal returns (bytes32) {
        return manager.setPool(_key(hook, bitmap, manager));
    }

    function _registered(uint16 bitmap) internal returns (address hook) {
        hook = address(new HonestHook(bitmap));
        vm.prank(alice);
        registry.register(hook, _meta("ipfs://audit"));
    }

    /*//////////////////////////////////////////////////////////////
                             HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_attest_recordsEverything() public {
        address hook = _registered(SWAP_TAX);
        bytes32 poolId = _pool(hook, SWAP_TAX);

        vm.warp(block.timestamp + 1 days);
        vm.prank(stranger);
        registry.attestFromPool(hook, address(manager), poolId);

        DeepCoreRecord memory r = registry.getDeepCore(hook);
        assertEq(r.attestedPermissions, SWAP_TAX);
        assertEq(r.attestedPoolManager, address(manager));
        assertEq(r.attestedPoolId, poolId);
        assertEq(r.attestedAt, uint64(block.timestamp));
        assertEq(r.attestationCount, 1);
        assertEq(r.updatedAt, uint64(block.timestamp));
        assertTrue(registry.isAttested(hook));
        assertTrue(registry.hasAttestedPool(hook, poolId));

        (uint32 count, uint16 perms, address pm, bytes32 pid, uint64 at) = registry.attestationOf(hook);
        assertEq(count, 1);
        assertEq(perms, SWAP_TAX);
        assertEq(pm, address(manager));
        assertEq(pid, poolId);
        assertEq(at, uint64(block.timestamp));
    }

    /// @notice Anyone may attest. There is no argument to this function that makes a record look
    /// milder, so there is nothing to gate.
    function test_attest_isPermissionless() public {
        address hook = _registered(TAME);
        bytes32 poolId = _pool(hook, TAME);
        vm.prank(stranger);
        registry.attestFromPool(hook, address(manager), poolId);
        assertTrue(registry.isAttested(hook));
    }

    function test_registerWithPool_listsAndAttestsInOneCall() public {
        address hook = address(new HonestHook(SWAP_TAX));
        // The pool key is fixed at initialization, so it exists before the listing does. That is
        // the normal order for a hook that shipped before it was listed.
        bytes32 poolId = _pool(hook, SWAP_TAX);

        vm.prank(alice);
        registry.registerWithPool(hook, _meta("ipfs://audit"), address(manager), poolId);

        assertTrue(registry.isRegistered(hook));
        assertTrue(registry.isAttested(hook));
        (, PermissionSource source) = registry.effectivePermissions(hook);
        assertEq(uint8(source), uint8(PermissionSource.PoolAttested));

        vm.prank(curator);
        registry.setVerification(hook, Verification.Audited, "");
        assertTrue(registry.isAudited(hook));
    }

    /// @notice A failed attestation must not leave a half-listed hook behind.
    function test_registerWithPool_isAtomic() public {
        address hook = address(new HonestHook(SWAP_TAX));
        bytes32 ghost = keccak256("nope");

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(manager), ghost));
        vm.prank(alice);
        registry.registerWithPool(hook, _meta(""), address(manager), ghost);

        assertFalse(registry.isRegistered(hook));
        assertEq(registry.deepcoreCount(), 0);
    }

    function test_attest_secondDistinctPoolIsCounted() public {
        address hook = _registered(SWAP_TAX);
        bytes32 p1 = _pool(hook, SWAP_TAX);
        bytes32 p2 = secondManager.setPool(_key(hook, SWAP_TAX, secondManager));

        registry.attestFromPool(hook, address(manager), p1);
        registry.attestFromPool(hook, address(secondManager), p2);

        DeepCoreRecord memory r = registry.getDeepCore(hook);
        assertEq(r.attestationCount, 2);
        assertEq(r.attestedPoolManager, address(secondManager), "most recent");
        assertTrue(registry.hasAttestedPool(hook, p1));
        assertTrue(registry.hasAttestedPool(hook, p2));
    }

    /*//////////////////////////////////////////////////////////////
                        REJECTED ATTESTATIONS
    //////////////////////////////////////////////////////////////*/

    function test_reject_unregisteredHook() public {
        address hook = address(new HonestHook(TAME));
        bytes32 poolId = _pool(hook, TAME);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.attestFromPool(hook, address(manager), poolId);
    }

    /// @notice The attacker's obvious move: deploy your own "pool manager" that says whatever you
    /// like. The Vault gate is what stops it, and `registerApp` is `onlyOwner` on the 48h custody
    /// timelock.
    function test_reject_managerNotRegisteredWithVault() public {
        address hook = _registered(SWAP_TAX);
        MockPoolManager rogue = new MockPoolManager();
        bytes32 poolId = rogue.setPool(_key(hook, TAME, rogue));

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.UntrustedPoolManager.selector, address(rogue)));
        registry.attestFromPool(hook, address(rogue), poolId);
    }

    /// @notice And the Vault gate is checked BEFORE anything is read from the manager, so a rogue
    /// manager never gets to run code in this frame at all.
    function test_reject_untrustedManagerIsCheckedFirst() public {
        address hook = _registered(SWAP_TAX);
        // Not even a contract. If the order were wrong this would revert on the call instead.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.UntrustedPoolManager.selector, stranger));
        registry.attestFromPool(hook, stranger, keccak256("x"));
    }

    /// @notice A Vault app is not necessarily a pool manager.
    function test_reject_vaultAppThatIsNotAPoolManager() public {
        address hook = _registered(SWAP_TAX);
        NotAPoolManager notOne = new NotAPoolManager();
        vault.registerApp(address(notOne));

        vm.expectRevert();
        registry.attestFromPool(hook, address(notOne), keccak256("x"));
    }

    function test_reject_poolDoesNotExist() public {
        address hook = _registered(SWAP_TAX);
        bytes32 ghost = keccak256("ghost");
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(manager), ghost));
        registry.attestFromPool(hook, address(manager), ghost);
    }

    /// @notice The zero key is what an uninitialized slot returns. Filed under its own hash it
    /// survives the `toId` check, and is caught by the manager-identity check instead.
    function test_reject_zeroKeyFiledUnderItsOwnHash() public {
        address hook = _registered(SWAP_TAX);
        PoolKey memory zero;
        bytes32 zeroId = PoolId.unwrap(zero.toId());
        manager.forgePool(zeroId, zero);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(manager), zeroId));
        registry.attestFromPool(hook, address(manager), zeroId);
    }

    /// @notice A key filed under an id that is not its hash. Core cannot produce this; a
    /// compromised or buggy manager could, and the registry must not read permissions out of it.
    function test_reject_keyFiledUnderTheWrongId() public {
        address hook = _registered(TAME);
        PoolKey memory key = _key(hook, SWAP_TAX, manager);
        bytes32 wrongId = keccak256("a convenient id");
        manager.forgePool(wrongId, key);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(manager), wrongId));
        registry.attestFromPool(hook, address(manager), wrongId);
    }

    /// @notice A key naming a different manager. Core's `poolManagerMatch` makes this impossible
    /// at initialization, so its presence means the entry was written some other way.
    function test_reject_keyNamesADifferentManager() public {
        address hook = _registered(SWAP_TAX);
        // Filed on `manager`, but the key says `secondManager`.
        PoolKey memory key = _key(hook, SWAP_TAX, secondManager);
        bytes32 id = PoolId.unwrap(key.toId());
        manager.forgePool(id, key);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(manager), id));
        registry.attestFromPool(hook, address(manager), id);
    }

    function test_reject_poolRunsADifferentHook() public {
        address hook = _registered(SWAP_TAX);
        address other = address(new HonestHook(TAME));
        bytes32 poolId = _pool(other, TAME);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolHookMismatch.selector, poolId, hook, other));
        registry.attestFromPool(hook, address(manager), poolId);
    }

    function test_reject_samePoolTwice() public {
        address hook = _registered(SWAP_TAX);
        bytes32 poolId = _pool(hook, SWAP_TAX);
        registry.attestFromPool(hook, address(manager), poolId);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolAlreadyAttested.selector, hook, poolId));
        vm.prank(stranger);
        registry.attestFromPool(hook, address(manager), poolId);
    }

    /*//////////////////////////////////////////////////////////////
                        THE BADGE GATE
    //////////////////////////////////////////////////////////////*/

    function test_badge_requiresAttestation() public {
        address hook = _registered(TAME);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.AttestationRequired.selector, hook));
        vm.prank(curator);
        registry.setVerification(hook, Verification.SourceVerified, "");
    }

    /// @notice Setting the level back DOWN to Unverified never needs an attestation. Demotion must
    /// always be reachable — that is the same rule as the guardian being un-timelocked.
    function test_badge_demotionNeedsNothing() public {
        address hook = _registered(TAME);
        vm.prank(curator);
        registry.setVerification(hook, Verification.Unverified, "nothing here");
        assertEq(uint8(registry.getDeepCore(hook).verification), uint8(Verification.Unverified));
    }

    /// @notice A flagged listing fails on the flag, not on the attestation, so the error a curator
    /// sees names the thing they most need to know.
    function test_badge_maliciousFlagOutranksTheAttestationCheck() public {
        address hook = _registered(TAME);
        vm.prank(guardian);
        registry.setListing(hook, Listing.Malicious, "drains");

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreFlaggedMalicious.selector, hook));
        vm.prank(curator);
        registry.setVerification(hook, Verification.SourceVerified, "");
    }

    /// @notice Attestations survive a malicious flag and a later rehabilitation. They are evidence
    /// about the chain, not a curator opinion, and no role can clear them.
    function test_attestation_survivesFlagAndRehabilitation() public {
        address hook = _registered(SWAP_TAX);
        bytes32 poolId = _pool(hook, SWAP_TAX);
        registry.attestFromPool(hook, address(manager), poolId);

        vm.prank(guardian);
        registry.setListing(hook, Listing.Malicious, "drains");
        assertEq(registry.getDeepCore(hook).attestedPermissions, SWAP_TAX);

        vm.prank(curator);
        registry.setListing(hook, Listing.Active, "false alarm");
        assertEq(registry.getDeepCore(hook).attestedPermissions, SWAP_TAX);
        assertEq(registry.getDeepCore(hook).attestationCount, 1);
    }

    /*//////////////////////////////////////////////////////////////
                     EFFECTIVE PERMISSIONS SEMANTICS
    //////////////////////////////////////////////////////////////*/

    function test_effective_unattestedIsSelfReported() public {
        address hook = _registered(TAME);
        (uint16 p, PermissionSource s) = registry.effectivePermissions(hook);
        assertEq(p, TAME);
        assertEq(uint8(s), uint8(PermissionSource.SelfReported));
        assertEq(registry.permissionsConcealed(hook), 0, "no evidence is not evidence of none");
        assertFalse(registry.isAttested(hook));
    }

    /// @notice A hook that OVERstates to the registry is not flagged divergent. Overstating is
    /// harmless — the union already covers it — and treating it as deception would punish a hook
    /// that reserved a capability it never used.
    function test_effective_overstatingIsNotDivergence() public {
        address hook = _registered(SWAP_TAX);
        bytes32 poolId = _pool(hook, PERM_BEFORE_SWAP);
        registry.attestFromPool(hook, address(manager), poolId);

        (uint16 p, PermissionSource s) = registry.effectivePermissions(hook);
        assertEq(p, SWAP_TAX);
        assertEq(uint8(s), uint8(PermissionSource.PoolAttested));
        assertEq(registry.permissionsConcealed(hook), 0);
    }

    /// @notice `refreshPermissions` moves the self-report; it can never lower the attested union.
    function test_effective_refreshCannotErodeAnAttestation() public {
        MutableHook hook = new MutableHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta("ipfs://audit"));
        bytes32 poolId = _pool(address(hook), SWAP_TAX);
        registry.attestFromPool(address(hook), address(manager), poolId);

        // The hook now claims to be harmless. The pool it is in has not changed.
        hook.set(TAME);
        registry.refreshPermissions(address(hook));

        assertEq(registry.selfReportedPermissionsOf(address(hook)), TAME, "self-report followed the hook");
        (uint16 p, PermissionSource s) = registry.effectivePermissions(address(hook));
        assertEq(p, TAME | SWAP_TAX, "the live pool still enforces the tax");
        assertEq(uint8(s), uint8(PermissionSource.PoolAttestedDivergent));
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.ValueExtracting));
    }

    function test_riskAssessment_returnsClassAndProvenanceTogether() public {
        address hook = _registered(PERM_BEFORE_REMOVE_LIQUIDITY);
        (RiskClass c, PermissionSource s, uint32 n) = registry.riskAssessmentOf(hook);
        assertEq(uint8(c), uint8(RiskClass.ValueExtracting), "can refuse withdrawals");
        assertEq(uint8(s), uint8(PermissionSource.SelfReported));
        assertEq(n, 0);

        bytes32 poolId = _pool(hook, PERM_BEFORE_REMOVE_LIQUIDITY);
        registry.attestFromPool(hook, address(manager), poolId);
        (c, s, n) = registry.riskAssessmentOf(hook);
        assertEq(uint8(s), uint8(PermissionSource.PoolAttested));
        assertEq(n, 1);
    }

    function test_views_revertForUnregistered() public {
        address hook = address(new HonestHook(TAME));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.effectivePermissions(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.selfReportedPermissionsOf(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.riskAssessmentOf(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.permissionsConcealed(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.attestationOf(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.isAttested(hook);

        // `hasAttestedPool` is the exception: it is a plain lookup with no record to be missing.
        assertFalse(registry.hasAttestedPool(hook, keccak256("x")));
    }

    /*//////////////////////////////////////////////////////////////
                            THE INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Across an arbitrary sequence of attestations, the effective bitmap only grows and
    /// the risk class never falls. This is what makes `attestFromPool` safe to leave open.
    function testFuzz_unionIsMonotoneAcrossManyPools(uint16 reported, uint16[8] calldata pools) public {
        uint16 self = reported & PERM_ALL_ASSIGNED;
        address hook = address(new HonestHook(_valid(self)));
        vm.prank(alice);
        registry.register(hook, _meta("ipfs://audit"));

        (uint16 previous,) = registry.effectivePermissions(hook);
        RiskClass previousClass = registry.riskClassOf(hook);

        for (uint256 i; i < pools.length; ++i) {
            uint16 bitmap = _valid(pools[i] & PERM_ALL_ASSIGNED);
            bytes32 poolId = _pool(hook, bitmap);
            registry.attestFromPool(hook, address(manager), poolId);

            (uint16 current,) = registry.effectivePermissions(hook);
            assertEq(current & previous, previous, "no bit was ever dropped");
            assertEq(current, previous | bitmap, "exactly the union");
            RiskClass currentClass = registry.riskClassOf(hook);
            assertTrue(uint8(currentClass) >= uint8(previousClass), "risk class never falls");

            previous = current;
            previousClass = currentClass;
            assertEq(registry.getDeepCore(hook).attestationCount, uint32(i + 1));
        }
    }

    function _valid(uint16 raw) internal pure returns (uint16 p) {
        p = raw & PERM_ALL_ASSIGNED;
        if (p & (uint16(1) << 10) != 0) p |= uint16(1) << 6;
        if (p & (uint16(1) << 11) != 0) p |= uint16(1) << 7;
        if (p & (uint16(1) << 12) != 0) p |= uint16(1) << 3;
        if (p & (uint16(1) << 13) != 0) p |= uint16(1) << 5;
    }

    /*//////////////////////////////////////////////////////////////
        THE ADMIN ROLE CANNOT BE DROPPED

        Not part of the attestation fix, but folded into the same
        redeploy. AccessControl lets the sole admin walk away, and
        here that permanently removes the only path to appointing a
        curator or a guardian — no more badges, and no more flagging
        a DeepCore that is draining people.
    //////////////////////////////////////////////////////////////*/

    function test_admin_cannotRenounce() public {
        bytes32 ADMIN = registry.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(IDeepCoreRegistry.AdminRoleIsNotRenounceable.selector);
        vm.prank(admin);
        registry.renounceRole(ADMIN, admin);
        assertTrue(registry.hasRole(ADMIN, admin));
        assertEq(registry.adminCount(), 1);
    }

    /// L-1 (2026-09-18): a misdirected ERC-20 leaves through the admin, and only the admin.
    function test_admin_rescueERC20_adminOnly_wholeBalance() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.NothingToRescue.selector, address(stray)));
        registry.rescueERC20(address(stray), alice);

        stray.mint(address(registry), 9e18);
        bytes32 ADMIN = registry.DEFAULT_ADMIN_ROLE();
        address[3] memory refused = [curator, guardian, stranger];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, refused[i], ADMIN));
            registry.rescueERC20(address(stray), refused[i]);
        }
        vm.prank(admin);
        vm.expectRevert(IDeepCoreRegistry.RescueToZero.selector);
        registry.rescueERC20(address(stray), address(0));

        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IDeepCoreRegistry.ERC20Rescued(address(stray), alice, 9e18);
        registry.rescueERC20(address(stray), alice);
        assertEq(stray.balanceOf(alice), 9e18);
        assertEq(stray.balanceOf(address(registry)), 0);
    }

    function test_admin_cannotRevokeTheLastOne() public {
        bytes32 ADMIN = registry.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(IDeepCoreRegistry.LastAdminCannotBeRemoved.selector);
        vm.prank(admin);
        registry.revokeRole(ADMIN, admin);
        assertTrue(registry.hasRole(ADMIN, admin));
    }

    /// @notice Handover still works: grant the successor, then revoke the predecessor.
    function test_admin_handoverWorks() public {
        bytes32 ADMIN = registry.DEFAULT_ADMIN_ROLE();
        address successor = address(0x5CC);

        vm.prank(admin);
        registry.grantRole(ADMIN, successor);
        assertEq(registry.adminCount(), 2);

        vm.prank(successor);
        registry.revokeRole(ADMIN, admin);
        assertEq(registry.adminCount(), 1);
        assertFalse(registry.hasRole(ADMIN, admin));
        assertTrue(registry.hasRole(ADMIN, successor));

        // And the new sole admin is just as stuck as the old one.
        vm.expectRevert(IDeepCoreRegistry.LastAdminCannotBeRemoved.selector);
        vm.prank(successor);
        registry.revokeRole(ADMIN, successor);
    }

    /// @notice Granting an account that already holds the role must not double-count it, or the
    /// count would drift above the truth and the last-admin guard would stop working.
    function test_admin_countDoesNotDriftOnRepeatedGrants() public {
        bytes32 ADMIN = registry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        registry.grantRole(ADMIN, admin);
        registry.grantRole(ADMIN, admin);
        vm.stopPrank();
        assertEq(registry.adminCount(), 1);

        vm.expectRevert(IDeepCoreRegistry.LastAdminCannotBeRemoved.selector);
        vm.prank(admin);
        registry.revokeRole(ADMIN, admin);
    }

    /// @notice Revoking an account that never held it is a no-op, not a decrement.
    function test_admin_countDoesNotDriftOnRedundantRevokes() public {
        bytes32 ADMIN = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        registry.revokeRole(ADMIN, stranger);
        assertEq(registry.adminCount(), 1);
        assertTrue(registry.hasRole(ADMIN, admin));
    }

    /// @notice Curator and guardian stay renounceable. Losing every holder of either is one admin
    /// transaction away from being fixed, so there is nothing to protect against.
    function test_roles_curatorAndGuardianMayRenounce() public {
        bytes32 CURATOR = registry.CURATOR_ROLE();
        bytes32 GUARDIAN = registry.GUARDIAN_ROLE();

        vm.prank(curator);
        registry.renounceRole(CURATOR, curator);
        assertFalse(registry.hasRole(CURATOR, curator));

        vm.prank(guardian);
        registry.renounceRole(GUARDIAN, guardian);
        assertFalse(registry.hasRole(GUARDIAN, guardian));

        vm.prank(admin);
        registry.grantRole(CURATOR, curator);
        assertTrue(registry.hasRole(CURATOR, curator));
    }

    function test_roles_renounceStillRequiresSelf() public {
        bytes32 CURATOR = registry.CURATOR_ROLE();
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        vm.prank(stranger);
        registry.renounceRole(CURATOR, curator);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_zeroVaultRejected() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(IDeepCoreRegistry.ZeroAddress.selector);
        new DeepCoreRegistry(admin, address(0), empty, empty);
    }

    function test_constructor_vaultIsImmutableAndPublic() public view {
        assertEq(address(registry.vault()), address(vault));
    }

    function test_constructor_adminCountStartsAtOne() public view {
        assertEq(registry.adminCount(), 1);
    }
}
