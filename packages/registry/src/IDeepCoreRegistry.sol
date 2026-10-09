/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/*//////////////////////////////////////////////////////////////
                        PERMISSION BITS
    Mirrors the offsets in
    infinity-core/src/pool-cl/interfaces/ICLHooks.sol.
    Duplicated as masks (not offsets) because every consumer of
    this registry wants to test them, not shift them.
//////////////////////////////////////////////////////////////*/

uint16 constant PERM_BEFORE_INITIALIZE = uint16(1) << 0;
uint16 constant PERM_AFTER_INITIALIZE = uint16(1) << 1;
uint16 constant PERM_BEFORE_ADD_LIQUIDITY = uint16(1) << 2;
uint16 constant PERM_AFTER_ADD_LIQUIDITY = uint16(1) << 3;
uint16 constant PERM_BEFORE_REMOVE_LIQUIDITY = uint16(1) << 4;
uint16 constant PERM_AFTER_REMOVE_LIQUIDITY = uint16(1) << 5;
uint16 constant PERM_BEFORE_SWAP = uint16(1) << 6;
uint16 constant PERM_AFTER_SWAP = uint16(1) << 7;
uint16 constant PERM_BEFORE_DONATE = uint16(1) << 8;
uint16 constant PERM_AFTER_DONATE = uint16(1) << 9;
uint16 constant PERM_BEFORE_SWAP_RETURNS_DELTA = uint16(1) << 10;
uint16 constant PERM_AFTER_SWAP_RETURNS_DELTA = uint16(1) << 11;
uint16 constant PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA = uint16(1) << 12;
uint16 constant PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA = uint16(1) << 13;

/// @dev Bits 14-15 carry no meaning in ICLHooks and must be zero.
uint16 constant PERM_RESERVED_BITS = uint16(0xC000);

/// @dev Every bit that ICLHooks actually assigns.
uint16 constant PERM_ALL_ASSIGNED = uint16(0x3FFF);

/// @dev Any of these lets the hook return a balance delta, i.e. move value that would otherwise
/// belong to the swapper or the liquidity provider into the hook.
uint16 constant PERM_RETURNS_DELTA_MASK = PERM_BEFORE_SWAP_RETURNS_DELTA | PERM_AFTER_SWAP_RETURNS_DELTA
    | PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA | PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA;

/// @dev The two bits that let a hook take a cut of every single swap in its pool.
uint16 constant PERM_SWAP_CUT_MASK = PERM_BEFORE_SWAP_RETURNS_DELTA | PERM_AFTER_SWAP_RETURNS_DELTA;

/// @dev `before*` callbacks run before the action is applied and may revert, which blocks it.
uint16 constant PERM_BEFORE_MASK = PERM_BEFORE_INITIALIZE | PERM_BEFORE_ADD_LIQUIDITY | PERM_BEFORE_REMOVE_LIQUIDITY
    | PERM_BEFORE_SWAP | PERM_BEFORE_DONATE;

/*//////////////////////////////////////////////////////////////
                              TYPES
//////////////////////////////////////////////////////////////*/

/// @notice The verification ladder. Strictly ordered; higher means a curator has attested more.
/// @dev Unverified is the value of every freshly registered hook and of every hook whose
/// metadata or on-chain code has changed since it was last attested. It is never possible for a
/// submitter to move themselves up this ladder.
enum Verification {
    /// @dev Listed, permissions read from chain, nobody has vouched for anything else.
    Unverified,
    /// @dev A curator has confirmed the published source matches the deployed bytecode.
    SourceVerified,
    /// @dev A curator has confirmed a real audit report covers this exact deployment.
    Audited
}

/// @notice Whether the registry still recommends this listing. Independent of `Verification`.
enum Listing {
    Active,
    /// @dev Superseded or abandoned. Not an accusation. Verification is retained.
    Deprecated,
    /// @dev Known to harm users. Verification is force-reset to Unverified when this is set.
    Malicious
}

/// @notice Where a record's permission bitmap actually came from.
///
/// @dev This exists because `getHooksRegistrationBitmap()` is a `view` function on a contract
/// nobody has vetted, and a `view` function can read `msg.sender`. A hook can therefore answer the
/// registry with a tame bitmap and answer core with the real one. Core validates the bitmap exactly
/// ONCE — `Hooks.validateHookConfig` at pool initialization — and every dispatch after that reads
/// `poolKey.parameters`, never the hook. So the hook's answer to the registry and the permissions a
/// pool actually enforces are two independent facts, and only the second one can hurt anybody.
///
/// A UI that renders a risk class without rendering this value is rendering a claim as if it were a
/// measurement. `riskAssessmentOf` returns both together for that reason.
enum PermissionSource {
    /// @dev Only the hook's own answer has been read. Nothing on chain corroborates it. This is not
    /// an accusation — it is the correct state for a hook that is listed but not yet used by any
    /// pool — but it is the state in which the bitmap is a claim by the hook about itself.
    SelfReported,
    /// @dev At least one live pool's immutable `parameters` has been read back from a pool manager
    /// the Vault has registered, and it agrees with what the hook told the registry.
    PoolAttested,
    /// @dev Attested, and a live pool enforces at least one permission the hook did not admit to
    /// the registry. The recorded bitmap is the union of both, so it can only ever overstate.
    /// This is the signature of the spoof described above. It is not automatically proof of malice
    /// — a hook serving both a CL and a Bin pool may legitimately present two bitmaps — but it does
    /// mean the hook's self-report is not a safe thing to show a user on its own.
    PoolAttestedDivergent
}

/// @notice Capability class derived purely from the on-chain bitmap. No human judgement.
enum RiskClass {
    /// @dev Only `after*` callbacks that cannot return a delta. The hook observes; it cannot
    /// take value and it cannot block an action (an `after*` revert does block, but the action
    /// has already been priced, so it degrades to a denial of service on the whole pool rather
    /// than a selective one — still bad, still not value extraction).
    Passive,
    /// @dev Holds at least one `before*` callback. Can refuse a swap, a deposit, an
    /// initialization. Trading in the pool exists at the hook's discretion.
    Restrictive,
    /// @dev Holds a returns-delta bit (can take a cut of swaps or of liquidity movements) or
    /// `beforeRemoveLiquidity` (can permanently refuse withdrawals). This class can take or
    /// trap user funds. Nothing here should ever be presented without a prominent warning.
    ValueExtracting
}

/// @notice Human-supplied listing data. Never trusted for capability claims.
struct DeepCoreMetadata {
    string name;
    string description;
    /// @dev Source repository / verification URI.
    string sourceURI;
    /// @dev Audit report URI. Must be non-empty before a curator may set `Audited`.
    string auditURI;
    /// @dev Chain ids the submitter claims this hook is deployed on. Informational.
    uint256[] chainIds;
}

/// @notice The full registry record for one hook address.
/// @dev Field order is chosen for storage packing, not for prose:
/// slot 0 = submitter|submittedAt|permissions|verification|listing (exactly 32 bytes),
/// slot 1 = steward|updatedAt|permissionsValid|permissionsReadable|attestedPermissions (32),
/// slot 2 = codehash,
/// slot 3 = attestedPoolManager|attestedAt|attestationCount (exactly 32 bytes),
/// slot 4 = attestedPoolId.
struct DeepCoreRecord {
    /// @dev Who called `register`. Immutable, historical. Non-zero iff the hook is registered.
    address submitter;
    uint64 submittedAt;
    /// @dev SELF-REPORTED. Read from `getHooksRegistrationBitmap()` on the hook itself, so it is
    /// never submitter-supplied — but it is still the hook's own account of the hook, delivered to
    /// a caller the hook can identify. Read `attestedPermissions` before believing it, and prefer
    /// `effectivePermissions` / `riskAssessmentOf` over either field alone.
    uint16 permissions;
    Verification verification;
    Listing listing;
    /// @dev Who may currently edit the metadata. Transferable.
    address steward;
    uint64 updatedAt;
    /// @dev False if a refresh observed reserved bits or an unmet returns-delta dependency.
    bool permissionsValid;
    /// @dev False if a refresh could no longer read the bitmap at all. `permissions` then holds
    /// the last value that was successfully read, and must be treated as stale.
    bool permissionsReadable;
    /// @dev The union of every bitmap this hook has been observed enforcing in a live pool, taken
    /// from that pool's immutable `parameters`. Monotone: attestations only ever add bits, and no
    /// role can clear them. Zero and meaningless until `attestationCount > 0`.
    uint16 attestedPermissions;
    /// @dev `hook.codehash` at the time permissions were last read.
    bytes32 codehash;
    /// @dev Pool manager of the most recent attestation. Zero until first attested.
    address attestedPoolManager;
    /// @dev Timestamp of the most recent attestation.
    uint64 attestedAt;
    /// @dev How many DISTINCT live pools have corroborated this hook. Each pool counts once,
    /// forever. Zero means nothing on chain has confirmed the self-report.
    uint32 attestationCount;
    /// @dev Pool id of the most recent attestation, so a UI can link to the pool that vouched.
    bytes32 attestedPoolId;
    DeepCoreMetadata metadata;
}

/// @notice `permissions` expanded into named booleans, for UIs and off-chain consumers.
struct DecodedPermissions {
    bool beforeInitialize;
    bool afterInitialize;
    bool beforeAddLiquidity;
    bool afterAddLiquidity;
    bool beforeRemoveLiquidity;
    bool afterRemoveLiquidity;
    bool beforeSwap;
    bool afterSwap;
    bool beforeDonate;
    bool afterDonate;
    bool beforeSwapReturnsDelta;
    bool afterSwapReturnsDelta;
    bool afterAddLiquidityReturnsDelta;
    bool afterRemoveLiquidityReturnsDelta;
}

/// @title IDeepCoreRegistry
/// @notice The on-chain hook registry for DeepCoreProtocol.
interface IDeepCoreRegistry {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
        Between DeepCoreRegistered, DeepCoreMetadataUpdated,
        DeepCoreVerificationChanged, DeepCoreListingChanged,
        DeepCoreStewardTransferred and DeepCorePermissionsRefreshed, the
        entire registry state is reconstructible from logs alone.
        DeepCoreMetadataUpdated is emitted at registration too, so an
        indexer never has to read storage to learn the initial
        metadata.
    //////////////////////////////////////////////////////////////*/

    event DeepCoreRegistered(
        address indexed hook,
        address indexed submitter,
        uint16 permissions,
        RiskClass riskClass,
        bytes32 codehash,
        uint64 timestamp
    );

    event DeepCoreMetadataUpdated(
        address indexed hook,
        address indexed updater,
        string name,
        string description,
        string sourceURI,
        string auditURI,
        uint256[] chainIds
    );

    event DeepCoreVerificationChanged(
        address indexed hook, address indexed actor, Verification previous, Verification current, string note
    );

    event DeepCoreListingChanged(
        address indexed hook, address indexed actor, Listing previous, Listing current, string reason
    );

    event DeepCoreStewardTransferred(address indexed hook, address indexed previous, address indexed current);

    event DeepCorePermissionsRefreshed(
        address indexed hook,
        address indexed actor,
        uint16 previousPermissions,
        uint16 currentPermissions,
        bytes32 previousCodehash,
        bytes32 currentCodehash,
        bool readable,
        bool valid
    );

    /// @notice A live pool has corroborated this hook's permissions.
    /// @param poolPermissions The bitmap this one pool enforces, from its immutable `parameters`.
    /// @param attestedPermissions The union across every pool attested so far, after this call.
    /// @param selfReportedPermissions What the hook told the registry, for side-by-side comparison.
    event DeepCorePoolAttested(
        address indexed hook,
        address indexed attestor,
        address indexed poolManager,
        bytes32 poolId,
        uint16 poolPermissions,
        uint16 attestedPermissions,
        uint16 selfReportedPermissions,
        uint32 attestationCount
    );

    /// @notice A live pool enforces permissions the hook never admitted to the registry.
    /// @dev This is the event a marketplace should surface loudest. It is emitted only when
    /// `concealed != 0`, i.e. the hook's answer to the registry was strictly weaker than reality.
    /// @param concealed `attested & ~selfReported` — the bits the hook kept back.
    event DeepCorePermissionsUnderstated(address indexed hook, uint16 selfReported, uint16 attested, uint16 concealed);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error DeepCoreAlreadyRegistered(address hook);
    error DeepCoreNotRegistered(address hook);
    error DeepCoreHasNoCode(address hook);

    /// @notice `getHooksRegistrationBitmap()` reverted, ran out of the probe gas budget, or did
    /// not return exactly one clean 32-byte uint16.
    error PermissionsUnreadable(address hook);

    /// @notice The hook declares bits 14 or 15, which ICLHooks does not assign.
    error ReservedBitsSet(uint16 permissions);

    /// @notice A returns-delta bit was declared without the base callback that returns it.
    error PermissionDependencyMissing(uint16 permissions);

    /// @notice Not enough gas remains to give the probe its full budget, so an "unreadable"
    /// verdict would say more about the caller than about the hook.
    error InsufficientGasForProbe(uint256 available, uint256 required);

    error NotSteward(address hook, address caller);
    error NotCuratorOrGuardian(address caller);

    /// @notice A guardian tried to make a listing less cautious. Guardians only ever add warnings.
    error GuardianCannotRelist(Listing current, Listing attempted);

    /// @notice Verification cannot be raised while the hook is flagged malicious. Clear the flag
    /// first, in its own transaction, so the rehabilitation is separately visible in the logs.
    error DeepCoreFlaggedMalicious(address hook);

    /// @notice Verification cannot be raised on a hook whose on-chain permissions are unreadable
    /// or invalid. You cannot attest to what you cannot read.
    error PermissionsNotAttestable(address hook);

    /*//////////////////////////////////////////////////////////////
                          ATTESTATION ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool manager named is not an app the Vault has registered, so nothing it says
    /// about its own pools can be trusted. `Vault.registerApp` is the gate here on purpose: it is
    /// `onlyOwner` on the 48h custody timelock, which is the strictest approval in the protocol.
    error UntrustedPoolManager(address poolManager);

    /// @notice The manager holds no pool under that id, or the key it holds does not hash back to
    /// it. Either way there is no initialized pool to read permissions from.
    error PoolNotFound(address poolManager, bytes32 poolId);

    /// @notice The pool exists, but its `hooks` field is a different contract. An attestation only
    /// ever speaks for the hook the pool actually runs.
    error PoolHookMismatch(bytes32 poolId, address expected, address found);

    /// @notice That exact pool has already been counted. Re-attesting adds no information and
    /// would only spam the log — attest a different pool, or read the record.
    error PoolAlreadyAttested(address hook, bytes32 poolId);

    /// @notice A curator tried to badge a record that no live pool has corroborated. Verification
    /// is a statement about a deployment, and until a pool exists the only evidence available is
    /// the hook's own account of itself.
    error AttestationRequired(address hook);

    /*//////////////////////////////////////////////////////////////
                             ROLE ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `DEFAULT_ADMIN_ROLE` cannot be renounced. It is the only role that can appoint
    /// curators and guardians; dropping the last holder would permanently freeze the safety
    /// surface with no way back. Transfer it by granting the successor and then revoking.
    error AdminRoleIsNotRenounceable();

    /// @notice Revoking that account would leave `DEFAULT_ADMIN_ROLE` with no holder. Same reason.
    error LastAdminCannotBeRemoved();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    error AuditURIRequired();
    error SourceURIRequired();
    error PermissionsUnchanged(address hook);
    error StringTooLong(uint256 length, uint256 maximum);
    error EmptyName();
    error TooManyChains(uint256 count, uint256 maximum);
    error InvalidRange();
}
