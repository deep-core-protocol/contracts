// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";

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
    PERM_BEFORE_SWAP_RETURNS_DELTA
} from "../src/IDeepCoreRegistry.sol";

import {TwoFacedHook, GasBranchHook, HonestHook, PerCallerBitmapHook} from "./mocks/MockHooks.sol";

/// @title The spoof, run against real infinity-core
///
/// @notice Every other test in this package mocks the pool manager. This one does not. It stands
/// up a real `Vault`, a real `CLPoolManager`, a real `BinPoolManager`, initializes real pools, and
/// lets a real hook lie to the registry while telling core the truth.
///
/// It exists because the defect is a disagreement BETWEEN two contracts, and a mock of either one
/// is a mock of the disagreement. The critical assertion is `test_theSpoof_registryRecordsALie`:
/// it must hold with or without the fix, because it describes the attack, not the defence. What
/// changes is everything after it — whether the registry can be made to admit the truth, and
/// whether a curator can put a badge on the lie.
contract SpoofAgainstCoreTest is Test {
    using PoolIdLibrary for PoolKey;

    Vault internal vault;
    CLPoolManager internal clManager;
    BinPoolManager internal binManager;
    DeepCoreRegistry internal registry;

    address internal timelock = address(0x71E10);
    address internal curator = address(0xC0A70);
    address internal alice = address(0xA11CE);

    /// @dev What the marketplace would show: observes swaps, takes nothing, blocks nothing.
    uint16 internal constant TAME = PERM_AFTER_SWAP;

    /// @dev What the pool actually enforces: a veto on every swap plus a delta on every swap.
    uint16 internal constant SWAP_TAX = PERM_BEFORE_SWAP | PERM_BEFORE_SWAP_RETURNS_DELTA;

    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant BIN_STEP = 10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        vault = new Vault();
        clManager = new CLPoolManager(IVault(address(vault)));
        binManager = new BinPoolManager(IVault(address(vault)));

        // Exactly what 02_DeployCLPoolManager / 03_DeployBinPoolManager do on a real chain, and
        // the reason the registry can believe these two addresses about their own pools.
        vault.registerApp(address(clManager));
        vault.registerApp(address(binManager));

        address[] memory curators = new address[](1);
        curators[0] = curator;
        address[] memory guardians = new address[](0);
        registry = new DeepCoreRegistry(timelock, address(vault), curators, guardians);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _clParams(uint16 bitmap) internal pure returns (bytes32) {
        return bytes32(uint256(bitmap) | (uint256(uint24(TICK_SPACING)) << 16));
    }

    function _binParams(uint16 bitmap) internal pure returns (bytes32) {
        return bytes32(uint256(bitmap) | (uint256(BIN_STEP) << 16));
    }

    uint160 internal _tokenNonce = 0x1000;

    function _clKey(address hook, uint16 bitmap) internal returns (PoolKey memory key) {
        _tokenNonce += 2;
        key = PoolKey({
            currency0: Currency.wrap(address(_tokenNonce)),
            currency1: Currency.wrap(address(_tokenNonce + 1)),
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(clManager)),
            fee: 3000,
            parameters: _clParams(bitmap)
        });
    }

    function _binKey(address hook, uint16 bitmap) internal returns (PoolKey memory key) {
        _tokenNonce += 2;
        key = PoolKey({
            currency0: Currency.wrap(address(_tokenNonce)),
            currency1: Currency.wrap(address(_tokenNonce + 1)),
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(binManager)),
            fee: 3000,
            parameters: _binParams(bitmap)
        });
    }

    function _initCL(address hook, uint16 bitmap) internal returns (bytes32 poolId) {
        PoolKey memory key = _clKey(hook, bitmap);
        clManager.initialize(key, SQRT_PRICE_1_1);
        poolId = PoolId.unwrap(key.toId());
    }

    function _initBin(address hook, uint16 bitmap) internal returns (bytes32 poolId) {
        PoolKey memory key = _binKey(hook, bitmap);
        binManager.initialize(key, 2 ** 23);
        poolId = PoolId.unwrap(key.toId());
    }

    function _meta(string memory audit) internal pure returns (DeepCoreMetadata memory m) {
        m = DeepCoreMetadata({
            name: "Totally Passive Analytics",
            description: "Reads swaps for a dashboard. Takes nothing.",
            sourceURI: "ipfs://src",
            auditURI: audit,
            chainIds: new uint256[](0)
        });
    }

    /*//////////////////////////////////////////////////////////////
        1. THE ATTACK ITSELF — TRUE BEFORE AND AFTER THE FIX
    //////////////////////////////////////////////////////////////*/

    /// @notice Four lines of Solidity defeat the probe completely.
    ///
    /// @dev This test does NOT assert the fix. It asserts the defect, and it passes against the
    /// pre-fix contract too — that is the point. `register` records `TAME`, `classify` says
    /// `Passive`, `takesSwapCut` says false, and a real CL pool is simultaneously live with
    /// `beforeSwapReturnsDelta` enabled, because core asked the same hook and got a different
    /// answer. Every defence in `_probePermissions` is about the CALL; none of them make the
    /// ANSWER true.
    function test_theSpoof_registryRecordsALie() public {
        TwoFacedHook hook = new TwoFacedHook(address(registry), TAME, SWAP_TAX);

        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        // What the registry was told.
        assertEq(registry.selfReportedPermissionsOf(address(hook)), TAME, "registry got the tame bitmap");

        // What core was told, in the same block, by the same contract.
        bytes32 poolId = _initCL(address(hook), SWAP_TAX);
        assertTrue(poolId != bytes32(0));

        // And core would have REFUSED the tame bitmap for that pool, which proves the two answers
        // are genuinely different rather than an artefact of how the test asks.
        PoolKey memory tameKey = _clKey(address(hook), TAME);
        vm.expectRevert(Hooks.HookConfigValidationError.selector);
        clManager.initialize(tameKey, SQRT_PRICE_1_1);
    }

    /// @notice `refreshPermissions` cannot recover, and never will.
    /// @dev It is permissionless, but it still calls FROM the registry address, so it re-reads the
    /// same branch forever. The hook is immutable here, so the codehash never moves either — there
    /// is no signal anywhere in the pre-fix contract that anything is wrong.
    function test_theSpoof_refreshRereadsTheSameLie() public {
        TwoFacedHook hook = new TwoFacedHook(address(registry), TAME, SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));
        _initCL(address(hook), SWAP_TAX);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnchanged.selector, address(hook)));
        registry.refreshPermissions(address(hook));
    }

    /// @notice Probing from a different address would not have helped either.
    /// @dev `gasleft()` is the second axis. The registry forwards `PROBE_GAS` (100k); core forwards
    /// everything. A hook keyed on the budget rather than the caller lies to any prober the
    /// registry could possibly be, including a freshly deployed disposable one.
    function test_theSpoof_gasBranchDefeatsAnyProber() public {
        GasBranchHook hook = new GasBranchHook(150_000, TAME, SWAP_TAX);

        vm.prank(alice);
        registry.register(address(hook), _meta(""));
        assertEq(registry.selfReportedPermissionsOf(address(hook)), TAME, "probe budget is a signal");

        _initCL(address(hook), SWAP_TAX);
    }

    /*//////////////////////////////////////////////////////////////
        2. THE FIX — READ IT FROM A POOL CORE ALREADY VALIDATED
    //////////////////////////////////////////////////////////////*/

    /// @notice THE TEST THIS EXERCISE IS FOR.
    ///
    /// @dev Against the pre-fix contract this cannot even compile — there is no `attestFromPool`,
    /// no `attestedPermissions`, no `PermissionSource`. Against this one, one permissionless call
    /// against the live pool replaces the hook's account of itself with core's, and the record
    /// stops saying `Passive`.
    function test_attestation_catchesTheSpoof() public {
        TwoFacedHook hook = new TwoFacedHook(address(registry), TAME, SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));
        bytes32 poolId = _initCL(address(hook), SWAP_TAX);

        // Before: the marketplace would show "Passive".
        (uint16 before_, PermissionSource sourceBefore) = registry.effectivePermissions(address(hook));
        assertEq(before_, TAME);
        assertEq(uint8(sourceBefore), uint8(PermissionSource.SelfReported));
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.Passive));
        assertFalse(registry.takesSwapCut(before_));

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCorePoolAttested(
            address(hook), address(this), address(clManager), poolId, SWAP_TAX, SWAP_TAX, TAME, 1
        );
        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCorePermissionsUnderstated(address(hook), TAME, SWAP_TAX, SWAP_TAX & ~TAME);

        // Permissionless: no role, not the submitter, not the hook's deployer.
        registry.attestFromPool(address(hook), address(clManager), poolId);

        (uint16 after_, PermissionSource sourceAfter) = registry.effectivePermissions(address(hook));
        assertEq(after_, TAME | SWAP_TAX, "the union, so nothing observed can be lost");
        assertEq(uint8(sourceAfter), uint8(PermissionSource.PoolAttestedDivergent), "divergence is visible");
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.ValueExtracting));
        assertTrue(registry.takesSwapCut(after_), "the swap cut is now on the record");
        assertEq(registry.permissionsConcealed(address(hook)), SWAP_TAX & ~TAME, "exactly what was kept back");

        // The self-report is retained, unaltered, so the two can be shown side by side.
        assertEq(registry.selfReportedPermissionsOf(address(hook)), TAME);
    }

    /// @notice The gas-branch variant is caught by the same call, for the same reason.
    function test_attestation_catchesTheGasBranchSpoof() public {
        GasBranchHook hook = new GasBranchHook(150_000, TAME, SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));
        bytes32 poolId = _initCL(address(hook), SWAP_TAX);

        registry.attestFromPool(address(hook), address(clManager), poolId);

        (uint16 effective, PermissionSource source) = registry.effectivePermissions(address(hook));
        assertEq(effective, TAME | SWAP_TAX);
        assertEq(uint8(source), uint8(PermissionSource.PoolAttestedDivergent));
    }

    /// @notice An honest hook attests clean. The mechanism must not punish the common case.
    function test_attestation_honestHookIsUnaffected() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));
        bytes32 poolId = _initCL(address(hook), SWAP_TAX);

        registry.attestFromPool(address(hook), address(clManager), poolId);

        (uint16 effective, PermissionSource source) = registry.effectivePermissions(address(hook));
        assertEq(effective, SWAP_TAX);
        assertEq(uint8(source), uint8(PermissionSource.PoolAttested), "agrees, so no divergence flag");
        assertEq(registry.permissionsConcealed(address(hook)), 0);
    }

    /*//////////////////////////////////////////////////////////////
        3. THE BADGE — WHAT A CURATOR CAN AND CANNOT DO
    //////////////////////////////////////////////////////////////*/

    /// @notice A curator cannot badge a record no pool has corroborated.
    /// @dev Pre-fix, this is exactly how the spoof gets laundered: an official `Audited · Passive`
    /// over a hook taking a delta on every swap, with the registry's own logo next to it.
    function test_badge_refusedWithoutAnAttestation() public {
        TwoFacedHook hook = new TwoFacedHook(address(registry), TAME, SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta("ipfs://audit"));

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.AttestationRequired.selector, address(hook)));
        vm.prank(curator);
        registry.setVerification(address(hook), Verification.Audited, "looks passive to me");

        // Not even the bottom rung.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.AttestationRequired.selector, address(hook)));
        vm.prank(curator);
        registry.setVerification(address(hook), Verification.SourceVerified, "");

        assertFalse(registry.isAudited(address(hook)));
    }

    /// @notice And once it IS attested, the curator sees the real bitmap before deciding.
    /// @dev The fix does not stop a curator badging a value-extracting hook — that is a legitimate
    /// thing to do, and plenty of useful hooks take a cut. It stops them doing it while the record
    /// says `Passive`.
    function test_badge_allowedOnceAttestedAndTheClassIsHonest() public {
        TwoFacedHook hook = new TwoFacedHook(address(registry), TAME, SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta("ipfs://audit"));
        bytes32 poolId = _initCL(address(hook), SWAP_TAX);
        registry.attestFromPool(address(hook), address(clManager), poolId);

        vm.prank(curator);
        registry.setVerification(address(hook), Verification.Audited, "audited; takes 30bps, disclosed");

        assertTrue(registry.isAudited(address(hook)));
        (RiskClass class, PermissionSource source, uint32 count) = registry.riskAssessmentOf(address(hook));
        assertEq(uint8(class), uint8(RiskClass.ValueExtracting), "the badge sits next to the truth");
        assertEq(uint8(source), uint8(PermissionSource.PoolAttestedDivergent));
        assertEq(count, 1);
    }

    /// @notice A later attestation that reveals NEW capability strips the badge.
    /// @dev Same rule as `refreshPermissions`: an audit covers a set of capabilities, and a
    /// capability nobody had seen when it was granted is outside that set. Driven entirely by an
    /// immutable on-chain fact, so it is not griefable — and it fires at most once per genuinely
    /// new bitmap, of which there are at most fourteen bits' worth.
    function test_badge_strippedWhenALaterPoolRevealsMore() public {
        // Tells the registry and the CL manager the same tame story; tells the Bin manager the
        // truth, because that is the pool it actually wanted.
        PerCallerBitmapHook hook = new PerCallerBitmapHook(PERM_AFTER_SWAP);
        hook.setFor(address(binManager), SWAP_TAX);

        vm.prank(alice);
        registry.register(address(hook), _meta("ipfs://audit"));
        bytes32 clPool = _initCL(address(hook), PERM_AFTER_SWAP);
        registry.attestFromPool(address(hook), address(clManager), clPool);

        vm.prank(curator);
        registry.setVerification(address(hook), Verification.Audited, "passive, per the CL pool");
        assertTrue(registry.isAudited(address(hook)));

        bytes32 binPool = _initBin(address(hook), SWAP_TAX);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreVerificationChanged(
            address(hook),
            address(this),
            Verification.Audited,
            Verification.Unverified,
            "a live pool revealed permissions not covered by this attestation"
        );
        registry.attestFromPool(address(hook), address(binManager), binPool);

        assertFalse(registry.isAudited(address(hook)), "the badge did not cover the Bin pool");
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.ValueExtracting));
        assertEq(registry.getDeepCore(address(hook)).attestedPermissions, PERM_AFTER_SWAP | SWAP_TAX);
    }

    /// @notice An attestation that re-confirms what is already known must NOT cost a badge.
    /// @dev The other half of the rule. If any attestation demoted, the demotion would be a grief
    /// vector: anyone could strip an honest audit by re-attesting a pool the curator already saw.
    function test_badge_survivesAnAttestationThatAddsNothing() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta("ipfs://audit"));
        bytes32 clPool = _initCL(address(hook), SWAP_TAX);
        registry.attestFromPool(address(hook), address(clManager), clPool);

        vm.prank(curator);
        registry.setVerification(address(hook), Verification.Audited, "");

        // A second, distinct pool with the identical bitmap. New pool, no new capability.
        bytes32 binPool = _initBin(address(hook), SWAP_TAX);
        registry.attestFromPool(address(hook), address(binManager), binPool);

        assertTrue(registry.isAudited(address(hook)), "no new bits, no demotion");
        assertEq(registry.getDeepCore(address(hook)).attestationCount, 2);
    }

    /*//////////////////////////////////////////////////////////////
        4. BOTH POOL TYPES, AND THE SHAPE TRAP THAT ISN'T ONE
    //////////////////////////////////////////////////////////////*/

    /// @notice CL and Bin managers return DIFFERENT shapes from `getSlot0` — four fields versus
    /// three, `uint160 sqrtPriceX96` versus `uint24 activeId`. Reading initialization through
    /// `getSlot0` would need a per-type branch and a per-type ABI, which is the same class of trap
    /// the keeper hit with `getEpoch`.
    ///
    /// `poolIdToPoolKey` is on the SHARED `IPoolManager` interface with one shape for both, and
    /// core writes it inside `initialize` immediately after `validateHookConfig`. So there is no
    /// branch to get wrong. This test is the proof: identical code path, both managers.
    function test_bothPoolTypes_shareOneCodePath() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        bytes32 clPool = _initCL(address(hook), SWAP_TAX);
        registry.attestFromPool(address(hook), address(clManager), clPool);
        assertEq(registry.getDeepCore(address(hook)).attestationCount, 1);

        bytes32 binPool = _initBin(address(hook), SWAP_TAX);
        registry.attestFromPool(address(hook), address(binManager), binPool);

        DeepCoreRecord memory r = registry.getDeepCore(address(hook));
        assertEq(r.attestationCount, 2, "distinct pools, both counted");
        assertEq(r.attestedPoolManager, address(binManager), "most recent wins the link");
        assertEq(r.attestedPoolId, binPool);
        assertEq(r.attestedPermissions, SWAP_TAX);
    }

    /// @notice A hook can honestly present two different bitmaps to two pool types. The union is
    /// the only summary that cannot understate.
    function test_bothPoolTypes_unionAcrossDifferentBitmaps() public {
        // Reports the CL bitmap to the registry; the Bin pool below uses a different one.
        HonestHook hook = new HonestHook(PERM_AFTER_SWAP);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        bytes32 clPool = _initCL(address(hook), PERM_AFTER_SWAP);
        registry.attestFromPool(address(hook), address(clManager), clPool);
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.Passive));

        // The hook cannot be made to serve a Bin pool with a bitmap it will not answer with —
        // core would reject it. So use a second hook that does, to model the two-faced case where
        // both faces are real.
        TwoFacedHook twoFaced = new TwoFacedHook(address(registry), PERM_AFTER_SWAP, SWAP_TAX);
        vm.prank(alice);
        registry.register(address(twoFaced), _meta(""));

        bytes32 binPool = _initBin(address(twoFaced), SWAP_TAX);
        registry.attestFromPool(address(twoFaced), address(binManager), binPool);

        (uint16 effective,) = registry.effectivePermissions(address(twoFaced));
        assertEq(effective, PERM_AFTER_SWAP | SWAP_TAX, "union of everything observed");
        assertEq(uint8(registry.riskClassOf(address(twoFaced))), uint8(RiskClass.ValueExtracting));
    }

    /*//////////////////////////////////////////////////////////////
        5. THE ATTESTATION CANNOT BE FAKED
    //////////////////////////////////////////////////////////////*/

    /// @notice A pool that runs a different hook cannot vouch for this one.
    function test_reject_poolRunsADifferentHook() public {
        HonestHook victim = new HonestHook(SWAP_TAX);
        HonestHook other = new HonestHook(PERM_AFTER_SWAP);
        vm.prank(alice);
        registry.register(address(victim), _meta(""));

        bytes32 otherPool = _initCL(address(other), PERM_AFTER_SWAP);

        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreRegistry.PoolHookMismatch.selector, otherPool, address(victim), address(other))
        );
        registry.attestFromPool(address(victim), address(clManager), otherPool);
    }

    /// @notice An id nobody initialized resolves to the zero key, whose `hooks` is `address(0)`.
    function test_reject_poolThatDoesNotExist() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        bytes32 ghost = keccak256("no such pool");
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(clManager), ghost));
        registry.attestFromPool(address(hook), address(clManager), ghost);
    }

    /// @notice The same pool cannot be attested twice, so `attestationCount` means what it says.
    function test_reject_duplicateAttestation() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));
        bytes32 poolId = _initCL(address(hook), SWAP_TAX);

        registry.attestFromPool(address(hook), address(clManager), poolId);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolAlreadyAttested.selector, address(hook), poolId));
        registry.attestFromPool(address(hook), address(clManager), poolId);
    }

    /// @notice A pool manager the Vault does not know is not a witness.
    /// @dev The attacker's version of this is a contract of their own that answers
    /// `poolIdToPoolKey` with whatever they like. `Vault.registerApp` is `onlyOwner` on the 48h
    /// custody timelock, so getting one enrolled is not a step an attacker has available.
    function test_reject_unregisteredPoolManager() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        CLPoolManager rogue = new CLPoolManager(IVault(address(vault)));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x11)),
            currency1: Currency.wrap(address(0x22)),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(rogue)),
            fee: 3000,
            parameters: _clParams(SWAP_TAX)
        });
        rogue.initialize(key, SQRT_PRICE_1_1);
        bytes32 poolId = PoolId.unwrap(key.toId());

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.UntrustedPoolManager.selector, address(rogue)));
        registry.attestFromPool(address(hook), address(rogue), poolId);

        // Enrol it the way the protocol actually does, and the same call now works. This is the
        // whole trust model in two lines.
        vault.registerApp(address(rogue));
        registry.attestFromPool(address(hook), address(rogue), poolId);
        assertEq(registry.getDeepCore(address(hook)).attestedPermissions, SWAP_TAX);
    }

    /// @notice `attestFromPoolKey` accepts a key, but only to derive the id.
    function test_attestFromPoolKey_worksAndCannotBeDoctored() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        PoolKey memory key = _clKey(address(hook), SWAP_TAX);
        clManager.initialize(key, SQRT_PRICE_1_1);

        // Honest key: resolves and attests.
        registry.attestFromPoolKey(address(hook), key);
        assertEq(registry.getDeepCore(address(hook)).attestedPermissions, SWAP_TAX);

        // Doctored key claiming a tamer bitmap: hashes to a different id, which resolves to
        // nothing. There is no path here that records the caller's numbers.
        PoolKey memory lie = key;
        lie.parameters = _clParams(TAME);
        bytes32 lieId = PoolId.unwrap(lie.toId());
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PoolNotFound.selector, address(clManager), lieId));
        registry.attestFromPoolKey(address(hook), lie);
    }

    /*//////////////////////////////////////////////////////////////
        6. INVARIANT: ATTESTATION NEVER MAKES A RECORD LOOK MILDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Whatever a hook reports and whatever pools exist, the effective bitmap is a
    /// superset of both sources and the risk class never falls below either.
    /// @dev The permissionless-caller argument rests on this. If any sequence of attestations
    /// could drop a bit, `attestFromPool` would need a role.
    function testFuzz_attestationOnlyEverAddsBits(uint16 reportedRaw, uint16 poolRaw) public {
        uint16 reported = _sanitize(reportedRaw);
        uint16 poolBitmap = _sanitize(poolRaw);

        TwoFacedHook hook = new TwoFacedHook(address(registry), reported, poolBitmap);
        vm.prank(alice);
        registry.register(address(hook), _meta(""));

        (uint16 before_,) = registry.effectivePermissions(address(hook));
        assertEq(before_, reported);
        RiskClass classBefore = registry.riskClassOf(address(hook));

        bytes32 poolId = _initCL(address(hook), poolBitmap);
        registry.attestFromPool(address(hook), address(clManager), poolId);

        (uint16 after_, PermissionSource source) = registry.effectivePermissions(address(hook));
        assertEq(after_, reported | poolBitmap, "union");
        assertEq(after_ & before_, before_, "superset: no bit was dropped");
        assertTrue(uint8(registry.riskClassOf(address(hook))) >= uint8(classBefore), "risk class never falls");
        assertEq(
            uint8(source),
            uint8(
                (poolBitmap & ~reported) != 0 ? PermissionSource.PoolAttestedDivergent : PermissionSource.PoolAttested
            ),
            "divergence flag agrees with the bits"
        );
    }

    /// @dev Turn a fuzz word into a bitmap core will accept, matching `_dependenciesSatisfied`.
    ///
    /// Bits 0 and 1 (`beforeInitialize` / `afterInitialize`) are cleared. They are the only two
    /// core actually dispatches during `initialize`, so leaving them set would require the mock
    /// hooks to implement both callbacks and return the right selector — for both pool types, with
    /// different signatures. The property under test is arithmetic over the bitmap and is
    /// independent of which callbacks exist, and bits 2-13 are never called at initialization.
    function _sanitize(uint16 raw) internal pure returns (uint16 p) {
        p = raw & 0x3FFC;
        if (p & (uint16(1) << 10) != 0) p |= uint16(1) << 6;
        if (p & (uint16(1) << 11) != 0) p |= uint16(1) << 7;
        if (p & (uint16(1) << 12) != 0) p |= uint16(1) << 3;
        if (p & (uint16(1) << 13) != 0) p |= uint16(1) << 5;
    }
}
