// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {LaunchTokenFactory} from "../src/LaunchTokenFactory.sol";
import {DeployDeepCoreLPLockerScript} from "../script/DeployDeepCoreLPLocker.s.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";

import {LockerFixture} from "./utils/LockerFixture.sol";

contract FakeSafe {}

contract DeployDeepCoreLPLockerTest is LockerFixture {
    DeployDeepCoreLPLockerScript script;
    address safe;
    uint256 constant PK = 0xA11CE;

    function setUp() public {
        _deployCore();
        script = new DeployDeepCoreLPLockerScript();
        safe = address(new FakeSafe());
        CreateXTest.etch(); // every release script deploys through CreateX now
    }

    function _w(address pm, address recipient) internal view returns (DeployDeepCoreLPLockerScript.Wiring memory) {
        return DeployDeepCoreLPLockerScript.Wiring({
            pk: PK,
            positionManager: pm,
            protocolRecipient: recipient,
            lockerTarget: CreateXTest.target(vm.addr(PK), "locker.cl"),
            factoryTarget: CreateXTest.target(vm.addr(PK), "tokenfact")
        });
    }

    function test_deploy_assertsTheOwnersNumbers() public {
        (DeepCoreLPLocker l, LaunchTokenFactory f) = script.runWith(_w(address(posm), safe));
        assertEq(l.minProtocolBps(), 2_000);
        assertEq(l.maxProtocolBps(), 5_000);
        assertEq(l.maxIntegratorBps(), 2_000);
        assertEq(l.protocolRecipient(), safe);
        assertTrue(address(f).code.length > 0);
    }

    function test_deploy_refusesEoaRecipient() public {
        vm.expectRevert("LOCKER_PROTOCOL_RECIPIENT has no code - must be the Safe");
        script.runWith(_w(address(posm), address(0xE0A)));
    }

    function test_deploy_refusesPositionManagerWithoutCode() public {
        vm.expectRevert("CL_POSITION_MANAGER has no code");
        script.runWith(_w(address(0x1234), safe));
    }

    /// @notice The two contracts must never share a salt: one CREATE3 address holds one contract.
    function test_deploy_refusesOneSaltForBothContracts() public {
        DeployDeepCoreLPLockerScript.Wiring memory w = _w(address(posm), safe);
        w.factoryTarget = w.lockerTarget;
        vm.expectRevert("one salt cannot deploy two contracts");
        script.runWith(w);
    }
}
