// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";

import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {PermissionedPoolHook} from "../src/PermissionedPoolHook.sol";
import {StockPairHook} from "../src/StockPairHook.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {ManualPriceBandOracle} from "../src/oracles/ManualPriceBandOracle.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";
import {AllowlistComplianceOracle} from "../src/oracles/AllowlistComplianceOracle.sol";
import {ChainlinkPriceBandAdapter} from "../src/oracles/ChainlinkPriceBandAdapter.sol";

/// @dev The rescue surface, declared locally so one helper drives every contract.
interface IRescuable {
    function rescueERC20(address token, address to) external;
    function owner() external view returns (address);
}

/// @title RescueERC20Test
/// @notice Acceptance finding L-1 (docs/protocol-acceptance.md, 2026-09-18): a misdirected ERC-20
/// had no path out of the config-only contracts. Every `Ownable2Step` contract in
/// `packages/hooks-rwa/src` now has an owner-only `rescueERC20(token, to)`, and this file covers
/// all of them by the same list `RenounceDisabled.t.sol` keeps, so a new contract added without
/// the function has an obvious place to be caught.
///
/// Each test asserts: nothing to rescue reverts; a stranger is refused; the zero address is
/// refused; the owner moves the WHOLE balance to `to` with the event; a second call finds nothing.
contract RescueERC20Test is Test, Deployers {
    bytes4 constant NOTHING_TO_RESCUE = bytes4(keccak256("NothingToRescue(address)"));
    bytes4 constant RESCUE_TO_ZERO = bytes4(keccak256("RescueToZero()"));
    bytes32 constant ERC20_RESCUED = keccak256("ERC20Rescued(address,address,uint256)");

    address constant STRANGER = address(0x57A);
    address constant SINK = address(0x51);

    Vault vault;
    CLPoolManager poolManager;
    MockERC20 stray;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        stray = new MockERC20("Stray", "STRAY", 18);
    }

    function _assertRescuable(address target) internal {
        IRescuable c = IRescuable(target);
        assertEq(c.owner(), address(this), "fixture: this test owns the contract");

        vm.expectRevert(abi.encodeWithSelector(NOTHING_TO_RESCUE, address(stray)));
        c.rescueERC20(address(stray), SINK);

        stray.mint(target, 5e18);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        c.rescueERC20(address(stray), STRANGER);

        vm.expectRevert(RESCUE_TO_ZERO);
        c.rescueERC20(address(stray), address(0));

        vm.recordLogs();
        c.rescueERC20(address(stray), SINK);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == target && logs[i].topics[0] == ERC20_RESCUED) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(stray));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), SINK);
                assertEq(abi.decode(logs[i].data, (uint256)), 5e18);
                seen = true;
            }
        }
        assertTrue(seen, "ERC20Rescued emitted by the contract");
        assertEq(stray.balanceOf(SINK), 5e18, "the whole balance moved");
        assertEq(stray.balanceOf(target), 0);

        vm.expectRevert(abi.encodeWithSelector(NOTHING_TO_RESCUE, address(stray)));
        c.rescueERC20(address(stray), SINK);
    }

    function test_rescueERC20_MarketHoursHook() public {
        _assertRescuable(address(new MarketHoursHook(poolManager, address(this))));
    }

    function test_rescueERC20_PermissionedPoolHook() public {
        _assertRescuable(address(new PermissionedPoolHook(poolManager, address(this))));
    }

    /// Inherits the function through `PermissionedPoolHook`; `MarketHoursModule` must not shadow it.
    function test_rescueERC20_StockPairHook_inherits() public {
        _assertRescuable(address(new StockPairHook(poolManager, address(this))));
    }

    function test_rescueERC20_ManualPriceBandOracle() public {
        _assertRescuable(address(new ManualPriceBandOracle(address(this))));
    }

    function test_rescueERC20_PythPriceBandAdapter() public {
        _assertRescuable(address(new PythPriceBandAdapter(IPyth(address(0xF00D)), address(this))));
    }

    function test_rescueERC20_AllowlistComplianceOracle() public {
        _assertRescuable(address(new AllowlistComplianceOracle(address(this))));
    }

    function test_rescueERC20_ChainlinkPriceBandAdapter() public {
        _assertRescuable(address(new ChainlinkPriceBandAdapter(address(0), 0, address(this))));
    }

    /// One selector per error everywhere, so one ABI entry decodes the revert on every contract.
    function test_rescueErrors_selectorsAreIdenticalEverywhere() public pure {
        assertEq(MarketHoursHook.NothingToRescue.selector, NOTHING_TO_RESCUE);
        assertEq(PermissionedPoolHook.NothingToRescue.selector, NOTHING_TO_RESCUE);
        assertEq(ManualPriceBandOracle.NothingToRescue.selector, NOTHING_TO_RESCUE);
        assertEq(PythPriceBandAdapter.NothingToRescue.selector, NOTHING_TO_RESCUE);
        assertEq(AllowlistComplianceOracle.NothingToRescue.selector, NOTHING_TO_RESCUE);
        assertEq(ChainlinkPriceBandAdapter.NothingToRescue.selector, NOTHING_TO_RESCUE);
        assertEq(MarketHoursHook.RescueToZero.selector, RESCUE_TO_ZERO);
        assertEq(PermissionedPoolHook.RescueToZero.selector, RESCUE_TO_ZERO);
        assertEq(ManualPriceBandOracle.RescueToZero.selector, RESCUE_TO_ZERO);
        assertEq(PythPriceBandAdapter.RescueToZero.selector, RESCUE_TO_ZERO);
        assertEq(AllowlistComplianceOracle.RescueToZero.selector, RESCUE_TO_ZERO);
        assertEq(ChainlinkPriceBandAdapter.RescueToZero.selector, RESCUE_TO_ZERO);
    }
}
