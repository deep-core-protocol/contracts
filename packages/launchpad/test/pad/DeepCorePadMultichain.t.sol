// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {KitV2Fixture, FakeSafe} from "../kitv2/KitV2Fixture.sol";
import {CreateXLike} from "./helpers/CreateXLike.sol";
import {ICreateX, CreateXCreate3} from "../../script/CreateX.sol";
import {DeepCorePad} from "../../src/pad/DeepCorePad.sol";
import {DeepCorePadFactory} from "../../src/pad/DeepCorePadFactory.sol";
import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {ILaunchpadKitV2, TenantConfig} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";
import {BinShape} from "../../src/libraries/BinLaunchShapes.sol";

/// @notice Shared helpers: CreateX's CREATE3 path (a self-authored stand-in etched at CreateX's address),
/// the permissioned factory salt, and a create helper paying the fee in force.
abstract contract PadMultichainBase is KitV2Fixture {
    address internal constant PAD_CREATOR = address(0xC0FFEE);
    address internal constant PAD_WALLET = address(0x9A11);

    uint256 internal constant DEPLOYER_PK = 0xD39107;
    uint256 internal constant FEE = 0.003 ether;
    uint256 internal constant CAP = 0.03 ether;

    address[] internal noQuotes;

    function _baseSetUp() internal {
        _deployAll();
        vm.etch(CreateXCreate3.CREATEX, address(new CreateXLike()).code);
        vm.deal(PAD_CREATOR, 100 ether);
        vm.deal(ATTACKER, 100 ether);
    }

    function _config() internal pure returns (TenantConfig memory c) {
        c.integrator = PAD_WALLET;
        c.integratorBps = 500;
        c.integratorLaunchFeeWei = 0.001 ether;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch)) | uint8(1 << uint8(Preset.Custom));
        c.allowedBinShapes = uint8(1 << uint8(BinShape.Linear));
        c.active = true;
    }

    function _factorySalt() internal pure returns (bytes32) {
        return CreateXCreate3.permissionedCrossChainSalt(vm.addr(DEPLOYER_PK), bytes11("dcore.pads"));
    }

    function _deployFactoryViaCreate3(ILaunchpadKitV2 k, address owner_, uint256 fee, uint256 cap, uint32 notice)
        internal
        returns (DeepCorePadFactory)
    {
        bytes memory code =
            abi.encodePacked(type(DeepCorePadFactory).creationCode, abi.encode(k, owner_, owner_, fee, cap, notice));
        vm.prank(vm.addr(DEPLOYER_PK));
        return DeepCorePadFactory(ICreateX(CreateXCreate3.CREATEX).deployCreate3(_factorySalt(), code));
    }

    function _create(DeepCorePadFactory f, address who, bytes32 userSalt, string memory name_) internal returns (address) {
        uint256 fee = f.padFeeWei();
        vm.prank(who);
        return f.createPad{value: fee}(userSalt, name_, "", _config(), noQuotes);
    }
}

/// @notice Multi-chain Launchpads (owner decision 2026-09-19): one pad address on every chain, bound to its
/// creator. Salt binding, predict == create, duplicates, squatting, and the recorded origin.
contract DeepCorePadMultichainTest is PadMultichainBase {
    DeepCorePadFactory internal padFactory;

    function setUp() public {
        _baseSetUp();
        padFactory = _deployFactoryViaCreate3(ILaunchpadKitV2(address(kit)), safe, FEE, CAP, 7 days);
    }

    /*//////////////////////////////////////////////////////////////
                         THE FACTORY ADDRESS (CREATE3)
    //////////////////////////////////////////////////////////////*/

    function test_CREATE3_factoryLandsWherePredictedAndImplementationIsNonce1() public view {
        address predicted = CreateXCreate3.predict(CreateXCreate3.CREATEX, vm.addr(DEPLOYER_PK), _factorySalt());
        assertEq(address(padFactory), predicted, "factory at the CREATE3 prediction");
        assertEq(address(padFactory.IMPLEMENTATION()), vm.computeCreateAddress(address(padFactory), 1), "impl = nonce 1");
        assertEq(padFactory.IMPLEMENTATION().FACTORY(), address(padFactory));
        assertEq(padFactory.owner(), safe);
    }

    function test_CREATE3_anotherDeployerCannotTakeTheFactorySalt() public {
        // The salt names the DeepCore deployer. Anyone else sending it gets CreateX's "random salt" guard: a
        // different guarded salt, so a different address - never the DeepCore factory's, on any chain.
        bytes memory code = abi.encodePacked(
            type(DeepCorePadFactory).creationCode, abi.encode(ILaunchpadKitV2(address(kit)), ATTACKER, ATTACKER, 0, CAP, 7 days)
        );
        vm.prank(ATTACKER);
        address squat = ICreateX(CreateXCreate3.CREATEX).deployCreate3(_factorySalt(), code);
        assertTrue(squat != address(padFactory), "the attacker's factory is elsewhere");
        assertEq(
            squat,
            CreateXCreate3.create3Address(CreateXCreate3.CREATEX, keccak256(abi.encode(_factorySalt()))),
            "CreateX's random-salt guard, not the permissioned one"
        );
    }

    /*//////////////////////////////////////////////////////////////
                         SALT BINDING / PREDICTION
    //////////////////////////////////////////////////////////////*/

    function test_PREDICT_matchesTheOpenZeppelinFormula() public view {
        bytes32 s = keccak256("mochi");
        bytes32 bound = keccak256(abi.encode(PAD_CREATOR, s));
        assertEq(padFactory.padSalt(PAD_CREATOR, s), bound);
        assertEq(
            padFactory.predictPad(PAD_CREATOR, s),
            Clones.predictDeterministicAddress(address(padFactory.IMPLEMENTATION()), bound, address(padFactory))
        );
    }

    function testFuzz_PREDICT_equalsCreated(address creator, bytes32 userSalt) public {
        vm.assume(creator != address(0) && creator.code.length == 0 && uint160(creator) > 0xffff);
        vm.assume(creator != address(padFactory) && creator != CreateXCreate3.CREATEX);
        vm.deal(creator, 1 ether);
        address predicted = padFactory.predictPad(creator, userSalt);
        assertFalse(padFactory.isPad(predicted));
        assertEq(predicted.code.length, 0);
        address pad = _create(padFactory, creator, userSalt, "Fuzz");
        assertEq(pad, predicted, "created where predicted");
        assertTrue(padFactory.isPad(pad));
        assertEq(DeepCorePad(pad).owner(), creator, "owner is the sender");
        (address c, bytes32 s) = padFactory.padOrigin(pad);
        assertEq(c, creator);
        assertEq(s, userSalt);
    }

    function test_DUPLICATE_sameCreatorSameSaltRevertsCleanly() public {
        bytes32 s = keccak256("mochi");
        address pad = _create(padFactory, PAD_CREATOR, s, "Mochi");
        uint256 owedBefore = padFactory.protocolFeesOwed();
        uint256 balBefore = PAD_CREATOR.balance;
        vm.prank(PAD_CREATOR);
        vm.expectRevert(abi.encodeWithSelector(DeepCorePadFactory.PadAlreadyExists.selector, pad));
        padFactory.createPad{value: FEE}(s, "Mochi again", "", _config(), noQuotes);
        assertEq(padFactory.padCount(), 1);
        assertEq(padFactory.protocolFeesOwed(), owedBefore, "nothing charged");
        assertEq(PAD_CREATOR.balance, balBefore, "value returned by the revert");
        // Another salt from the same creator is another pad.
        address second = _create(padFactory, PAD_CREATOR, keccak256("mochi-2"), "Mochi 2");
        assertTrue(second != pad);
        assertEq(padFactory.padCount(), 2);
    }

    function testFuzz_SQUAT_anotherSenderWithTheSameSaltLandsElsewhere(address attacker, bytes32 userSalt) public {
        vm.assume(attacker != PAD_CREATOR && attacker != address(0) && attacker.code.length == 0 && uint160(attacker) > 0xffff);
        vm.assume(attacker != address(padFactory) && attacker != CreateXCreate3.CREATEX);
        vm.deal(attacker, 1 ether);
        address victims = padFactory.predictPad(PAD_CREATOR, userSalt);
        address squat = _create(padFactory, attacker, userSalt, "Squat");
        assertTrue(squat != victims, "the attacker's pad is elsewhere");
        assertFalse(padFactory.isPad(victims), "the victim's address is untouched");
        // The victim still gets its address, and owns it.
        address pad = _create(padFactory, PAD_CREATOR, userSalt, "Mine");
        assertEq(pad, victims);
        assertEq(DeepCorePad(pad).owner(), PAD_CREATOR);
    }

    function test_ORIGIN_eventsAndViews() public {
        bytes32 s = keccak256("frog");
        address predicted = padFactory.predictPad(PAD_CREATOR, s);
        vm.expectEmit(true, true, false, true, address(padFactory));
        emit DeepCorePadFactory.PadCreated(predicted, PAD_CREATOR, "Frog Swap");
        vm.expectEmit(true, true, true, true, address(padFactory));
        emit DeepCorePadFactory.PadOriginRecorded(predicted, PAD_CREATOR, s);
        _create(padFactory, PAD_CREATOR, s, "Frog Swap");
        (address c, bytes32 u) = padFactory.padOrigin(predicted);
        assertEq(c, PAD_CREATOR);
        assertEq(u, s);
        (c, u) = padFactory.padOrigin(address(0x1234));
        assertEq(c, address(0), "(0, 0) for a non-pad");
        assertEq(u, bytes32(0));
        // The origin names the PAD_CREATOR and survives an ownership move: opening the pad on a new chain is the
        // creator's key, not the current owner's (the new owner's key predicts a different address).
        vm.prank(PAD_CREATOR);
        DeepCorePad(predicted).transferOwnership(ATTACKER);
        vm.prank(ATTACKER);
        DeepCorePad(predicted).acceptOwnership();
        (c,) = padFactory.padOrigin(predicted);
        assertEq(c, PAD_CREATOR);
        assertTrue(padFactory.predictPad(ATTACKER, s) != predicted);
    }

    function test_IMPLEMENTATION_andForeignClonesCannotBeInitialized() public {
        DeepCorePad impl = padFactory.IMPLEMENTATION();
        vm.prank(address(padFactory));
        vm.expectRevert(); // locked: _owner = 0xdead
        impl.initialize(PAD_CREATOR, "x", "", _config(), noQuotes);
        // A clone made by anyone else can never be initialized: FACTORY is the only caller, and it only ever
        // initializes the clone it just made.
        vm.prank(ATTACKER);
        address rogue = Clones.cloneDeterministic(address(impl), keccak256("rogue"));
        vm.prank(ATTACKER);
        vm.expectRevert();
        DeepCorePad(rogue).initialize(ATTACKER, "x", "", _config(), noQuotes);
        assertFalse(padFactory.isPad(rogue));
    }
}

/// @notice The cross-chain proof. Each test starts with NO factory deployed, snapshots, plays chain A,
/// reverts to the snapshot and plays chain B with DIFFERENT constructor arguments (kit, Safe, fee, cap,
/// notice) - which is exactly what differs between two real chains.
contract DeepCorePadCrossChainTest is PadMultichainBase {
    function setUp() public {
        _baseSetUp();
    }

    struct ChainView {
        address factory;
        address implementation;
        address pad;
        address kit;
        uint256 fee;
        address owner;
        address padKit;
        address padOwner;
    }

    function _chain(uint256 chainId, ILaunchpadKitV2 k, address owner_, uint256 fee, uint256 cap, uint32 notice, bytes32 userSalt)
        internal
        returns (ChainView memory v)
    {
        vm.chainId(chainId);
        DeepCorePadFactory f = _deployFactoryViaCreate3(k, owner_, fee, cap, notice);
        address predicted = f.predictPad(PAD_CREATOR, userSalt);
        v.pad = _create(f, PAD_CREATOR, userSalt, "Mochi Pad");
        assertEq(v.pad, predicted, "predicted on this chain");
        v.factory = address(f);
        v.implementation = address(f.IMPLEMENTATION());
        v.kit = address(f.KIT());
        v.fee = f.protocolFeesOwed();
        v.owner = f.owner();
        v.padKit = address(DeepCorePad(v.pad).KIT());
        v.padOwner = DeepCorePad(v.pad).owner();
    }

    function test_CROSSCHAIN_differentConstructorArgsSameFactorySameImplementationSamePad() public {
        bytes32 userSalt = keccak256("mochi");
        uint256 clean = vm.snapshotState();

        // Chain A: HyperEVM-like. Kit A, Safe A, fee 0.003, cap 0.03, 7 days.
        ChainView memory a = _chain(999, ILaunchpadKitV2(address(kit)), safe, FEE, CAP, 7 days, userSalt);

        vm.revertToState(clean);

        // Chain B: a different kit (another deployment), a different Safe, a different fee, cap and notice.
        address safeB = address(new FakeSafe());
        LaunchpadKitV2.Deployment memory d = _deploymentFor(safeB);
        LaunchpadKitV2 kitB = new LaunchpadKitV2(d);
        ChainView memory b = _chain(11155111, ILaunchpadKitV2(address(kitB)), safeB, 0.5 ether, 5 ether, 1 days, userSalt);

        assertTrue(a.kit != b.kit, "different kits");
        assertTrue(a.owner != b.owner, "different owners");
        assertTrue(a.fee != b.fee, "different fees");
        assertEq(a.factory, b.factory, "SAME factory address");
        assertEq(a.implementation, b.implementation, "SAME implementation address");
        assertEq(a.pad, b.pad, "SAME pad address");
        assertEq(a.padKit, a.kit, "chain A's pad is chain A's tenant");
        assertEq(b.padKit, b.kit, "chain B's pad is chain B's tenant");
        assertEq(a.padOwner, PAD_CREATOR);
        assertEq(b.padOwner, PAD_CREATOR);
    }

    function test_CROSSCHAIN_aSquatterOnTheSecondChainCannotTakeTheAddress() public {
        bytes32 userSalt = keccak256("mochi");
        uint256 clean = vm.snapshotState();
        vm.chainId(999);
        DeepCorePadFactory fA = _deployFactoryViaCreate3(ILaunchpadKitV2(address(kit)), safe, FEE, CAP, 7 days);
        address onA = _create(fA, PAD_CREATOR, userSalt, "Mochi Pad");
        vm.revertToState(clean);

        // "Chain B": the same factory address, fresh state. The attacker watched chain A, copies the salt
        // and the name, and gets there first.
        vm.chainId(11155111);
        DeepCorePadFactory fB = _deployFactoryViaCreate3(ILaunchpadKitV2(address(kit)), safe, FEE, CAP, 7 days);
        assertEq(address(fB), address(fA), "same factory");
        address squat = _create(fB, ATTACKER, userSalt, "Mochi Pad");
        assertTrue(squat != onA, "the copy is elsewhere");
        address mine = _create(fB, PAD_CREATOR, userSalt, "Mochi Pad");
        assertEq(mine, onA, "the creator still opens the same address on chain B");
        assertEq(DeepCorePad(mine).owner(), PAD_CREATOR);
    }

    function test_CROSSCHAIN_anotherDeployerOrSaltIsAnotherAddress() public {
        address deepcore = CreateXCreate3.predict(CreateXCreate3.CREATEX, vm.addr(DEPLOYER_PK), _factorySalt());
        address otherSalt = CreateXCreate3.predict(
            CreateXCreate3.CREATEX,
            vm.addr(DEPLOYER_PK),
            CreateXCreate3.permissionedCrossChainSalt(vm.addr(DEPLOYER_PK), bytes11("dcore.pad2"))
        );
        address otherKey = CreateXCreate3.predict(
            CreateXCreate3.CREATEX, address(0xD00D), CreateXCreate3.permissionedCrossChainSalt(address(0xD00D), bytes11("dcore.pads"))
        );
        assertTrue(deepcore != otherSalt && deepcore != otherKey && otherSalt != otherKey);
        // The chain id plays no part: the same prediction under any chain id.
        vm.chainId(1);
        assertEq(CreateXCreate3.predict(CreateXCreate3.CREATEX, vm.addr(DEPLOYER_PK), _factorySalt()), deepcore);
    }
}

/// @notice Invariant handler: random creators and a small salt space, so duplicates happen often.
contract PadHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    DeepCorePadFactory internal immutable f;
    TenantConfig internal cfg;
    uint256 public creates;
    uint256 public duplicates;

    constructor(DeepCorePadFactory f_, TenantConfig memory c) {
        f = f_;
        cfg = c;
    }

    function create(uint8 who, uint8 saltSeed, uint96 extra) external {
        address creator = address(uint160(0x100000 + (who % 8)));
        bytes32 userSalt = bytes32(uint256(saltSeed % 6));
        uint256 value = f.padFeeWei() + (uint256(extra) % 1 ether);
        vm.deal(creator, value);
        address[] memory none;
        address predicted = f.predictPad(creator, userSalt);
        bool existed = f.isPad(predicted);
        vm.prank(creator);
        try f.createPad{value: value}(userSalt, "Inv", "", cfg, none) returns (address pad) {
            require(!existed && pad == predicted, "created off prediction or over an existing pad");
            require(creator.balance == value - f.padFeeWei(), "surplus not refunded");
            creates++;
        } catch {
            require(existed, "a fresh (creator, salt) was refused");
            duplicates++;
        }
    }
}

/// @notice Every listed pad sits exactly where `predictPad(origin)` says, is a pad, is owned by its recorded
/// creator (no transfers in this handler), and the factory holds exactly the credited fees.
contract DeepCorePadMultichainInvariantTest is KitV2Fixture {
    DeepCorePadFactory internal f;
    PadHandler internal handler;

    function setUp() public {
        _deployAll();
        f = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, 0.003 ether, 0.03 ether, 7 days);
        TenantConfig memory c;
        c.integrator = address(0x9A11);
        c.integratorBps = 500;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch));
        c.active = true;
        handler = new PadHandler(f, c);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    /// forge-config: legacy.invariant.runs = 32
    /// forge-config: legacy.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: legacy.invariant.fail-on-revert = true
    function invariant_everyPadIsWherePredictedAndFeesAreExact() public view {
        uint256 n = f.padCount();
        for (uint256 i; i < n; ++i) {
            address pad = f.padAt(i);
            (address creator, bytes32 userSalt) = f.padOrigin(pad);
            assertEq(f.predictPad(creator, userSalt), pad);
            assertTrue(f.isPad(pad));
            assertEq(DeepCorePad(pad).owner(), creator);
        }
        assertEq(n, handler.creates());
        assertEq(address(f).balance, f.protocolFeesOwed());
        assertEq(f.protocolFeesOwed(), n * 0.003 ether);
    }
}
