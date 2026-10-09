/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Verification, Listing} from "./IDeepCoreRegistry.sol";

/*//////////////////////////////////////////////////////////////
                              TYPES

    `Verification` and `Listing` are IMPORTED from IDeepCoreRegistry
    rather than redefined. A launchpad moves up the same ladder a
    DeepCore does and gets flagged by the same guardians under the
    same rule, so it must be the same enum: two enums with the
    same members are two chances for a front end to map one of
    them wrongly, and the one it maps wrongly is the one that
    says "Malicious".
//////////////////////////////////////////////////////////////*/

/// @notice How a launch record came to name a launchpad, and therefore how much its attribution is
/// worth.
///
/// @dev This is the launch index's analogue of `PermissionSource`, and it exists for the same
/// reason: a marketplace row that says "launched via Acme" is a trust signal, and a trust signal
/// nobody can check is worse than none.
///
/// The invariant that makes it readable, enforced everywhere a record is written:
///
///     record.launchpad != address(0)   <=>   record.origin == LaunchpadAttested
///
/// There is deliberately no such thing as a *claimed* launchpad. A caller that names a launchpad
/// which does not vouch for the pool is REVERTED, not downgraded, so the field can never hold an
/// unproven name for a careless UI to render. If you want a record with no attribution, pass
/// `address(0)` and say so.
enum LaunchOrigin {
    /// @dev The pool is proven — it was read back out of a Vault-registered pool manager — but
    /// nothing corroborates who launched it. `creator` is whatever the registrant typed and must
    /// be rendered as such, or not rendered at all. This is the correct and expected state for a
    /// launch indexed by a third party.
    Claimed,
    /// @dev The named launchpad's own code named this pool: either it registered the launch itself
    /// (`msg.sender`) or it answered `IDeepCoreLaunchOrigin.launchOriginOf`. `creator` came from the
    /// launchpad in both cases. Nobody can forge this onto a launchpad from outside.
    LaunchpadAttested
}

/// @notice How a launchpad's own listing came to exist.
enum LaunchpadOrigin {
    /// @dev Somebody else listed this launchpad. Useful — an ecosystem index should be able to
    /// cover launchpads that predate this registry — but the metadata, including the display name
    /// a marketplace prints, is a stranger's account of somebody else's contract.
    Claimed,
    /// @dev The launchpad contract itself called `registerLaunchpad` or `claimLaunchpad`. The
    /// display name is then the contract's own, and a curator badge is only ever granted here.
    SelfRegistered
}

/// @notice Human-supplied listing data for one launch. Never trusted for anything checkable.
///
/// @dev There is no `name` field, on purpose. A launch's name and symbol are read off the token
/// contract — see `LaunchRecord.tokenName`. Accepting them here would let a registrant list a pool
/// of some worthless token under the symbol `USDC`, which is the single most common launchpad scam
/// and exactly the laundering an official-looking index must not perform.
///
/// ######################### EVERY FIELD HERE IS HOSTILE #########################
///
/// `registerLaunch` is permissionless, so all five fields are attacker-controlled. What the
/// registry checks differs by TYPE, and the split is the point:
///
/// **The two strings** (`description`, `websiteURI`) are bounded in LENGTH
/// (`MAX_URI_BYTES` / `MAX_DESCRIPTION_BYTES`) and checked NOTHING ELSE — no scheme, no character
/// set, no domain. That is deliberate, not an omission: an on-chain scheme filter is bypassed by
/// case, by whitespace, by percent-encoding and by multi-byte characters, while its real cost is
/// convincing a front-end author that the registry sanitised the value. A contract cannot make a
/// URL safe to render, and validation that LOOKS like safety is worse than none because it moves
/// the check to the layer that cannot perform it.
///
/// **The two handles** (`xHandle`, `telegramHandle`) are the opposite case, and they are handles
/// rather than URLs for exactly that reason. A URL field invites the attack the rule above cannot
/// close: `https://x.com∕evil` and `https://x-com.example/project` are both just strings, so a
/// reader has no way to tell a homoglyph domain from the real one. A handle has no domain in it at
/// all. The consumer renders `https://x.com/<handle>` from a value this contract has already
/// proven is `[A-Za-z0-9_]` within the platform's own length limit, so there is nothing left to
/// spoof and nothing left to sanitise. Validation here is cheap, total and checkable — which is
/// why it is performed, and why performing it does not contradict the paragraph above.
///
/// A consumer MUST:
///   1. for the three STRINGS, allowlist the scheme before putting the value in an `href`, `src`,
///      `action` or `window.open` — `https:` for the website, `https:`/`ipfs:`/`ar:` for the icon.
///      A `javascript:` or `data:` value reaching an `href` is script execution on your origin;
///   2. proxy any off-chain image rather than hotlinking it;
///   3. set `rel="noopener noreferrer"` on every outbound link;
///   4. escape the STRINGS on render — their bytes may contain control characters, newlines, or
///      bidi overrides (`U+202E`) that reorder what the reader sees. The handles cannot: their
///      alphabet excludes every one of those;
///   5. truncate the strings for display; 512 bytes of link will break a layout;
///   6. never let any of this sit next to a verification badge as though the badge covered it. The
///      ladder in this registry verifies a LAUNCHPAD, never a launch's free text;
///   7. never infer OWNERSHIP from a handle. `xHandle` is whoever the registrant typed. The
///      contract proves the handle is well-formed and renderable; it cannot prove the account
///      belongs to the project, and no on-chain check could. Well-formed is not authentic.
struct LaunchMetadata {
    string description;
    /// @dev The project's own site. A real URL, so it stays a string: a website has no handle form.
    string websiteURI;
    /* ################ THIS STRUCT MUST STAY EXACTLY FOUR `string` MEMBERS ################

       `iconURI` WAS HERE and was removed on 2026-09-24, because the struct could not afford it.
       That is not a style call, it is a measurement, and the shape of the measurement is the part
       worth keeping: `LaunchpadKitV2` ABI-encodes `LaunchParamsV2` (which nests this struct) into
       memory to DELEGATECALL its linked `LaunchLegs` library, and that encoder lives in
       `createLaunch`. EIP-170 caps the kit's runtime at 24,576 bytes, and forge's test EVM does
       NOT enforce that cap — so every variant below passed the whole suite, and only an artifact
       read says which ones can be deployed.

       It is a CLIFF, not a gradient. Only the four-`string` shape is cheap (each figure is the
       kit's runtime size, read from `deployedBytecode.object`, default profile, 9,000 runs):

           4 x string                 23,988   +588   <-- the only shape that fits
           5 x string                 24,971   -395
           3 x string + 2 x bytes32   24,931   -355
           2 x string + 2 x bytes32   24,901   -325

       So neither member COUNT nor member TYPE is a linear cost, and reasoning about encoding cost
       will mislead you: `bytes32` is the cheaper type everywhere else and costs 913 bytes HERE.
       Treat it as a via-IR optimizer threshold in that one encoder and do not build a finer theory
       on it. Any departure from four `string`s costs roughly 900-980 bytes and puts the kit over.

       Three levers were measured and are spent: member REORDERING is worth 2 bytes; moving work
       into `LaunchLegs` buys the kit ~125 bytes while costing the library ~2,067, which only makes
       `LaunchLegs` the next EIP-170 problem; and lowering the kit's optimizer runs does not build
       at all, because `script/DevLocalStack.s.sol` imports both this kit and `CLPositionManager`,
       which itself needs 9,000 runs to fit EIP-170, so forge cannot resolve one profile for that
       compilation unit.

       CONSEQUENCE: adding any field here costs ~900 bytes and breaks deployment. If a field is
       genuinely needed, the structural fix is to stop nesting `listing` inside `LaunchParamsV2` —
       a separate `createLaunch` argument, or a separate `setLaunchListing` call — which changes
       the kit's public ABI and is an owner decision, not a local one.

       `iconURI` was the right member to give up, and it is the weakest one by this file's own
       account: the comment that used to sit here called it attacker-controlled, to be proxied and
       never hotlinked and never shown beside a badge it had not earned. It is untrusted
       presentation, not a claim like a handle or a site. An icon belongs in the token list or the
       launch's own `metadataURI`, where being wrong costs a broken image rather than a broken
       record. Making it `bytes` instead was tried and measured WORSE still (+798 over the struct);
       do not reach for that again. */
    /// @dev The project's X (formerly Twitter) handle, WITHOUT the leading at-sign
    /// (`"deepcoreprotocol"`, never `"@deepcoreprotocol"` and never a URL). Render as
    /// `https://x.com/<h>`. `""` means "not given" and is always legal — every link here is
    /// optional.
    ///
    /// A `string` rather than a `bytes32`, and that is load-bearing: see the block above. `bytes32`
    /// was the original encoding and it is what pushed the kit past EIP-170. Nothing about the
    /// handle's SAFETY rested on it — the charset and length bounds below are what make a handle
    /// renderable, and they apply identically to a string.
    string xHandle;
    /// @dev The project's Telegram group, channel or user, WITHOUT the leading at-sign, encoded as
    /// `xHandle` is. Render as `https://t.me/<h>`.
    ///
    /// Why two NAMED fields and not a list: the objection that kept this struct small was to an
    /// UNBOUNDED write — a `string[]` makes the per-record cost a function of attacker-chosen `n`,
    /// and every reader of the record pays it forever. A fixed field has none of that property:
    /// the cost is known at compile time and paid once, at launch. So a list is still refused and
    /// a generic "other link" slot is refused with it — a field with no type cannot be rendered as
    /// anything but "another link", and it is the first step back towards the list. An open-ended
    /// set belongs behind `websiteURI`, or in a separate opt-in contract that its records pay for.
    string telegramHandle;
}

/// @notice Human-supplied listing data for one launchpad.
struct LaunchpadMetadata {
    /// @dev The display name a marketplace prints as "launched via …". Impersonation is possible
    /// and is handled the way the DeepCore registry handles it: curators reassign, guardians flag,
    /// and no badge is ever granted to a record the launchpad itself did not acknowledge.
    string name;
    string description;
    /// @dev Source repository. Required before any verification level above `Unverified`.
    string sourceURI;
    /// @dev Audit report. Required before `Audited`. A badge with nothing to click through to is
    /// theatre, and the same rule already governs `DeepCoreRegistry.setVerification`.
    string auditURI;
    string websiteURI;
}

/// @notice One launch: a token, the pool it trades in, and who — if anybody provable — made it.
///
/// @dev Field order is chosen for storage packing, not for prose:
///   slot 0 = token|registeredAt|hookPermissions|origin|listing            (exactly 32 bytes)
///   slot 1 = quote|updatedAt|fee|tokenInfoReadable                        (exactly 32 bytes)
///   slot 2 = poolManager|originAttestedAt|tokenDecimals|tokenIsCurrency0  (30 bytes)
///   slot 3 = hooks|registeredAtBlock                                      (28 bytes)
///   slot 4 = launchpad, slot 5 = creator, slot 6 = steward, slot 7 = registrant,
///   slot 8 = tokenCodehash, then the two dynamic strings and the metadata struct.
struct LaunchRecord {
    /*----------------------- proven against the pool manager -----------------------*/
    /// @dev The launched token. Verified to be one of the pool's two currencies; WHICH of the two
    /// is the caller's assertion, so on a `Claimed` record a UI should render the pair, not a side.
    address token;
    /// @dev When the record was written. NOT when the pool opened — see the note on
    /// `launchedAtIsNotKnowable` in `DeepCoreLaunchRegistry`. Never label this "launched".
    uint64 registeredAt;
    /// @dev The bitmap this pool enforces, taken from its immutable `parameters`. Unforgeable: the
    /// hook presented it to core at `initialize` or the pool would not exist.
    uint16 hookPermissions;
    LaunchOrigin origin;
    Listing listing;
    /// @dev The pool's other currency. `address(0)` is the chain's native asset.
    address quote;
    uint64 updatedAt;
    uint24 fee;
    /// @dev False when the token would not answer `name()`/`symbol()` to a bounded probe. The
    /// stored strings are then the last values that were readable, or empty.
    bool tokenInfoReadable;
    address poolManager;
    /// @dev When the launchpad attribution was proven. Zero on a `Claimed` record.
    uint64 originAttestedAt;
    uint8 tokenDecimals;
    bool tokenIsCurrency0;
    /// @dev The pool's hook. `address(0)` for a plain pool; a launch does not have to use a DeepCore.
    address hooks;
    /// @dev `block.number` AS THE EVM SAW IT at registration. INFORMATIONAL, and NOT a log-scan
    /// bound on every chain: on Arbitrum Nitro (Robinhood Chain, 4663) the EVM's `block.number` is
    /// the PARENT chain's block, while `eth_getLogs` ranges use the L2 block the RPC reports - so
    /// using this as `fromBlock` there scans from the wrong clock. Use `registeredAt` (a timestamp)
    /// for anything time-shaped. Kept for storage and ABI compatibility with the deployed registry;
    /// no duration anywhere in DeepCore is derived from it.
    uint64 registeredAtBlock;
    /*------------------------------- provenance --------------------------------*/
    /// @dev Non-zero IF AND ONLY IF `origin == LaunchpadAttested`.
    address launchpad;
    /// @dev Launchpad-attested when `origin == LaunchpadAttested`; otherwise the registrant's
    /// unverified assertion, and possibly zero.
    address creator;
    /// @dev May edit this record's metadata. Transferable; reassignable by a curator.
    address steward;
    /// @dev Who called `registerLaunch`. Immutable, historical. Non-zero iff the record exists.
    address registrant;
    /*----------------------------- read off the token -----------------------------*/
    /// @dev `token.codehash` when the token info was last read. A change means the token's code
    /// moved — a proxy upgrade — and the name and symbol next to it may no longer be current.
    bytes32 tokenCodehash;
    string tokenName;
    string tokenSymbol;
    LaunchMetadata metadata;
}

/// @notice One launchpad — a tenant of the shared core, in white-label terms.
struct LaunchpadRecord {
    address registrant;
    uint64 registeredAt;
    LaunchpadOrigin origin;
    Verification verification;
    Listing listing;
    address steward;
    uint64 updatedAt;
    /// @dev `launchpad.codehash` at registration or at the last refresh. A change demotes the
    /// verification, because a badge attests to a deployment and stops meaning anything the moment
    /// that deployment is swapped out behind a proxy.
    bytes32 codehash;
    LaunchpadMetadata metadata;
}

/// @title IDeepCoreLaunchRegistry
/// @notice Events, errors and types for the shared index of launches.
interface IDeepCoreLaunchRegistry {
    /*//////////////////////////////////////////////////////////////
                             LAUNCH EVENTS

        Between these and the launchpad events below, the whole
        index is reconstructible from logs alone. Metadata and
        token info are emitted at registration too, so an indexer
        never has to read storage to learn the initial state.
    //////////////////////////////////////////////////////////////*/

    /// @param launchpad Indexed so a marketplace can subscribe to one tenant's launches. Zero on a
    /// `Claimed` record, which is itself the useful filter: `launchpad != 0` is exactly the set of
    /// launches whose attribution was proven.
    event LaunchRegistered(
        bytes32 indexed poolId,
        address indexed token,
        address indexed launchpad,
        address poolManager,
        address quote,
        address hooks,
        uint16 hookPermissions,
        uint24 fee,
        bool tokenIsCurrency0,
        address creator,
        address registrant,
        LaunchOrigin origin,
        uint64 timestamp
    );

    event LaunchTokenInfoUpdated(
        bytes32 indexed poolId, string name, string symbol, uint8 decimals, bytes32 codehash, bool readable
    );

    /// @dev Carries every metadata field, so an indexer never has to read storage to learn the
    /// current free text. The strings are unvalidated beyond length — see `LaunchMetadata`, whose
    /// consumer rules apply to a log decode exactly as they apply to a storage read. The two
    /// handles ARE validated, so a decoder may render them without further cleaning; it still must
    /// not read them as proof of who owns the account.
    event LaunchMetadataUpdated(
        bytes32 indexed poolId,
        address indexed updater,
        string description,
        string websiteURI,
        string xHandle,
        string telegramHandle
    );

    event LaunchStewardTransferred(bytes32 indexed poolId, address indexed previous, address indexed current);

    /// @notice A launchpad's own code has vouched for a record that previously had no attribution.
    event LaunchOriginAttested(
        bytes32 indexed poolId, address indexed launchpad, address indexed creator, address attestor
    );

    /// @notice A curator has removed an attribution. The record drops back to `Claimed` and the
    /// launchpad field is cleared; the correct launchpad may then attest again, permissionlessly.
    event LaunchAttributionCleared(
        bytes32 indexed poolId, address indexed previousLaunchpad, address indexed curator, string reason
    );

    event LaunchListingChanged(
        bytes32 indexed poolId, address indexed actor, Listing previous, Listing current, string reason
    );

    /// @notice The pool's hook was pushed into `DeepCoreRegistry` as a pool attestation.
    /// @dev Best-effort and never fatal: `ok` is false when the hook is not listed there, when the
    /// pool was already counted, or when the deployed registry predates `attestFromPool`.
    event HookAttestationForwarded(bytes32 indexed poolId, address indexed hook, bool ok);

    /*//////////////////////////////////////////////////////////////
                            LAUNCHPAD EVENTS
    //////////////////////////////////////////////////////////////*/

    event LaunchpadRegistered(
        address indexed launchpad,
        address indexed registrant,
        address indexed steward,
        LaunchpadOrigin origin,
        bytes32 codehash,
        uint64 timestamp
    );

    event LaunchpadMetadataUpdated(
        address indexed launchpad,
        address indexed updater,
        string name,
        string description,
        string sourceURI,
        string auditURI,
        string websiteURI
    );

    event LaunchpadStewardTransferred(address indexed launchpad, address indexed previous, address indexed current);

    /// @notice A launchpad contract has taken over a listing a stranger created for it.
    event LaunchpadClaimed(address indexed launchpad, address indexed steward);

    event LaunchpadVerificationChanged(
        address indexed launchpad, address indexed actor, Verification previous, Verification current, string note
    );

    event LaunchpadListingChanged(
        address indexed launchpad, address indexed actor, Listing previous, Listing current, string reason
    );

    event LaunchpadCodeRefreshed(address indexed launchpad, bytes32 previous, bytes32 current);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    /*------------------------------- launches -------------------------------*/

    error LaunchAlreadyRegistered(bytes32 poolId);
    error LaunchNotRegistered(bytes32 poolId);

    /// @notice The named token is neither of the pool's two currencies, so this pool is not a
    /// venue for it and the record would be a fabrication.
    error TokenNotInPool(bytes32 poolId, address token);

    /// @notice The chain's native asset cannot be the launched token. Only the quote side may be
    /// native, matching `LaunchpadKit`.
    error LaunchTokenCannotBeNative();

    /// @notice The launch token has no code, so it cannot be an ERC-20.
    error LaunchTokenHasNoCode(address token);

    /*------------------------------ provenance ------------------------------*/

    /// @notice A launchpad was named but its own code did not vouch for this pool — it is not the
    /// caller and `launchOriginOf` did not return a creator. The call reverts rather than quietly
    /// recording an unproven attribution. Pass `address(0)` for a launch you cannot attribute.
    error LaunchpadDidNotVouch(address launchpad, bytes32 poolId);

    /// @notice A launchpad must be a contract. An EOA cannot have created a pool through a
    /// launchpad it does not have.
    error LaunchpadHasNoCode(address launchpad);

    /// @notice This record already names a launchpad. Attribution is not a race to be re-run: a
    /// curator must clear the existing one first, in its own transaction, so the change is visible.
    error OriginAlreadyAttested(bytes32 poolId, address launchpad);

    /// @notice There is no attribution on this record to clear.
    error NoAttributionToClear(bytes32 poolId);

    /*------------------------------ launchpads ------------------------------*/

    error LaunchpadAlreadyRegistered(address launchpad);
    error LaunchpadNotRegistered(address launchpad);

    /// @notice A curator tried to badge a listing the launchpad's own contract never acknowledged.
    /// This is the launch index's `AttestationRequired`: a badge on a record a stranger wrote about
    /// somebody else's contract vouches for the stranger's typing, not for the launchpad.
    error LaunchpadNotSelfRegistered(address launchpad);

    /// @notice A curator tried to badge a launchpad that has not produced a single attributed
    /// launch. Verification is a statement about a thing that works; until one launch has been
    /// proven to come from it, there is nothing to have verified.
    error LaunchpadHasNoLaunches(address launchpad);

    /// @notice Verification cannot be raised while the launchpad is flagged malicious. Clear the
    /// flag first, in its own transaction, so the rehabilitation is separately visible in the logs.
    error LaunchpadFlaggedMalicious(address launchpad);

    /// @notice `refreshLaunchpadCode` found nothing to record. Reverts so keepers cannot spam.
    error CodehashUnchanged(address launchpad);

    /*-------------------------------- access --------------------------------*/

    error NotLaunchSteward(bytes32 poolId, address caller);
    error NotLaunchpadSteward(address launchpad, address caller);
    error NotCurator(address caller);
    error NotCuratorOrGuardian(address caller);

    /// @notice A guardian tried to make a listing less cautious. Guardians only ever add warnings.
    error GuardianCannotRelist(Listing current, Listing attempted);

    /*------------------------------- validation ------------------------------*/

    /// @notice Not enough gas remains to give a probe its full budget, so a "did not answer"
    /// verdict would say more about the caller than about the callee.
    error InsufficientGasForProbe(uint256 available, uint256 required);

    error SourceURIRequired();
    error AuditURIRequired();
    error EmptyName();
    error StringTooLong(uint256 length, uint256 maximum);

    /// @notice A social handle was not something this registry can render as a URL.
    ///
    /// @dev Raised for a handle longer than its platform allows, and for any byte outside
    /// `[A-Za-z0-9_]` — which is what rejects a leading at-sign, a `/`, a scheme, a space, a NUL,
    /// a bidi override and every other display hazard in one check.
    ///
    /// `""` is NOT this error: an absent handle is legal.
    ///
    /// Note for anyone reading history: while these handles were `bytes32` this error also covered
    /// "a zero byte followed by a non-zero one", because a left-aligned zero-padded word made an
    /// embedded NUL both possible and invisible on render. As a `string` the length is explicit and
    /// a NUL is simply a byte outside the charset, so that rule is gone rather than relaxed.
    ///
    /// @param handle The offending value, returned whole so a caller can see what it sent.
    /// @param maximum The platform's own limit in bytes.
    error InvalidHandle(string handle, uint256 maximum);
    error InvalidRange();
}
