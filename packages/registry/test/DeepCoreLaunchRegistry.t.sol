// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreRegistry} from "../src/DeepCoreRegistry.sol";
import {
    IDeepCoreRegistry,
    DeepCoreMetadata,
    Verification,
    Listing,
    RiskClass,
    PERM_AFTER_SWAP,
    PERM_BEFORE_SWAP,
    PERM_BEFORE_SWAP_RETURNS_DELTA
} from "../src/IDeepCoreRegistry.sol";
import {DeepCoreLaunchRegistry} from "../src/DeepCoreLaunchRegistry.sol";
import {
    IDeepCoreLaunchRegistry,
    LaunchMetadata,
    LaunchRecord,
    LaunchOrigin,
    LaunchpadMetadata,
    LaunchpadRecord,
    LaunchpadOrigin
} from "../src/IDeepCoreLaunchRegistry.sol";
import {PoolProof} from "../src/libraries/PoolProof.sol";
import {RegistryPaging} from "../src/libraries/RegistryPaging.sol";

import {HonestHook} from "./mocks/MockHooks.sol";
import {MockVault, MockPoolManager, NotAPoolManager} from "./mocks/MockPools.sol";
import {HonestLaunchpad, SilentLaunchpad} from "./mocks/MockLaunchpads.sol";
import {
    GoodToken,
    SilentToken,
    RevertingToken,
    LongNameToken,
    MalformedNameToken,
    LyingLengthToken,
    WideDecimalsToken,
    GasBurnerToken
} from "./mocks/MockTokens.sol";

/// @title DeepCoreLaunchRegistry — unit coverage
/// @notice Everything except the provenance mechanism, which is large enough and load-bearing
/// enough to get its own file: `LaunchProvenance.t.sol`.
///
/// @dev The pool manager here is the same writable mock the DeepCore registry's attestation tests
/// use, so a pool can be filed under the wrong id or name a manager that is not itself — things
/// core can never do, and therefore the only way to exercise the checks that catch them. Keys are
/// laid out with the launch token deliberately on one side or the other rather than sorted by
/// address, so `tokenIsCurrency0` is asserted against something chosen and not against whatever
/// `vm` happened to hand out.
contract DeepCoreLaunchRegistryTest is Test {
    DeepCoreRegistry internal deepcoreRegistry;
    DeepCoreLaunchRegistry internal registry;
    MockVault internal vault;
    MockPoolManager internal manager;

    GoodToken internal token;
    GoodToken internal quote;

    address internal admin = address(0x71E10);
    address internal curator = address(0xC0A70);
    address internal guardian = address(0x69A2D);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stranger = address(0x57A6E);

    uint16 internal constant TAME = PERM_AFTER_SWAP;
    uint16 internal constant SWAP_TAX = PERM_BEFORE_SWAP | PERM_BEFORE_SWAP_RETURNS_DELTA;

    function setUp() public {
        vault = new MockVault();
        manager = new MockPoolManager();
        vault.registerApp(address(manager));

        address[] memory curators = new address[](1);
        curators[0] = curator;
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        deepcoreRegistry = new DeepCoreRegistry(admin, address(vault), curators, guardians);

        registry = new DeepCoreLaunchRegistry(address(vault), address(deepcoreRegistry));

        token = new GoodToken("Foo Token", "FOO", 18);
        quote = new GoodToken("DeepCore USD", "ltUSD", 6);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(address c0, address c1, address hook, uint16 bitmap) internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(hook),
            poolManager: IPoolManager(address(manager)),
            fee: 3000,
            parameters: bytes32(uint256(bitmap) | (uint256(60) << 16))
        });
    }

    function _pool(address c0, address c1, address hook, uint16 bitmap) internal returns (bytes32) {
        return manager.setPool(_key(c0, c1, hook, bitmap));
    }

    function _meta() internal pure returns (LaunchMetadata memory) {
        return LaunchMetadata({
            description: "a launch",
            websiteURI: "https://example.invalid",
            xHandle: "example",
            telegramHandle: "example_tg"
        });
    }

    function _padMeta(string memory source, string memory audit) internal pure returns (LaunchpadMetadata memory) {
        return LaunchpadMetadata({
            name: "Acme Launchpad",
            description: "a launchpad",
            sourceURI: source,
            auditURI: audit,
            websiteURI: "https://acme.invalid"
        });
    }

    function _register(bytes32 poolId, address token_) internal {
        registry.registerLaunch(address(manager), poolId, token_, address(0), alice, address(0), _meta());
    }

    /*//////////////////////////////////////////////////////////////
                       REGISTRATION — PROVEN FACTS
    //////////////////////////////////////////////////////////////*/

    function test_register_recordsFactsReadBackFromTheManager() public {
        bytes32 poolId = _pool(address(token), address(quote), address(new HonestHook(SWAP_TAX)), SWAP_TAX);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), bob, address(0), _meta());

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(r.token, address(token));
        assertEq(r.quote, address(quote));
        assertTrue(r.tokenIsCurrency0);
        assertEq(r.fee, 3000);
        assertEq(r.poolManager, address(manager));
        assertEq(r.hookPermissions, SWAP_TAX, "bitmap must come from the pool's immutable parameters");
        assertEq(r.registrant, alice);
        assertEq(r.steward, alice, "zero steward defaults to the caller");
        assertEq(uint8(r.listing), uint8(Listing.Active));
        assertEq(uint8(r.origin), uint8(LaunchOrigin.Claimed));
        assertEq(r.registeredAt, uint64(block.timestamp));
        assertEq(r.registeredAtBlock, uint64(block.number));
    }

    /// @notice The launch token may be either side of the pair, and the record says which.
    function test_register_tokenOnCurrency1Side() public {
        bytes32 poolId = _pool(address(quote), address(token), address(0), 0);
        _register(poolId, address(token));

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertFalse(r.tokenIsCurrency0);
        assertEq(r.quote, address(quote));
    }

    /// @notice A pool with no hook is a perfectly good launch. Gating on one would exclude every
    /// plain pool from the shared index for no safety gain.
    function test_register_hooklessPoolIsAllowed() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        (address hooks, uint16 permissions, RiskClass risk, bool listed) = registry.launchHookOf(poolId);
        assertEq(hooks, address(0));
        assertEq(permissions, 0);
        assertEq(uint8(risk), uint8(RiskClass.Passive));
        assertFalse(listed);
    }

    function test_register_explicitStewardIsHonoured() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, bob, _meta());
        assertEq(registry.getLaunch(poolId).steward, bob);
    }

    function test_register_indicesArePopulated() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        assertEq(registry.launchCount(), 1);
        assertEq(registry.launchAt(0), poolId);
        assertEq(registry.tokenLaunchCount(address(token)), 1);
        assertEq(registry.launchesOfToken(address(token), 0, 10)[0], poolId);
        assertEq(registry.creatorLaunchCount(alice), 1);
        // No launchpad was named, so the "launched via" index must stay empty.
        assertEq(registry.launchpadLaunchCount(address(0)), 0);
    }

    /// @notice One token, several pools. A marketplace has to be able to show all of them.
    function test_register_oneTokenManyPools() public {
        GoodToken other = new GoodToken("Other", "OTH", 18);
        bytes32 a = _pool(address(token), address(quote), address(0), 0);
        bytes32 b = _pool(address(token), address(other), address(0), 0);
        _register(a, address(token));
        _register(b, address(token));

        assertEq(registry.tokenLaunchCount(address(token)), 2);
        bytes32[] memory all = registry.launchesOfToken(address(token), 0, type(uint256).max);
        assertEq(all.length, 2);
        assertEq(all[0], a);
        assertEq(all[1], b);
    }

    /*//////////////////////////////////////////////////////////////
                       REGISTRATION — WHAT IS REFUSED
    //////////////////////////////////////////////////////////////*/

    function test_reject_untrustedPoolManager() public {
        MockPoolManager rogue = new MockPoolManager();
        bytes32 poolId = rogue.setPool(
            PoolKey({
                currency0: Currency.wrap(address(token)),
                currency1: Currency.wrap(address(quote)),
                hooks: IHooks(address(0)),
                poolManager: IPoolManager(address(rogue)),
                fee: 3000,
                parameters: bytes32(0)
            })
        );
        vm.expectRevert(abi.encodeWithSelector(PoolProof.UntrustedPoolManager.selector, address(rogue)));
        registry.registerLaunch(address(rogue), poolId, address(token), address(0), alice, address(0), _meta());
    }

    /// @notice A Vault app is not necessarily a pool manager. Decoding garbage would be worse than
    /// failing.
    function test_reject_vaultAppThatIsNotAPoolManager() public {
        NotAPoolManager fake = new NotAPoolManager();
        vault.registerApp(address(fake));
        vm.expectRevert();
        registry.registerLaunch(
            address(fake), bytes32(uint256(1)), address(token), address(0), alice, address(0), _meta()
        );
    }

    function test_reject_poolDoesNotExist() public {
        bytes32 poolId = keccak256("never initialized");
        vm.expectRevert(abi.encodeWithSelector(PoolProof.PoolNotFound.selector, address(manager), poolId));
        _register(poolId, address(token));
    }

    /// @notice A key filed under an id that is not its own hash. Core cannot produce this; the
    /// `key.toId() == poolId` check is what catches a manager that tries.
    function test_reject_keyFiledUnderTheWrongId() public {
        bytes32 wrongId = keccak256("wrong");
        manager.forgePool(wrongId, _key(address(token), address(quote), address(0), 0));
        vm.expectRevert(abi.encodeWithSelector(PoolProof.PoolNotFound.selector, address(manager), wrongId));
        _register(wrongId, address(token));
    }

    function test_reject_tokenNotInPool() public {
        GoodToken outsider = new GoodToken("Outsider", "OUT", 18);
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.TokenNotInPool.selector, poolId, address(outsider)));
        _register(poolId, address(outsider));
    }

    function test_reject_nativeAsLaunchToken() public {
        bytes32 poolId = _pool(address(0), address(token), address(0), 0);
        vm.expectRevert(IDeepCoreLaunchRegistry.LaunchTokenCannotBeNative.selector);
        _register(poolId, address(0));
    }

    function test_reject_tokenWithoutCode() public {
        address eoa = address(0xDEAD);
        bytes32 poolId = _pool(eoa, address(quote), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchTokenHasNoCode.selector, eoa));
        _register(poolId, eoa);
    }

    function test_reject_duplicateRegistration() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchAlreadyRegistered.selector, poolId));
        _register(poolId, address(token));
    }

    function test_reject_oversizedMetadata() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory m = _meta();
        m.description = string(new bytes(2049));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.StringTooLong.selector, 2049, 2048));
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN IDENTITY

        Read off the token, never supplied. There is no parameter
        anywhere in this contract through which a registrant can
        type a name or a ticker.
    //////////////////////////////////////////////////////////////*/

    function test_tokenInfo_isReadFromTheTokenItself() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        (string memory name, string memory symbol, uint8 decimals, bytes32 codehash, bool readable) =
            registry.launchTokenInfoOf(poolId);
        assertEq(name, "Foo Token");
        assertEq(symbol, "FOO");
        assertEq(decimals, 18);
        assertEq(codehash, address(token).codehash);
        assertTrue(readable);
    }

    function test_tokenInfo_silentTokenIsUnreadableNotFabricated() public {
        SilentToken silent = new SilentToken();
        bytes32 poolId = _pool(address(silent), address(quote), address(0), 0);
        _register(poolId, address(silent));

        (string memory name, string memory symbol,,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertEq(bytes(name).length, 0);
        assertEq(bytes(symbol).length, 0);
        assertFalse(readable, "a token that will not say its name must not be recorded as if it did");
    }

    function test_tokenInfo_revertingTokenIsUnreadable() public {
        RevertingToken bad = new RevertingToken();
        bytes32 poolId = _pool(address(bad), address(quote), address(0), 0);
        _register(poolId, address(bad));
        (,,,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertFalse(readable);
    }

    /// @notice An over-long name is rejected, not truncated. A truncated name is a different name.
    function test_tokenInfo_longNameRejectedOnSize() public {
        LongNameToken long = new LongNameToken();
        bytes32 poolId = _pool(address(long), address(quote), address(0), 0);
        _register(poolId, address(long));

        (string memory name, string memory symbol,,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertEq(bytes(name).length, 0);
        assertEq(symbol, "LONG", "the symbol was well formed and must still be read");
        assertFalse(readable);
    }

    function test_tokenInfo_malformedHeadRejected() public {
        MalformedNameToken bad = new MalformedNameToken();
        bytes32 poolId = _pool(address(bad), address(quote), address(0), 0);
        _register(poolId, address(bad));
        (string memory name,,,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertEq(bytes(name).length, 0);
        assertFalse(readable);
    }

    /// @notice A length longer than the bytes actually returned is the short-buffer trick. It must
    /// not produce a string that reads past the copy.
    function test_tokenInfo_lyingLengthRejected() public {
        LyingLengthToken bad = new LyingLengthToken();
        bytes32 poolId = _pool(address(bad), address(quote), address(0), 0);
        _register(poolId, address(bad));
        (string memory name,,,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertEq(bytes(name).length, 0);
        assertFalse(readable);
    }

    function test_tokenInfo_wideDecimalsIgnored() public {
        WideDecimalsToken wide = new WideDecimalsToken();
        bytes32 poolId = _pool(address(wide), address(quote), address(0), 0);
        _register(poolId, address(wide));
        (,, uint8 decimals,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertEq(decimals, 0, "a value that does not fit a uint8 is not a small uint8");
        assertTrue(readable, "name and symbol were fine; only decimals was junk");
    }

    /// @notice A token that burns every unit of gas it is given costs the registrant its probe
    /// budget and nothing else. It cannot stop its own launch being indexed.
    function test_tokenInfo_gasBurnerCannotBrickRegistration() public {
        GasBurnerToken burner = new GasBurnerToken();
        bytes32 poolId = _pool(address(burner), address(quote), address(0), 0);
        _register(poolId, address(burner));

        (string memory name, string memory symbol,,, bool readable) = registry.launchTokenInfoOf(poolId);
        assertEq(bytes(name).length, 0);
        assertEq(symbol, "BURN");
        assertFalse(readable);
    }

    /// @notice Launch as FOO, rename to something that impersonates a real asset. The refresh is
    /// permissionless precisely so anybody who notices can put the truth back on chain.
    function test_refreshTokenInfo_picksUpARename() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        token.rename("USD Coin", "USDC");
        vm.prank(stranger);
        registry.refreshTokenInfo(poolId);

        (string memory name, string memory symbol,,,) = registry.launchTokenInfoOf(poolId);
        assertEq(name, "USD Coin");
        assertEq(symbol, "USDC");
    }

    /// @notice A proxy swap moves the codehash even when the name does not. The view exists so a
    /// UI can say "this token's code changed since we read it" without a refresh landing first.
    function test_tokenCodeHasMoved_afterAnUpgrade() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));
        assertFalse(registry.tokenCodeHasMoved(poolId));

        vm.etch(address(token), type(SilentToken).runtimeCode);
        assertTrue(registry.tokenCodeHasMoved(poolId));
    }

    /*//////////////////////////////////////////////////////////////
                    ROLES COME FROM THE DEEPCORE REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_roles_areReadFromTheDeepCoreRegistry() public {
        assertTrue(registry.isCurator(curator));
        assertTrue(registry.isGuardian(guardian));
        assertFalse(registry.isCurator(stranger));

        // One grant, on one contract, and it takes effect on both surfaces.
        bytes32 role = deepcoreRegistry.CURATOR_ROLE();
        vm.prank(admin);
        deepcoreRegistry.grantRole(role, stranger);
        assertTrue(registry.isCurator(stranger));
    }

    function test_roles_constantsMatchTheDeepCoreRegistry() public view {
        assertEq(registry.CURATOR_ROLE(), deepcoreRegistry.CURATOR_ROLE());
        assertEq(registry.GUARDIAN_ROLE(), deepcoreRegistry.GUARDIAN_ROLE());
    }

    /*//////////////////////////////////////////////////////////////
                            LAUNCH LISTING
    //////////////////////////////////////////////////////////////*/

    function test_listing_curatorMaySetAnyStatus() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        vm.prank(curator);
        registry.setLaunchListing(poolId, Listing.Malicious, "drains buyers");
        assertEq(uint8(registry.getLaunch(poolId).listing), uint8(Listing.Malicious));

        vm.prank(curator);
        registry.setLaunchListing(poolId, Listing.Active, "false positive");
        assertEq(uint8(registry.getLaunch(poolId).listing), uint8(Listing.Active));
    }

    function test_listing_guardianMayOnlyEscalate() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        vm.prank(guardian);
        registry.setLaunchListing(poolId, Listing.Malicious, "rug in progress");

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDeepCoreLaunchRegistry.GuardianCannotRelist.selector, Listing.Malicious, Listing.Active
            )
        );
        registry.setLaunchListing(poolId, Listing.Active, "");
    }

    function test_listing_strangerRejected() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.NotCuratorOrGuardian.selector, stranger));
        registry.setLaunchListing(poolId, Listing.Malicious, "");
    }

    /*//////////////////////////////////////////////////////////////
                          LAUNCH STEWARDSHIP
    //////////////////////////////////////////////////////////////*/

    function test_metadata_stewardMayEdit() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), _meta());

        LaunchMetadata memory m = _meta();
        m.description = "edited";
        vm.prank(alice);
        registry.updateLaunchMetadata(poolId, m);
        assertEq(registry.getLaunch(poolId).metadata.description, "edited");
    }

    function test_metadata_strangerRejected() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), _meta());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.NotLaunchSteward.selector, poolId, stranger));
        registry.updateLaunchMetadata(poolId, _meta());
    }

    /*//////////////////////////////////////////////////////////////
                         THE THREE LAUNCH LINKS

        Website (a string, because a website is a real URL), X and
        Telegram (bytes32 HANDLES). Three NAMED fields, because the
        thing the original one-social-link rule refused was an
        UNBOUNDED write every reader of the record pays for, and a
        fixed field is not that. See docs/launch-links.md.

        The split of rules is the thing under test. The strings get
        a length bound and NOTHING else - the last two tests in this
        section assert that absence on purpose. The handles get a
        TOTAL check, because for them one exists: [A-Za-z0-9_] within
        the platform's own limit is exactly the set of values that
        render into x.com/<h> or t.me/<h> as the handle they claim.
    //////////////////////////////////////////////////////////////*/

    /// @dev Left-aligned ASCII, zero-padded - the encoding `LaunchMetadata` documents. Built a
    /// byte at a time rather than with `mload`, so the padding is provably zero and a test can
    /// never pass on stale memory.
    /// @dev Handles are plain strings. This stayed as a helper after the fields moved off `bytes32`
    /// (2026-09-24) so the call sites below still read as "this is a handle", and so a future
    /// encoding change has one place to land again.
    function _h(string memory s) internal pure returns (string memory) {
        return s;
    }

    function _repeat(bytes1 c, uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = c;
        }
        return string(out);
    }

    function test_links_registerStoresAllThree() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        LaunchMetadata memory stored = registry.getLaunch(poolId).metadata;
        assertEq(stored.websiteURI, "https://example.invalid");
        assertEq(stored.xHandle, _h("example"));
        assertEq(stored.telegramHandle, _h("example_tg"));
    }

    function test_links_emittedAtRegistration() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IDeepCoreLaunchRegistry.LaunchMetadataUpdated(
            poolId,
            address(this),
            "a launch",
            "https://example.invalid",
            _h("example"),
            _h("example_tg")
        );
        _register(poolId, address(token));
    }

    function test_links_stewardMayEditEachIndependently() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), _meta());

        LaunchMetadata memory m = _meta();
        m.xHandle = _h("moved");
        vm.prank(alice);
        registry.updateLaunchMetadata(poolId, m);

        LaunchMetadata memory stored = registry.getLaunch(poolId).metadata;
        assertEq(stored.xHandle, _h("moved"));
        assertEq(stored.telegramHandle, _h("example_tg"), "telegram untouched");
    }

    /// @notice A project that leaves X or Telegram can clear the field. `updateLaunchMetadata`
    /// REPLACES the whole struct, so a zero handle must actually land as zero rather than leaving
    /// the old value in storage for a front end to keep rendering.
    function test_links_mayBeClearedToEmpty() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), _meta());

        LaunchMetadata memory m = _meta();
        m.xHandle = "";
        m.telegramHandle = "";
        vm.prank(alice);
        registry.updateLaunchMetadata(poolId, m);

        LaunchMetadata memory stored = registry.getLaunch(poolId).metadata;
        assertEq(stored.xHandle, "");
        assertEq(stored.telegramHandle, "");
    }

    /// @notice All three links are optional. A launch with none of them registers.
    function test_links_allEmptyIsLegal() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory empty;
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), empty);
        assertEq(registry.getLaunch(poolId).metadata.telegramHandle, "");
    }

    function test_links_xHandleAtTheLimitIsAccepted() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory m = _meta();
        m.xHandle = _repeat("a", registry.MAX_X_HANDLE_BYTES());
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
        assertEq(registry.getLaunch(poolId).metadata.xHandle, _repeat("a", 15));
    }

    function test_links_xHandleOneOverTheLimitIsRefused() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        uint256 max = registry.MAX_X_HANDLE_BYTES();
        LaunchMetadata memory m = _meta();
        m.xHandle = _repeat("a", max + 1);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, m.xHandle, max));
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
    }

    /// @notice Telegram's limit is 32, which is exactly `bytes32`'s capacity.
    ///
    /// @dev So the 33-character case this contract would refuse CANNOT ARRIVE - the type refuses it
    /// first, and there is no calldata that expresses it. That is worth an assertion rather than a
    /// comment, because it relocates the truncation risk: whoever ENCODES a handle must refuse a
    /// 33-character input instead of taking its first 32 bytes, and no on-chain check can catch
    /// that mistake. The bound is still written into `_boundHandle` for the same reason the type
    /// is not relied on elsewhere - if `MAX_TELEGRAM_HANDLE_BYTES` is ever lowered, the check is
    /// already in the right place.
    function test_links_telegramLimitIsTheWidthOfTheType() public {
        assertEq(registry.MAX_TELEGRAM_HANDLE_BYTES(), 32, "a 33-byte handle is unrepresentable");

        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory m = _meta();
        m.telegramHandle = _repeat("z", 32);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
        assertEq(registry.getLaunch(poolId).metadata.telegramHandle, _repeat("z", 32));
    }

    /// @notice The character set is what makes a handle renderable without further cleaning, so
    /// each hazard it exists to exclude is named here rather than covered by one representative.
    function test_links_hostileHandleBytesAreRefused() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        uint256 max = registry.MAX_X_HANDLE_BYTES();

        string[7] memory bad = [
            _h("@example"), // the leading @ the encoder must strip
            _h("x.com/evil"), // a path, which is how a handle field becomes a URL field
            _h("ex ample"), // whitespace
            _h("ex-ample"), // outside the platform alphabet
            _h("."), // a bare '.'
            // A NUL byte. While these fields were `bytes32` this could not be expressed as a
            // one-character handle at all — a zero-padded word made it indistinguishable from
            // "absent" — so it needed its own embedded-zero rule. As a `string` it is simply a
            // byte outside the alphabet, refused by the same check as everything else here.
            _h(string(hex"00")),
            // "café" as UTF-8 bytes. Written as hex because solc refuses a non-ASCII plain string
            // literal (error 8936) — and multi-byte UTF-8 is the class of byte a bidi override
            // lives in, which is exactly what the handle alphabet exists to exclude.
            _h(string(hex"636166c3a9"))
        ];

        for (uint256 i = 0; i < bad.length; i++) {
            LaunchMetadata memory m = _meta();
            m.xHandle = bad[i];
            vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, bad[i], max));
            registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
        }
    }

    /// @notice An embedded zero is still refused — kept as its own test because the REASON changed
    /// on 2026-09-24 and the property must not quietly lapse with it.
    ///
    /// @dev While these fields were `bytes32`, `"good\0evil"` was the subtle case: a left-aligned
    /// zero-padded word made a front end stop at the first zero (as it must, since padding is how
    /// a short handle is expressed), so a record could DISPLAY `good` while a comparison matched a
    /// different value. That needed a dedicated "no non-zero byte after the padding starts" rule.
    ///
    /// As a `string` the length is explicit, so nothing is dropped on render and the attack does
    /// not exist. The NUL is now refused by the ordinary charset check, since `\0` is not in
    /// `[A-Za-z0-9_]`. Same refusal, ordinary reason — and this test is what would catch someone
    /// "simplifying" the charset check in a way that lets a NUL through.
    function test_links_embeddedZeroIsRefused() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        uint256 max = registry.MAX_X_HANDLE_BYTES();

        string memory sneaky = string(abi.encodePacked("good", hex"00", "evil"));
        assertEq(bytes(sneaky).length, 9, "the NUL must be a real byte in the middle, not a terminator");

        LaunchMetadata memory m = _meta();
        m.xHandle = sneaky;
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, sneaky, max));
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
    }

    /// @notice The handle rules are enforced on the EDIT path too. A steward that could write an
    /// invalid handle after registration would make the registration-time check decorative.
    function test_links_invalidHandleOnTheUpdatePathIsRefused() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(alice);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), _meta());

        uint256 max = registry.MAX_X_HANDLE_BYTES();
        LaunchMetadata memory m = _meta();
        m.xHandle = _h("@nope");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, m.xHandle, max));
        registry.updateLaunchMetadata(poolId, m);
    }

    /// @notice The bound is exactly the platform's, at every length, for any run of legal bytes.
    function testFuzz_links_handleBoundIsExactlyTheLimit(uint8 xLen, uint8 tgLen) public {
        uint256 xMax = registry.MAX_X_HANDLE_BYTES();
        uint256 tgMax = registry.MAX_TELEGRAM_HANDLE_BYTES();
        xLen = uint8(bound(xLen, 0, 32));
        tgLen = uint8(bound(tgLen, 0, 32));

        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory m;
        m.xHandle = _repeat("a", xLen);
        m.telegramHandle = _repeat("b", tgLen);

        if (xLen > xMax) {
            vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, m.xHandle, xMax));
        } else if (tgLen > tgMax) {
            // Unreachable while tgMax == 32; kept so the assertion follows the constant if it moves.
            vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, m.telegramHandle, tgMax));
        }
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
    }

    /// @notice Every byte of the alphabet is accepted, so the check cannot be quietly narrowed.
    function testFuzz_links_everyLegalByteIsAccepted(uint8 raw) public {
        bytes1 c = bytes1(raw);
        bool legal = (raw >= 0x61 && raw <= 0x7A) || (raw >= 0x41 && raw <= 0x5A) || (raw >= 0x30 && raw <= 0x39)
            || raw == 0x5F;

        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory m;
        bytes memory one = new bytes(1);
        one[0] = c;
        m.xHandle = string(one);

        // NUL is no longer a special case. While these fields were `bytes32`, `bytes32(0)` meant
        // BOTH "absent" and "a single NUL", so a one-character NUL handle had to be accepted as
        // absence. A `string` carries its length, so `"\0"` is a one-character handle whose only
        // character is outside `[A-Za-z0-9_]` — it falls through to the `!legal` branch below and
        // is refused. Only `""` is "not given"; that is asserted separately by
        // `test_links_absentHandlesAreLegal`.
        if (!legal) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDeepCoreLaunchRegistry.InvalidHandle.selector, m.xHandle, registry.MAX_X_HANDLE_BYTES()
                )
            );
        }
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
    }

    /// @notice DELIBERATE ABSENCE OF VALIDATION ON THE STRINGS, asserted so that "tightening" it
    /// later is a conscious act rather than a silent one.
    ///
    /// The registry stores a `javascript:` link, a bidi-override and a newline without complaint.
    /// That is the design FOR STRINGS: a scheme filter on chain is bypassed by case, by whitespace
    /// and by encoding, and its real cost is persuading a front-end author that the registry
    /// sanitised the value. `LaunchMetadata`'s header states what a consumer must do instead —
    /// allowlist the scheme at render time, escape, truncate, never infer identity.
    ///
    /// The handles are the deliberate CONTRAST: the same bytes are refused two tests above,
    /// because a handle admits a total check and a URL does not. If this test is ever changed to
    /// expect a revert, `docs/launch-links.md` §6 is the argument being overruled, and the
    /// immutability of the deployed registry is the price.
    function test_links_hostileStringContentIsStoredNotRefused() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        LaunchMetadata memory m;
        m.websiteURI = "javascript:alert(document.domain)";
        // U+202E RIGHT-TO-LEFT OVERRIDE, built from bytes rather than written as a literal: solc
        // itself REFUSES an unbalanced directional override in source (error 8936), which is worth
        // noticing — the compiler protects its own readers and the registry protects nobody,
        // because calldata is not source. A front end is in the registry's position, not solc's.
        //
        // This case used to sit on `iconURI`. That member was removed on 2026-09-24 (see the block
        // above `LaunchMetadata` — the struct could not afford it and stay deployable), so the
        // override moved to `description`, which is the other member with no validation at all.
        // The property under test is unchanged: an unvalidated string is STORED, not refused.
        bytes memory hostile = abi.encodePacked("line one\nreal", hex"E280AE", "/kcatta");
        m.description = string(hostile);

        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);

        LaunchMetadata memory stored = registry.getLaunch(poolId).metadata;
        assertEq(stored.websiteURI, "javascript:alert(document.domain)");
        assertEq(stored.description, string(hostile));
    }

    /// @notice The string length bound still exists and is still exactly `MAX_URI_BYTES`.
    function test_links_oversizedWebsiteIsRefused() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        uint256 max = registry.MAX_URI_BYTES();
        LaunchMetadata memory m = _meta();
        m.websiteURI = string(new bytes(max + 1));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.StringTooLong.selector, max + 1, max));
        registry.registerLaunch(address(manager), poolId, address(token), address(0), alice, address(0), m);
    }

    /// @notice Registration is open, so a stranger can index somebody's real pool with hostile
    /// copy. Reassignment repairs the listing instead of deleting it, and `registrant` stays put.
    function test_steward_curatorFixesSquatting() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        vm.prank(stranger);
        registry.registerLaunch(address(manager), poolId, address(token), address(0), address(0), address(0), _meta());

        vm.prank(curator);
        registry.transferLaunchSteward(poolId, alice);

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(r.steward, alice);
        assertEq(r.registrant, stranger, "who actually listed it stays auditable");
    }

    /*//////////////////////////////////////////////////////////////
                              LAUNCHPADS
    //////////////////////////////////////////////////////////////*/

    function test_launchpad_thirdPartyListingIsClaimed() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        vm.prank(stranger);
        registry.registerLaunchpad(address(pad), address(0), _padMeta("ipfs://src", ""));

        LaunchpadRecord memory r = registry.getLaunchpad(address(pad));
        assertEq(uint8(r.origin), uint8(LaunchpadOrigin.Claimed));
        assertEq(r.registrant, stranger);
        assertEq(r.steward, stranger);
    }

    function test_launchpad_selfListingIsSelfRegistered() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        pad.selfRegister(address(registry), alice, _padMeta("ipfs://src", ""));

        LaunchpadRecord memory r = registry.getLaunchpad(address(pad));
        assertEq(uint8(r.origin), uint8(LaunchpadOrigin.SelfRegistered));
        assertEq(r.registrant, address(pad));
        assertEq(r.steward, alice);
        assertEq(r.codehash, address(pad).codehash);
    }

    function test_launchpad_eoaRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadHasNoCode.selector, alice));
        registry.registerLaunchpad(alice, address(0), _padMeta("", ""));
    }

    function test_launchpad_duplicateRejected() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        registry.registerLaunchpad(address(pad), address(0), _padMeta("", ""));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadAlreadyRegistered.selector, address(pad)));
        registry.registerLaunchpad(address(pad), address(0), _padMeta("", ""));
    }

    function test_launchpad_emptyNameRejected() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        LaunchpadMetadata memory m = _padMeta("", "");
        m.name = "";
        vm.expectRevert(IDeepCoreLaunchRegistry.EmptyName.selector);
        registry.registerLaunchpad(address(pad), address(0), m);
    }

    /// @notice The squatting remedy that needs no curator: only the launchpad can call this.
    function test_launchpad_claimUpgradesAndMovesSteward() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        vm.prank(stranger);
        registry.registerLaunchpad(address(pad), address(0), _padMeta("ipfs://src", ""));

        pad.claim(address(registry), alice);

        LaunchpadRecord memory r = registry.getLaunchpad(address(pad));
        assertEq(uint8(r.origin), uint8(LaunchpadOrigin.SelfRegistered));
        assertEq(r.steward, alice);
    }

    function test_launchpad_claimRequiresAListing() public {
        SilentLaunchpad pad = new SilentLaunchpad();
        vm.prank(address(pad));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadNotRegistered.selector, address(pad)));
        registry.claimLaunchpad(alice);
    }

    /*//////////////////////////////////////////////////////////////
                        LAUNCHPAD VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @dev Stands up a self-registered launchpad with one attributed launch, i.e. the minimum
    /// state in which a badge is permitted at all.
    function _badgeableLaunchpad(string memory audit) internal returns (HonestLaunchpad pad, bytes32 poolId) {
        pad = new HonestLaunchpad();
        pad.selfRegister(address(registry), alice, _padMeta("ipfs://src", audit));
        poolId = _pool(address(token), address(quote), address(0), 0);
        pad.registerLaunch(address(registry), address(manager), poolId, address(token), bob, bob, _meta());
    }

    function test_verification_happyPath() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "reviewed");
        assertTrue(registry.isLaunchpadAudited(address(pad)));
    }

    function test_verification_refusedOnAClaimedListing() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        vm.prank(stranger);
        registry.registerLaunchpad(address(pad), address(0), _padMeta("ipfs://src", "ipfs://audit"));
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        pad.registerLaunch(address(registry), address(manager), poolId, address(token), bob, bob, _meta());

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadNotSelfRegistered.selector, address(pad)));
        registry.setLaunchpadVerification(address(pad), Verification.SourceVerified, "");
    }

    function test_verification_refusedWithoutAnAttributedLaunch() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        pad.selfRegister(address(registry), alice, _padMeta("ipfs://src", ""));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadHasNoLaunches.selector, address(pad)));
        registry.setLaunchpadVerification(address(pad), Verification.SourceVerified, "");
    }

    function test_verification_requiresSourceURI() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        pad.selfRegister(address(registry), alice, _padMeta("", ""));
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        pad.registerLaunch(address(registry), address(manager), poolId, address(token), bob, bob, _meta());

        vm.prank(curator);
        vm.expectRevert(IDeepCoreLaunchRegistry.SourceURIRequired.selector);
        registry.setLaunchpadVerification(address(pad), Verification.SourceVerified, "");
    }

    function test_verification_auditedRequiresAuditURI() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("");
        vm.prank(curator);
        vm.expectRevert(IDeepCoreLaunchRegistry.AuditURIRequired.selector);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");
    }

    function test_verification_blockedWhileMalicious() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(guardian);
        registry.setLaunchpadListing(address(pad), Listing.Malicious, "hostile");

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadFlaggedMalicious.selector, address(pad)));
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");
    }

    function test_verification_strangerRejected() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.NotCurator.selector, stranger));
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");
    }

    /// @notice A badge must not survive the listing being flagged, not even for one block.
    function test_verification_maliciousFlagResetsIt() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");

        vm.prank(guardian);
        registry.setLaunchpadListing(address(pad), Listing.Malicious, "turned");

        assertEq(uint8(registry.getLaunchpad(address(pad)).verification), uint8(Verification.Unverified));
        assertFalse(registry.isLaunchpadAudited(address(pad)));
    }

    /// @notice Deprecating an honest launchpad is not an accusation, so the audit stands.
    function test_verification_deprecationKeepsIt() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");

        vm.prank(curator);
        registry.setLaunchpadListing(address(pad), Listing.Deprecated, "v2 shipped");
        assertEq(uint8(registry.getLaunchpad(address(pad)).verification), uint8(Verification.Audited));
    }

    /// @notice The bait-and-switch: get badged, then repoint the source at something else.
    function test_verification_stewardEditDemotes() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");

        vm.prank(alice); // the steward
        registry.updateLaunchpadMetadata(address(pad), _padMeta("ipfs://something-else", "ipfs://audit"));
        assertEq(uint8(registry.getLaunchpad(address(pad)).verification), uint8(Verification.Unverified));
    }

    function test_verification_curatorEditDoesNotDemote() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");

        vm.prank(curator);
        registry.updateLaunchpadMetadata(address(pad), _padMeta("ipfs://src", "ipfs://audit"));
        assertEq(uint8(registry.getLaunchpad(address(pad)).verification), uint8(Verification.Audited));
    }

    /// @notice The other bait-and-switch: swap the implementation behind a proxy after the review.
    function test_verification_codeChangeDemotes() public {
        (HonestLaunchpad pad,) = _badgeableLaunchpad("ipfs://audit");
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");

        // The live badge check notices immediately, before anybody calls the refresh.
        vm.etch(address(pad), type(SilentLaunchpad).runtimeCode);
        assertFalse(registry.isLaunchpadAudited(address(pad)));

        vm.prank(stranger);
        registry.refreshLaunchpadCode(address(pad));
        assertEq(uint8(registry.getLaunchpad(address(pad)).verification), uint8(Verification.Unverified));
    }

    function test_refreshLaunchpadCode_revertsWhenUnchanged() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        registry.registerLaunchpad(address(pad), address(0), _padMeta("", ""));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.CodehashUnchanged.selector, address(pad)));
        registry.refreshLaunchpadCode(address(pad));
    }

    /*//////////////////////////////////////////////////////////////
                    FORWARDING INTO THE DEEPCORE REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice A launch carries exactly the evidence the DeepCore registry needs to move a hook off
    /// `SelfReported`, so it is pushed across for free.
    function test_forwarding_attestsTheHook() public {
        HonestHook hook = new HonestHook(SWAP_TAX);
        deepcoreRegistry.register(
            address(hook),
            DeepCoreMetadata({
                name: "Hook", description: "d", sourceURI: "ipfs://src", auditURI: "", chainIds: new uint256[](0)
            })
        );
        assertFalse(deepcoreRegistry.isAttested(address(hook)));

        bytes32 poolId = _pool(address(token), address(quote), address(hook), SWAP_TAX);
        _register(poolId, address(token));

        assertTrue(deepcoreRegistry.isAttested(address(hook)), "the launch's pool corroborated the hook");
        (uint32 count,,, bytes32 attestedPoolId,) = deepcoreRegistry.attestationOf(address(hook));
        assertEq(count, 1);
        assertEq(attestedPoolId, poolId);
    }

    /// @notice An unlisted hook is not a reason to refuse a launch. The forward simply fails.
    function test_forwarding_isBestEffort() public {
        HonestHook hook = new HonestHook(TAME);
        bytes32 poolId = _pool(address(token), address(quote), address(hook), TAME);
        _register(poolId, address(token));

        assertTrue(registry.isLaunchRegistered(poolId));
        assertFalse(deepcoreRegistry.isRegistered(address(hook)));
    }

    /// @notice And it can be retried once the hook is listed, which is the common ordering.
    function test_forwarding_standaloneRetry() public {
        HonestHook hook = new HonestHook(TAME);
        bytes32 poolId = _pool(address(token), address(quote), address(hook), TAME);
        _register(poolId, address(token));

        deepcoreRegistry.register(
            address(hook),
            DeepCoreMetadata({
                name: "Hook", description: "d", sourceURI: "ipfs://src", auditURI: "", chainIds: new uint256[](0)
            })
        );
        assertFalse(deepcoreRegistry.isAttested(address(hook)));

        vm.prank(stranger);
        assertTrue(registry.attestHookFromLaunch(poolId));
        assertTrue(deepcoreRegistry.isAttested(address(hook)));
    }

    function test_forwarding_hooklessPoolIsANoOp() public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));
        assertFalse(registry.attestHookFromLaunch(poolId));
    }

    /*//////////////////////////////////////////////////////////////
                             VIEWS & PAGING
    //////////////////////////////////////////////////////////////*/

    function test_views_revertForUnknownLaunch() public {
        bytes32 ghost = keccak256("ghost");
        bytes memory expected = abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchNotRegistered.selector, ghost);

        vm.expectRevert(expected);
        registry.getLaunch(ghost);
        vm.expectRevert(expected);
        registry.provenanceOf(ghost);
        vm.expectRevert(expected);
        registry.launchHookOf(ghost);
        vm.expectRevert(expected);
        registry.launchPairOf(ghost);
        vm.expectRevert(expected);
        registry.launchTokenInfoOf(ghost);
        vm.expectRevert(expected);
        registry.tokenCodeHasMoved(ghost);
        vm.expectRevert(expected);
        registry.refreshTokenInfo(ghost);
        vm.expectRevert(expected);
        registry.attestHookFromLaunch(ghost);

        assertFalse(registry.isLaunchRegistered(ghost));
    }

    function test_views_revertForUnknownLaunchpad() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadNotRegistered.selector, alice));
        registry.getLaunchpad(alice);
        assertFalse(registry.isLaunchpadRegistered(alice));
        assertFalse(registry.isLaunchpadAudited(alice));
    }

    function test_paging_clampsAndPreservesOrder() public {
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            GoodToken t = new GoodToken("T", "T", 18);
            ids[i] = _pool(address(t), address(quote), address(0), 0);
            _register(ids[i], address(t));
        }

        assertEq(registry.listLaunches(0, type(uint256).max).length, 5);
        assertEq(registry.listLaunches(3, 100).length, 2);
        assertEq(registry.listLaunches(5, 100).length, 0);
        bytes32[] memory middle = registry.listLaunches(1, 2);
        assertEq(middle[0], ids[1]);
        assertEq(middle[1], ids[2]);
    }

    function test_paging_offsetPastEndReverts() public {
        vm.expectRevert(RegistryPaging.InvalidRange.selector);
        registry.listLaunches(1, 1);
        vm.expectRevert(RegistryPaging.InvalidRange.selector);
        registry.listLaunchpads(1, 1);
    }

    /// @notice Paging must never panic, whatever offset and limit a front end passes.
    function testFuzz_paging_neverPanics(uint256 offset, uint256 limit) public {
        bytes32 poolId = _pool(address(token), address(quote), address(0), 0);
        _register(poolId, address(token));

        offset = bound(offset, 0, 1);
        try registry.listLaunches(offset, limit) returns (bytes32[] memory page) {
            assertLe(page.length, 1);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), RegistryPaging.InvalidRange.selector);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(IDeepCoreLaunchRegistry.ZeroAddress.selector);
        new DeepCoreLaunchRegistry(address(0), address(deepcoreRegistry));
        vm.expectRevert(IDeepCoreLaunchRegistry.ZeroAddress.selector);
        new DeepCoreLaunchRegistry(address(vault), address(0));
    }

    function test_constructor_anchorsAreImmutableAndPublic() public view {
        assertEq(address(registry.vault()), address(vault));
        assertEq(address(registry.deepcoreRegistry()), address(deepcoreRegistry));
    }
}
