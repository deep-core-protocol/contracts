// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";

import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {PermissionedPoolHook} from "../src/PermissionedPoolHook.sol";
import {StockPairHook} from "../src/StockPairHook.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {ManualPriceBandOracle} from "../src/oracles/ManualPriceBandOracle.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";
import {AllowlistComplianceOracle} from "../src/oracles/AllowlistComplianceOracle.sol";
import {ChainlinkPriceBandAdapter} from "../src/oracles/ChainlinkPriceBandAdapter.sol";

/// @dev The `Ownable2Step` surface, declared locally so one helper can drive every contract.
interface IOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function renounceOwnership() external;
}

/// @title RenounceDisabledTest
/// @notice CLAUDE.md § "Deployed and unfixable", item 1: every contract deployed from here on
/// overrides `renounceOwnership` to revert, with `MerkleEpochDistributor` as the reference. This
/// file covers EVERY `Ownable2Step` contract in `packages/hooks-rwa/src` — found by grep, not
/// from memory — so a new one added without the override has an obvious place to be caught.
///
/// Each test asserts four things:
///   1. renouncing reverts `RenounceDisabled()` for the owner, and for anyone else;
///   2. ownership survives the attempt;
///   3. the legitimate route, `transferOwnership` + `acceptOwnership`, still works and is two-step;
///   4. the new owner can exercise an `onlyOwner` power and the old one cannot, and the new owner
///      cannot renounce either.
///
/// FAILS AGAINST STOCK OZ: without the override the owner's first call succeeds, `owner()` becomes
/// zero, and step 1's `expectRevert` is not met.
contract RenounceDisabledTest is Test, Deployers {
    /// @dev One selector for every contract, so a single ABI entry decodes the revert everywhere —
    /// including `MerkleEpochDistributor`, `RevShareHook` and `DeepCoreProtocolFeeControllerV2`,
    /// which declare the same error.
    bytes4 constant RENOUNCE_DISABLED = bytes4(keccak256("RenounceDisabled()"));

    address constant STRANGER = address(0x57A);
    address constant NEW_OWNER = address(0x0E3);
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));

    Vault vault;
    CLPoolManager poolManager;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
    }

    function _assertRenounceDisabled(address target, bytes memory ownerOnlyCall) internal {
        IOwnable2Step c = IOwnable2Step(target);
        assertEq(c.owner(), address(this), "fixture: this test owns the contract");

        // 1. The owner cannot renounce.
        vm.expectRevert(RENOUNCE_DISABLED);
        c.renounceOwnership();

        // ...and it is not merely gated on the owner: there is no caller for whom it works.
        vm.prank(STRANGER);
        vm.expectRevert(RENOUNCE_DISABLED);
        c.renounceOwnership();

        // 2. Ownership survived.
        assertEq(c.owner(), address(this), "ownership must survive the attempt");
        assertEq(c.pendingOwner(), address(0), "and nothing was nominated by it");

        // 3. The bounded form of the same intent still works, and is two-step.
        c.transferOwnership(NEW_OWNER);
        assertEq(c.owner(), address(this), "step one must not move ownership");
        assertEq(c.pendingOwner(), NEW_OWNER);
        vm.prank(NEW_OWNER);
        c.acceptOwnership();
        assertEq(c.owner(), NEW_OWNER);
        assertEq(c.pendingOwner(), address(0));

        // 4. The power really moved.
        (bool oldOwnerOk,) = target.call(ownerOnlyCall);
        assertFalse(oldOwnerOk, "the previous owner has lost its onlyOwner power");
        vm.prank(NEW_OWNER);
        (bool newOwnerOk,) = target.call(ownerOnlyCall);
        assertTrue(newOwnerOk, "the new owner holds it");

        vm.prank(NEW_OWNER);
        vm.expectRevert(RENOUNCE_DISABLED);
        c.renounceOwnership();
        assertEq(c.owner(), NEW_OWNER);
    }

    /*//////////////////////////////////////////////////////////////
                               THE HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_renounceOwnership_isDisabled_MarketHoursHook() public {
        MarketHoursHook hook = new MarketHoursHook(poolManager, address(this));
        _assertRenounceDisabled(address(hook), abi.encodeCall(hook.setMarketGuardian, (address(0xBEEF))));
    }

    function test_renounceOwnership_isDisabled_PermissionedPoolHook() public {
        PermissionedPoolHook hook = new PermissionedPoolHook(poolManager, address(this));
        _assertRenounceDisabled(address(hook), abi.encodeCall(hook.setTrustedRouter, (address(0xBEEF), true)));
    }

    /// `StockPairHook` declares no override of its own. It must inherit `PermissionedPoolHook`'s,
    /// and `MarketHoursModule` must not re-open the function on the way. Checked with BOTH halves'
    /// owner-only powers, since this contract answers to one owner for both.
    function test_renounceOwnership_isDisabled_StockPairHook_inheritsTheOverride() public {
        StockPairHook hook = new StockPairHook(poolManager, address(this));
        _assertRenounceDisabled(address(hook), abi.encodeCall(hook.setTrustedRouter, (address(0xBEEF), true)));

        vm.prank(NEW_OWNER);
        hook.setMarketGuardian(address(0xBEEF));
        assertEq(hook.marketGuardian(), address(0xBEEF), "the market half answers to the same new owner");
    }

    /// The case that makes this override matter most on the compliance hook: a renounce while
    /// paused would have made the pause permanent, because `unpause` is `onlyOwner`.
    function test_renounceOwnership_whilePaused_cannotStrandThePause() public {
        PermissionedPoolHook hook = new PermissionedPoolHook(poolManager, address(this));
        hook.pause();

        vm.expectRevert(RENOUNCE_DISABLED);
        hook.renounceOwnership();

        hook.unpause();
        assertFalse(hook.paused(), "the owner can still lift the pause");
    }

    /*//////////////////////////////////////////////////////////////
                              THE ORACLES
    //////////////////////////////////////////////////////////////*/

    /// The case that makes this override matter most on the manual oracle: revoking a compromised
    /// publisher is owner-only, so a renounce would have left the key walking the band forever.
    function test_renounceOwnership_isDisabled_ManualPriceBandOracle() public {
        ManualPriceBandOracle oracle = new ManualPriceBandOracle(address(this));
        oracle.setPublisher(address(0xB0B), true);
        _assertRenounceDisabled(address(oracle), abi.encodeCall(oracle.setPublisher, (address(0xB0B), false)));
        assertFalse(oracle.isPublisher(address(0xB0B)), "the new owner revoked the publisher");
    }

    function test_renounceOwnership_isDisabled_PythPriceBandAdapter() public {
        PythPriceBandAdapter adapter = new PythPriceBandAdapter(IPyth(address(0xF00D)), address(this));
        _assertRenounceDisabled(address(adapter), abi.encodeCall(adapter.removeFeed, (POOL)));
    }

    function test_renounceOwnership_isDisabled_AllowlistComplianceOracle() public {
        AllowlistComplianceOracle oracle = new AllowlistComplianceOracle(address(this));
        address[] memory accounts = new address[](1);
        accounts[0] = address(0xA11CE);
        _assertRenounceDisabled(address(oracle), abi.encodeCall(oracle.revoke, (accounts)));
    }

    /// Already had the override before this file existed; included so the package is covered by
    /// one list rather than by whichever test file happened to remember.
    function test_renounceOwnership_isDisabled_ChainlinkPriceBandAdapter() public {
        ChainlinkPriceBandAdapter adapter = new ChainlinkPriceBandAdapter(address(0), 0, address(this));
        _assertRenounceDisabled(address(adapter), abi.encodeCall(adapter.removeFeed, (POOL)));
    }

    /*//////////////////////////////////////////////////////////////
                         ONE ERROR, ONE ABI ENTRY
    //////////////////////////////////////////////////////////////*/

    function test_renounceDisabled_selectorIsIdenticalEverywhere() public pure {
        assertEq(MarketHoursHook.RenounceDisabled.selector, RENOUNCE_DISABLED);
        assertEq(PermissionedPoolHook.RenounceDisabled.selector, RENOUNCE_DISABLED);
        // `StockPairHook` inherits the error rather than declaring it, and Solidity does not expose
        // an inherited error as `StockPairHook.RenounceDisabled`. Its revert data is matched against
        // `RENOUNCE_DISABLED` byte for byte in the StockPairHook test above instead.
        assertEq(ManualPriceBandOracle.RenounceDisabled.selector, RENOUNCE_DISABLED);
        assertEq(PythPriceBandAdapter.RenounceDisabled.selector, RENOUNCE_DISABLED);
        assertEq(AllowlistComplianceOracle.RenounceDisabled.selector, RENOUNCE_DISABLED);
        assertEq(ChainlinkPriceBandAdapter.RenounceDisabled.selector, RENOUNCE_DISABLED);
    }
}
