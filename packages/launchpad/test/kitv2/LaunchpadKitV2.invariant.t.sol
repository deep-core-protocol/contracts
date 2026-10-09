// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";

import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../../src/DeepCoreBinLPLocker.sol";
import {
    LegKind, BinShape, LegParams, LaunchParamsV2, LaunchResultV2, LegRecord
} from "../../src/interfaces/ILaunchpadKitV2.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev Drives random launches, random stranger pools on both guards, random trades, and time.
contract KitV2Handler is Test {
    using PoolIdLibrary for PoolKey;

    KitV2InvariantTest internal immutable t;
    LaunchpadKitV2 internal immutable kit;

    bytes32[] public launchedIds;
    address[] public launchedTokens;
    bytes32[] public strangerIds;
    PoolKey[] internal clLegKeys;
    address[] internal clLegTokens;
    uint256 public launches;

    constructor(KitV2InvariantTest t_, LaunchpadKitV2 kit_) {
        t = t_;
        kit = kit_;
    }

    function launch(uint256 seed, uint8 legsRaw) external {
        uint256 n = bound(legsRaw, 1, 2);
        bytes32 salt = keccak256(abi.encode("inv", launches, seed));
        address token = kit.predictLaunchToken(address(this), salt);
        LegParams[] memory legs = new LegParams[](n);
        address[2] memory quotes = [t.quoteAddr(), address(0)];
        for (uint256 i; i < n; ++i) {
            uint16 w = n == 1 ? 10_000 : 5_000;
            if ((seed >> i) & 1 == 0) legs[i] = t.clLegFor(token, quotes[i], w);
            else legs[i] = t.binLegFor(quotes[i], w, BinShape(bound(seed >> (8 + i), 1, 4)), uint16(bound(seed >> 40, 1, 12)));
        }
        LaunchParamsV2 memory p = t.paramsFor(salt, legs);
        uint256 fee = kit.launchFeeWei();
        vm.deal(address(this), fee);
        LaunchResultV2 memory r = kit.createLaunch{value: fee}(p);
        ++launches;
        launchedTokens.push(r.token);
        for (uint256 i; i < n; ++i) {
            launchedIds.push(r.poolIds[i]);
            if (legs[i].kind == LegKind.CL) {
                (PoolKey memory key,,) = kit.computeLegKey(r.token, legs[i]);
                clLegKeys.push(key);
                clLegTokens.push(r.token);
            }
        }
    }

    /// @dev A stranger opens a kit-shaped pool on a non-factory token straight on a guard. Never flagged.
    function strangerPool(uint256 seed) external {
        MockERC20 fake = new MockERC20("Fake", "F", 18);
        LegParams memory leg = seed & 1 == 0
            ? t.clLegFor(address(fake), t.quoteAddr(), 10_000)
            : t.binLegFor(t.quoteAddr(), 10_000, BinShape.Flat, 4);
        (PoolKey memory key, bytes32 id,) = kit.computeLegKey(address(fake), leg);
        if (leg.kind == LegKind.CL) {
            LaunchGuardHook h = kit.clHook();
            h.configureLaunch(key, LaunchGuardHook.LaunchConfig(uint40(block.timestamp + 1), 60, 1, 1, 0, true, true));
            kit.clPoolManager().initialize(key, 79228162514264337593543950336);
        } else {
            BinLaunchGuardHook h = kit.binHook();
            h.configureLaunch(key, BinLaunchGuardHook.LaunchConfig(uint40(block.timestamp + 1), 60, 1, 1, 0, true, true));
            kit.binPoolManager().initialize(key, 2 ** 23);
        }
        strangerIds.push(id);
    }

    /// @dev A buyer trades a launched CL leg; the flag and the lock must not care.
    function trade(uint256 index, uint96 amount) external {
        if (clLegKeys.length == 0) return;
        index = bound(index, 0, clLegKeys.length - 1);
        vm.warp(block.timestamp + 121);
        try t.buyCLFor(clLegKeys[index], clLegTokens[index], bound(amount, 1e15, 1e21)) {} catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 7 days));
    }

    function launchedCount() external view returns (uint256) {
        return launchedIds.length;
    }

    function strangerCount() external view returns (uint256) {
        return strangerIds.length;
    }

    function tokenCount() external view returns (uint256) {
        return launchedTokens.length;
    }

    receive() external payable {}
}

/// @notice THE invariant V3 trusts: every flagged pool id has a locker record whose pool id matches, and only
/// kit legs are ever flagged.
contract KitV2InvariantTest is KitV2Fixture {
    KitV2Handler internal handler;

    function setUp() public {
        _deployAll();
        handler = new KitV2Handler(this, kit);
        quote.mint(address(this), 1e30);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = KitV2Handler.launch.selector;
        selectors[1] = KitV2Handler.strangerPool.selector;
        selectors[2] = KitV2Handler.trade.selector;
        selectors[3] = KitV2Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ---- helpers the handler calls back into (the fixture's builders are internal) ----

    function quoteAddr() external view returns (address) {
        return address(quote);
    }

    function clLegFor(address token, address q, uint16 w) external pure returns (LegParams memory) {
        return _clLeg(token, q, w);
    }

    function binLegFor(address q, uint16 w, BinShape s, uint16 n) external pure returns (LegParams memory) {
        return _binLeg(q, w, s, n);
    }

    function paramsFor(bytes32 salt, LegParams[] memory legs) external pure returns (LaunchParamsV2 memory) {
        return _params(salt, legs);
    }

    function buyCLFor(PoolKey memory key, address token, uint256 amount) external {
        _buyCL(key, token, amount);
    }

    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 12
    /// forge-config: legacy.invariant.runs = 12
    /// forge-config: legacy.invariant.depth = 12
    function invariant_everyFlaggedPoolHasAMatchingLock() public view {
        uint256 n = handler.launchedCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.launchedIds(i);
            assertTrue(kit.isLockedLaunch(id), "kit leg lost its flag");
            LegRecord memory leg = kit.getLeg(id);
            assertTrue(leg.lockId != 0, "flagged leg with no lock id");
            if (leg.kind == LegKind.CL) {
                assertTrue(clLocker.isLocked(leg.lockId));
                assertEq(PoolId.unwrap(clLocker.getLock(leg.lockId).poolId), id, "CL lock names another pool");
                assertEq(clPosm.ownerOf(leg.lockId), address(clLocker));
                (,, uint24 pf,) = clPM.getSlot0(PoolId.wrap(id));
                assertEq(pf, 0, "flagged CL pool not born at zero");
            } else {
                assertTrue(binLocker.isLocked(leg.lockId));
                assertEq(PoolId.unwrap(binLocker.getLock(leg.lockId).poolId), id, "Bin lock names another pool");
                (, uint24 pf,) = binPM.getSlot0(PoolId.wrap(id));
                assertEq(pf, 0, "flagged Bin pool not born at zero");
            }
        }
    }

    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 12
    /// forge-config: legacy.invariant.runs = 12
    /// forge-config: legacy.invariant.depth = 12
    function invariant_onlyKitLegsAreFlagged() public view {
        uint256 n = handler.strangerCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.strangerIds(i);
            assertFalse(kit.isLockedLaunch(id), "a stranger's pool was flagged");
            assertEq(kit.getLeg(id).launchToken, address(0));
        }
        assertFalse(kit.isLockedLaunch(bytes32(0)));
    }

    /// forge-config: default.invariant.runs = 12
    /// forge-config: default.invariant.depth = 12
    /// forge-config: legacy.invariant.runs = 12
    /// forge-config: legacy.invariant.depth = 12
    function invariant_kitCustodiesOnlyOwedFees() public view {
        assertEq(address(kit).balance, kit.totalFeesOwed(), "native on the kit is exactly what it owes");
        uint256 n = handler.tokenCount();
        for (uint256 i; i < n; ++i) {
            assertEq(IERC20(handler.launchedTokens(i)).balanceOf(address(kit)), 0, "kit kept launch token");
        }
    }
}
