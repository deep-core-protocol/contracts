// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreRegistry} from "../src/DeepCoreRegistry.sol";
import {
    IDeepCoreRegistry,
    DeepCoreMetadata,
    DeepCoreRecord,
    DecodedPermissions,
    Verification,
    Listing,
    PermissionSource,
    RiskClass,
    PERM_BEFORE_INITIALIZE,
    PERM_AFTER_INITIALIZE,
    PERM_BEFORE_ADD_LIQUIDITY,
    PERM_AFTER_ADD_LIQUIDITY,
    PERM_BEFORE_REMOVE_LIQUIDITY,
    PERM_AFTER_REMOVE_LIQUIDITY,
    PERM_BEFORE_SWAP,
    PERM_AFTER_SWAP,
    PERM_BEFORE_DONATE,
    PERM_AFTER_DONATE,
    PERM_BEFORE_SWAP_RETURNS_DELTA,
    PERM_AFTER_SWAP_RETURNS_DELTA,
    PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA,
    PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA,
    PERM_ALL_ASSIGNED,
    PERM_RETURNS_DELTA_MASK,
    PERM_SWAP_CUT_MASK,
    PERM_BEFORE_MASK
} from "../src/IDeepCoreRegistry.sol";

import {
    HonestHook,
    MutableHook,
    RevertingHook,
    SilentRevertHook,
    GasBurnerHook,
    GasBurnThenRevertHook,
    DirtyWordHook,
    ShortReturnHook,
    EmptyReturnHook,
    ReturnBombHook,
    RawButHonestHook,
    NoBitmapHook,
    ReentrantHook,
    TwoFacedHook,
    GasBranchHook
} from "./mocks/MockHooks.sol";
import {MockVault, MockPoolManager, NotAPoolManager} from "./mocks/MockPools.sol";

contract DeepCoreRegistryTest is Test {
    DeepCoreRegistry internal registry;
    MockVault internal vault;
    MockPoolManager internal poolManager;

    address internal timelock = address(0x71E10);
    address internal curator = address(0xC0A70);
    address internal guardian = address(0x69A2D);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stranger = address(0x57A6E);

    /// @dev A tame, honest hook: afterSwap only. Passive.
    uint16 internal constant TAME = PERM_AFTER_SWAP;

    /// @dev The bitmap this registry exists to make impossible to miss: takes a cut of every swap.
    uint16 internal constant SWAP_TAX = PERM_BEFORE_SWAP | PERM_BEFORE_SWAP_RETURNS_DELTA;

    function setUp() public {
        address[] memory curators = new address[](1);
        curators[0] = curator;
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        vault = new MockVault();
        poolManager = new MockPoolManager();
        vault.registerApp(address(poolManager));
        registry = new DeepCoreRegistry(timelock, address(vault), curators, guardians);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _meta() internal pure returns (DeepCoreMetadata memory) {
        return _meta("Dynamic Fee Hook", "ipfs://source", "");
    }

    function _meta(string memory name, string memory sourceURI, string memory auditURI)
        internal
        pure
        returns (DeepCoreMetadata memory m)
    {
        uint256[] memory chains = new uint256[](2);
        chains[0] = 1;
        chains[1] = 56;
        m = DeepCoreMetadata({
            name: name,
            description: "Adjusts the LP fee with realised volatility.",
            sourceURI: sourceURI,
            auditURI: auditURI,
            chainIds: chains
        });
    }

    /// @dev Register AND attest against a live pool that enforces exactly what the hook reported.
    /// Most tests here predate attestation and care about something else; this keeps them in the
    /// corroborated state that a real listing reaches as soon as its pool exists. Tests that are
    /// specifically about the UNattested state use `_registerOnly`.
    function _register(address who, address hook) internal {
        _registerOnly(who, hook);
        _attest(hook);
    }

    function _registerFull(address who, address hook, string memory source, string memory audit) internal {
        _registerOnlyFull(who, hook, source, audit);
        _attest(hook);
    }

    function _registerOnly(address who, address hook) internal {
        vm.prank(who);
        registry.register(hook, _meta());
    }

    function _registerOnlyFull(address who, address hook, string memory source, string memory audit) internal {
        vm.prank(who);
        registry.register(hook, _meta("Hook", source, audit));
    }

    /// @dev Distinct currencies per pool so every helper-built pool gets its own id.
    uint160 internal _poolNonce;

    function _poolKey(address hook, uint16 bitmap) internal returns (PoolKey memory key) {
        _poolNonce += 1;
        key = PoolKey({
            currency0: Currency.wrap(address(_poolNonce)),
            currency1: Currency.wrap(address(_poolNonce + 0x1000)),
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(poolManager)),
            fee: 3000,
            // [0-16) hooks bitmap, [16-40) tickSpacing. Same layout core uses.
            parameters: bytes32(uint256(bitmap) | (uint256(60) << 16))
        });
    }

    /// @dev File a pool enforcing `bitmap` for `hook` and attest it.
    function _attestWith(address hook, uint16 bitmap) internal returns (bytes32 poolId) {
        poolId = poolManager.setPool(_poolKey(hook, bitmap));
        registry.attestFromPool(hook, address(poolManager), poolId);
    }

    /// @dev Attest a pool that agrees with whatever the hook told the registry.
    function _attest(address hook) internal returns (bytes32) {
        return _attestWith(hook, registry.selfReportedPermissionsOf(hook));
    }

    /// @dev Drive a hook all the way to Audited/Active.
    function _makeAudited(address hook) internal {
        _registerFull(alice, hook, "ipfs://src", "ipfs://audit");
        vm.prank(curator);
        registry.setVerification(hook, Verification.Audited, "reviewed by X");
        assertEq(uint8(registry.getDeepCore(hook).verification), uint8(Verification.Audited));
    }

    /// @dev Turn an arbitrary fuzz word into a bitmap core would accept.
    function _sanitize(uint16 raw) internal pure returns (uint16 p) {
        p = raw & PERM_ALL_ASSIGNED;
        if (p & PERM_BEFORE_SWAP_RETURNS_DELTA != 0) p |= PERM_BEFORE_SWAP;
        if (p & PERM_AFTER_SWAP_RETURNS_DELTA != 0) p |= PERM_AFTER_SWAP;
        if (p & PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA != 0) p |= PERM_AFTER_ADD_LIQUIDITY;
        if (p & PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA != 0) p |= PERM_AFTER_REMOVE_LIQUIDITY;
    }

    function _callRegister(address hook, uint256 gasCap) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(registry).call{gas: gasCap}(abi.encodeCall(DeepCoreRegistry.register, (hook, _meta())));
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4) {
        if (ret.length < 4) return bytes4(0);
        return bytes4(ret);
    }

    /*//////////////////////////////////////////////////////////////
                             HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_register_recordsEverything() public {
        address hook = address(new HonestHook(SWAP_TAX));

        vm.prank(alice);
        registry.register(hook, _meta("Fee Skimmer", "ipfs://src", "ipfs://audit"));

        DeepCoreRecord memory r = registry.getDeepCore(hook);
        assertEq(r.submitter, alice, "submitter");
        assertEq(r.steward, alice, "steward defaults to submitter");
        assertEq(r.submittedAt, uint64(block.timestamp), "submittedAt");
        assertEq(r.updatedAt, uint64(block.timestamp), "updatedAt");
        assertEq(r.permissions, SWAP_TAX, "permissions read from chain");
        assertTrue(r.permissionsValid, "valid");
        assertTrue(r.permissionsReadable, "readable");
        assertEq(uint8(r.verification), uint8(Verification.Unverified), "enters unverified");
        assertEq(uint8(r.listing), uint8(Listing.Active), "enters active");
        assertEq(r.codehash, hook.codehash, "codehash snapshot");
        assertEq(r.metadata.name, "Fee Skimmer");
        assertEq(r.metadata.sourceURI, "ipfs://src");
        assertEq(r.metadata.auditURI, "ipfs://audit");
        assertEq(r.metadata.chainIds.length, 2);
        assertEq(r.metadata.chainIds[1], 56);

        assertTrue(registry.isRegistered(hook));
        assertEq(registry.deepcoreCount(), 1);
        assertEq(registry.deepcoreAt(0), hook);
        assertEq(registry.submittedCount(alice), 1);
    }

    /// @notice Everything an indexer needs must be in the logs, including the initial metadata.
    function test_register_emitsRebuildableEvents() public {
        address hook = address(new HonestHook(TAME));
        DeepCoreMetadata memory m = _meta("Vol Oracle", "ipfs://src", "");

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreRegistered(
            hook, alice, TAME, RiskClass.Passive, hook.codehash, uint64(block.timestamp)
        );
        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreMetadataUpdated(
            hook, alice, m.name, m.description, m.sourceURI, m.auditURI, m.chainIds
        );

        vm.prank(alice);
        registry.register(hook, m);
    }

    function test_register_isFreeAndUngated() public {
        // No value sent, no role held, not the hook's deployer: still works.
        address hook = address(new HonestHook(TAME));
        vm.prank(stranger);
        registry.register(hook, _meta());
        assertTrue(registry.isRegistered(hook));
        assertEq(address(registry).balance, 0, "registry must never hold a listing fee");
    }

    function test_register_duplicateRejected() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreAlreadyRegistered.selector, hook));
        vm.prank(bob);
        registry.register(hook, _meta());
    }

    function test_register_zeroAddressRejected() public {
        vm.expectRevert(IDeepCoreRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.register(address(0), _meta());
    }

    function test_register_eoaRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreHasNoCode.selector, bob));
        vm.prank(alice);
        registry.register(bob, _meta());
    }

    function test_register_emptyNameRejected() public {
        address hook = address(new HonestHook(TAME));
        vm.expectRevert(IDeepCoreRegistry.EmptyName.selector);
        vm.prank(alice);
        registry.register(hook, _meta("", "ipfs://src", ""));
    }

    function test_register_oversizeMetadataRejected() public {
        address hook = address(new HonestHook(TAME));
        string memory tooLong = new string(65);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.StringTooLong.selector, 65, 64));
        vm.prank(alice);
        registry.register(hook, _meta(tooLong, "ipfs://src", ""));
    }

    function test_register_tooManyChainsRejected() public {
        address hook = address(new HonestHook(TAME));
        DeepCoreMetadata memory m = _meta();
        m.chainIds = new uint256[](33);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.TooManyChains.selector, 33, 32));
        vm.prank(alice);
        registry.register(hook, m);
    }

    /*//////////////////////////////////////////////////////////////
        THE CORE INVARIANT — PERMISSIONS COME FROM THE HOOK
    //////////////////////////////////////////////////////////////*/

    /// @notice There is no submitter-supplied permissions field anywhere in the API. The value
    /// stored always equals what the hook itself reports, whatever the submitter writes in the
    /// description. This is the whole attack the registry exists to prevent.
    function test_permissions_cannotBeInfluencedBySubmitter() public {
        address hook = address(new HonestHook(SWAP_TAX));
        DeepCoreMetadata memory lie = _meta();
        lie.description = "Completely passive, holds no permissions, cannot touch your funds.";

        vm.prank(alice);
        registry.register(hook, lie);

        (uint16 permissions,,,) = registry.permissionsOf(hook);
        assertEq(permissions, SWAP_TAX, "chain, not the submitter, decides");
        assertEq(uint8(registry.riskClassOf(hook)), uint8(RiskClass.ValueExtracting));
        assertTrue(registry.takesSwapCut(permissions), "bit 10 must surface as a swap cut");
    }

    function test_permissions_reservedBitsRejected() public {
        uint16 bad = TAME | uint16(1 << 14);
        address hook = address(new HonestHook(bad));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.ReservedBitsSet.selector, bad));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_permissions_reservedBit15Rejected() public {
        uint16 bad = TAME | uint16(1 << 15);
        address hook = address(new HonestHook(bad));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.ReservedBitsSet.selector, bad));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_permissions_returnsDeltaWithoutBaseRejected() public {
        uint16 bad = PERM_BEFORE_SWAP_RETURNS_DELTA; // no beforeSwap
        address hook = address(new HonestHook(bad));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionDependencyMissing.selector, bad));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_permissions_allFourDeltaDependenciesEnforced() public view {
        uint16[4] memory orphans = [
            PERM_BEFORE_SWAP_RETURNS_DELTA,
            PERM_AFTER_SWAP_RETURNS_DELTA,
            PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA,
            PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA
        ];
        uint16[4] memory bases =
            [PERM_BEFORE_SWAP, PERM_AFTER_SWAP, PERM_AFTER_ADD_LIQUIDITY, PERM_AFTER_REMOVE_LIQUIDITY];
        for (uint256 i; i < 4; ++i) {
            assertFalse(registry.isValidBitmap(orphans[i]), "orphan delta bit must be invalid");
            assertTrue(registry.isValidBitmap(orphans[i] | bases[i]), "paired must be valid");
        }
    }

    function test_permissions_decode() public view {
        DecodedPermissions memory d = registry.decodePermissions(SWAP_TAX);
        assertTrue(d.beforeSwap);
        assertTrue(d.beforeSwapReturnsDelta);
        assertFalse(d.afterSwap);
        assertFalse(d.afterSwapReturnsDelta);
        assertFalse(d.beforeRemoveLiquidity);
    }

    function test_classify_theThreeClasses() public view {
        assertEq(uint8(registry.classify(0)), uint8(RiskClass.Passive));
        assertEq(uint8(registry.classify(PERM_AFTER_SWAP | PERM_AFTER_DONATE)), uint8(RiskClass.Passive));
        assertEq(uint8(registry.classify(PERM_BEFORE_SWAP)), uint8(RiskClass.Restrictive));
        assertEq(uint8(registry.classify(PERM_BEFORE_INITIALIZE)), uint8(RiskClass.Restrictive));
        assertEq(uint8(registry.classify(SWAP_TAX)), uint8(RiskClass.ValueExtracting));
        assertEq(
            uint8(registry.classify(PERM_AFTER_SWAP | PERM_AFTER_SWAP_RETURNS_DELTA)),
            uint8(RiskClass.ValueExtracting),
            "bit 11 takes a cut of every swap"
        );
        assertEq(
            uint8(registry.classify(PERM_BEFORE_REMOVE_LIQUIDITY)),
            uint8(RiskClass.ValueExtracting),
            "refusing withdrawals strands funds just as surely as taking them"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            HOSTILE HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_hostile_revertingHook() public {
        address hook = address(new RevertingHook());
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_hostile_silentRevert() public {
        address hook = address(new SilentRevertHook());
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_hostile_noSuchFunction() public {
        address hook = address(new NoBitmapHook());
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_hostile_emptyReturn() public {
        address hook = address(new EmptyReturnHook());
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_hostile_shortReturn() public {
        address hook = address(new ShortReturnHook());
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    /// @notice The low 16 bits look like `afterSwap`. The word does not fit a uint16, so solc's own
    /// decoder would reject it and so do we — a hook must not be able to look tame here and behave
    /// differently at the pool manager.
    function test_hostile_dirtyHighBits() public {
        address hook = address(new DirtyWordHook((uint256(1) << 200) | uint256(PERM_AFTER_SWAP)));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    function test_hostile_maxUintReturn() public {
        address hook = address(new DirtyWordHook(type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    /// @notice A clean uint16 delivered by raw assembly is fine. We reject malformed returns, not
    /// unusual implementations.
    function test_hostile_rawButHonestAccepted() public {
        address hook = address(new RawButHonestHook(TAME));
        _register(alice, hook);
        (uint16 p,,,) = registry.permissionsOf(hook);
        assertEq(p, TAME);
    }

    function test_hostile_returnBombIsRejectedCheaply() public {
        address hook = address(new ReturnBombHook());

        uint256 before = gasleft();
        (bool ok, bytes memory ret) = _callRegister(hook, gasleft() - 20_000);
        uint256 used = before - gasleft();

        assertFalse(ok, "32KB of return data is not a uint16");
        assertEq(_selectorOf(ret), IDeepCoreRegistry.PermissionsUnreadable.selector);
        assertLt(used, 300_000, "outsize is pinned at 32 bytes, so we never pay to copy the bomb");
    }

    /// @notice The headline defence. An infinite loop in the callee costs the caller the probe
    /// budget and nothing more, instead of the entire block gas limit.
    function test_hostile_gasBurnerIsBounded() public {
        address hook = address(new GasBurnerHook());

        uint256 before = gasleft();
        (bool ok, bytes memory ret) = _callRegister(hook, gasleft() - 20_000);
        uint256 used = before - gasleft();

        assertFalse(ok);
        assertEq(_selectorOf(ret), IDeepCoreRegistry.PermissionsUnreadable.selector);
        assertLt(used, 300_000, "a non-terminating hook must not be able to drain the caller");
        assertGt(used, registry.PROBE_GAS() / 2, "sanity: the probe really did run");
    }

    function test_hostile_gasBurnThenRevertIsBounded() public {
        address hook = address(new GasBurnThenRevertHook());

        uint256 before = gasleft();
        (bool ok,) = _callRegister(hook, gasleft() - 20_000);
        uint256 used = before - gasleft();

        assertFalse(ok);
        assertLt(used, 300_000);
    }

    /// @notice THE property that matters: one hostile hook must not be able to stop anyone else
    /// from listing. Registration touches no shared state before the probe, so a failed probe
    /// leaves the registry byte-identical.
    function test_hostile_cannotBrickTheRegistryForOthers() public {
        address burner = address(new GasBurnerHook());
        address reverter = address(new RevertingHook());
        address bomb = address(new ReturnBombHook());
        address good = address(new HonestHook(TAME));

        _callRegister(burner, gasleft() - 20_000);
        _callRegister(reverter, gasleft() - 20_000);
        _callRegister(bomb, gasleft() - 20_000);

        assertEq(registry.deepcoreCount(), 0, "no failed probe may leave a trace");
        assertFalse(registry.isRegistered(burner));

        _register(bob, good);
        assertEq(registry.deepcoreCount(), 1, "honest registration is unaffected");
        assertEq(registry.deepcoreAt(0), good);

        // And still unaffected after another round of hostility.
        _callRegister(burner, gasleft() - 20_000);
        address good2 = address(new HonestHook(PERM_BEFORE_SWAP));
        _register(alice, good2);
        assertEq(registry.deepcoreCount(), 2);
    }

    /// @notice An honest registration and a hostile one must cost the same order of magnitude.
    function test_hostile_gasIsComparableToHonestPath() public {
        address good = address(new HonestHook(TAME));
        uint256 g0 = gasleft();
        _register(alice, good);
        uint256 honestCost = g0 - gasleft();

        address burner = address(new GasBurnerHook());
        uint256 g1 = gasleft();
        _callRegister(burner, gasleft() - 20_000);
        uint256 hostileCost = g1 - gasleft();

        assertLt(hostileCost, honestCost + registry.PROBE_GAS() + 50_000, "bounded overhead");
    }

    /// @notice The probe is a staticcall, so a hook cannot reenter and write anything.
    function test_hostile_probeCannotReenter() public {
        ReentrantHook hook = new ReentrantHook();
        address victim = address(new HonestHook(TAME));
        hook.arm(address(registry), abi.encodeCall(DeepCoreRegistry.register, (victim, _meta())));

        _register(alice, address(hook));

        assertEq(registry.deepcoreCount(), 1, "the reentrant register must not have landed");
        assertFalse(registry.isRegistered(victim));
    }

    /// @notice Starving the frame must not produce a verdict. Without this floor, anyone could
    /// hand-tune gas so an honest hook reports as unreadable.
    function test_hostile_gasStarvationIsRejectedNotRecorded() public {
        address hook = address(new HonestHook(TAME));

        (bool ok, bytes memory ret) = _callRegister(hook, 120_000);
        assertFalse(ok, "below the probe floor");
        assertEq(_selectorOf(ret), IDeepCoreRegistry.InsufficientGasForProbe.selector);
        assertFalse(registry.isRegistered(hook), "nothing recorded");

        // Same hook, adequate gas: registers fine.
        _register(alice, hook);
        assertTrue(registry.isRegistered(hook));
    }

    function test_hostile_gasStarvationCannotDemoteAnAuditedHook() public {
        MutableHook hook = new MutableHook(TAME);
        _makeAudited(address(hook));

        (bool ok, bytes memory ret) =
            address(registry).call{gas: 120_000}(abi.encodeCall(DeepCoreRegistry.refreshPermissions, (address(hook))));
        assertFalse(ok);
        assertEq(_selectorOf(ret), IDeepCoreRegistry.InsufficientGasForProbe.selector);
        assertEq(
            uint8(registry.getDeepCore(address(hook)).verification),
            uint8(Verification.Audited),
            "a starved caller must not be able to strip an audit"
        );
    }

    /*//////////////////////////////////////////////////////////////
                   VERIFICATION LADDER — AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function test_promotion_requiresCurator() public {
        address hook = address(new HonestHook(TAME));
        _registerFull(alice, hook, "ipfs://src", "ipfs://audit");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.CURATOR_ROLE()
            )
        );
        vm.prank(alice);
        registry.setVerification(hook, Verification.Audited, "");
    }

    /// @notice The submitter cannot promote themselves even though they steward the listing.
    function test_promotion_submitterCannotSelfAttest() public {
        address hook = address(new HonestHook(SWAP_TAX));
        _registerFull(alice, hook, "ipfs://src", "ipfs://audit");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.CURATOR_ROLE()
            )
        );
        vm.prank(alice);
        registry.setVerification(hook, Verification.SourceVerified, "trust me");

        assertFalse(registry.isAudited(hook));
        assertEq(uint8(registry.getDeepCore(hook).verification), uint8(Verification.Unverified));
    }

    function test_promotion_guardianCannotPromote() public {
        address hook = address(new HonestHook(TAME));
        _registerFull(alice, hook, "ipfs://src", "ipfs://audit");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, registry.CURATOR_ROLE()
            )
        );
        vm.prank(guardian);
        registry.setVerification(hook, Verification.Audited, "");
    }

    function test_promotion_ladderWorks() public {
        address hook = address(new HonestHook(TAME));
        _registerFull(alice, hook, "ipfs://src", "ipfs://audit");

        vm.prank(curator);
        registry.setVerification(hook, Verification.SourceVerified, "source matches bytecode");
        assertEq(uint8(registry.getDeepCore(hook).verification), uint8(Verification.SourceVerified));
        assertFalse(registry.isAudited(hook));

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreVerificationChanged(
            hook, curator, Verification.SourceVerified, Verification.Audited, "report checked"
        );
        vm.prank(curator);
        registry.setVerification(hook, Verification.Audited, "report checked");
        assertTrue(registry.isAudited(hook));
    }

    function test_promotion_sourceVerifiedRequiresSourceURI() public {
        address hook = address(new HonestHook(TAME));
        _registerFull(alice, hook, "", "");
        vm.expectRevert(IDeepCoreRegistry.SourceURIRequired.selector);
        vm.prank(curator);
        registry.setVerification(hook, Verification.SourceVerified, "");
    }

    function test_promotion_auditedRequiresAuditURI() public {
        address hook = address(new HonestHook(TAME));
        _registerFull(alice, hook, "ipfs://src", "");
        vm.expectRevert(IDeepCoreRegistry.AuditURIRequired.selector);
        vm.prank(curator);
        registry.setVerification(hook, Verification.Audited, "");
    }

    function test_promotion_blockedWhileFlaggedMalicious() public {
        address hook = address(new HonestHook(TAME));
        _registerFull(alice, hook, "ipfs://src", "ipfs://audit");

        vm.prank(guardian);
        registry.setListing(hook, Listing.Malicious, "drains on afterSwap");

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreFlaggedMalicious.selector, hook));
        vm.prank(curator);
        registry.setVerification(hook, Verification.Audited, "");

        // Rehabilitation is deliberately two separate, separately logged transactions.
        vm.prank(curator);
        registry.setListing(hook, Listing.Active, "false positive, reviewed");
        vm.prank(curator);
        registry.setVerification(hook, Verification.Audited, "re-reviewed");
        assertTrue(registry.isAudited(hook));
    }

    function test_promotion_blockedWhenPermissionsUnreadable() public {
        MutableHook hook = new MutableHook(TAME);
        _registerFull(alice, address(hook), "ipfs://src", "ipfs://audit");

        // Hook stops answering.
        vm.etch(address(hook), address(new RevertingHook()).code);
        registry.refreshPermissions(address(hook));
        assertFalse(registry.getDeepCore(address(hook)).permissionsReadable);

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsNotAttestable.selector, address(hook)));
        vm.prank(curator);
        registry.setVerification(address(hook), Verification.SourceVerified, "");
    }

    function test_promotion_curatorCanDemote() public {
        address hook = address(new HonestHook(TAME));
        _makeAudited(hook);
        vm.prank(curator);
        registry.setVerification(hook, Verification.Unverified, "audit withdrawn");
        assertFalse(registry.isAudited(hook));
    }

    /*//////////////////////////////////////////////////////////////
                   METADATA — THE BAIT AND SWITCH
    //////////////////////////////////////////////////////////////*/

    /// @notice Get audited, then repoint the source at something else. The badge must not survive.
    function test_metadata_stewardEditResetsVerification() public {
        address hook = address(new HonestHook(TAME));
        _makeAudited(hook);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreVerificationChanged(
            hook, alice, Verification.Audited, Verification.Unverified, "metadata edited by steward"
        );
        vm.prank(alice);
        registry.updateMetadata(hook, _meta("Hook", "ipfs://a-completely-different-repo", "ipfs://audit"));

        assertFalse(registry.isAudited(hook), "an edited listing is not the listing that was audited");
        assertEq(registry.getDeepCore(hook).metadata.sourceURI, "ipfs://a-completely-different-repo");
    }

    function test_metadata_curatorEditKeepsVerification() public {
        address hook = address(new HonestHook(TAME));
        _makeAudited(hook);
        vm.prank(curator);
        registry.updateMetadata(hook, _meta("Hook", "ipfs://src", "ipfs://audit-v2"));
        assertTrue(registry.isAudited(hook), "a curator editing is a curator attesting");
    }

    function test_metadata_onlyStewardOrCurator() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.NotSteward.selector, hook, stranger));
        vm.prank(stranger);
        registry.updateMetadata(hook, _meta());
    }

    function test_steward_transferByStewardThenEdits() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreStewardTransferred(hook, alice, bob);
        vm.prank(alice);
        registry.transferSteward(hook, bob);

        vm.prank(bob);
        registry.updateMetadata(hook, _meta("Renamed", "ipfs://src", ""));
        assertEq(registry.getDeepCore(hook).metadata.name, "Renamed");

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.NotSteward.selector, hook, alice));
        vm.prank(alice);
        registry.updateMetadata(hook, _meta());

        assertEq(registry.getDeepCore(hook).submitter, alice, "submitter is history and never moves");
    }

    /// @notice Ungated submission means someone can list a hook they did not write. Reassignment
    /// is the remedy, rather than deletion.
    function test_steward_curatorCanFixSquatting() public {
        address hook = address(new HonestHook(TAME));
        _register(stranger, hook); // squatter lists someone else's hook first
        vm.prank(curator);
        registry.transferSteward(hook, alice); // real author shows up
        vm.prank(alice);
        registry.updateMetadata(hook, _meta("Real Name", "ipfs://real", ""));
        assertEq(registry.getDeepCore(hook).metadata.name, "Real Name");
        assertEq(registry.getDeepCore(hook).submitter, stranger, "who squatted stays on the record");
    }

    function test_steward_zeroAddressRejected() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectRevert(IDeepCoreRegistry.ZeroAddress.selector);
        vm.prank(alice);
        registry.transferSteward(hook, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                       DEPRECATION AND FLAGGING
    //////////////////////////////////////////////////////////////*/

    function test_flag_maliciousResetsVerificationInSameTx() public {
        address hook = address(new HonestHook(SWAP_TAX));
        _makeAudited(hook);

        vm.prank(curator);
        registry.setListing(hook, Listing.Malicious, "takes 90% of every swap");

        DeepCoreRecord memory r = registry.getDeepCore(hook);
        assertEq(uint8(r.listing), uint8(Listing.Malicious));
        assertEq(uint8(r.verification), uint8(Verification.Unverified), "must not stay audited for one block");
        assertFalse(registry.isAudited(hook));
    }

    function test_flag_deprecatedKeepsVerification() public {
        address hook = address(new HonestHook(TAME));
        _makeAudited(hook);

        vm.prank(curator);
        registry.setListing(hook, Listing.Deprecated, "superseded by v2");

        DeepCoreRecord memory r = registry.getDeepCore(hook);
        assertEq(uint8(r.listing), uint8(Listing.Deprecated));
        assertEq(uint8(r.verification), uint8(Verification.Audited), "a retired audit is still a real audit");
        assertFalse(registry.isAudited(hook), "but the trust badge is off");
    }

    function test_flag_guardianMayOnlyEscalateCaution() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);

        vm.prank(guardian);
        registry.setListing(hook, Listing.Deprecated, "suspicious");

        vm.prank(guardian);
        registry.setListing(hook, Listing.Malicious, "confirmed");

        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreRegistry.GuardianCannotRelist.selector, Listing.Malicious, Listing.Active)
        );
        vm.prank(guardian);
        registry.setListing(hook, Listing.Active, "never mind");

        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreRegistry.GuardianCannotRelist.selector, Listing.Malicious, Listing.Malicious)
        );
        vm.prank(guardian);
        registry.setListing(hook, Listing.Malicious, "again");

        // Only a curator can clear a warning.
        vm.prank(curator);
        registry.setListing(hook, Listing.Active, "cleared after review");
        assertEq(uint8(registry.getDeepCore(hook).listing), uint8(Listing.Active));
    }

    function test_flag_strangerCannotFlag() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.NotCuratorOrGuardian.selector, stranger));
        vm.prank(stranger);
        registry.setListing(hook, Listing.Malicious, "i just do not like it");
    }

    function test_flag_stewardCannotFlagTheirOwnHook() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.NotCuratorOrGuardian.selector, alice));
        vm.prank(alice);
        registry.setListing(hook, Listing.Deprecated, "");
    }

    function test_flag_reasonIsEmittedForUsersToRead() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCoreListingChanged(
            hook, guardian, Listing.Active, Listing.Malicious, "steals LP fees via afterSwap delta"
        );
        vm.prank(guardian);
        registry.setListing(hook, Listing.Malicious, "steals LP fees via afterSwap delta");
    }

    /// @notice Nothing is ever removed. A flagged hook stays enumerable and stays queryable,
    /// because the users who need the warning are the ones already exposed to it.
    function test_flag_recordSurvivesAndStaysDiscoverable() public {
        address hook = address(new HonestHook(SWAP_TAX));
        _register(alice, hook);
        vm.prank(curator);
        registry.setListing(hook, Listing.Malicious, "rug");

        assertEq(registry.deepcoreCount(), 1, "still enumerable");
        assertEq(registry.deepcoreAt(0), hook);
        assertTrue(registry.isRegistered(hook));
        DeepCoreRecord memory r = registry.getDeepCore(hook);
        assertEq(r.permissions, SWAP_TAX, "the evidence is still readable");
        assertEq(r.submitter, alice, "and so is who listed it");

        // The slot can never be recycled by whoever wants to relist it clean.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreAlreadyRegistered.selector, hook));
        vm.prank(bob);
        registry.register(hook, _meta());
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSION REFRESH
    //////////////////////////////////////////////////////////////*/

    function test_refresh_noChangeReverts() public {
        address hook = address(new HonestHook(TAME));
        _register(alice, hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnchanged.selector, hook));
        registry.refreshPermissions(hook);
    }

    function test_refresh_unregisteredReverts() public {
        address hook = address(new HonestHook(TAME));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.refreshPermissions(hook);
    }

    /// @notice A hook that grows a swap-cut permission after being audited must lose the badge and
    /// must start reporting its real risk class.
    function test_refresh_escalatedPermissionsDemoteAndReclassify() public {
        MutableHook hook = new MutableHook(TAME);
        _makeAudited(address(hook));
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.Passive));

        hook.set(SWAP_TAX);

        vm.prank(stranger); // permissionless: anyone may correct the record
        registry.refreshPermissions(address(hook));

        DeepCoreRecord memory r = registry.getDeepCore(address(hook));
        assertEq(r.permissions, SWAP_TAX, "new bitmap recorded");
        assertEq(uint8(r.verification), uint8(Verification.Unverified), "audit no longer applies");
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.ValueExtracting));
        assertFalse(registry.isAudited(address(hook)));
    }

    function test_refresh_emitsFullBeforeAndAfter() public {
        MutableHook hook = new MutableHook(TAME);
        _register(alice, address(hook));
        bytes32 codehash = address(hook).codehash;
        hook.set(PERM_BEFORE_SWAP);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IDeepCoreRegistry.DeepCorePermissionsRefreshed(
            address(hook), address(this), TAME, PERM_BEFORE_SWAP, codehash, codehash, true, true
        );
        registry.refreshPermissions(address(hook));
    }

    /// @notice An invalid bitmap cannot be registered, but a hook can mutate into one. That is
    /// recorded as a fact and blocks any further attestation.
    function test_refresh_becomingInvalidIsRecorded() public {
        MutableHook hook = new MutableHook(PERM_BEFORE_SWAP | PERM_BEFORE_SWAP_RETURNS_DELTA);
        _makeAudited(address(hook));

        hook.set(PERM_BEFORE_SWAP_RETURNS_DELTA); // drops the base callback
        registry.refreshPermissions(address(hook));

        DeepCoreRecord memory r = registry.getDeepCore(address(hook));
        assertFalse(r.permissionsValid, "dependency no longer satisfied");
        assertTrue(r.permissionsReadable);
        assertEq(uint8(r.verification), uint8(Verification.Unverified));
    }

    /// @notice A hook that stops answering keeps its last known bitmap rather than silently
    /// reporting zero permissions, which would understate what it can do.
    function test_refresh_becomingUnreadableKeepsLastKnownBitmap() public {
        MutableHook hook = new MutableHook(SWAP_TAX);
        _makeAudited(address(hook));

        vm.etch(address(hook), address(new GasBurnerHook()).code);
        registry.refreshPermissions(address(hook));

        DeepCoreRecord memory r = registry.getDeepCore(address(hook));
        assertFalse(r.permissionsReadable, "flagged stale");
        assertFalse(r.permissionsValid);
        assertEq(r.permissions, SWAP_TAX, "last known value retained, not zeroed");
        assertEq(uint8(registry.riskClassOf(address(hook))), uint8(RiskClass.ValueExtracting));
        assertEq(uint8(r.verification), uint8(Verification.Unverified));
        assertFalse(registry.isAudited(address(hook)));
    }

    /// @notice Same bitmap, different bytecode. The audit was of the bytecode, so it lapses.
    function test_refresh_codehashChangeAloneDemotes() public {
        HonestHook hook = new HonestHook(TAME);
        _makeAudited(address(hook));
        bytes32 oldHash = address(hook).codehash;

        // Different implementation, identical answer.
        vm.etch(address(hook), address(new RawButHonestHook(TAME)).code);
        assertTrue(address(hook).codehash != oldHash, "precondition: code really changed");

        registry.refreshPermissions(address(hook));

        DeepCoreRecord memory r = registry.getDeepCore(address(hook));
        assertEq(r.permissions, TAME, "bitmap unchanged");
        assertEq(r.codehash, address(hook).codehash, "new codehash recorded");
        assertEq(uint8(r.verification), uint8(Verification.Unverified), "audited code is gone");
    }

    /*//////////////////////////////////////////////////////////////
                             ENUMERATION
    //////////////////////////////////////////////////////////////*/

    function test_enumeration_paging() public {
        address[] memory hooks = new address[](5);
        for (uint256 i; i < 5; ++i) {
            hooks[i] = address(new HonestHook(uint16(1 << i)));
            _register(i % 2 == 0 ? alice : bob, hooks[i]);
        }

        assertEq(registry.deepcoreCount(), 5);

        address[] memory page = registry.listDeepCores(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], hooks[0]);
        assertEq(page[1], hooks[1]);

        page = registry.listDeepCores(3, 10);
        assertEq(page.length, 2, "limit clamps to the end");
        assertEq(page[0], hooks[3]);
        assertEq(page[1], hooks[4]);

        page = registry.listDeepCores(5, 10);
        assertEq(page.length, 0, "offset at the end is an empty page, not a revert");

        page = registry.listDeepCores(0, type(uint256).max);
        assertEq(page.length, 5, "'give me everything' must not overflow");

        assertEq(registry.submittedCount(alice), 3);
        assertEq(registry.submittedCount(bob), 2);
        address[] memory mine = registry.listBySubmitter(alice, 0, 10);
        assertEq(mine.length, 3);
        assertEq(mine[0], hooks[0]);
        assertEq(mine[2], hooks[4]);
    }

    function test_enumeration_offsetPastEndReverts() public {
        vm.expectRevert(IDeepCoreRegistry.InvalidRange.selector);
        registry.listDeepCores(1, 1);
    }

    function test_enumeration_indicesAreStableAcrossStatusChanges() public {
        address a = address(new HonestHook(TAME));
        address b = address(new HonestHook(PERM_BEFORE_SWAP));
        _register(alice, a);
        _register(alice, b);

        vm.prank(curator);
        registry.setListing(a, Listing.Malicious, "rug");

        assertEq(registry.deepcoreAt(0), a, "index 0 never moves");
        assertEq(registry.deepcoreAt(1), b);
        assertEq(registry.deepcoreCount(), 2);
    }

    function test_views_revertForUnregistered() public {
        address hook = address(new HonestHook(TAME));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.getDeepCore(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.permissionsOf(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.riskClassOf(hook);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.DeepCoreNotRegistered.selector, hook));
        registry.statusOf(hook);
        assertFalse(registry.isAudited(hook), "isAudited must be false, never revert");
        assertFalse(registry.isRegistered(hook));
    }

    /*//////////////////////////////////////////////////////////////
                          ROLE ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_roles_timelockOwnsTheAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), timelock));
        assertTrue(registry.hasRole(registry.CURATOR_ROLE(), curator));
        assertTrue(registry.hasRole(registry.GUARDIAN_ROLE(), guardian));
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(this)), "deployer holds nothing");
    }

    function test_roles_onlyAdminMayAppointCurators() public {
        bytes32 curatorRole = registry.CURATOR_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, curator, adminRole)
        );
        vm.prank(curator);
        registry.grantRole(curatorRole, stranger);

        vm.prank(timelock);
        registry.grantRole(curatorRole, bob);
        assertTrue(registry.hasRole(curatorRole, bob));

        vm.prank(timelock);
        registry.revokeRole(curatorRole, bob);
        assertFalse(registry.hasRole(curatorRole, bob));
    }

    function test_roles_zeroAdminRejected() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(IDeepCoreRegistry.ZeroAddress.selector);
        new DeepCoreRegistry(address(0), address(vault), empty, empty);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Any bitmap core would accept must register, and must be stored verbatim.
    function testFuzz_register_anyValidBitmap(uint16 raw) public {
        uint16 permissions = _sanitize(raw);
        address hook = address(new HonestHook(permissions));

        vm.prank(alice);
        registry.register(hook, _meta());

        (uint16 stored, bool readable, bool valid,) = registry.permissionsOf(hook);
        assertEq(stored, permissions, "stored verbatim");
        assertTrue(readable);
        assertTrue(valid);
        assertTrue(registry.isValidBitmap(stored));
        assertEq(uint8(registry.getDeepCore(hook).verification), uint8(Verification.Unverified), "never auto-verified");
    }

    /// @notice Reserved bits are always refused, no matter what else is set.
    function testFuzz_register_reservedBitsAlwaysRejected(uint16 raw, bool useBit15) public {
        uint16 permissions = _sanitize(raw) | (useBit15 ? uint16(1 << 15) : uint16(1 << 14));
        address hook = address(new HonestHook(permissions));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.ReservedBitsSet.selector, permissions));
        vm.prank(alice);
        registry.register(hook, _meta());
        assertFalse(registry.isRegistered(hook));
    }

    /// @notice A word that does not fit a uint16 is never accepted, whatever its low bits say.
    function testFuzz_probe_dirtyWordNeverAccepted(uint256 word) public {
        word = bound(word, uint256(type(uint16).max) + 1, type(uint256).max);
        address hook = address(new DirtyWordHook(word));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnreadable.selector, hook));
        vm.prank(alice);
        registry.register(hook, _meta());
    }

    /// @notice `decodePermissions` is a lossless view of the assigned bits.
    function testFuzz_decodePermissions_roundTrips(uint16 raw) public view {
        DecodedPermissions memory d = registry.decodePermissions(raw);
        uint16 rebuilt;
        if (d.beforeInitialize) rebuilt |= PERM_BEFORE_INITIALIZE;
        if (d.afterInitialize) rebuilt |= PERM_AFTER_INITIALIZE;
        if (d.beforeAddLiquidity) rebuilt |= PERM_BEFORE_ADD_LIQUIDITY;
        if (d.afterAddLiquidity) rebuilt |= PERM_AFTER_ADD_LIQUIDITY;
        if (d.beforeRemoveLiquidity) rebuilt |= PERM_BEFORE_REMOVE_LIQUIDITY;
        if (d.afterRemoveLiquidity) rebuilt |= PERM_AFTER_REMOVE_LIQUIDITY;
        if (d.beforeSwap) rebuilt |= PERM_BEFORE_SWAP;
        if (d.afterSwap) rebuilt |= PERM_AFTER_SWAP;
        if (d.beforeDonate) rebuilt |= PERM_BEFORE_DONATE;
        if (d.afterDonate) rebuilt |= PERM_AFTER_DONATE;
        if (d.beforeSwapReturnsDelta) rebuilt |= PERM_BEFORE_SWAP_RETURNS_DELTA;
        if (d.afterSwapReturnsDelta) rebuilt |= PERM_AFTER_SWAP_RETURNS_DELTA;
        if (d.afterAddLiquidityReturnsDelta) rebuilt |= PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA;
        if (d.afterRemoveLiquidityReturnsDelta) rebuilt |= PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA;
        assertEq(rebuilt, raw & PERM_ALL_ASSIGNED);
    }

    /// @notice The classifier can never understate a hook that can take or trap funds.
    function testFuzz_classify_neverUnderstatesValueRisk(uint16 raw) public view {
        RiskClass class = registry.classify(raw);
        bool dangerous = raw & PERM_RETURNS_DELTA_MASK != 0 || raw & PERM_BEFORE_REMOVE_LIQUIDITY != 0;
        if (dangerous) {
            assertEq(uint8(class), uint8(RiskClass.ValueExtracting), "must be ValueExtracting");
        } else if (raw & PERM_BEFORE_MASK != 0) {
            assertEq(uint8(class), uint8(RiskClass.Restrictive));
        } else {
            assertEq(uint8(class), uint8(RiskClass.Passive));
            assertFalse(registry.takesSwapCut(raw));
            assertFalse(registry.returnsDelta(raw));
            assertFalse(registry.canBlockSwaps(raw));
            assertFalse(registry.canTrapLiquidity(raw));
        }
        // Bits 10 and 11 are the ones that let a hook take a cut of every swap.
        assertEq(registry.takesSwapCut(raw), raw & PERM_SWAP_CUT_MASK != 0);
    }

    /// @notice Whatever a hook reports, only a curator can ever raise its verification.
    function testFuzz_noSelfPromotionForAnyBitmap(uint16 raw, address submitter) public {
        vm.assume(submitter != address(0) && submitter != curator);
        uint16 permissions = _sanitize(raw);
        address hook = address(new HonestHook(permissions));

        vm.prank(submitter);
        registry.register(hook, _meta("H", "ipfs://src", "ipfs://audit"));
        assertFalse(registry.isAudited(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, submitter, registry.CURATOR_ROLE()
            )
        );
        vm.prank(submitter);
        registry.setVerification(hook, Verification.Audited, "");
        assertFalse(registry.isAudited(hook));
    }

    /// @notice A refresh must never leave a record claiming more trust than before.
    function testFuzz_refresh_neverRaisesVerification(uint16 from, uint16 to) public {
        uint16 a = _sanitize(from);
        uint16 b = _sanitize(to);
        MutableHook hook = new MutableHook(a);
        _makeAudited(address(hook));

        hook.set(b);
        if (a == b) {
            vm.expectRevert(abi.encodeWithSelector(IDeepCoreRegistry.PermissionsUnchanged.selector, address(hook)));
            registry.refreshPermissions(address(hook));
            assertTrue(registry.isAudited(address(hook)), "a no-op refresh changes nothing");
        } else {
            registry.refreshPermissions(address(hook));
            DeepCoreRecord memory r = registry.getDeepCore(address(hook));
            assertEq(r.permissions, b);
            assertEq(uint8(r.verification), uint8(Verification.Unverified));
        }
    }
}
