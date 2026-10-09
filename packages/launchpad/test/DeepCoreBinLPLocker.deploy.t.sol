// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {DeployDeepCoreBinLPLockerScript} from "../script/DeployDeepCoreBinLPLocker.s.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";

import {BinLockerFixture} from "./utils/BinLockerFixture.sol";

contract BinFakeSafe {}

contract BinCLLockerStub {
    address public protocolRecipient;
    uint16 public minProtocolBps;
    uint16 public maxProtocolBps = 5_000;
    uint16 public maxIntegratorBps = 2_000;
    address public vault;

    constructor(address recipient_, uint16 min_, address vault_) {
        protocolRecipient = recipient_;
        minProtocolBps = min_;
        vault = vault_;
    }
}

contract DeployDeepCoreBinLPLockerTest is BinLockerFixture {
    DeployDeepCoreBinLPLockerScript script;
    address safe;
    uint256 constant PK = 0xA11CE;

    function setUp() public {
        _deployCore();
        script = new DeployDeepCoreBinLPLockerScript();
        safe = address(new BinFakeSafe());
        CreateXTest.etch();
    }

    function _w(address pm, address recipient, address cl) internal view returns (DeployDeepCoreBinLPLockerScript.Wiring memory) {
        return DeployDeepCoreBinLPLockerScript.Wiring({
            pk: PK,
            positionManager: pm,
            protocolRecipient: recipient,
            clLocker: cl,
            target: CreateXTest.target(vm.addr(PK), "locker.bin")
        });
    }

    function test_deploy_assertsEveryImmutable() public {
        DeepCoreBinLPLocker l = script.runWith(_w(address(binPm), safe, address(0)));
        assertEq(address(l.positionManager()), address(binPm));
        assertEq(address(l.binPoolManager()), address(binPoolManager));
        assertEq(l.vault(), address(vault));
        assertEq(l.protocolRecipient(), safe);
        assertEq(l.minProtocolBps(), 2_000);
        assertEq(l.maxProtocolBps(), 5_000);
        assertEq(l.maxIntegratorBps(), 2_000);
        assertEq(l.maxBinsPerLock(), 64);
    }

    /// @dev The refusals come FIRST and the accepted wiring last, because every case here uses the one
    /// mined salt: once the good one has deployed, the CREATE3 address has code and the script refuses
    /// any further run at that salt before it ever looks at the CL locker (which is itself the point of
    /// `the predicted address already has code on this chain`).
    function test_deploy_crossChecksTheClLocker() public {
        BinCLLockerStub otherRecipient = new BinCLLockerStub(address(0x5AFE), 2_000, address(vault));
        vm.expectRevert("CL locker pays a different protocol recipient");
        script.runWith(_w(address(binPm), safe, address(otherRecipient)));

        BinCLLockerStub lowFloor = new BinCLLockerStub(safe, 1_000, address(vault));
        vm.expectRevert("CL locker floor differs");
        script.runWith(_w(address(binPm), safe, address(lowFloor)));

        BinCLLockerStub otherVault = new BinCLLockerStub(safe, 2_000, address(0x1234));
        vm.expectRevert("CL locker is on a different vault");
        script.runWith(_w(address(binPm), safe, address(otherVault)));

        BinCLLockerStub good = new BinCLLockerStub(safe, 2_000, address(vault));
        DeepCoreBinLPLocker l = script.runWith(_w(address(binPm), safe, address(good)));
        assertEq(l.protocolRecipient(), safe);

        // And the salt is one-shot: a second run at it is refused, never a silent reuse.
        vm.expectRevert("the predicted address already has code on this chain (DEEPCORE_BIN_LP_LOCKER)");
        script.runWith(_w(address(binPm), safe, address(good)));
    }

    function test_deploy_refusesEoaRecipient() public {
        vm.expectRevert("LOCKER_PROTOCOL_RECIPIENT has no code - must be the Safe");
        script.runWith(_w(address(binPm), address(0xE0A), address(0)));
    }

    function test_deploy_refusesPositionManagerWithoutCode() public {
        vm.expectRevert("BIN_POSITION_MANAGER has no code");
        script.runWith(_w(address(0x1234), safe, address(0)));
    }
}
