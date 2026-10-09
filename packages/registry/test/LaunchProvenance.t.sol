// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {DeepCoreRegistry} from "../src/DeepCoreRegistry.sol";
import {Verification, Listing} from "../src/IDeepCoreRegistry.sol";
import {DeepCoreLaunchRegistry} from "../src/DeepCoreLaunchRegistry.sol";
import {
    IDeepCoreLaunchRegistry,
    LaunchMetadata,
    LaunchRecord,
    LaunchOrigin,
    LaunchpadMetadata,
    LaunchpadOrigin
} from "../src/IDeepCoreLaunchRegistry.sol";

import {MockVault, MockPoolManager} from "./mocks/MockPools.sol";
import {
    HonestLaunchpad,
    SilentLaunchpad,
    OverClaimingLaunchpad,
    DenyingLaunchpad,
    RevertingLaunchpad,
    GasBurnerLaunchpad,
    DirtyAddressLaunchpad,
    ShortReturnLaunchpad,
    BombLaunchpad,
    TwoFacedLaunchpad
} from "./mocks/MockLaunchpads.sol";
import {GoodToken} from "./mocks/MockTokens.sol";

/// @title Launch provenance — the property the whole index rests on
///
/// @notice A shared marketplace is only worth being in if "launched via Acme" cannot be faked. If
/// it can, the first convincing forgery teaches every reader to discount every row, and the
/// network effect the registry exists to create becomes a liability instead.
///
/// @dev The claim under test, stated so it can fail:
///
///     A LAUNCH RECORD NAMES A LAUNCHPAD IF AND ONLY IF THAT LAUNCHPAD'S OWN CODE NAMED THE POOL.
///
/// Two accepted proofs — the launchpad is `msg.sender`, or the launchpad answers
/// `IDeepCoreLaunchOrigin.launchOriginOf` — and nothing else, ever, including a curator. The
/// representation is what makes the invariant readable rather than merely documented: there is no
/// "claimed launchpad" field to downgrade into, so `record.launchpad != address(0)` and
/// `record.origin == LaunchpadAttested` are the same statement, and a front end cannot render an
/// unproven attribution because one cannot exist.
///
/// The honest limit is tested too: a launchpad CAN over-claim as itself. It cannot impersonate a
/// different launchpad, and it does so at an address a curator can clear.
contract LaunchProvenanceTest is Test {
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
    address internal attacker = address(0xBAD);

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

    uint160 internal _nonce;

    function _pool() internal returns (bytes32) {
        return _pool(address(token));
    }

    function _pool(address launchToken) internal returns (bytes32) {
        _nonce += 1;
        return manager.setPool(
            PoolKey({
                currency0: Currency.wrap(launchToken),
                currency1: Currency.wrap(address(quote)),
                hooks: IHooks(address(0)),
                poolManager: IPoolManager(address(manager)),
                // Distinct fee per pool so every call gets a fresh id.
                fee: 3000 + uint24(_nonce),
                parameters: bytes32(uint256(60) << 16)
            })
        );
    }

    function _meta() internal pure returns (LaunchMetadata memory) {
        return LaunchMetadata({description: "", websiteURI: "", xHandle: "", telegramHandle: ""});
    }

    function _padMeta() internal pure returns (LaunchpadMetadata memory) {
        return LaunchpadMetadata({
            name: "Acme Launchpad", description: "", sourceURI: "ipfs://src", auditURI: "ipfs://audit", websiteURI: ""
        });
    }

    function _registerClaimed(bytes32 poolId, address creator) internal {
        registry.registerLaunch(address(manager), poolId, address(token), address(0), creator, address(0), _meta());
    }

    /*//////////////////////////////////////////////////////////////
        THE TEST THIS DESIGN EXISTS FOR

        An attacker holds a real pool, real bytes, and a real
        launchpad's address. Everything they need to make a row
        that reads "launched via Acme" — except Acme's code.
    //////////////////////////////////////////////////////////////*/

    function test_SPOOF_strangerCannotHangALaunchOffSomebodyElsesLaunchpad() public {
        // Acme is a real, self-registered, audited launchpad with a genuine launch to its name.
        HonestLaunchpad acme = new HonestLaunchpad();
        acme.selfRegister(address(registry), alice, _padMeta());
        bytes32 genuine = _pool();
        acme.recordLaunch(genuine, alice);
        acme.registerLaunch(address(registry), address(manager), genuine, address(token), alice, alice, _meta());
        vm.prank(curator);
        registry.setLaunchpadVerification(address(acme), Verification.Audited, "reviewed");
        assertTrue(registry.isLaunchpadAudited(address(acme)));

        // The attacker's own pool. Real, initialized, indistinguishable from Acme's at the manager.
        GoodToken scam = new GoodToken("Foo Token", "FOO", 18);
        bytes32 rug = manager.setPool(
            PoolKey({
                currency0: Currency.wrap(address(scam)),
                currency1: Currency.wrap(address(quote)),
                hooks: IHooks(address(0)),
                poolManager: IPoolManager(address(manager)),
                fee: 500,
                parameters: bytes32(uint256(60) << 16)
            })
        );

        // Attempt 1: just name Acme. Acme's code has never heard of this pool.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(acme), rug));
        registry.registerLaunch(address(manager), rug, address(scam), address(acme), attacker, address(0), _meta());

        // Attempt 2: index it without attribution — which is allowed, and is the honest outcome —
        // then try to attach Acme's name afterwards.
        vm.prank(attacker);
        registry.registerLaunch(address(manager), rug, address(scam), address(0), attacker, address(0), _meta());
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(acme), rug));
        registry.attestLaunchOrigin(rug, address(acme), attacker);

        // Attempt 3: the attacker's own contract vouching FOR Acme buys nothing, because the
        // record names whoever was probed, and the probe is the address being named.
        OverClaimingLaunchpad liar = new OverClaimingLaunchpad(attacker);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(acme), rug));
        registry.attestLaunchOrigin(rug, address(acme), attacker);

        // Attempt 4: not even a curator can assign an attribution. There is no such function.
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.NoAttributionToClear.selector, rug));
        registry.clearLaunchAttribution(rug, "");

        // The rug row is, and stays, unattributed.
        (LaunchOrigin origin, address launchpad,, bool padRegistered,,) = registry.provenanceOf(rug);
        assertEq(uint8(origin), uint8(LaunchOrigin.Claimed));
        assertEq(launchpad, address(0), "an unproven launchpad is not recorded, it is refused");
        assertFalse(padRegistered);

        // And Acme's "launched via" index contains exactly its one real launch.
        assertEq(registry.launchpadLaunchCount(address(acme)), 1);
        assertEq(registry.launchesOfLaunchpad(address(acme), 0, 10)[0], genuine);

        // The liar exists but is attached to nothing.
        assertEq(registry.launchpadLaunchCount(address(liar)), 0);
    }

    /// @notice The representation invariant, over every path that can write `launchpad`.
    /// @dev If this ever fails, some path has produced a named launchpad without a vouch, or an
    /// attested origin with no name — either way a UI is about to print something it cannot back.
    function test_SPOOF_launchpadIsSetIffOriginIsAttested() public {
        HonestLaunchpad pad = new HonestLaunchpad();

        bytes32 claimed = _pool();
        _registerClaimed(claimed, alice);
        _assertInvariant(claimed);

        bytes32 selfCalled = _pool();
        pad.registerLaunch(address(registry), address(manager), selfCalled, address(token), alice, alice, _meta());
        _assertInvariant(selfCalled);

        bytes32 probed = _pool();
        _registerClaimed(probed, alice);
        pad.recordLaunch(probed, bob);
        registry.attestLaunchOrigin(probed, address(pad), address(0));
        _assertInvariant(probed);

        vm.prank(curator);
        registry.clearLaunchAttribution(probed, "wrong pad");
        _assertInvariant(probed);
    }

    function _assertInvariant(bytes32 poolId) internal view {
        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(
            r.launchpad != address(0), r.origin == LaunchOrigin.LaunchpadAttested, "launchpad set <=> origin attested"
        );
        if (r.origin == LaunchOrigin.LaunchpadAttested) {
            assertGt(r.originAttestedAt, 0);
        } else {
            assertEq(r.originAttestedAt, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PATH 1 — THE LAUNCHPAD CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice `msg.sender` needs no interface, which is what makes it the path a new launchpad
    /// should take: it works from the same transaction as `initialize`, so there is no race.
    function test_selfCall_attestsWithoutImplementingAnything() public {
        SilentLaunchpad pad = new SilentLaunchpad();
        bytes32 poolId = _pool();
        pad.registerLaunch(address(registry), address(manager), poolId, address(token), bob, bob, _meta());

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(uint8(r.origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(r.launchpad, address(pad));
        assertEq(r.creator, bob, "on the self-call path the launchpad names the creator");
        assertEq(r.registrant, address(pad));
        assertEq(registry.launchpadLaunchCount(address(pad)), 1);
    }

    /// @notice An EOA cannot be a launchpad, so it cannot mint itself the strong tier by naming
    /// itself.
    function test_selfCall_eoaCannotBeItsOwnLaunchpad() public {
        bytes32 poolId = _pool();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadHasNoCode.selector, attacker));
        registry.registerLaunch(address(manager), poolId, address(token), attacker, attacker, address(0), _meta());
    }

    /*//////////////////////////////////////////////////////////////
                        PATH 2 — THE LAUNCHPAD ANSWERS
    //////////////////////////////////////////////////////////////*/

    function test_probe_honestLaunchpadVouchesAtRegistration() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        bytes32 poolId = _pool();
        pad.recordLaunch(poolId, bob);

        // A third party indexes the launch and the launchpad's own answer carries it.
        vm.prank(attacker);
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(uint8(r.origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(r.launchpad, address(pad));
        assertEq(r.creator, bob, "the launchpad's answer wins over the caller's argument");
        assertEq(r.registrant, attacker);
        assertEq(registry.creatorLaunchCount(bob), 1);
        assertEq(registry.creatorLaunchCount(alice), 0);
    }

    function test_probe_upgradesAClaimedRecordLater() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        bytes32 poolId = _pool();
        _registerClaimed(poolId, alice);
        assertEq(uint8(registry.getLaunch(poolId).origin), uint8(LaunchOrigin.Claimed));

        pad.recordLaunch(poolId, bob);
        vm.prank(attacker); // permissionless: the caller supplies no facts
        registry.attestLaunchOrigin(poolId, address(pad), address(0));

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(uint8(r.origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(r.creator, bob);
        assertEq(r.steward, address(this), "attesting must not move stewardship");
    }

    /// @notice A launchpad that predates the interface can still vouch for its own old launches.
    function test_probe_selfCallAlsoWorksAfterTheFact() public {
        SilentLaunchpad pad = new SilentLaunchpad();
        bytes32 poolId = _pool();
        _registerClaimed(poolId, alice);

        vm.prank(address(pad));
        registry.attestLaunchOrigin(poolId, address(pad), bob);
        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(r.launchpad, address(pad));
        assertEq(r.creator, bob);
    }

    function test_probe_denyingLaunchpadIsRefused() public {
        DenyingLaunchpad pad = new DenyingLaunchpad();
        bytes32 poolId = _pool();
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(pad), poolId)
        );
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());
    }

    function test_probe_revertingLaunchpadIsRefused() public {
        RevertingLaunchpad pad = new RevertingLaunchpad();
        bytes32 poolId = _pool();
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(pad), poolId)
        );
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());
    }

    /// @notice A launchpad that never returns costs the caller its probe budget and stops. It
    /// cannot make the registry unusable for anybody else.
    function test_probe_gasBurnerIsRefusedAndBounded() public {
        GasBurnerLaunchpad pad = new GasBurnerLaunchpad();
        bytes32 poolId = _pool();
        uint256 before = gasleft();
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(pad), poolId)
        );
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());
        assertLt(before - gasleft(), 400_000, "the burn must be capped near PROBE_GAS, not open-ended");

        // The next registration is unaffected.
        bytes32 clean = _pool();
        _registerClaimed(clean, alice);
        assertTrue(registry.isLaunchRegistered(clean));
    }

    /// @notice Dirty high bits above the address are not a small address. solc's own decoder would
    /// reject the word, so accepting the low 160 bits would let a launchpad present one creator to
    /// a decoder and a different one to a raw reader.
    function test_probe_dirtyAddressIsRefused() public {
        DirtyAddressLaunchpad pad = new DirtyAddressLaunchpad();
        bytes32 poolId = _pool();
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(pad), poolId)
        );
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());
    }

    function test_probe_shortReturnIsRefused() public {
        ShortReturnLaunchpad pad = new ShortReturnLaunchpad();
        bytes32 poolId = _pool();
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(pad), poolId)
        );
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());
    }

    function test_probe_returnBombIsRefused() public {
        BombLaunchpad pad = new BombLaunchpad();
        bytes32 poolId = _pool();
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadDidNotVouch.selector, address(pad), poolId)
        );
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());
    }

    /// @notice A `view` function can read `msg.sender`, so a launchpad can answer the registry one
    /// way and everybody else another. That branch buys it nothing, because the registry never
    /// treats the answer as anything more than the launchpad's own word about ITSELF — which is
    /// exactly what gets recorded either way.
    function test_probe_msgSenderBranchingChangesNothingThatMatters() public {
        TwoFacedLaunchpad pad = new TwoFacedLaunchpad(address(registry), bob);
        bytes32 poolId = _pool();
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());

        LaunchRecord memory r = registry.getLaunch(poolId);
        assertEq(r.launchpad, address(pad), "still only ever itself");
        assertEq(r.creator, bob);
        // The launchpad's own standing is what a reader has to weigh, and it is returned in the
        // same call as the attribution so it cannot be dropped.
        (,,, bool padRegistered, Verification v, Listing l) = registry.provenanceOf(poolId);
        assertFalse(padRegistered, "no listing at all: render the address, never a name");
        assertEq(uint8(v), uint8(Verification.Unverified));
        assertEq(uint8(l), uint8(Listing.Active));
    }

    /*//////////////////////////////////////////////////////////////
                       THE HONEST LIMIT, AND ITS REMEDY
    //////////////////////////////////////////////////////////////*/

    /// @notice What the mechanism does NOT prevent, pinned so nobody claims more for it than it
    /// gives: a launchpad that answers for pools it did not create takes attribution for itself.
    function test_LIMIT_aLaunchpadCanOverClaimAsItself() public {
        OverClaimingLaunchpad liar = new OverClaimingLaunchpad(attacker);
        bytes32 someoneElses = _pool();
        _registerClaimed(someoneElses, alice);

        registry.attestLaunchOrigin(someoneElses, address(liar), address(0));
        LaunchRecord memory r = registry.getLaunch(someoneElses);
        assertEq(r.launchpad, address(liar), "it can name itself, and only itself");
        assertEq(r.creator, attacker);

        // The remedy is a curator, and it is strictly a REDUCTION: clear, never assign.
        vm.prank(curator);
        registry.clearLaunchAttribution(someoneElses, "over-claiming launchpad");

        r = registry.getLaunch(someoneElses);
        assertEq(r.launchpad, address(0));
        assertEq(uint8(r.origin), uint8(LaunchOrigin.Claimed));
        assertEq(r.originAttestedAt, 0);

        // And a guardian can flag the launchpad itself once it is listed.
        registry.registerLaunchpad(address(liar), address(0), _padMeta());
        vm.prank(guardian);
        registry.setLaunchpadListing(address(liar), Listing.Malicious, "claims launches it did not make");
        assertEq(uint8(registry.getLaunchpad(address(liar)).listing), uint8(Listing.Malicious));
    }

    /// @notice Attribution is one-shot. Replacing one is always two visible steps, so a race
    /// cannot be re-run silently.
    function test_attribution_cannotBeReplacedWhileSet() public {
        HonestLaunchpad first = new HonestLaunchpad();
        HonestLaunchpad second = new HonestLaunchpad();
        bytes32 poolId = _pool();
        _registerClaimed(poolId, alice);

        first.recordLaunch(poolId, alice);
        second.recordLaunch(poolId, bob);
        registry.attestLaunchOrigin(poolId, address(first), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.OriginAlreadyAttested.selector, poolId, address(first))
        );
        registry.attestLaunchOrigin(poolId, address(second), address(0));

        // Cleared, the correct launchpad attests for itself — no curator involved in the repair.
        vm.prank(curator);
        registry.clearLaunchAttribution(poolId, "wrong pad won a race");
        registry.attestLaunchOrigin(poolId, address(second), address(0));
        assertEq(registry.getLaunch(poolId).launchpad, address(second));
    }

    function test_clearAttribution_isCuratorOnly() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        bytes32 poolId = _pool();
        pad.recordLaunch(poolId, bob);
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.NotCurator.selector, guardian));
        registry.clearLaunchAttribution(poolId, "");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.NotCurator.selector, attacker));
        registry.clearLaunchAttribution(poolId, "");
    }

    function test_attestOrigin_rejectsZeroLaunchpad() public {
        bytes32 poolId = _pool();
        _registerClaimed(poolId, alice);
        vm.expectRevert(IDeepCoreLaunchRegistry.ZeroAddress.selector);
        registry.attestLaunchOrigin(poolId, address(0), address(0));
    }

    function test_attestOrigin_rejectsEoaLaunchpad() public {
        bytes32 poolId = _pool();
        _registerClaimed(poolId, alice);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadHasNoCode.selector, attacker));
        registry.attestLaunchOrigin(poolId, attacker, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                     PROVENANCE AS A UI SEES IT
    //////////////////////////////////////////////////////////////*/

    /// @notice The most dangerous row a marketplace can render is a proven attribution to a
    /// launchpad that has since been flagged. `provenanceOf` returns both halves together so no
    /// front end can ship the first without the second.
    function test_provenanceOf_returnsAttributionAndStandingTogether() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        pad.selfRegister(address(registry), alice, _padMeta());
        bytes32 poolId = _pool();
        pad.registerLaunch(address(registry), address(manager), poolId, address(token), bob, bob, _meta());

        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "");

        (
            LaunchOrigin origin,
            address launchpad,
            address creator,
            bool padRegistered,
            Verification verification,
            Listing listing
        ) = registry.provenanceOf(poolId);
        assertEq(uint8(origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(launchpad, address(pad));
        assertEq(creator, bob);
        assertTrue(padRegistered);
        assertEq(uint8(verification), uint8(Verification.Audited));
        assertEq(uint8(listing), uint8(Listing.Active));

        vm.prank(guardian);
        registry.setLaunchpadListing(address(pad), Listing.Malicious, "turned hostile");

        (,,,, verification, listing) = registry.provenanceOf(poolId);
        assertEq(uint8(verification), uint8(Verification.Unverified), "the badge is gone in the same call");
        assertEq(uint8(listing), uint8(Listing.Malicious));
    }

    /*//////////////////////////////////////////////////////////////
        LOW, FIXED 2026-09-14 — A CLEARED ATTRIBUTION LEFT THE
        POOL IN THE LAUNCHPAD'S INDEX

        `clearLaunchAttribution` reset `record.launchpad` but never
        removed the pool from `_byLaunchpad`, so "launched via X"
        kept listing a launch the registry no longer attributed to
        X, the verification ladder's one-launch gate passed on it,
        and clear-then-re-attest listed the pool twice. Reproduced
        on a 4663 fork: ops/fork-campaign/results/phases/
        launchregistry.json. Every test below fails on that code.
    //////////////////////////////////////////////////////////////*/

    event LaunchpadVerificationChanged(
        address indexed launchpad, address indexed actor, Verification previous, Verification current, string note
    );

    function _selfRegisteredPad() internal returns (HonestLaunchpad pad) {
        pad = new HonestLaunchpad();
        pad.selfRegister(address(registry), alice, _padMeta());
    }

    function _launchVia(HonestLaunchpad pad) internal returns (bytes32 poolId) {
        poolId = _pool();
        pad.registerLaunch(address(registry), address(manager), poolId, address(token), bob, bob, _meta());
    }

    function test_FIX_clearRemovesThePoolFromTheLaunchpadIndex() public {
        HonestLaunchpad pad = _selfRegisteredPad();
        bytes32 poolId = _launchVia(pad);
        assertEq(registry.launchpadLaunchCount(address(pad)), 1);

        vm.prank(curator);
        registry.clearLaunchAttribution(poolId, "over-claim");

        assertEq(registry.launchpadLaunchCount(address(pad)), 0, "a cleared launch is not launched via the pad");
        assertEq(registry.launchesOfLaunchpad(address(pad), 0, 10).length, 0);
    }

    /// @notice The fork-campaign reproduction, inverted: a launchpad whose only attribution was
    /// cleared has no launch, so it cannot be badged.
    function test_FIX_launchpadWhoseOnlyLaunchWasClearedCannotBeVerified() public {
        HonestLaunchpad pad = _selfRegisteredPad();
        bytes32 poolId = _launchVia(pad);
        vm.prank(curator);
        registry.clearLaunchAttribution(poolId, "only launch attribution was cleared");

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.LaunchpadHasNoLaunches.selector, address(pad)));
        registry.setLaunchpadVerification(address(pad), Verification.SourceVerified, "");
    }

    /// @notice A badge earned on a launch that is later withdrawn does not survive the withdrawal.
    function test_FIX_clearingTheLastLaunchResetsAnExistingBadge() public {
        HonestLaunchpad pad = _selfRegisteredPad();
        bytes32 poolId = _launchVia(pad);
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "reviewed");
        assertTrue(registry.isLaunchpadAudited(address(pad)));

        vm.expectEmit(address(registry));
        emit LaunchpadVerificationChanged(
            address(pad), curator, Verification.Audited, Verification.Unverified, "last attributed launch cleared"
        );
        vm.prank(curator);
        registry.clearLaunchAttribution(poolId, "never made it");

        assertEq(uint8(registry.getLaunchpad(address(pad)).verification), uint8(Verification.Unverified));
        assertFalse(registry.isLaunchpadAudited(address(pad)));
    }

    /// @notice The reset is about the LAST launch only; a pad with other attributed launches keeps
    /// its badge when one over-claim is cleared.
    function test_FIX_clearingOneOfSeveralLaunchesKeepsTheBadge() public {
        HonestLaunchpad pad = _selfRegisteredPad();
        bytes32 first = _launchVia(pad);
        _launchVia(pad);
        vm.prank(curator);
        registry.setLaunchpadVerification(address(pad), Verification.Audited, "reviewed");

        vm.recordLogs();
        vm.prank(curator);
        registry.clearLaunchAttribution(first, "one bad row");
        assertEq(vm.getRecordedLogs().length, 1, "only LaunchAttributionCleared, no demotion");

        assertEq(registry.launchpadLaunchCount(address(pad)), 1);
        assertTrue(registry.isLaunchpadAudited(address(pad)));
    }

    /// @notice Clear then re-attest by the same launchpad: listed once, not twice.
    function test_FIX_reattestAfterClearIsListedOnce() public {
        HonestLaunchpad pad = new HonestLaunchpad();
        bytes32 poolId = _pool();
        pad.recordLaunch(poolId, bob);
        registry.registerLaunch(address(manager), poolId, address(token), address(pad), alice, address(0), _meta());

        vm.prank(curator);
        registry.clearLaunchAttribution(poolId, "mistake");
        registry.attestLaunchOrigin(poolId, address(pad), address(0));

        assertEq(registry.launchpadLaunchCount(address(pad)), 1, "no duplicate entry");
        assertEq(registry.launchesOfLaunchpad(address(pad), 0, 10)[0], poolId);
    }

    /// @notice Swap-and-pop from the middle, the end and the front keeps every position map right.
    function test_FIX_swapAndPopKeepsTheIndexExact() public {
        HonestLaunchpad pad = _selfRegisteredPad();
        bytes32 a = _launchVia(pad);
        bytes32 b = _launchVia(pad);
        bytes32 c = _launchVia(pad);

        vm.startPrank(curator);
        registry.clearLaunchAttribution(b, ""); // middle: c moves into b's slot
        bytes32[] memory list = registry.launchesOfLaunchpad(address(pad), 0, 10);
        assertEq(list.length, 2);
        assertEq(list[0], a);
        assertEq(list[1], c);

        registry.clearLaunchAttribution(a, ""); // front: c moves again
        list = registry.launchesOfLaunchpad(address(pad), 0, 10);
        assertEq(list.length, 1);
        assertEq(list[0], c);

        registry.clearLaunchAttribution(c, ""); // the moved entry is still removable
        vm.stopPrank();
        assertEq(registry.launchpadLaunchCount(address(pad)), 0);

        // And a cleared pool re-enters cleanly.
        pad.attestOwn(address(registry), b, bob);
        list = registry.launchesOfLaunchpad(address(pad), 0, 10);
        assertEq(list.length, 1);
        assertEq(list[0], b);
    }

    /// @notice Model check over a random attest/clear sequence across two launchpads: each index is
    /// exactly the set of pools whose record names that launchpad, with no duplicates.
    function testFuzz_FIX_launchpadIndexMatchesTheRecords(uint256 seed) public {
        HonestLaunchpad[2] memory pads = [new HonestLaunchpad(), new HonestLaunchpad()];
        bytes32[6] memory pools;
        for (uint256 i; i < pools.length; ++i) {
            pools[i] = _pool();
            _registerClaimed(pools[i], alice);
        }

        for (uint256 step; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            bytes32 poolId = pools[r % pools.length];
            address current = registry.getLaunch(poolId).launchpad;
            if (current == address(0)) {
                HonestLaunchpad pad = pads[(r >> 8) % 2];
                pad.attestOwn(address(registry), poolId, bob);
            } else {
                vm.prank(curator);
                registry.clearLaunchAttribution(poolId, "");
            }
        }

        for (uint256 p; p < 2; ++p) {
            bytes32[] memory list = registry.launchesOfLaunchpad(address(pads[p]), 0, type(uint256).max);
            uint256 expected;
            for (uint256 i; i < pools.length; ++i) {
                bool named = registry.getLaunch(pools[i]).launchpad == address(pads[p]);
                uint256 occurrences;
                for (uint256 j; j < list.length; ++j) {
                    if (list[j] == pools[i]) ++occurrences;
                }
                assertEq(occurrences, named ? 1 : 0, "index membership == record attribution, once");
                if (named) ++expected;
            }
            assertEq(list.length, expected);
            assertEq(registry.launchpadLaunchCount(address(pads[p])), expected);
        }
    }
}
