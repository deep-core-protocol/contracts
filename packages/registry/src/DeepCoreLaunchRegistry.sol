/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ParametersHelper} from "infinity-core/src/libraries/math/ParametersHelper.sol";

import {Verification, Listing, RiskClass} from "./IDeepCoreRegistry.sol";
import {IDeepCoreLaunchOrigin} from "./IDeepCoreLaunchOrigin.sol";
import {
    IDeepCoreLaunchRegistry,
    LaunchMetadata,
    LaunchRecord,
    LaunchOrigin,
    LaunchpadMetadata,
    LaunchpadRecord,
    LaunchpadOrigin
} from "./IDeepCoreLaunchRegistry.sol";
import {PoolProof, IVaultAppRegistry} from "./libraries/PoolProof.sol";
import {PermissionMath} from "./libraries/PermissionMath.sol";
import {RegistryPaging} from "./libraries/RegistryPaging.sol";

/// @notice What this registry needs from `DeepCoreRegistry`.
/// @dev Narrow on purpose, and every entry is either a read or a permissionless write. This
/// contract holds NO privileged position in the DeepCore registry and must never be given one.
interface IDeepCoreRegistryLink {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function isRegistered(address hook) external view returns (bool);
    function attestFromPool(address hook, address poolManager, bytes32 poolId) external;
}

/// @title DeepCoreLaunchRegistry
/// @notice The shared index of tokens launched through any DeepCore-based launchpad.
///
/// @dev ####################### WHY THIS CONTRACT EXISTS #######################
///
/// DeepCore is infrastructure other people ship on. A tenant deploys their own launchpad, their own
/// hook and their own UI against the Vault and pool managers DeepCore already has live. The thing
/// that makes being a tenant worth more than forking the whole stack is that a launch registered
/// here is visible in EVERY tenant's marketplace, while a full fork starts with an empty index.
/// That is the network effect, and it is one of the few defensible assets in a GPL codebase.
///
/// A network effect made of unverifiable records is not an asset, it is a liability, because the
/// first convincing fake launch teaches every reader to discount the whole index. So the governing
/// question for every line below is: WHAT CAN ACTUALLY BE PROVEN ON CHAIN, and what has to be
/// labelled as somebody's word.
///
/// ############################ WHAT IS PROVEN ############################
///
/// Every record in this registry is pool-proven. There is no such thing as an unverified pool
/// here: `registerLaunch` reads the `PoolKey` back out of a pool manager the Vault has registered
/// (`PoolProof`, shared with `DeepCoreRegistry.attestFromPool`), so these are measurements:
///
///   - the pool exists and is initialized;
///   - its two currencies, its fee, and its hook;
///   - the permission bitmap that hook enforces in that pool, from the immutable `parameters`;
///   - that the launched token is one of the two currencies.
///
/// Also read rather than accepted: the token's own `name()`, `symbol()` and `decimals()`. A
/// registrant CANNOT type a name or a symbol into a record. Listing a worthless token under the
/// symbol `USDC` is the oldest launchpad scam there is, and an official-looking index that let a
/// submitter supply the ticker would be performing the laundering rather than preventing it.
///
/// ########################## WHAT CANNOT BE PROVEN ##########################
///
/// Two things, and they are stated here because a reader deserves to know where the floor is:
///
///   1. WHEN A POOL OPENED. Core stores no initialization timestamp — `poolIdToPoolKey` has no
///      such field and `getSlot0` carries price and fees, not time. `registeredAt` is when THIS
///      RECORD was written, which for a retroactively indexed launch can be months late. It must
///      never be rendered as a launch date. An indexer that wants the real one has to read the
///      manager's `Initialize` log, which no contract can do.
///
///   2. WHO OPENED IT. Core keeps no creator either; the sender survives only in that same log.
///      "Launched via Acme" is therefore a fact only Acme's own contract holds, which is the
///      entire reason `LaunchOrigin` exists.
///
/// ################ HOW ATTRIBUTION IS MADE UNFORGEABLE ANYWAY ################
///
/// A launch record may name a launchpad only when the launchpad's own code named the pool. Two
/// accepted paths, no others:
///
///   - the launchpad IS `msg.sender`. Unforgeable by construction, and when the registration sits
///     in the same transaction as `initialize` it cannot even be front-run;
///   - the launchpad answers `IDeepCoreLaunchOrigin.launchOriginOf(poolId)` with a non-zero creator,
///     through the same gas-capped, size-checked `staticcall` discipline `DeepCoreRegistry` uses on
///     an unvetted hook.
///
/// Anything else REVERTS. There is no "claimed launchpad" field to downgrade into, because a field
/// holding an unproven name is a field some front end will render without the caveat. The result
/// is the property the whole network effect rests on:
///
///     NOBODY CAN HANG A LAUNCH OFF SOMEBODY ELSE'S LAUNCHPAD.
///
/// And plainly, the property it does NOT give: a launchpad that answers `launchOriginOf` for pools
/// it did not create can steal attribution FOR itself. It cannot fake being a different launchpad,
/// only over-claim as itself, and it does so at an address a curator can clear and a guardian can
/// flag. `provenanceOf` therefore returns the launchpad's verification and listing status in the
/// same call as the attribution, so no UI can show the second without the first.
///
/// ########################### NO ROLES OF ITS OWN ###########################
///
/// This contract deliberately does NOT inherit AccessControl. `CURATOR_ROLE` and `GUARDIAN_ROLE`
/// are read from the live `DeepCoreRegistry`, which already owns that governance surface and whose
/// role assignments are tabulated in CLAUDE.md. One admin, one place to grant curation, no new row
/// in the ownership table, and a curator appointed to handle a malicious DeepCore can flag the
/// launches that use it without a second grant landing first. The cost, accepted: this registry
/// cannot have a curator the DeepCore registry does not, and pointing it at a different registry
/// address would repoint its governance — which is why `deepcoreRegistry` is immutable.
///
/// ########################## WHY NOTHING IS DELETED ##########################
///
/// Same as `DeepCoreRegistry`, for the same four reasons, and one more that is specific to launches:
/// the users who most need a `Malicious` flag on a launch are the ones already holding the token.
/// Delisting is precisely the moment they stop being able to look it up.
contract DeepCoreLaunchRegistry is IDeepCoreLaunchRegistry {
    using ParametersHelper for bytes32;
    using RegistryPaging for bytes32[];
    using RegistryPaging for address[];

    /*//////////////////////////////////////////////////////////////
                                 ROLES

        The values MUST equal DeepCoreRegistry's. They are the same
        roles, on the same contract, read across rather than
        duplicated — see the header. Restated as literals because
        the constants are `public constant` on the implementation
        and pulling in the whole implementation to read two hashes
        would drag the DeepCore registry's bytecode into this build.
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant CURATOR_ROLE = keccak256("DEEPCORE_HOOK_REGISTRY_CURATOR");
    bytes32 public constant GUARDIAN_ROLE = keccak256("DEEPCORE_HOOK_REGISTRY_GUARDIAN");

    /*//////////////////////////////////////////////////////////////
                              PROBE LIMITS

        Identical discipline to DeepCoreRegistry._probePermissions,
        applied to three more untrusted callees: the launch token
        and the launchpad. See that contract's header for why an
        untrusted `view` function is a claim and never a
        measurement — the probes below are defensive about the
        CALL, never about the ANSWER.
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard gas ceiling on any call into an unvetted contract.
    uint256 public constant PROBE_GAS = 100_000;

    /// @notice Gas that must remain before probing.
    /// @dev EIP-150 forwards at most 63/64 of what is left, so `PROBE_GAS * 64 / 63` is what we
    /// must hold for the child to actually receive its full budget. The 30k reserve covers the
    /// writes that follow. Below this floor we revert rather than record a verdict that a starved
    /// call frame produced — without it, anyone could call `refreshTokenInfo` with hand-tuned gas
    /// and blank out an honest token's name.
    uint256 public constant PROBE_GAS_FLOOR = PROBE_GAS + PROBE_GAS / 63 + 30_000;

    /*//////////////////////////////////////////////////////////////
                            METADATA LIMITS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_TOKEN_NAME_BYTES = 128;
    uint256 public constant MAX_TOKEN_SYMBOL_BYTES = 32;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_DESCRIPTION_BYTES = 2048;
    uint256 public constant MAX_URI_BYTES = 512;
    uint256 public constant MAX_NOTE_BYTES = 512;

    /// @notice X's own maximum handle length. Not a DeepCore choice — matching the platform is the
    /// whole reason a handle can be rendered into a URL without being checked again downstream.
    uint256 public constant MAX_X_HANDLE_BYTES = 15;

    /// @notice Telegram's own maximum. The check is a REFUSAL rather than a truncation: a
    /// 33-character value silently cut to 32 would store a handle that renders as a working link
    /// to somebody else's channel. (It happens to equal 32, which is where these fields' original
    /// `bytes32` encoding came from — that encoding is gone, but the platform limit is unchanged
    /// because it was never ours to choose.)
    uint256 public constant MAX_TELEGRAM_HANDLE_BYTES = 32;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Vault this registry believes about pool managers.
    /// @dev Immutable. There is exactly one Vault and it is the protocol root; making this settable
    /// would hand whoever can set it the power to mint pool proofs from a contract of their own
    /// choosing, which is the attack the whole mechanism closes.
    IVaultAppRegistry public immutable vault;

    /// @notice The DeepCore registry. Supplies this contract's curator and guardian roles, and
    /// receives the hook attestations this contract forwards.
    /// @dev Immutable for the same reason: it IS the governance surface, so a setter would be a
    /// governance takeover switch.
    IDeepCoreRegistryLink public immutable deepcoreRegistry;

    mapping(bytes32 poolId => LaunchRecord) private _launches;
    mapping(address launchpad => LaunchpadRecord) private _launchpads;

    /// @dev Append-only. Index positions are stable forever, which is what lets an indexer page
    /// through without entries shifting underneath it.
    bytes32[] private _launchList;
    address[] private _launchpadList;

    /// @dev Secondary indices. `_byToken` and `_byCreator` are append-only. `_byCreator` may hold a
    /// superseded entry when a later `attestLaunchOrigin` replaces a claimed creator with a
    /// launchpad-attested one, so a consumer filtering by creator MUST re-read the record rather
    /// than trusting membership. For those two, mutable indices would break the stable-position
    /// guarantee that makes paging safe, which is the worse trade.
    ///
    /// `_byLaunchpad` is the one exception, and it is a SET: exactly the pools whose record names
    /// that launchpad right now. It used to be append-only too, and `clearLaunchAttribution` left
    /// the cleared pool in it, so `launchpadLaunchCount` kept counting a launch the registry no
    /// longer attributed, `setLaunchpadVerification`'s one-launch gate passed on it, and a pool
    /// cleared then re-attested by the same launchpad was listed twice. "Launched via X" is a
    /// trust claim, so it is kept exact at the cost of position stability: a curator clear
    /// swap-and-pops, moving the last entry into the removed slot. It is rare, curator-only and
    /// always emits `LaunchAttributionCleared`, which is an indexer's cue to re-page that launchpad.
    mapping(address token => bytes32[] poolIds) private _byToken;
    mapping(address launchpad => bytes32[] poolIds) private _byLaunchpad;
    mapping(address creator => bytes32[] poolIds) private _byCreator;

    /// @dev `index + 1` of `poolId` inside `_byLaunchpad[_launches[poolId].launchpad]`; zero means
    /// the pool is not in any launchpad index. A pool names at most one launchpad at a time, so one
    /// position per pool is enough, and it is what makes the removal O(1) whatever the launchpad
    /// has launched — an O(n) scan would let an over-claiming launchpad price its own remedy out of
    /// a block by inflating n. Appended after every pre-existing slot.
    mapping(bytes32 poolId => uint256 indexPlusOne) private _launchpadIndexPosition;

    /// @param vault_ The DeepCoreProtocol Vault. Pool managers are believed iff it registered them.
    /// @param deepcoreRegistry_ The live `DeepCoreRegistry`. Governance and hook listings both come from
    /// here; there is no second admin.
    constructor(address vault_, address deepcoreRegistry_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (deepcoreRegistry_ == address(0)) revert ZeroAddress();
        vault = IVaultAppRegistry(vault_);
        deepcoreRegistry = IDeepCoreRegistryLink(deepcoreRegistry_);
    }

    /*//////////////////////////////////////////////////////////////
                        PERMISSIONLESS SUBMISSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Index a launch. Open to anyone, free, no allowlist.
    ///
    /// @dev Ungated for the same reason `DeepCoreRegistry.register` is: a gated index is a walled
    /// garden, and a walled garden has no network effect. What ungated does NOT mean is that
    /// anything in the record is taken on trust — the pool is proven, the token's identity is read
    /// off the token, and the only field a stranger controls is the free text.
    ///
    /// @param poolManager A pool manager the Vault has registered as an app.
    /// @param poolId The pool's id, i.e. `keccak256` over its `PoolKey`.
    /// @param token The launched token. Must be one of the pool's two currencies and must have
    /// code. WHICH side it is remains the caller's assertion — see `LaunchRecord.token`.
    /// @param launchpad The launchpad to attribute this launch to, or `address(0)` for none.
    /// A non-zero value must vouch, or the call reverts; it is never silently downgraded.
    /// @param creator Used only when `launchpad` is zero or is the caller. When the attribution
    /// comes from a probe, the launchpad's own answer wins and this argument is ignored.
    /// @param steward Who may edit the free text afterwards. `address(0)` means `msg.sender`.
    function registerLaunch(
        address poolManager,
        bytes32 poolId,
        address token,
        address launchpad,
        address creator,
        address steward,
        LaunchMetadata calldata metadata
    ) external {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant != address(0)) revert LaunchAlreadyRegistered(poolId);
        _validateLaunchMetadata(metadata);

        // ---------------------------------------------------------------- proof
        // The Vault check runs FIRST. Everything after it reads state from `poolManager`, so if it
        // is wrong nothing below means anything.
        PoolProof.requireTrustedManager(vault, poolManager);
        PoolKey memory key = PoolProof.verifiedKey(poolManager, poolId);

        if (token == address(0)) revert LaunchTokenCannotBeNative();
        if (token.code.length == 0) revert LaunchTokenHasNoCode(token);

        bool tokenIsCurrency0;
        address quote;
        if (Currency.unwrap(key.currency0) == token) {
            tokenIsCurrency0 = true;
            quote = Currency.unwrap(key.currency1);
        } else if (Currency.unwrap(key.currency1) == token) {
            quote = Currency.unwrap(key.currency0);
        } else {
            revert TokenNotInPool(poolId, token);
        }

        // ----------------------------------------------------------- provenance
        LaunchOrigin origin = LaunchOrigin.Claimed;
        if (launchpad != address(0)) {
            creator = _requireVouch(launchpad, poolId, creator);
            origin = LaunchOrigin.LaunchpadAttested;
        }

        // --------------------------------------------------------------- effects
        record.token = token;
        record.registeredAt = uint64(block.timestamp);
        record.hookPermissions = key.parameters.getHooksRegistrationBitmap();
        record.origin = origin;
        record.listing = Listing.Active;
        record.quote = quote;
        record.updatedAt = uint64(block.timestamp);
        record.fee = key.fee;
        record.poolManager = poolManager;
        record.originAttestedAt = origin == LaunchOrigin.LaunchpadAttested ? uint64(block.timestamp) : 0;
        record.tokenIsCurrency0 = tokenIsCurrency0;
        record.hooks = address(key.hooks);
        record.registeredAtBlock = uint64(block.number);
        record.launchpad = launchpad;
        record.creator = creator;
        record.steward = steward == address(0) ? msg.sender : steward;
        record.registrant = msg.sender;
        _writeLaunchMetadata(record, metadata);

        _launchList.push(poolId);
        _byToken[token].push(poolId);
        if (launchpad != address(0)) _addToLaunchpadIndex(launchpad, poolId);
        if (creator != address(0)) _byCreator[creator].push(poolId);

        emit LaunchRegistered(
            poolId,
            token,
            launchpad,
            poolManager,
            quote,
            address(key.hooks),
            record.hookPermissions,
            key.fee,
            tokenIsCurrency0,
            creator,
            msg.sender,
            origin,
            uint64(block.timestamp)
        );
        _emitLaunchMetadata(poolId, metadata);

        // ------------------------------------------------- interactions, last
        // Both of these call out. Every state write above is already committed, so CEI holds and a
        // callee that misbehaves can only cost this caller gas.
        _readAndStoreTokenInfo(poolId, record, token);
        _forwardHookAttestation(poolId, address(key.hooks), poolManager);
    }

    /*//////////////////////////////////////////////////////////////
                           ORIGIN ATTESTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Prove, after the fact, that a launchpad produced a launch that was indexed without
    /// attribution.
    ///
    /// @dev Permissionless: the only thing this can do is move a record from "nobody knows who made
    /// this" to "this contract says it did", and the launchpad's own bytecode is what decides. The
    /// caller supplies no facts at all.
    ///
    /// Deliberately does NOT touch the steward or the metadata. A launchpad vouching for a pool is
    /// a statement about origin, not a claim on somebody else's editing rights, and letting it move
    /// the steward would turn a hostile launchpad's over-claim into a listing takeover.
    ///
    /// Attribution is one-shot: a record that already names a launchpad reverts. A curator must
    /// `clearLaunchAttribution` first, so replacing an attribution is always two visible steps.
    ///
    /// KNOWN, ACCEPTED: a hostile launchpad can win a race to vouch for somebody else's unattributed
    /// pool, which mislabels the row until a curator clears it. The defence is not on chain — it is
    /// to register at creation time, in the same transaction as `initialize`, where there is no race
    /// to win.
    ///
    /// @param creator Used only when the launchpad is itself the caller — a launchpad that never
    /// implemented `IDeepCoreLaunchOrigin` can still vouch for its own old launches this way, and it
    /// is the only party that could name the creator. Ignored on the probe path, where the
    /// launchpad's own answer is authoritative and overwrites whatever the record claimed before.
    function attestLaunchOrigin(bytes32 poolId, address launchpad, address creator) external {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        if (record.launchpad != address(0)) revert OriginAlreadyAttested(poolId, record.launchpad);
        if (launchpad == address(0)) revert ZeroAddress();

        creator = _requireVouch(launchpad, poolId, creator);

        record.launchpad = launchpad;
        record.creator = creator;
        record.origin = LaunchOrigin.LaunchpadAttested;
        record.originAttestedAt = uint64(block.timestamp);
        record.updatedAt = uint64(block.timestamp);

        _addToLaunchpadIndex(launchpad, poolId);
        if (creator != address(0)) _byCreator[creator].push(poolId);

        emit LaunchOriginAttested(poolId, launchpad, creator, msg.sender);
    }

    /// @notice Remove an attribution. Curator only.
    /// @dev The remedy for an over-claiming launchpad, and the only way `origin` ever moves
    /// backwards. Strictly a REDUCTION — it can never create an attribution, only delete one — so
    /// it fits the house rule that delay belongs on escalation and not on privilege reduction, and
    /// it is safe on the same Ops-tier curator key that flags a malicious DeepCore.
    ///
    /// A curator cannot ASSIGN an attribution, on purpose. If a curator could, `LaunchpadAttested`
    /// would stop meaning "the launchpad's own code said so" and start meaning "somebody with a
    /// role believed it", which is the whole distinction this registry sells. After clearing, the
    /// correct launchpad attests for itself, permissionlessly.
    ///
    /// `creator` is left in place: it is now unattested, and `origin == Claimed` says exactly that.
    ///
    /// The pool also leaves `previous`'s launch index, so `launchpadLaunchCount` and
    /// `launchesOfLaunchpad` stop reporting it. If that was `previous`'s last attributed launch
    /// and it holds a badge, the badge is reset in the same transaction: the ladder's
    /// one-launch precondition no longer holds, and a badge earned on a launch the registry has
    /// just withdrawn must not outlive it. Another strict reduction, so it rides the same key.
    function clearLaunchAttribution(bytes32 poolId, string calldata reason) external {
        _requireCurator();
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        address previous = record.launchpad;
        if (previous == address(0)) revert NoAttributionToClear(poolId);
        _boundString(bytes(reason).length, MAX_NOTE_BYTES);

        record.launchpad = address(0);
        record.origin = LaunchOrigin.Claimed;
        record.originAttestedAt = 0;
        record.updatedAt = uint64(block.timestamp);
        _removeFromLaunchpadIndex(previous, poolId);

        emit LaunchAttributionCleared(poolId, previous, msg.sender, reason);

        if (_byLaunchpad[previous].length == 0) {
            LaunchpadRecord storage pad = _launchpads[previous];
            if (pad.registrant != address(0)) _demoteLaunchpad(previous, pad, "last attributed launch cleared");
        }
    }

    /// @dev The only two writes to `_byLaunchpad`. A pool enters when a vouch names a launchpad
    /// and leaves when a curator clears it; `record.launchpad != address(0)` iff the pool is in
    /// exactly that launchpad's index, at `_launchpadIndexPosition[poolId] - 1`.
    function _addToLaunchpadIndex(address launchpad, bytes32 poolId) private {
        bytes32[] storage index = _byLaunchpad[launchpad];
        index.push(poolId);
        _launchpadIndexPosition[poolId] = index.length;
    }

    /// @dev Swap-and-pop. The position is guaranteed non-zero for an attributed pool by the
    /// invariant above; underflow here would mean that invariant broke, and a checked-arithmetic
    /// panic is the correct response to that.
    function _removeFromLaunchpadIndex(address launchpad, bytes32 poolId) private {
        bytes32[] storage index = _byLaunchpad[launchpad];
        uint256 position = _launchpadIndexPosition[poolId] - 1;
        uint256 last = index.length - 1;
        if (position != last) {
            bytes32 moved = index[last];
            index[position] = moved;
            _launchpadIndexPosition[moved] = position + 1;
        }
        index.pop();
        delete _launchpadIndexPosition[poolId];
    }

    /// @dev The one place attribution is decided. Returns the creator to record.
    /// Two accepted proofs and no third: the launchpad is the caller, or the launchpad's own
    /// `launchOriginOf` names the pool. A launchpad must have code — an EOA cannot have created a
    /// pool through a launchpad it does not have.
    function _requireVouch(address launchpad, bytes32 poolId, address callerSuppliedCreator)
        private
        view
        returns (address creator)
    {
        if (launchpad.code.length == 0) revert LaunchpadHasNoCode(launchpad);

        if (launchpad == msg.sender) {
            // The launchpad is speaking for itself in its own transaction. Whatever creator it
            // names is its own assertion about its own launch, which is the strongest statement
            // available and exactly what the probe path would have returned.
            return callerSuppliedCreator;
        }

        (bool answered, address vouched) = _probeLaunchOrigin(launchpad, poolId);
        if (!answered || vouched == address(0)) revert LaunchpadDidNotVouch(launchpad, poolId);
        return vouched;
    }

    /*//////////////////////////////////////////////////////////////
                     FORWARDING TO THE DEEPCORE REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice Push this launch's pool into `DeepCoreRegistry` as a pool attestation for its hook.
    ///
    /// @dev Free corroboration flowing the useful direction. Every launch here already carries a
    /// pool the Vault's own manager vouched for, and that is precisely the evidence the DeepCore
    /// registry needs to move a hook off `SelfReported`. Attempted automatically at registration
    /// and exposed standalone for the cases where it could not land yet — most often because the
    /// hook was listed after the launch was.
    ///
    /// Best-effort and never fatal. `attestFromPool` reverts for a hook that is not listed, for a
    /// pool already counted, and on a deployed registry that predates the function entirely; none
    /// of those is a reason to refuse a launch. The outcome is emitted so an indexer can retry.
    function attestHookFromLaunch(bytes32 poolId) external returns (bool ok) {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        return _forwardHookAttestation(poolId, record.hooks, record.poolManager);
    }

    function _forwardHookAttestation(bytes32 poolId, address hook, address poolManager) private returns (bool ok) {
        if (hook == address(0)) return false;
        try deepcoreRegistry.attestFromPool(hook, poolManager, poolId) {
            ok = true;
        } catch {
            ok = false;
        }
        emit HookAttestationForwarded(poolId, hook, ok);
    }

    /*//////////////////////////////////////////////////////////////
                              TOKEN IDENTITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Re-read a launch token's name, symbol, decimals and code hash.
    ///
    /// @dev Permissionless, and it has to be. A token behind a proxy can be renamed after listing —
    /// launch as `FOO`, become `USDC` once the row is buried in a marketplace — and the codehash
    /// moving is the signal that it happened. Nothing here can be griefed: the values written are
    /// whatever the token itself answers, and a caller with too little gas is rejected by the probe
    /// floor rather than being allowed to manufacture an "unreadable" verdict.
    ///
    /// Unlike `DeepCoreRegistry.refreshPermissions` this does not revert on a no-op. There is no
    /// verification badge on a launch to protect from log spam, and a keeper that re-reads a token
    /// costs itself gas and nobody else anything.
    function refreshTokenInfo(bytes32 poolId) external {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        record.updatedAt = uint64(block.timestamp);
        _readAndStoreTokenInfo(poolId, record, record.token);
    }

    /// @dev A failed read leaves the last known name and symbol in place rather than blanking
    /// them. An empty string is a meaningful answer ("this token has no name"), and claiming it for
    /// a token that merely stopped answering would be a different lie. `tokenInfoReadable == false`
    /// is the signal that the stored values are stale.
    function _readAndStoreTokenInfo(bytes32 poolId, LaunchRecord storage record, address token) private {
        (bool nameOk, string memory name) = _probeString(token, 0x06fdde03, MAX_TOKEN_NAME_BYTES); // name()
        (bool symbolOk, string memory symbol) = _probeString(token, 0x95d89b41, MAX_TOKEN_SYMBOL_BYTES); // symbol()
        (bool decimalsOk, uint256 rawDecimals) = _probeWord(token, 0x313ce567); // decimals()

        bool readable = nameOk && symbolOk;
        if (nameOk) record.tokenName = name;
        if (symbolOk) record.tokenSymbol = symbol;
        if (decimalsOk && rawDecimals <= type(uint8).max) record.tokenDecimals = uint8(rawDecimals);
        record.tokenInfoReadable = readable;
        record.tokenCodehash = token.codehash;

        emit LaunchTokenInfoUpdated(
            poolId, record.tokenName, record.tokenSymbol, record.tokenDecimals, record.tokenCodehash, readable
        );
    }

    /*//////////////////////////////////////////////////////////////
                           LAUNCH STEWARDSHIP
    //////////////////////////////////////////////////////////////*/

    /// @notice Replace a launch's free text. Steward or curator.
    /// @dev There is no verification ladder on an individual launch to demote — see
    /// `setLaunchpadVerification` for where the ladder lives and why — so unlike
    /// `DeepCoreRegistry.updateMetadata` a steward edit here costs the record nothing. Everything a
    /// reader should be sizing risk from (the pool, the hook's bitmap, the token's own symbol) is
    /// read from chain and cannot be reached from this function at all.
    function updateLaunchMetadata(bytes32 poolId, LaunchMetadata calldata metadata) external {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        if (msg.sender != record.steward && !_isCurator(msg.sender)) revert NotLaunchSteward(poolId, msg.sender);

        _validateLaunchMetadata(metadata);
        _writeLaunchMetadata(record, metadata);
        record.updatedAt = uint64(block.timestamp);
        _emitLaunchMetadata(poolId, metadata);
    }

    /// @notice Hand over the right to edit a launch's free text.
    /// @dev Two callers, one function, exactly as in `DeepCoreRegistry.transferSteward`. The curator
    /// path is the squatting remedy: registration is open, so nothing stops a stranger indexing
    /// somebody's real pool with hostile copy. Reassignment repairs the listing instead of deleting
    /// it, and `registrant` never changes, so who actually wrote it stays auditable.
    function transferLaunchSteward(bytes32 poolId, address newSteward) external {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        if (newSteward == address(0)) revert ZeroAddress();
        if (msg.sender != record.steward && !_isCurator(msg.sender)) revert NotLaunchSteward(poolId, msg.sender);

        address previous = record.steward;
        record.steward = newSteward;
        record.updatedAt = uint64(block.timestamp);
        emit LaunchStewardTransferred(poolId, previous, newSteward);
    }

    /// @notice Deprecate a launch, flag it malicious, or restore it. Curator, or guardian upwards.
    /// @dev Same asymmetry as the DeepCore registry: curators may set any status, guardians may only
    /// make a listing strictly more cautious. A compromised guardian can slander a launch, which is
    /// visible, reversible by a curator, and costs nobody their funds; it cannot clear a warning.
    /// @param reason Emitted verbatim, and it is what a marketplace prints next to the warning, so
    /// it should be a sentence a holder can act on rather than a ticket number.
    function setLaunchListing(bytes32 poolId, Listing status, string calldata reason) external {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        _boundString(bytes(reason).length, MAX_NOTE_BYTES);
        _requireListingAuthority(record.listing, status);

        Listing previous = record.listing;
        record.listing = status;
        record.updatedAt = uint64(block.timestamp);
        emit LaunchListingChanged(poolId, msg.sender, previous, status, reason);
    }

    /*//////////////////////////////////////////////////////////////
                               LAUNCHPADS

        A launchpad is a tenant's front door. Its record is what
        turns "launched via Acme" from a string into a reputation
        that Acme accumulates and can lose.
    //////////////////////////////////////////////////////////////*/

    /// @notice List a launchpad. Anyone may, but only the launchpad itself gets the strong record.
    /// @dev `origin` is `SelfRegistered` iff `msg.sender` is the launchpad. A third-party listing
    /// is genuinely useful — an ecosystem index should cover launchpads that predate this
    /// registry — but it is a stranger's account of somebody else's contract, so it can never be
    /// badged. The launchpad takes over with `claimLaunchpad`.
    function registerLaunchpad(address launchpad, address steward, LaunchpadMetadata calldata metadata) external {
        if (launchpad == address(0)) revert ZeroAddress();
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant != address(0)) revert LaunchpadAlreadyRegistered(launchpad);
        if (launchpad.code.length == 0) revert LaunchpadHasNoCode(launchpad);
        _validateLaunchpadMetadata(metadata);

        LaunchpadOrigin origin = msg.sender == launchpad ? LaunchpadOrigin.SelfRegistered : LaunchpadOrigin.Claimed;

        record.registrant = msg.sender;
        record.registeredAt = uint64(block.timestamp);
        record.updatedAt = uint64(block.timestamp);
        record.origin = origin;
        record.verification = Verification.Unverified;
        record.listing = Listing.Active;
        record.steward = steward == address(0) ? msg.sender : steward;
        record.codehash = launchpad.codehash;
        _writeLaunchpadMetadata(record, metadata);

        _launchpadList.push(launchpad);

        emit LaunchpadRegistered(
            launchpad, msg.sender, record.steward, origin, record.codehash, uint64(block.timestamp)
        );
        _emitLaunchpadMetadata(launchpad, metadata);
    }

    /// @notice A launchpad contract takes over a listing a stranger created for it.
    /// @dev Callable only by the launchpad itself, which is the whole point: it is the one claim
    /// nobody can forge. Upgrades `Claimed` to `SelfRegistered` and moves the steward, so a
    /// squatted launchpad listing is repaired without a curator ever being involved. Idempotent
    /// only in the sense that re-claiming re-sets the steward; the origin cannot move backwards.
    function claimLaunchpad(address newSteward) external {
        LaunchpadRecord storage record = _launchpads[msg.sender];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(msg.sender);
        if (newSteward == address(0)) revert ZeroAddress();

        address previous = record.steward;
        record.origin = LaunchpadOrigin.SelfRegistered;
        record.steward = newSteward;
        record.updatedAt = uint64(block.timestamp);

        emit LaunchpadClaimed(msg.sender, newSteward);
        if (previous != newSteward) emit LaunchpadStewardTransferred(msg.sender, previous, newSteward);
    }

    /// @notice Replace a launchpad's metadata. Steward or curator.
    /// @dev A steward edit ALWAYS resets verification. Without that the ladder is decorative: get
    /// badged, then repoint `sourceURI` at a repo that no longer matches the bytecode, or rename
    /// the launchpad to something that impersonates another tenant, and the badge now vouches for
    /// something no curator ever saw. A curator edit does not demote, because a curator correcting
    /// a listing is the review.
    function updateLaunchpadMetadata(address launchpad, LaunchpadMetadata calldata metadata) external {
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(launchpad);
        bool asCurator = _isCurator(msg.sender);
        if (msg.sender != record.steward && !asCurator) revert NotLaunchpadSteward(launchpad, msg.sender);

        _validateLaunchpadMetadata(metadata);
        _writeLaunchpadMetadata(record, metadata);
        record.updatedAt = uint64(block.timestamp);

        _emitLaunchpadMetadata(launchpad, metadata);
        if (!asCurator) _demoteLaunchpad(launchpad, record, "metadata edited by steward");
    }

    function transferLaunchpadSteward(address launchpad, address newSteward) external {
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(launchpad);
        if (newSteward == address(0)) revert ZeroAddress();
        if (msg.sender != record.steward && !_isCurator(msg.sender)) {
            revert NotLaunchpadSteward(launchpad, msg.sender);
        }

        address previous = record.steward;
        record.steward = newSteward;
        record.updatedAt = uint64(block.timestamp);
        emit LaunchpadStewardTransferred(launchpad, previous, newSteward);
    }

    /// @notice Re-read a launchpad's code hash. Permissionless.
    /// @dev The bait-and-switch this closes: get a launchpad badged, then swap the implementation
    /// behind a proxy so the contract producing attributed launches is no longer the contract that
    /// was reviewed. A moved codehash demotes the badge. Reverts when nothing changed so a keeper
    /// cannot spam the log; probe it with `eth_call` first if you want a cheap no-op.
    function refreshLaunchpadCode(address launchpad) external {
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(launchpad);

        bytes32 previous = record.codehash;
        bytes32 current = launchpad.codehash;
        if (previous == current) revert CodehashUnchanged(launchpad);

        record.codehash = current;
        record.updatedAt = uint64(block.timestamp);
        emit LaunchpadCodeRefreshed(launchpad, previous, current);
        _demoteLaunchpad(launchpad, record, "launchpad code changed");
    }

    /// @notice Move a launchpad along the verification ladder. Curator only, both directions.
    ///
    /// @dev The gates, each closing a way a badge could mean less than it looks:
    ///   - nothing is promoted while flagged `Malicious`; rehabilitation is two transactions so it
    ///     leaves two separately reviewable log entries;
    ///   - `SourceVerified` and above need a `sourceURI`, `Audited` also an `auditURI`;
    ///   - NOTHING IS PROMOTED ON A `Claimed` RECORD. This is the launch index's analogue of
    ///     `AttestationRequired`. A badge on a listing a stranger wrote about somebody else's
    ///     contract vouches for the stranger's typing. The launchpad must have acknowledged the
    ///     record with `claimLaunchpad`, which only it can call;
    ///   - NOTHING IS PROMOTED UNTIL ONE ATTRIBUTED LAUNCH EXISTS. `_byLaunchpad` only ever grows
    ///     through a vouch and shrinks when a curator clears one, so this is a check that the
    ///     launchpad has a launch the registry CURRENTLY attributes to it, not that somebody said
    ///     it did or that it once had one.
    function setLaunchpadVerification(address launchpad, Verification level, string calldata note) external {
        _requireCurator();
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(launchpad);
        _boundString(bytes(note).length, MAX_NOTE_BYTES);

        if (level != Verification.Unverified) {
            if (record.listing == Listing.Malicious) revert LaunchpadFlaggedMalicious(launchpad);
            if (record.origin != LaunchpadOrigin.SelfRegistered) revert LaunchpadNotSelfRegistered(launchpad);
            if (_byLaunchpad[launchpad].length == 0) revert LaunchpadHasNoLaunches(launchpad);
            if (bytes(record.metadata.sourceURI).length == 0) revert SourceURIRequired();
            if (level == Verification.Audited && bytes(record.metadata.auditURI).length == 0) {
                revert AuditURIRequired();
            }
        }

        Verification previous = record.verification;
        record.verification = level;
        record.updatedAt = uint64(block.timestamp);
        emit LaunchpadVerificationChanged(launchpad, msg.sender, previous, level, note);
    }

    /// @notice Deprecate a launchpad, flag it malicious, or restore it. Curator, or guardian up.
    /// @dev Flagging `Malicious` force-resets verification in the same transaction — a launchpad
    /// that turned out to be hostile must not keep presenting a badge for even one block.
    /// `Deprecated` KEEPS it: a superseded but genuinely audited launchpad is not a lie, and
    /// erasing the audit there would punish maintainers for retiring old versions honestly.
    function setLaunchpadListing(address launchpad, Listing status, string calldata reason) external {
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(launchpad);
        _boundString(bytes(reason).length, MAX_NOTE_BYTES);
        _requireListingAuthority(record.listing, status);

        Listing previous = record.listing;
        record.listing = status;
        record.updatedAt = uint64(block.timestamp);
        emit LaunchpadListingChanged(launchpad, msg.sender, previous, status, reason);

        if (status == Listing.Malicious) _demoteLaunchpad(launchpad, record, "flagged malicious");
    }

    /*//////////////////////////////////////////////////////////////
                          UNTRUSTED CALL PROBES

        The only places this contract touches an address nobody has
        vetted. Everything here is defensive about the CALL. None
        of it makes the ANSWER true, which is why an answer is only
        ever recorded as the callee's own claim about itself.
    //////////////////////////////////////////////////////////////*/

    /// @dev One-word probe. `readable` is true only if the call succeeded and returned exactly 32
    /// bytes — the same conditions solc's own decoder would impose on a `uint8`/`address` return.
    function _probeWord(address target, bytes4 selector) private view returns (bool readable, uint256 raw) {
        uint256 available = gasleft();
        if (available < PROBE_GAS_FLOOR) revert InsufficientGasForProbe(available, PROBE_GAS_FLOOR);
        uint256 budget = PROBE_GAS;
        bool success;

        assembly ("memory-safe") {
            // Scratch space (0x00-0x3f) only: 4 bytes of calldata in, 32 bytes of return out. The
            // input is fully consumed before the output is written, so one buffer is enough.
            mstore(0, selector)
            success := staticcall(budget, target, 0, 4, 0, 32)
            raw := mload(0)
            // A return bomb is truncated by outsize=32 above; this rejects anything that is not
            // exactly one word, including the empty return of a plain EOA-like fallback.
            success := and(success, eq(returndatasize(), 32))
        }

        if (!success) return (false, 0);
        return (true, raw);
    }

    /// @dev `_probeWord` narrowed to a clean address, matching what solc would accept. Dirty high
    /// bits are not a small address.
    function _probeLaunchOrigin(address launchpad, bytes32 poolId) private view returns (bool, address) {
        uint256 available = gasleft();
        if (available < PROBE_GAS_FLOOR) revert InsufficientGasForProbe(available, PROBE_GAS_FLOOR);
        uint256 budget = PROBE_GAS;
        bytes4 selector = IDeepCoreLaunchOrigin.launchOriginOf.selector;
        bool success;
        uint256 raw;

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), poolId)
            success := staticcall(budget, launchpad, ptr, 36, 0, 32)
            raw := mload(0)
            success := and(success, eq(returndatasize(), 32))
        }

        if (!success) return (false, address(0));
        if (raw > type(uint160).max) return (false, address(0));
        return (true, address(uint160(raw)));
    }

    /// @dev String probe with a bounded copy.
    ///
    /// The output size is NOT capped by the staticcall, because a well-formed string return is
    /// three-plus words and the length has to be read before the data. Instead the callee's gas is
    /// capped at `PROBE_GAS`, which bounds how much memory it can expand and therefore how much it
    /// can return; anything larger than the largest well-formed answer we would accept is rejected
    /// on `returndatasize()` BEFORE a single byte is copied. So a return bomb costs the probe
    /// budget and nothing else.
    ///
    /// The framing is then checked by hand rather than through `abi.decode`, because `abi.decode`
    /// on attacker-controlled bytes is a revert we would have to catch and a memory cost we would
    /// have to pay first: head word must be exactly 0x20, length must fit the cap, and the data
    /// must actually be present in what was returned.
    function _probeString(address target, bytes4 selector, uint256 maxBytes)
        private
        view
        returns (bool readable, string memory value)
    {
        uint256 available = gasleft();
        if (available < PROBE_GAS_FLOOR) revert InsufficientGasForProbe(available, PROBE_GAS_FLOOR);
        uint256 budget = PROBE_GAS;
        // head (0x20) + length + data, padded up to a word.
        uint256 maxReturn = 64 + ((maxBytes + 31) / 32) * 32;
        value = "";

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            // outsize 0: nothing is copied until the size has been judged acceptable.
            let success := staticcall(budget, target, ptr, 4, 0, 0)
            let size := returndatasize()
            if and(success, and(iszero(lt(size, 64)), iszero(gt(size, maxReturn)))) {
                returndatacopy(ptr, 0, size)
                // A conforming encoder always writes 0x20 here. Anything else is either a
                // different type or a hand-rolled encoding aimed at the decoder.
                if eq(mload(ptr), 32) {
                    let len := mload(add(ptr, 32))
                    // Yul `and` does not short-circuit, so `add(64, len)` is evaluated even for an
                    // absurd length and may wrap. Harmless: the wrap can only make the SECOND
                    // condition pass, and the first one — `len <= maxBytes` — has already failed.
                    if and(iszero(gt(len, maxBytes)), iszero(gt(add(64, len), size))) {
                        // The string's own header (length, then data) is already laid out at
                        // ptr+32, so the value is just a pointer to it.
                        value := add(ptr, 32)
                        let end := add(add(ptr, 64), len)
                        // Claim the region plus a word of slack, THEN zero the tail of the final
                        // word so the value hashes and re-encodes deterministically.
                        mstore(0x40, add(end, 32))
                        mstore(end, 0)
                        readable := 1
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             LAUNCH VIEWS
    //////////////////////////////////////////////////////////////*/

    function isLaunchRegistered(bytes32 poolId) public view returns (bool) {
        return _launches[poolId].registrant != address(0);
    }

    /// @notice The full record. Reverts for an unknown pool rather than returning a zeroed struct,
    /// because a zeroed struct reads as "Active, no hook permissions, no launchpad" — the safest
    /// possible answer about a launch nobody has ever looked at.
    function getLaunch(bytes32 poolId) external view returns (LaunchRecord memory) {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        return record;
    }

    /// @notice Everything a marketplace must have before it prints "launched via …".
    ///
    /// @dev One call, deliberately, and this is the function a front end should use. `origin` and
    /// the launchpad's own standing are two very different statements — a `LaunchpadAttested` row
    /// whose launchpad is flagged `Malicious` is the most dangerous row on the screen, and separate
    /// calls make it easy to ship only the first. `launchpadRegistered` false means the attribution
    /// is proven but the launchpad has no listing at all: render the address, never a name.
    function provenanceOf(bytes32 poolId)
        external
        view
        returns (
            LaunchOrigin origin,
            address launchpad,
            address creator,
            bool launchpadRegistered,
            Verification launchpadVerification,
            Listing launchpadListing
        )
    {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        launchpad = record.launchpad;
        LaunchpadRecord storage pad = _launchpads[launchpad];
        launchpadRegistered = launchpad != address(0) && pad.registrant != address(0);
        return (
            record.origin,
            launchpad,
            record.creator,
            launchpadRegistered,
            launchpadRegistered ? pad.verification : Verification.Unverified,
            launchpadRegistered ? pad.listing : Listing.Active
        );
    }

    /// @notice The hook sitting in this launch's swap path, and what it is able to do.
    /// @dev `hookPermissions` came from the pool's immutable `parameters`, so unlike a bitmap read
    /// off a hook it is not the hook's account of itself. `hookListed` says whether the DeepCore
    /// registry has anything further to say about it; false is not an accusation, it means nobody
    /// has listed it and the marketplace has no metadata, no audit trail and no flag to show.
    function launchHookOf(bytes32 poolId)
        external
        view
        returns (address hooks, uint16 hookPermissions, RiskClass hookRisk, bool hookListed)
    {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        hooks = record.hooks;
        hookPermissions = record.hookPermissions;
        hookRisk = PermissionMath.classify(hookPermissions);
        hookListed = hooks != address(0) && deepcoreRegistry.isRegistered(hooks);
    }

    /// @notice The pair, as proven against the pool manager.
    function launchPairOf(bytes32 poolId)
        external
        view
        returns (address token, address quote, bool tokenIsCurrency0, uint24 fee, address poolManager)
    {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        return (record.token, record.quote, record.tokenIsCurrency0, record.fee, record.poolManager);
    }

    /// @notice The token's own account of itself, as last read from the token.
    /// @dev `readable == false` means the strings are stale, not that they are empty.
    function launchTokenInfoOf(bytes32 poolId)
        external
        view
        returns (string memory name, string memory symbol, uint8 decimals, bytes32 codehash, bool readable)
    {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        return
            (record.tokenName, record.tokenSymbol, record.tokenDecimals, record.tokenCodehash, record.tokenInfoReadable);
    }

    /// @notice True when the token's code has moved since its name and symbol were last read.
    /// @dev A proxy that renamed itself after listing. Call `refreshTokenInfo` and show the diff.
    function tokenCodeHasMoved(bytes32 poolId) external view returns (bool) {
        LaunchRecord storage record = _launches[poolId];
        if (record.registrant == address(0)) revert LaunchNotRegistered(poolId);
        return record.token.codehash != record.tokenCodehash;
    }

    function launchCount() external view returns (uint256) {
        return _launchList.length;
    }

    function launchAt(uint256 index) external view returns (bytes32) {
        return _launchList[index];
    }

    /// @notice Page through every launch. Index positions never change.
    function listLaunches(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return _launchList.page(offset, limit);
    }

    function tokenLaunchCount(address token) external view returns (uint256) {
        return _byToken[token].length;
    }

    /// @notice Every pool indexed for one token. A token legitimately has several — different fee
    /// tiers, different quote currencies — so this is a list and not a lookup.
    function launchesOfToken(address token, uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return _byToken[token].page(offset, limit);
    }

    function launchpadLaunchCount(address launchpad) external view returns (uint256) {
        return _byLaunchpad[launchpad].length;
    }

    /// @notice "Launched via X". Exactly the launches whose record names X right now, each proven.
    /// @dev Unlike every other list here, positions are NOT stable: `clearLaunchAttribution`
    /// moves the last entry into the cleared one's slot. Re-page a launchpad after a
    /// `LaunchAttributionCleared` naming it.
    function launchesOfLaunchpad(address launchpad, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        return _byLaunchpad[launchpad].page(offset, limit);
    }

    function creatorLaunchCount(address creator) external view returns (uint256) {
        return _byCreator[creator].length;
    }

    /// @notice Launches indexed against a creator.
    /// @dev Append-only, so an entry can be superseded by a later attestation that named a
    /// different creator. Re-read `getLaunch(poolId).creator` before trusting membership, and
    /// remember the creator on a `Claimed` record is nobody's proven claim.
    function launchesOfCreator(address creator, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        return _byCreator[creator].page(offset, limit);
    }

    /*//////////////////////////////////////////////////////////////
                            LAUNCHPAD VIEWS
    //////////////////////////////////////////////////////////////*/

    function isLaunchpadRegistered(address launchpad) external view returns (bool) {
        return _launchpads[launchpad].registrant != address(0);
    }

    function getLaunchpad(address launchpad) external view returns (LaunchpadRecord memory) {
        LaunchpadRecord storage record = _launchpads[launchpad];
        if (record.registrant == address(0)) revert LaunchpadNotRegistered(launchpad);
        return record;
    }

    /// @notice The single question a front end should ask before showing a launchpad's badge.
    /// @dev Never true for an unregistered launchpad, a flagged one, one a stranger listed, one
    /// whose code has moved since it was reviewed, or one that has produced no attributed launch.
    function isLaunchpadAudited(address launchpad) external view returns (bool) {
        LaunchpadRecord storage record = _launchpads[launchpad];
        return record.registrant != address(0) && record.verification == Verification.Audited
            && record.listing == Listing.Active && record.origin == LaunchpadOrigin.SelfRegistered
            && record.codehash == launchpad.codehash && _byLaunchpad[launchpad].length > 0;
    }

    function launchpadCount() external view returns (uint256) {
        return _launchpadList.length;
    }

    function launchpadAt(uint256 index) external view returns (address) {
        return _launchpadList[index];
    }

    function listLaunchpads(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _launchpadList.page(offset, limit);
    }

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether an account curates here. Answered by `DeepCoreRegistry`, not by this contract.
    function isCurator(address account) external view returns (bool) {
        return _isCurator(account);
    }

    /// @notice Whether an account may flag here. Answered by `DeepCoreRegistry`.
    function isGuardian(address account) external view returns (bool) {
        return deepcoreRegistry.hasRole(GUARDIAN_ROLE, account);
    }

    function _isCurator(address account) private view returns (bool) {
        return deepcoreRegistry.hasRole(CURATOR_ROLE, account);
    }

    function _requireCurator() private view {
        if (!_isCurator(msg.sender)) revert NotCurator(msg.sender);
    }

    /// @dev Curators may set any status; guardians may only move a listing to a strictly more
    /// cautious one. Shared by the launch and launchpad paths so the rule cannot drift apart.
    function _requireListingAuthority(Listing current, Listing attempted) private view {
        if (_isCurator(msg.sender)) return;
        if (!deepcoreRegistry.hasRole(GUARDIAN_ROLE, msg.sender)) revert NotCuratorOrGuardian(msg.sender);
        if (uint8(attempted) <= uint8(current)) revert GuardianCannotRelist(current, attempted);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reset a launchpad's verification and say why. No-op when already unverified, so
    /// nothing that merely re-confirms the status quo shows up in the log.
    function _demoteLaunchpad(address launchpad, LaunchpadRecord storage record, string memory note) private {
        Verification previous = record.verification;
        if (previous == Verification.Unverified) return;
        record.verification = Verification.Unverified;
        emit LaunchpadVerificationChanged(launchpad, msg.sender, previous, Verification.Unverified, note);
    }

    /// @dev Two different rules, because the two kinds of field admit different guarantees.
    ///
    /// The STRINGS get length and nothing else — no scheme check, no character set, no domain. See
    /// `LaunchMetadata`'s header for why: a contract cannot make a URL safe to render, and a
    /// partial filter here would be read by front ends as a guarantee it cannot give. The bound is
    /// what stops the one attack that IS a contract problem — an unbounded write every reader of
    /// the record pays for.
    ///
    /// The HANDLES get a total check, because for them one exists. `[A-Za-z0-9_]` within the
    /// platform's own limit is the complete set of values that render into `x.com/<h>` or
    /// `t.me/<h>` as the handle they say they are. Enforcing it is not the partial filtering
    /// refused above; it is the reason these are handles and not URLs.
    function _validateLaunchMetadata(LaunchMetadata calldata metadata) private pure {
        _boundString(bytes(metadata.description).length, MAX_DESCRIPTION_BYTES);
        _boundString(bytes(metadata.websiteURI).length, MAX_URI_BYTES);
        _boundHandle(metadata.xHandle, MAX_X_HANDLE_BYTES);
        _boundHandle(metadata.telegramHandle, MAX_TELEGRAM_HANDLE_BYTES);
    }

    /// @dev A handle is a plain ASCII string with no at-sign and no scheme. `""` is "not given"
    /// and always passes — every link on a record is optional.
    ///
    /// Walks the bytes once: the length must be within the platform's own limit, and every byte
    /// must be in `[A-Za-z0-9_]`. That single charset check is what rejects a leading at-sign, a
    /// `/`, a scheme, a space, a NUL and every bidi override in one place, which is the whole
    /// reason these are handles rather than URLs.
    ///
    /// These were `bytes32` until 2026-09-24, and the type is the ONLY thing that changed — see
    /// the block above `LaunchMetadata`, where the 913 bytes it cost `LaunchpadKitV2` are measured.
    /// The old "a zero byte followed by a non-zero one" rule is gone rather than relaxed: it
    /// existed because a left-aligned zero-padded word made `"good\0evil"` both expressible and
    /// invisible on render. A `string` carries its length explicitly, so a NUL is just a byte
    /// outside the charset and the loop below already refuses it.
    ///
    /// Deliberately NOT enforced, and the omission is the conservative direction: minimum length,
    /// a leading-letter rule, no-trailing-underscore, no-double-underscore, and any reserved-name
    /// list. Those are platform policies that change without notice, and this contract is
    /// immutable — a rule that is too strict refuses a legitimate project's real handle forever,
    /// while a rule that is merely not strict enough costs a dead link the steward can fix. Only
    /// the two properties this contract can guarantee for good are checked: it fits, and it is
    /// renderable.
    function _boundHandle(string calldata handle, uint256 maximum) private pure {
        bytes calldata raw = bytes(handle);
        uint256 length = raw.length;
        if (length == 0) return;
        // Past the platform's limit, so this handle cannot be the one it claims to be.
        if (length > maximum) revert InvalidHandle(handle, maximum);

        for (uint256 i = 0; i < length; i++) {
            uint8 c = uint8(raw[i]);
            bool ok = (c >= 0x61 && c <= 0x7A) // a-z
                || (c >= 0x41 && c <= 0x5A) // A-Z
                || (c >= 0x30 && c <= 0x39) // 0-9
                || c == 0x5F; // _
            if (!ok) revert InvalidHandle(handle, maximum);
        }
    }

    function _validateLaunchpadMetadata(LaunchpadMetadata calldata metadata) private pure {
        uint256 nameLength = bytes(metadata.name).length;
        if (nameLength == 0) revert EmptyName();
        _boundString(nameLength, MAX_NAME_BYTES);
        _boundString(bytes(metadata.description).length, MAX_DESCRIPTION_BYTES);
        _boundString(bytes(metadata.sourceURI).length, MAX_URI_BYTES);
        _boundString(bytes(metadata.auditURI).length, MAX_URI_BYTES);
        _boundString(bytes(metadata.websiteURI).length, MAX_URI_BYTES);
    }

    function _boundString(uint256 length, uint256 maximum) private pure {
        if (length > maximum) revert StringTooLong(length, maximum);
    }

    function _writeLaunchMetadata(LaunchRecord storage record, LaunchMetadata calldata metadata) private {
        record.metadata.description = metadata.description;
        record.metadata.websiteURI = metadata.websiteURI;
        record.metadata.xHandle = metadata.xHandle;
        record.metadata.telegramHandle = metadata.telegramHandle;
    }

    function _emitLaunchMetadata(bytes32 poolId, LaunchMetadata calldata metadata) private {
        emit LaunchMetadataUpdated(
            poolId,
            msg.sender,
            metadata.description,
            metadata.websiteURI,
            metadata.xHandle,
            metadata.telegramHandle
        );
    }

    function _writeLaunchpadMetadata(LaunchpadRecord storage record, LaunchpadMetadata calldata metadata) private {
        record.metadata.name = metadata.name;
        record.metadata.description = metadata.description;
        record.metadata.sourceURI = metadata.sourceURI;
        record.metadata.auditURI = metadata.auditURI;
        record.metadata.websiteURI = metadata.websiteURI;
    }

    function _emitLaunchpadMetadata(address launchpad, LaunchpadMetadata calldata metadata) private {
        emit LaunchpadMetadataUpdated(
            launchpad,
            msg.sender,
            metadata.name,
            metadata.description,
            metadata.sourceURI,
            metadata.auditURI,
            metadata.websiteURI
        );
    }
}
