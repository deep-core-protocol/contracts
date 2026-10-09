// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchTokenFactory} from "../src/LaunchTokenFactory.sol";
import {ILaunchTokenFactory} from "../src/interfaces/ILaunchTokenFactory.sol";

/// @dev Plays a kit that forgets to fold its caller into the salt, to show why the integration spec
/// requires it.
contract NaiveKit {
    LaunchTokenFactory public immutable factory;

    constructor(LaunchTokenFactory factory_) {
        factory = factory_;
    }

    function launch(bytes32 salt) external returns (address) {
        return factory.createToken("Naive", "NV", "", 1e18, msg.sender, salt);
    }
}

/// @dev Deploys `LaunchToken` bytecode from a contract that is NOT the canonical factory, as a would-be
/// impersonator would. It can produce a token, but never one the factory vouches for.
contract ImpostorFactory {
    function launchTokenParameters()
        external
        pure
        returns (string memory, string memory, string memory, address, uint256)
    {
        return ("Fake", "FAKE", "", address(0xBAD), 1e18);
    }

    function deploy() external returns (address) {
        return address(new LaunchToken());
    }
}

contract LaunchTokenFactoryTest is Test {
    LaunchTokenFactory factory;

    address constant ALICE = address(0xA11CE);
    address constant MALLORY = address(0xBAD);
    address constant KIT = address(0x4417);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        factory = new LaunchTokenFactory();
    }

    function _create(address caller, bytes32 salt) internal returns (LaunchToken) {
        vm.prank(caller);
        return LaunchToken(factory.createToken("DeepCore Cat", "LCAT", "ipfs://cid", SUPPLY, KIT, salt));
    }

    /*//////////////////////////////////////////////////////////////
                              THE TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_token_isPlainFixedSupply() public {
        LaunchToken t = _create(ALICE, bytes32("s"));
        assertEq(t.name(), "DeepCore Cat");
        assertEq(t.symbol(), "LCAT");
        assertEq(t.decimals(), 18);
        assertEq(t.metadataURI(), "ipfs://cid");
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(KIT), SUPPLY);
        assertEq(t.factory(), address(factory));
        assertTrue(factory.isLaunchToken(address(t)));
        assertEq(factory.deployerOf(address(t)), ALICE);
    }

    /// @dev No tax, no hook: a transfer moves exactly the amount, to anyone, from anyone.
    function testFuzz_token_transferIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != KIT);
        amount = bound(amount, 0, SUPPLY);
        LaunchToken t = _create(ALICE, bytes32("s"));
        vm.prank(KIT);
        t.transfer(to, amount);
        assertEq(t.balanceOf(to), amount);
        assertEq(t.balanceOf(KIT), SUPPLY - amount);
        assertEq(t.totalSupply(), SUPPLY);
    }

    /// @dev Unauthorized access, by construction: the token has no privileged selector to call. Each
    /// selector a malicious token commonly carries must be absent (the call hits no function and reverts).
    function test_token_hasNoAdminSurface() public {
        LaunchToken t = _create(ALICE, bytes32("s"));
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", MALLORY, 1),
            abi.encodeWithSignature("burn(address,uint256)", KIT, 1),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setBlacklist(address,bool)", KIT, true),
            abi.encodeWithSignature("setTax(uint256)", 100),
            abi.encodeWithSignature("initialize(string,string)", "x", "y"),
            abi.encodeWithSignature("setMetadataURI(string)", "evil")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(MALLORY);
            (bool ok,) = address(t).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.metadataURI(), "ipfs://cid");
    }

    function test_token_parametersUnreadableOutsideCreation() public {
        vm.expectRevert(ILaunchTokenFactory.NoDeploymentInProgress.selector);
        factory.launchTokenParameters();
        _create(ALICE, bytes32("s"));
        vm.expectRevert(ILaunchTokenFactory.NoDeploymentInProgress.selector);
        factory.launchTokenParameters();
    }

    function test_token_impostorBytecodeIsNotVouchedFor() public {
        ImpostorFactory impostor = new ImpostorFactory();
        LaunchToken fake = LaunchToken(impostor.deploy());
        assertEq(fake.factory(), address(impostor));
        assertFalse(factory.isLaunchToken(address(fake)));
    }

    /*//////////////////////////////////////////////////////////////
                              ADDRESSES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_address_matchesPrediction(address caller, bytes32 salt) public {
        vm.assume(caller != address(0));
        address predicted = factory.predictTokenAddress(caller, salt);
        vm.prank(caller);
        address token = factory.createToken("N", "S", "", 1, KIT, salt);
        assertEq(token, predicted);
    }

    /// @dev The init-code hash the SDK needs is exposed and is what CREATE2 actually used.
    function test_address_initCodeHashIsTheRealOne() public view {
        assertEq(factory.launchTokenInitCodeHash(), keccak256(type(LaunchToken).creationCode));
        bytes32 salt = keccak256(abi.encode(ALICE, bytes32("x")));
        address manual = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, factory.launchTokenInitCodeHash()))))
        );
        assertEq(factory.predictTokenAddress(ALICE, bytes32("x")), manual);
    }

    /// @dev Vanity salts are reusable across names: the address does not depend on metadata or supply.
    function test_address_independentOfMetadata() public {
        address predicted = factory.predictTokenAddress(ALICE, bytes32("vanity"));
        vm.prank(ALICE);
        address token = factory.createToken("Something Else", "ELSE", "https://x", 42, address(0xCAFE), bytes32("vanity"));
        assertEq(token, predicted);
    }

    /// @dev THE SQUATTING ATTEMPT. Mallory sees Alice's pending transaction and copies its salt. She lands
    /// somewhere else, and Alice still gets exactly the address she mined.
    function test_squatting_frontRunnerCannotTakeTheAddress() public {
        bytes32 mined = bytes32("alice-mined-7777");
        address aliceAddr = factory.predictTokenAddress(ALICE, mined);

        vm.prank(MALLORY);
        address malloryToken = factory.createToken("DeepCore Cat", "LCAT", "ipfs://cid", SUPPLY, MALLORY, mined);
        assertTrue(malloryToken != aliceAddr, "same salt, different deployer, different address");
        assertEq(aliceAddr.code.length, 0, "alice's address still free");

        LaunchToken aliceToken = _create(ALICE, mined);
        assertEq(address(aliceToken), aliceAddr);
        assertEq(factory.deployerOf(aliceAddr), ALICE);
    }

    /// @dev Squatting by fuzz: no (attacker, salt) pair produces the address another deployer mined.
    function testFuzz_squatting_noCrossDeployerCollision(address attacker, bytes32 attackerSalt, bytes32 aliceSalt)
        public
        view
    {
        vm.assume(attacker != ALICE);
        assertTrue(factory.predictTokenAddress(attacker, attackerSalt) != factory.predictTokenAddress(ALICE, aliceSalt));
    }

    /// @dev Reusing a salt is refused with a named error, not a bare CREATE2 failure.
    function test_squatting_sameDeployerSameSaltReverts() public {
        LaunchToken first = _create(ALICE, bytes32("once"));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ILaunchTokenFactory.TokenAlreadyDeployed.selector, address(first)));
        factory.createToken("Again", "AGN", "", SUPPLY, KIT, bytes32("once"));
    }

    /// @dev Why the kit must fold its caller into the salt: without it, every kit user shares the kit's
    /// namespace, so Mallory CAN squat Alice's address THROUGH a naive kit.
    function test_squatting_naiveKitSharesOneNamespace() public {
        NaiveKit kit = new NaiveKit(factory);
        bytes32 mined = bytes32("alice-mined");
        address aliceWants = factory.predictTokenAddress(address(kit), mined);

        vm.prank(MALLORY);
        assertEq(kit.launch(mined), aliceWants, "mallory took it");

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ILaunchTokenFactory.TokenAlreadyDeployed.selector, aliceWants));
        kit.launch(mined);
    }

    /*//////////////////////////////////////////////////////////////
                              VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_validation() public {
        vm.expectRevert(ILaunchTokenFactory.EmptyName.selector);
        factory.createToken("", "S", "", 1, KIT, bytes32(0));
        vm.expectRevert(ILaunchTokenFactory.EmptySymbol.selector);
        factory.createToken("N", "", "", 1, KIT, bytes32(0));
        vm.expectRevert(ILaunchTokenFactory.ZeroSupply.selector);
        factory.createToken("N", "S", "", 0, KIT, bytes32(0));
        vm.expectRevert(ILaunchTokenFactory.ZeroRecipient.selector);
        factory.createToken("N", "S", "", 1, address(0), 0);

        string memory name65 = string(new bytes(65));
        vm.expectRevert(abi.encodeWithSelector(ILaunchTokenFactory.NameTooLong.selector, 65, 64));
        factory.createToken(name65, "S", "", 1, KIT, bytes32(0));
        string memory symbol33 = string(new bytes(33));
        vm.expectRevert(abi.encodeWithSelector(ILaunchTokenFactory.SymbolTooLong.selector, 33, 32));
        factory.createToken("N", symbol33, "", 1, KIT, bytes32(0));
        string memory uri513 = string(new bytes(513));
        vm.expectRevert(abi.encodeWithSelector(ILaunchTokenFactory.MetadataURITooLong.selector, 513, 512));
        factory.createToken("N", "S", uri513, 1, KIT, bytes32(0));

        // Exactly at every bound is fine.
        factory.createToken(string(new bytes(64)), string(new bytes(32)), string(new bytes(512)), type(uint256).max, KIT, bytes32(0));
    }

    function test_event() public {
        address predicted = factory.predictTokenAddress(ALICE, bytes32("e"));
        vm.expectEmit(true, true, true, true, address(factory));
        emit ILaunchTokenFactory.LaunchTokenCreated(
            predicted, ALICE, KIT, bytes32("e"), "DeepCore Cat", "LCAT", "ipfs://cid", SUPPLY
        );
        _create(ALICE, bytes32("e"));
    }

    /// @dev Gas reference for the report.
    function test_gas_createToken() public {
        vm.prank(ALICE);
        uint256 g = gasleft();
        factory.createToken("DeepCore Cat", "LCAT", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", SUPPLY, KIT, bytes32("g"));
        emit log_named_uint("createToken gas", g - gasleft());
    }
}
