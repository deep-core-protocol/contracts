/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {ParametersHelper} from "infinity-core/src/libraries/math/ParametersHelper.sol";

import {PoolProof, IVaultAppRegistry} from "./libraries/PoolProof.sol";
import {PermissionMath} from "./libraries/PermissionMath.sol";
import {RegistryPaging} from "./libraries/RegistryPaging.sol";

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
    PERM_RESERVED_BITS,
    PERM_RETURNS_DELTA_MASK,
    PERM_SWAP_CUT_MASK,
    PERM_BEFORE_MASK
} from "./IDeepCoreRegistry.sol";

/// @title DeepCoreRegistry
/// @notice The discovery and safety surface for DeepCoreProtocol hooks.
///
/// @dev ################### WHAT THIS CONTRACT IS ACTUALLY FOR ###################
///
/// A DeepCore hook can be attached to a pool from any address — permissions live in the pool key and
/// are cross-checked against the hook, so there is no CREATE2 salt mining and therefore no address
/// to read capabilities off. That is a real developer advantage and it moves an entire class of
/// risk off-chain: a user looking at `0xAbCd…` has no way to see, from the address alone, that the
/// hook behind it holds `beforeSwapReturnsDelta` and takes 30 bps of every trade in the pool.
///
/// This registry exists to put that back on-chain, and it is a SAFETY surface before it is a
/// DISCOVERY surface. Three rules follow from that and none of them are negotiable:
///
///   1. PERMISSIONS COME FROM THE HOOK, NEVER FROM THE SUBMITTER. `register` reads
///      `getHooksRegistrationBitmap()` off the hook contract. There is no parameter through which
///      a submitter can declare, suggest or influence what their hook is allowed to do. A registry
///      that took the submitter's word for it would be worse than no registry, because it would
///      launder a lie through an official-looking surface.
///
///      AND THAT IS NOT SUFFICIENT ON ITS OWN — see the next section. Reading the bitmap off the
///      hook removes the SUBMITTER from the loop. It does not remove the HOOK from the loop, and
///      the hook is the party with the motive.
///
///   2. NOBODY CAN PROMOTE THEMSELVES. Every hook enters at `Unverified`. Only a curator moves it
///      up the ladder, and any subsequent change to the metadata or to the hook's own code knocks
///      it straight back down. The bait-and-switch — get audited, then repoint `sourceURI` at
///      something else, or upgrade the implementation behind a proxy — is the attack this defends.
///
///   3. LISTING IS FREE AND UNGATED. No fee, no allowlist, no minimum stake. A listing fee taxes
///      exactly the independent developers the marketplace exists to attract, while being pocket
///      change to anyone running a scam at scale. Spam is priced by gas, which is the only
///      mechanism here that charges an attacker more than it charges an honest developer.
///
/// ########################### WHY NOTHING IS EVER REMOVED ###########################
///
/// There is no `delete`, no `unregister`, no owner escape hatch that erases a record. This was the
/// hardest call in the design and it went this way for four reasons:
///
///   - Deletion and censorship are the same transaction. Whoever holds a delete key can silently
///     remove a competitor. There is no on-chain way to tell that apart from removing a scam, and
///     "trust our curators not to" is exactly the assumption a registry should not require.
///
///   - Deleting a malicious hook DESTROYS THE WARNING. Absence is indistinguishable from "never
///     submitted". The users who most need the warning are the ones already in that hook's pool,
///     and delisting is precisely the moment they stop being able to look it up. A `Malicious`
///     tombstone with a reason string is strictly more protective than an empty slot.
///
///   - Log replay must be deterministic. The events here are specified so an indexer can rebuild
///     the entire registry from scratch. Deletion introduces state that exists in the log history
///     and not in storage, and every consumer then has to agree on how to reconcile that.
///
///   - Removal buys nothing. Every effect a delete could have — hide from default listings, warn
///     loudly, break the audited badge — is already reachable through `Listing.Malicious`, which
///     also force-resets verification. The only additional thing delete offers is deniability.
///
/// The cost of this choice, stated plainly: the registry accumulates junk forever, and a hook
/// squatted by a bad-faith first submitter can never have its entry vacated. Both are handled by
/// filtering rather than erasure — see `transferSteward` for the squatting case.
///
/// ####################### CALLING AN UNTRUSTED CONTRACT #######################
///
/// `register` and `refreshPermissions` call an address nobody has vetted. Core makes the same call
/// in `Hooks.validateHookConfig` with all remaining gas and no guards, which is safe there only
/// because a hostile hook that bricks its own pool initialization harms nobody else. Here it would
/// be a shared surface, so the call is made through `_probePermissions`:
///
///   - hard gas cap of `PROBE_GAS`, so an infinite loop costs its own submitter and stops;
///   - output buffer fixed at 32 bytes, so a return bomb cannot make us pay to copy it;
///   - `returndatasize() == 32` checked, so a short or empty return is a failure, not a zero;
///   - the raw word is rejected unless it fits in a `uint16`, matching what solc's own ABI decoder
///     would accept, so dirty high bits cannot be laundered into a small bitmap;
///   - `staticcall`, so the probe cannot reenter or write anything;
///   - a `gasleft()` floor, so an "unreadable" verdict is always about the hook and never about a
///     caller who deliberately starved the frame. Without it, anyone could call
///     `refreshPermissions` with hand-tuned gas and demote an honest audited hook.
///
/// A hostile hook can therefore make its own registration fail. It cannot make anyone else's fail,
/// and it cannot cost a caller more than the probe budget.
///
/// ############### WHY THE PROBE ALONE CANNOT BE BELIEVED: ATTESTATION ###############
///
/// `getHooksRegistrationBitmap()` is `view`, and a `view` function can read `msg.sender` and
/// `gasleft()`. Everything the probe does is defensive about the CALL; none of it makes the ANSWER
/// true. A hook can branch:
///
///     function getHooksRegistrationBitmap() external view returns (uint16) {
///         if (msg.sender == DEEPCORE_REGISTRY) return TAME;   // afterSwap only
///         return TAME | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA;   // takes a cut
///     }
///
/// and the registry records `TAME`. `classify` then returns `Passive`, `takesSwapCut` returns
/// false, and the marketplace shows "observes only, takes no cut" above a pool that is skimming
/// every trade. `refreshPermissions` is permissionless but still calls FROM this address, so it
/// re-reads the same lie forever and the codehash never moves.
///
/// Probing differently does not fix this and the road is a dead end. A fresh disposable prober
/// beats the `msg.sender` branch but not `if (gasleft() < N)`. Raising `PROBE_GAS` moves the
/// threshold. Any budget this contract commits to is itself a signal the hook can key off. The
/// fixed point of that game is: an untrusted `view` function is a claim, never a measurement.
///
/// So the registry reads the bitmap from somewhere the hook cannot reach — A POOL CORE HAS ALREADY
/// VALIDATED. The chain of custody:
///
///   - `CLPoolManager.initialize` / `BinPoolManager.initialize` call `Hooks.validateHookConfig`,
///     which requires `poolKey.hooks.getHooksRegistrationBitmap() == poolKey.parameters` bitmap.
///     That is the only time core ever asks the hook.
///   - Immediately after, the manager writes `poolIdToPoolKey[id] = key`.
///   - Every dispatch from then on reads `key.parameters`, never the hook — see
///     `CLHooks.shouldCall`. `parameters` is part of the pool id, so it is IMMUTABLE for the life
///     of that pool.
///
/// Therefore `poolIdToPoolKey[id].parameters` is a bitmap that (a) the hook answered with at least
/// once, under core's own eyes and not ours, and (b) is what that pool actually enforces today.
/// `attestFromPool` reads exactly that. A hook cannot lie to it, because a lie there would have
/// prevented the pool from existing.
///
/// The trust anchor is the Vault, not a list this contract keeps. A pool manager is believed iff
/// `Vault.isAppRegistered(manager)`, which is `onlyOwner` on the 48h custody timelock and grants
/// permanent authority to move Vault funds. Anything already trusted that far is trusted to report
/// its own pool keys. The alternative — a curator-managed allowlist — would let an Ops hot key
/// enroll a fake "pool manager" and mint attestations for any bitmap it liked, which is precisely
/// the laundering this whole mechanism exists to stop.
///
/// What an attestation is and is not:
///   - It proves the hook presented that bitmap to core for that pool. It does NOT prove the hook
///     presents the same bitmap everywhere. The same hook can back a CL pool and a Bin pool with
///     different bitmaps, honestly.
///   - `attestedPermissions` is therefore the UNION over every attested pool, and attestations are
///     monotone: they only ever add bits, and no role can clear them. Overstating is a survivable
///     error; understating is the one that costs somebody their money.
///   - `effectivePermissions` is `selfReported | attested`, so no combination of hook behaviour and
///     attestation order can produce a bitmap milder than something already observed.
///   - Anyone may attest. There is no way to use it to make a record look cleaner, so there is no
///     reason to gate it.
/// ###############################################################################
contract DeepCoreRegistry is IDeepCoreRegistry, AccessControl {
    using PoolIdLibrary for PoolKey;
    using ParametersHelper for bytes32;
    using RegistryPaging for address[];

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice May attest: move a hook up or down the verification ladder, change any listing
    /// status, reassign a steward, correct metadata.
    /// @dev Curators are deliberately NOT timelocked. Marking a live hook malicious is an incident
    /// response and a six-hour queue makes it useless. The timelock sits one level up: it decides
    /// who is a curator. Granting the role is the escalation; using it is not.
    bytes32 public constant CURATOR_ROLE = keccak256("DEEPCORE_HOOK_REGISTRY_CURATOR");

    /// @notice May only ever make a listing MORE cautious — Active to Deprecated, anything to
    /// Malicious — and nothing else.
    /// @dev Same reasoning as the guardian on DeepCoreProtocolFeeController: delay and blast radius
    /// belong on privilege escalation, not on privilege reduction. A compromised guardian can
    /// slander a hook, which is visible, reversible by a curator, and costs nobody their funds. It
    /// cannot grant an audit badge, edit metadata, or clear an existing warning. That asymmetry is
    /// what makes it safe to hand this role to a fast-moving security desk.
    bytes32 public constant GUARDIAN_ROLE = keccak256("DEEPCORE_HOOK_REGISTRY_GUARDIAN");

    /*//////////////////////////////////////////////////////////////
                              PROBE LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard gas ceiling on the untrusted `getHooksRegistrationBitmap()` call.
    /// @dev An honest implementation is `pure` and returns a constant: under 500 gas. 100k is
    /// roughly 200x headroom, enough for a hook that reads a few storage slots, while still being
    /// a bounded, affordable loss when the callee is a deliberate gas bomb.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice Gas that must remain before probing.
    /// @dev EIP-150 forwards at most 63/64 of what is left, so `PROBE_GAS * 64 / 63` is the amount
    /// we must hold to guarantee the child actually receives its full budget. The 30k reserve
    /// covers the storage writes that follow the probe. Below this floor we revert rather than
    /// record a verdict that a starved call frame produced.
    uint256 public constant PROBE_GAS_FLOOR = PROBE_GAS + PROBE_GAS / 63 + 30_000;

    /*//////////////////////////////////////////////////////////////
                            METADATA LIMITS
        Bounded so one registration cannot write unbounded storage
        or emit an unbounded log. Generous enough that no honest
        listing hits them.
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_DESCRIPTION_BYTES = 2048;
    uint256 public constant MAX_URI_BYTES = 512;
    uint256 public constant MAX_NOTE_BYTES = 512;
    uint256 public constant MAX_CHAINS = 32;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Vault this registry believes about pool managers.
    /// @dev Immutable. The Vault is the protocol root and there is exactly one; making this
    /// settable would hand whoever can set it the power to mint attestations from a contract of
    /// their own choosing, which is the entire attack this mechanism closes.
    IVaultAppRegistry public immutable vault;

    mapping(address hook => DeepCoreRecord) private _records;

    /// @dev Which pools have already been counted for a hook, so `attestationCount` means
    /// "distinct live pools" and re-attesting the same pool cannot inflate it or spam the log.
    mapping(address hook => mapping(bytes32 poolId => bool counted)) private _attestedPools;

    /// @dev Append-only. Index positions are stable forever, which is what lets an indexer page
    /// through the registry without worrying about entries shifting underneath it.
    address[] private _hookList;

    /// @dev Append-only, same guarantee.
    mapping(address submitter => address[] hooks) private _submitted;

    /// @dev How many accounts hold DEFAULT_ADMIN_ROLE. Maintained by the `_grantRole` /
    /// `_revokeRole` overrides so the last one cannot be dropped. See those overrides for why.
    uint256 private _adminCount;

    /// @param admin Holds DEFAULT_ADMIN_ROLE and therefore decides who curates. Should be
    /// DeepCoreTimelock or the governance Safe on any live chain, never an EOA.
    /// @param vault_ The DeepCoreProtocol Vault. Pool managers are believed iff this Vault has
    /// registered them as apps.
    /// @param curators Initial curators. May be empty; the admin can appoint later.
    /// @param guardians Initial guardians. May be empty.
    constructor(address admin, address vault_, address[] memory curators, address[] memory guardians) {
        if (admin == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = IVaultAppRegistry(vault_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i; i < curators.length; ++i) {
            _grantRole(CURATOR_ROLE, curators[i]);
        }
        for (uint256 i; i < guardians.length; ++i) {
            _grantRole(GUARDIAN_ROLE, guardians[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONLESS SUBMISSION
    //////////////////////////////////////////////////////////////*/

    /// @notice List a hook. Open to anyone, free, no allowlist.
    /// @dev The permissions recorded are read from `hook` itself; `metadata` cannot influence them.
    /// Registration is rejected if the bitmap cannot be read, declares reserved bits 14-15, or
    /// declares a returns-delta bit without the base callback that returns it. Those are not
    /// stylistic objections: core calls the same function during pool initialization, so such a
    /// hook can never back a pool. Listing it would create an official-looking entry for something
    /// that is unusable, and "permissions unknown" is the one thing this registry must never say.
    ///
    /// What this DOES NOT establish: that the bitmap is true. It is the hook's answer to a caller
    /// the hook can identify. A fresh listing is `PermissionSource.SelfReported` and a front end
    /// must say so. Call `attestFromPool` — or use `registerWithPool` — the moment a live pool
    /// exists. Registration is deliberately still open to hooks with no pool yet: refusing to list
    /// an unused hook would make the registry useless exactly when a developer needs it, at launch.
    /// @param hook Address of the deployed hook contract.
    /// @param metadata Human-readable listing data. Purely descriptive.
    function register(address hook, DeepCoreMetadata calldata metadata) external {
        _register(hook, metadata);
    }

    /// @notice List a hook and attest it against a live pool in the same transaction.
    /// @dev The path a hook developer should take once their pool exists. Identical to `register`
    /// followed by `attestFromPool`; it exists so the corroborated state is reachable in one call
    /// and a UI never has to show a freshly listed hook in the weaker state.
    function registerWithPool(address hook, DeepCoreMetadata calldata metadata, address poolManager, bytes32 poolId)
        external
    {
        _register(hook, metadata);
        _attest(hook, poolManager, poolId);
    }

    function _register(address hook, DeepCoreMetadata calldata metadata) private {
        if (hook == address(0)) revert ZeroAddress();
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter != address(0)) revert DeepCoreAlreadyRegistered(hook);
        if (hook.code.length == 0) revert DeepCoreHasNoCode(hook);

        _validateMetadata(metadata);

        (bool readable, uint16 permissions) = _probePermissions(hook);
        if (!readable) revert PermissionsUnreadable(hook);
        if (permissions & PERM_RESERVED_BITS != 0) revert ReservedBitsSet(permissions);
        if (!_dependenciesSatisfied(permissions)) revert PermissionDependencyMissing(permissions);

        bytes32 codehash = hook.codehash;

        record.submitter = msg.sender;
        record.steward = msg.sender;
        record.submittedAt = uint64(block.timestamp);
        record.updatedAt = uint64(block.timestamp);
        record.permissions = permissions;
        record.permissionsValid = true;
        record.permissionsReadable = true;
        record.verification = Verification.Unverified;
        record.listing = Listing.Active;
        record.codehash = codehash;
        _writeMetadata(record, metadata);

        _hookList.push(hook);
        _submitted[msg.sender].push(hook);

        emit DeepCoreRegistered(hook, msg.sender, permissions, classify(permissions), codehash, uint64(block.timestamp));
        _emitMetadata(hook, metadata);
    }

    /// @notice Re-read a hook's permissions and code hash from chain.
    /// @dev Permissionless on purpose. `getHooksRegistrationBitmap` is `view`, not `pure` — an
    /// implementation may read storage, and any hook behind a proxy can be swapped wholesale. The
    /// bitmap recorded at registration is a snapshot, and this is how the snapshot gets corrected.
    ///
    /// If anything moved, verification drops to `Unverified`, because an audit attests to a
    /// specific deployment and stops meaning anything the moment that deployment changes. This is
    /// not griefable: the demotion only fires when the hook's own answer or code hash actually
    /// differs from what was recorded, which is information no third party controls. Callers with
    /// too little gas are rejected by the `PROBE_GAS_FLOOR` check rather than being allowed to
    /// manufacture an "unreadable" verdict.
    ///
    /// Reverts with `PermissionsUnchanged` when there is nothing to record, so keepers cannot spam
    /// the log. Probe it with `eth_call` first if you want a cheap no-op.
    function refreshPermissions(address hook) external {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);

        uint16 previousPermissions = record.permissions;
        bytes32 previousCodehash = record.codehash;

        (bool readable, uint16 permissions) = _probePermissions(hook);
        bytes32 currentCodehash = hook.codehash;
        bool valid = readable && permissions & PERM_RESERVED_BITS == 0 && _dependenciesSatisfied(permissions);

        bool changed = readable != record.permissionsReadable || valid != record.permissionsValid
            || currentCodehash != previousCodehash || (readable && permissions != previousPermissions);
        if (!changed) revert PermissionsUnchanged(hook);

        // A failed read leaves the last known bitmap in place rather than zeroing it. Zero is a
        // meaningful bitmap ("this hook is never called"); silently claiming it for a hook that
        // merely stopped answering would understate its capabilities, which is the wrong direction
        // to be wrong in. `permissionsReadable == false` is the signal that the value is stale.
        if (readable) record.permissions = permissions;
        record.permissionsReadable = readable;
        record.permissionsValid = valid;
        record.codehash = currentCodehash;
        record.updatedAt = uint64(block.timestamp);

        emit DeepCorePermissionsRefreshed(
            hook,
            msg.sender,
            previousPermissions,
            record.permissions,
            previousCodehash,
            currentCodehash,
            readable,
            valid
        );

        _demote(hook, record, "on-chain permissions or code changed");
    }

    /*//////////////////////////////////////////////////////////////
                           POOL ATTESTATION
        The only un-spoofable permission source on chain. See the
        contract-level notes for the full chain of custody.
    //////////////////////////////////////////////////////////////*/

    /// @notice Record the bitmap a live pool actually enforces for this hook.
    ///
    /// @dev Permissionless, and safe to leave that way: every outcome of this function either adds
    /// bits to `attestedPermissions` or reverts. There is no argument, ordering or repetition that
    /// makes a record look milder, so there is nothing here for an attacker to want.
    ///
    /// The pool key is READ BACK from the manager rather than accepted from the caller. `poolId`
    /// is only used to look it up, and the stored key is then required to hash back to that id, so
    /// a caller supplying a doctored key changes the id and finds nothing.
    ///
    /// Effects on the record:
    ///   - `attestedPermissions |= poolPermissions`. Monotone, never cleared.
    ///   - If that union GREW, verification is reset to `Unverified`: a badge attests to a set of
    ///     capabilities, and capabilities nobody had seen when it was granted are outside it. This
    ///     is not griefable — the demotion is driven by an immutable on-chain fact, it can happen
    ///     at most once per genuinely new bitmap, and a curator who attests every live pool before
    ///     badging will never see it.
    ///   - If the union exceeds what the hook told the registry, `DeepCorePermissionsUnderstated` is
    ///     emitted and `PermissionSource` becomes `PoolAttestedDivergent`. The listing is NOT
    ///     auto-flagged `Malicious`: divergence has an innocent explanation (one hook, two pool
    ///     types, two bitmaps) and permissionless slander is not a power this contract hands out.
    ///     Flagging stays a guardian decision, now made with the evidence in front of them.
    ///
    /// @param hook The registered hook the attestation speaks for.
    /// @param poolManager A pool manager the Vault has registered as an app.
    /// @param poolId The pool's id, i.e. `keccak256` over its `PoolKey`.
    function attestFromPool(address hook, address poolManager, bytes32 poolId) external {
        _attest(hook, poolManager, poolId);
    }

    /// @notice `attestFromPool` for callers that hold the `PoolKey` rather than the id.
    /// @dev The key is used ONLY to derive the id. Every field is then re-read from the manager
    /// and validated, so passing a doctored key cannot smuggle anything in — it just fails to
    /// resolve. Kept as a convenience because periphery and the SDK carry keys, not ids.
    function attestFromPoolKey(address hook, PoolKey calldata key) external {
        PoolKey memory k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: key.hooks,
            poolManager: key.poolManager,
            fee: key.fee,
            parameters: key.parameters
        });
        _attest(hook, address(key.poolManager), PoolId.unwrap(k.toId()));
    }

    function _attest(address hook, address poolManager, bytes32 poolId) private {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);

        // The Vault is the trust anchor. Everything below reads state from `poolManager`, so if
        // this check is wrong nothing after it means anything.
        PoolProof.requireTrustedManager(vault, poolManager);

        if (_attestedPools[hook][poolId]) revert PoolAlreadyAttested(hook, poolId);

        uint16 poolPermissions = _readPoolBitmap(hook, poolManager, poolId);

        uint16 previousUnion = record.attestedPermissions;
        uint16 union = previousUnion | poolPermissions;
        uint32 count = record.attestationCount + 1;

        _attestedPools[hook][poolId] = true;
        record.attestedPermissions = union;
        record.attestedPoolManager = poolManager;
        record.attestedPoolId = poolId;
        record.attestedAt = uint64(block.timestamp);
        record.attestationCount = count;
        record.updatedAt = uint64(block.timestamp);

        uint16 selfReported = record.permissions;
        emit DeepCorePoolAttested(hook, msg.sender, poolManager, poolId, poolPermissions, union, selfReported, count);

        uint16 concealed = union & ~selfReported;
        if (concealed != 0) {
            emit DeepCorePermissionsUnderstated(hook, selfReported, union, concealed);
        }

        // Only when new capability appears. An attestation that merely re-confirms what was
        // already known must not cost an honest listing its badge.
        if (union != previousUnion) {
            _demote(hook, record, "a live pool revealed permissions not covered by this attestation");
        }
    }

    /// @dev Resolve `poolId` on `poolManager` and return the bitmap that pool enforces.
    ///
    /// The proof itself lives in `PoolProof` because `DeepCoreLaunchRegistry` rests on exactly the
    /// same three checks, and this is the only load-bearing security logic either of them has —
    /// two copies would be two chances to fix a bug in one and not the other. See that library for
    /// what each check closes. `PoolProof`'s errors share their selectors with the ones declared on
    /// `IDeepCoreRegistry`, so nothing a consumer matches on changes.
    ///
    /// An uninitialized slot returns the zero key, whose `poolManager` is `address(0)`, so an
    /// unused id fails the first check and can never attest anything.
    function _readPoolBitmap(address hook, address poolManager, bytes32 poolId) private view returns (uint16) {
        PoolKey memory key = PoolProof.verifiedKeyFor(poolManager, poolId, hook);
        return key.parameters.getHooksRegistrationBitmap();
    }

    /*//////////////////////////////////////////////////////////////
                            STEWARD ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Replace a listing's metadata.
    /// @dev Callable by the steward or by a curator. A steward edit ALWAYS resets verification to
    /// `Unverified`; a curator edit does not. Without that rule the ladder is decorative: get an
    /// audit badge on an honest listing, then repoint `sourceURI` at a repo that no longer matches
    /// the bytecode, or `auditURI` at a report for a different contract, and the badge now vouches
    /// for something no curator ever saw.
    function updateMetadata(address hook, DeepCoreMetadata calldata metadata) external {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);

        bool asCurator = hasRole(CURATOR_ROLE, msg.sender);
        if (msg.sender != record.steward && !asCurator) revert NotSteward(hook, msg.sender);

        _validateMetadata(metadata);
        _writeMetadata(record, metadata);
        record.updatedAt = uint64(block.timestamp);

        _emitMetadata(hook, metadata);
        if (!asCurator) _demote(hook, record, "metadata edited by steward");
    }

    /// @notice Hand over the right to edit a listing's metadata.
    /// @dev Two callers, one function. The steward uses it to hand a listing to a co-maintainer or
    /// to the real author. A curator uses it to fix the squatting case: registration is open, so
    /// nothing stops a stranger from listing someone else's hook first and controlling its
    /// description. That is the price of ungated submission, and reassignment is the right remedy
    /// because it repairs the listing instead of deleting it. `submitter` never changes — the
    /// historical record of who actually listed it stays intact and auditable.
    function transferSteward(address hook, address newSteward) external {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        if (newSteward == address(0)) revert ZeroAddress();
        if (msg.sender != record.steward && !hasRole(CURATOR_ROLE, msg.sender)) {
            revert NotSteward(hook, msg.sender);
        }

        address previous = record.steward;
        record.steward = newSteward;
        record.updatedAt = uint64(block.timestamp);
        emit DeepCoreStewardTransferred(hook, previous, newSteward);
    }

    /*//////////////////////////////////////////////////////////////
                            CURATED PROMOTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Move a hook along the verification ladder. Curator only, both directions.
    /// @dev Guards, all of which exist so a badge cannot mean less than it appears to:
    ///   - `SourceVerified` and above need a non-empty `sourceURI`; `Audited` also needs a
    ///     non-empty `auditURI`. A badge with nothing to click through to is theatre.
    ///   - Nothing can be promoted while flagged `Malicious`. Rehabilitation is two transactions
    ///     so it leaves two separately reviewable log entries.
    ///   - Nothing can be promoted while its permissions are unreadable or invalid.
    ///   - NOTHING CAN BE PROMOTED WITHOUT AT LEAST ONE POOL ATTESTATION. A badge on a record whose
    ///     only evidence is the hook's own answer to a caller it can identify is exactly the lie
    ///     this registry exists to prevent — an official-looking "Audited · Passive · takes no cut"
    ///     over a hook skimming every swap. The badge waits for a live pool.
    ///
    ///     This applies to `SourceVerified` too, not just `Audited`. `SourceVerified` reads to a
    ///     user as "the registry checked something", and the thing most worth checking is the
    ///     capability line printed next to it. The cost is real and accepted: a hook listed before
    ///     any pool uses it cannot carry a badge yet. Nobody is exposed to it yet either.
    /// @param note Short free-text rationale, emitted with the event. May be empty.
    function setVerification(address hook, Verification level, string calldata note) external onlyRole(CURATOR_ROLE) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        _boundString(bytes(note).length, MAX_NOTE_BYTES);

        if (level != Verification.Unverified) {
            if (record.listing == Listing.Malicious) revert DeepCoreFlaggedMalicious(hook);
            if (!record.permissionsReadable || !record.permissionsValid) {
                revert PermissionsNotAttestable(hook);
            }
            if (record.attestationCount == 0) revert AttestationRequired(hook);
            if (bytes(record.metadata.sourceURI).length == 0) revert SourceURIRequired();
            if (level == Verification.Audited && bytes(record.metadata.auditURI).length == 0) {
                revert AuditURIRequired();
            }
        }

        Verification previous = record.verification;
        record.verification = level;
        record.updatedAt = uint64(block.timestamp);
        emit DeepCoreVerificationChanged(hook, msg.sender, previous, level, note);
    }

    /// @notice Deprecate a hook, flag it malicious, or restore it to active.
    /// @dev Curators may set any status. Guardians may only move a listing to a strictly more
    /// cautious one, never back. Flagging `Malicious` force-resets verification to `Unverified` in
    /// the same transaction — a hook that turned out to be malicious must not keep presenting an
    /// audited badge for even one block, and relying on a curator to remember the second call is
    /// exactly the kind of gap incidents are made of. `Deprecated` deliberately KEEPS verification:
    /// a superseded but genuinely audited hook is not a lie, and erasing the audit there would
    /// punish maintainers for retiring old versions honestly.
    /// @param reason Emitted verbatim. This is what a marketplace shows next to the warning, so it
    /// should be a sentence a user can act on, not a ticket number.
    function setListing(address hook, Listing status, string calldata reason) external {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        _boundString(bytes(reason).length, MAX_NOTE_BYTES);

        if (!hasRole(CURATOR_ROLE, msg.sender)) {
            if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert NotCuratorOrGuardian(msg.sender);
            if (uint8(status) <= uint8(record.listing)) {
                revert GuardianCannotRelist(record.listing, status);
            }
        }

        Listing previous = record.listing;
        record.listing = status;
        record.updatedAt = uint64(block.timestamp);
        emit DeepCoreListingChanged(hook, msg.sender, previous, status, reason);

        if (status == Listing.Malicious) _demote(hook, record, "flagged malicious");
    }

    /*//////////////////////////////////////////////////////////////
                          UNTRUSTED CALL PROBE
    //////////////////////////////////////////////////////////////*/

    /// @dev The only place this contract touches an unvetted address. See the contract-level notes.
    /// @return readable True only if the call succeeded, returned exactly 32 bytes, and those bytes
    /// are a clean `uint16` — the same three conditions solc's own decoder would impose.
    /// @return permissions The decoded bitmap, or zero when `readable` is false.
    function _probePermissions(address hook) private view returns (bool readable, uint16 permissions) {
        uint256 available = gasleft();
        if (available < PROBE_GAS_FLOOR) revert InsufficientGasForProbe(available, PROBE_GAS_FLOOR);

        bytes4 selector = IHooks.getHooksRegistrationBitmap.selector;
        uint256 budget = PROBE_GAS;
        bool success;
        uint256 raw;

        assembly ("memory-safe") {
            // Scratch space (0x00-0x3f) only: 4 bytes of calldata in, 32 bytes of return out.
            // The input is fully consumed before the output is written, so one buffer is enough.
            mstore(0, selector)
            success := staticcall(budget, hook, 0, 4, 0, 32)
            raw := mload(0)
            // A return bomb is truncated by outsize=32 above; this rejects anything that is not
            // exactly one word, including the empty return of a plain EOA-like fallback.
            success := and(success, eq(returndatasize(), 32))
        }

        if (!success) return (false, 0);
        // Dirty high bits are not a small bitmap. Core decodes this as `uint16` and solc reverts on
        // a value that does not fit, so accepting the low 16 bits here would let a hook show a tame
        // bitmap in the registry while being unusable, or differently readable, everywhere else.
        if (raw > type(uint16).max) return (false, 0);
        return (true, uint16(raw));
    }

    /*//////////////////////////////////////////////////////////////
                          PERMISSION SEMANTICS
        Pure, shared with the SDK, the lint package and the UI so
        that one bitmap cannot be described three different ways.
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether a bitmap is one core would accept.
    /// @dev Mirrors `BaseCLHook._validatePermissions`. The body lives in `PermissionMath` so the
    /// launch index cannot end up describing the same pool's hook differently; these stay on the
    /// ABI because the SDK, the lint package and the UI all call them.
    function isValidBitmap(uint16 permissions) public pure returns (bool) {
        return PermissionMath.isValidBitmap(permissions);
    }

    /// @dev A returns-delta bit is meaningless without the callback that returns the delta.
    function _dependenciesSatisfied(uint16 p) private pure returns (bool) {
        return PermissionMath.dependenciesSatisfied(p);
    }

    /// @notice Capability class of a bitmap. Derived, not curated — no role can change this.
    function classify(uint16 permissions) public pure returns (RiskClass) {
        return PermissionMath.classify(permissions);
    }

    /// @notice True if the hook can take a cut of every swap in its pool (bits 10 or 11).
    function takesSwapCut(uint16 permissions) public pure returns (bool) {
        return permissions & PERM_SWAP_CUT_MASK != 0;
    }

    /// @notice True if the hook can take a cut of any swap or liquidity movement (bits 10-13).
    function returnsDelta(uint16 permissions) public pure returns (bool) {
        return permissions & PERM_RETURNS_DELTA_MASK != 0;
    }

    /// @notice True if the hook can block trading in its pool outright (bit 6).
    function canBlockSwaps(uint16 permissions) public pure returns (bool) {
        return permissions & PERM_BEFORE_SWAP != 0;
    }

    /// @notice True if the hook can refuse liquidity withdrawals and strand LP funds (bit 4).
    function canTrapLiquidity(uint16 permissions) public pure returns (bool) {
        return permissions & PERM_BEFORE_REMOVE_LIQUIDITY != 0;
    }

    /// @notice Expand a bitmap into named booleans.
    function decodePermissions(uint16 p) public pure returns (DecodedPermissions memory d) {
        d.beforeInitialize = p & PERM_BEFORE_INITIALIZE != 0;
        d.afterInitialize = p & PERM_AFTER_INITIALIZE != 0;
        d.beforeAddLiquidity = p & PERM_BEFORE_ADD_LIQUIDITY != 0;
        d.afterAddLiquidity = p & PERM_AFTER_ADD_LIQUIDITY != 0;
        d.beforeRemoveLiquidity = p & PERM_BEFORE_REMOVE_LIQUIDITY != 0;
        d.afterRemoveLiquidity = p & PERM_AFTER_REMOVE_LIQUIDITY != 0;
        d.beforeSwap = p & PERM_BEFORE_SWAP != 0;
        d.afterSwap = p & PERM_AFTER_SWAP != 0;
        d.beforeDonate = p & PERM_BEFORE_DONATE != 0;
        d.afterDonate = p & PERM_AFTER_DONATE != 0;
        d.beforeSwapReturnsDelta = p & PERM_BEFORE_SWAP_RETURNS_DELTA != 0;
        d.afterSwapReturnsDelta = p & PERM_AFTER_SWAP_RETURNS_DELTA != 0;
        d.afterAddLiquidityReturnsDelta = p & PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA != 0;
        d.afterRemoveLiquidityReturnsDelta = p & PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA != 0;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function isRegistered(address hook) public view returns (bool) {
        return _records[hook].submitter != address(0);
    }

    /// @notice The full record. Reverts for an unregistered hook rather than returning a zeroed
    /// struct, because a zeroed struct reads as "Unverified, Active, no permissions" — the safest
    /// possible answer about a hook nobody has ever looked at.
    function getDeepCore(address hook) external view returns (DeepCoreRecord memory) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        return record;
    }

    /// @notice The bitmap a consumer should actually act on, and where it came from.
    /// @dev `selfReported | attested`. The union, not a choice between them, because each source
    /// can be true of a different pool and only understating can hurt anybody. An unattested
    /// record returns its self-report with `source == SelfReported`, which a UI must render as
    /// "the hook says so", not as a fact.
    function effectivePermissions(address hook) public view returns (uint16 permissions, PermissionSource source) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        return _effective(record);
    }

    function _effective(DeepCoreRecord storage record) private view returns (uint16 permissions, PermissionSource source) {
        uint16 selfReported = record.permissions;
        if (record.attestationCount == 0) return (selfReported, PermissionSource.SelfReported);

        uint16 attested = record.attestedPermissions;
        permissions = selfReported | attested;
        source =
            (attested & ~selfReported) != 0 ? PermissionSource.PoolAttestedDivergent : PermissionSource.PoolAttested;
    }

    /// @notice Both halves of a permission read, so neither can be shown without the other.
    /// @dev `permissions` is the effective (union) bitmap; `readable`/`valid` describe the last
    /// self-report probe; `source` says whether any live pool corroborates it.
    function permissionsOf(address hook)
        external
        view
        returns (uint16 permissions, bool readable, bool valid, PermissionSource source)
    {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        (permissions, source) = _effective(record);
        return (permissions, record.permissionsReadable, record.permissionsValid, source);
    }

    /// @notice Exactly what the hook told this registry, with nothing merged in.
    /// @dev Only useful for showing the two side by side. Do not size a risk warning off it.
    function selfReportedPermissionsOf(address hook) external view returns (uint16) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        return record.permissions;
    }

    /// @notice Risk class of the EFFECTIVE bitmap. Never milder than either source alone.
    function riskClassOf(address hook) external view returns (RiskClass) {
        (uint16 permissions,) = effectivePermissions(hook);
        return classify(permissions);
    }

    /// @notice The class and its provenance in one call.
    /// @dev Use this, not `riskClassOf`, anywhere a badge or a class label is rendered. A
    /// `Passive` on a `SelfReported` record and a `Passive` on a `PoolAttested` record are two
    /// very different statements, and separate calls make it easy to ship only the first.
    function riskAssessmentOf(address hook)
        external
        view
        returns (RiskClass class, PermissionSource source, uint32 attestationCount)
    {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        uint16 permissions;
        (permissions, source) = _effective(record);
        return (classify(permissions), source, record.attestationCount);
    }

    /// @notice True once at least one live pool has corroborated this hook.
    function isAttested(address hook) external view returns (bool) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        return record.attestationCount > 0;
    }

    /// @notice The bits a live pool enforces that the hook did not admit to this registry.
    /// @dev Non-zero is direct evidence that `getHooksRegistrationBitmap()` answers this address
    /// differently than it answered core. Always zero for an unattested record — absence of
    /// evidence, which is not the same as zero concealment.
    function permissionsConcealed(address hook) external view returns (uint16) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        if (record.attestationCount == 0) return 0;
        return record.attestedPermissions & ~record.permissions;
    }

    /// @notice The most recent attestation, for linking a badge back to the pool that earned it.
    function attestationOf(address hook)
        external
        view
        returns (uint32 count, uint16 attestedPermissions, address poolManager, bytes32 poolId, uint64 attestedAt)
    {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        return (
            record.attestationCount,
            record.attestedPermissions,
            record.attestedPoolManager,
            record.attestedPoolId,
            record.attestedAt
        );
    }

    /// @notice Whether this exact pool has already been counted towards `attestationCount`.
    function hasAttestedPool(address hook, bytes32 poolId) external view returns (bool) {
        return _attestedPools[hook][poolId];
    }

    function statusOf(address hook) external view returns (Verification verification, Listing listing) {
        DeepCoreRecord storage record = _records[hook];
        if (record.submitter == address(0)) revert DeepCoreNotRegistered(hook);
        return (record.verification, record.listing);
    }

    /// @notice The single question a front end should ask before showing a trust badge.
    /// @dev Never true for an unregistered hook, a flagged one, one whose code has moved since the
    /// audit was attested, or one no live pool has corroborated. Deliberately a view and not a
    /// modifier anywhere: this contract makes no authorization decisions on anyone's behalf.
    ///
    /// The `attestationCount` term is redundant with the gate in `setVerification` — a record
    /// cannot reach `Audited` without it and attestations are never removed. It is restated here
    /// anyway, because this is the function integrators actually call and the invariant it depends
    /// on lives in a different function.
    function isAudited(address hook) external view returns (bool) {
        DeepCoreRecord storage record = _records[hook];
        return record.submitter != address(0) && record.verification == Verification.Audited
            && record.listing == Listing.Active && record.permissionsReadable && record.permissionsValid
            && record.attestationCount > 0;
    }

    function deepcoreCount() external view returns (uint256) {
        return _hookList.length;
    }

    function deepcoreAt(uint256 index) external view returns (address) {
        return _hookList[index];
    }

    /// @notice Page through every registered hook. Index positions never change.
    function listDeepCores(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _hookList.page(offset, limit);
    }

    function submittedCount(address submitter) external view returns (uint256) {
        return _submitted[submitter].length;
    }

    function listBySubmitter(address submitter, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        return _submitted[submitter].page(offset, limit);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN ROLE CANNOT BE DROPPED

        AccessControl's default behaviour lets the sole holder of
        DEFAULT_ADMIN_ROLE walk away — `renounceRole`, or
        `revokeRole` on itself. Here that is a one-way brick: the
        admin role is the ONLY way to appoint a curator or a
        guardian, and there is no other path to either. Listings
        would keep working (register and refreshPermissions are
        permissionless), but nothing could ever be badged again and
        NOTHING COULD EVER BE FLAGGED MALICIOUS AGAIN. A safety
        surface that cannot raise an alarm is worse than none,
        because it still looks like one.

        This is the registry's analogue of the `renounceOwnership`
        finding open against the RWA hooks and the oracle. Two
        guards, because the two paths are distinct: renouncing the
        admin role is refused outright (there is never a good reason
        — hand it to a successor instead), and revoking is refused
        only when it would take the count to zero, so ordinary
        rotation of a multi-admin setup still works.

        Curator and guardian stay freely renounceable. Losing every
        holder of those is recoverable in one admin transaction.
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AccessControl
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert AdminRoleIsNotRenounceable();
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev The registry holds nothing by design (no `receive`, no `fallback`), so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
    function rescueERC20(address token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && role == DEFAULT_ADMIN_ROLE) {
            unchecked {
                ++_adminCount;
            }
        }
    }

    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        revoked = super._revokeRole(role, account);
        if (revoked && role == DEFAULT_ADMIN_ROLE) {
            // `revoked` is only true if the account held the role, so the count is at least 1.
            if (_adminCount == 1) revert LastAdminCannotBeRemoved();
            unchecked {
                --_adminCount;
            }
        }
    }

    /// @notice How many accounts hold DEFAULT_ADMIN_ROLE. Never zero after construction.
    function adminCount() external view returns (uint256) {
        return _adminCount;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reset verification and say why. No-op when already unverified, so nothing that merely
    /// re-confirms the status quo shows up in the log.
    function _demote(address hook, DeepCoreRecord storage record, string memory note) private {
        Verification previous = record.verification;
        if (previous == Verification.Unverified) return;
        record.verification = Verification.Unverified;
        emit DeepCoreVerificationChanged(hook, msg.sender, previous, Verification.Unverified, note);
    }

    function _validateMetadata(DeepCoreMetadata calldata metadata) private pure {
        uint256 nameLength = bytes(metadata.name).length;
        if (nameLength == 0) revert EmptyName();
        _boundString(nameLength, MAX_NAME_BYTES);
        _boundString(bytes(metadata.description).length, MAX_DESCRIPTION_BYTES);
        _boundString(bytes(metadata.sourceURI).length, MAX_URI_BYTES);
        _boundString(bytes(metadata.auditURI).length, MAX_URI_BYTES);
        if (metadata.chainIds.length > MAX_CHAINS) revert TooManyChains(metadata.chainIds.length, MAX_CHAINS);
    }

    function _boundString(uint256 length, uint256 maximum) private pure {
        if (length > maximum) revert StringTooLong(length, maximum);
    }

    function _writeMetadata(DeepCoreRecord storage record, DeepCoreMetadata calldata metadata) private {
        record.metadata.name = metadata.name;
        record.metadata.description = metadata.description;
        record.metadata.sourceURI = metadata.sourceURI;
        record.metadata.auditURI = metadata.auditURI;
        record.metadata.chainIds = metadata.chainIds;
    }

    function _emitMetadata(address hook, DeepCoreMetadata calldata metadata) private {
        emit DeepCoreMetadataUpdated(
            hook,
            msg.sender,
            metadata.name,
            metadata.description,
            metadata.sourceURI,
            metadata.auditURI,
            metadata.chainIds
        );
    }
}
