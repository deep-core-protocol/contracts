// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeepCoreSignerScript} from "../script/DeepCoreSigner.sol";

/// @dev Exposes the helper. The ENVIRONMENT half (`_pkFromEnv`) is not driven here: `vm.setEnv` is
/// process-wide and test functions run in parallel, so env-based cases race each other. The rule it
/// applies is `_resolveSigner`, which is tested directly; the broadcast half is tested through the
/// named-deployer slot it reads.
contract SignerHarness is DeepCoreSignerScript {
    function resolve(uint256 pk, address named) external pure returns (address) {
        return _resolveSigner(pk, named);
    }

    function setNamed(address named) external {
        _namedDeployer = named;
    }

    function signerOf(uint256 pk) external view returns (address) {
        return _signerOf(pk);
    }

    function broadcastAs(uint256 pk) external {
        _startBroadcastAs(pk);
        vm.stopBroadcast();
    }
}

contract DeepCoreSignerTest is Test {
    uint256 internal constant PK = 0xA11CE;
    SignerHarness internal h;

    function setUp() public {
        h = new SignerHarness();
    }

    function test_aKeyAlone_signsWithThatKey() public view {
        assertEq(h.resolve(PK, address(0)), address(0));
        assertEq(h.signerOf(PK), vm.addr(PK));
    }

    function test_aKeyAndTheMatchingDeployer_isAccepted() public view {
        assertEq(h.resolve(PK, vm.addr(PK)), address(0));
    }

    function test_aKeyAndAnotherDeployer_isRefused() public {
        address other = makeAddr("someone else");
        vm.expectRevert(bytes("DEPLOYER does not match PRIVATE_KEY"));
        h.resolve(PK, other);
    }

    function test_aNamedDeployerWithAZeroKey_isTheSigner() public {
        address named = makeAddr("the deployer");
        assertEq(h.resolve(0, named), named);
        h.setNamed(named);
        assertEq(h.signerOf(0), named);
        h.broadcastAs(0);
    }

    function test_neitherSet_isRefused() public {
        vm.expectRevert(bytes("set PRIVATE_KEY, or DEPLOYER with --account/--ledger/--unlocked"));
        h.resolve(0, address(0));
    }

    function test_aZeroKeyWithNoNamedDeployer_neverFallsBackToForgesDefaultSender() public {
        vm.expectRevert(bytes("no signer: PRIVATE_KEY and DEPLOYER are both unset"));
        h.signerOf(0);
        vm.expectRevert(bytes("no signer: PRIVATE_KEY and DEPLOYER are both unset"));
        h.broadcastAs(0);
    }

    function test_aKeyAlwaysWinsOverARecordedName() public {
        h.setNamed(makeAddr("the deployer"));
        assertEq(h.signerOf(PK), vm.addr(PK));
    }

    function testFuzz_resolve(uint256 pk, address named) public {
        pk = bound(pk, 0, 115792089237316195423570985008687907852837564279074904382605163141518161494336);
        if (pk != 0) {
            if (named != address(0) && named != vm.addr(pk)) {
                vm.expectRevert(bytes("DEPLOYER does not match PRIVATE_KEY"));
                h.resolve(pk, named);
            } else {
                assertEq(h.resolve(pk, named), address(0));
            }
        } else if (named == address(0)) {
            vm.expectRevert(bytes("set PRIVATE_KEY, or DEPLOYER with --account/--ledger/--unlocked"));
            h.resolve(pk, named);
        } else {
            assertEq(h.resolve(pk, named), named);
        }
    }
}
