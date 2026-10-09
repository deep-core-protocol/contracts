// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {Lock} from "../../src/interfaces/IDeepCoreLPLocker.sol";
import {BinLock} from "../../src/interfaces/IDeepCoreBinLPLocker.sol";
import {BinLaunchShapes} from "../../src/libraries/BinLaunchShapes.sol";
import {
    LegKind, BinShape, LegParams, ScheduleParams, LaunchParamsV2, LaunchResultV2
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev Exposes the shape library so its pure properties can be fuzzed cheaply.
contract ShapesHarness {
    function build(BinShape shape, uint256 n, uint256 maxBins)
        external
        pure
        returns (uint24[] memory offsets, uint64[] memory weights, uint16 floorBins)
    {
        return BinLaunchShapes.build(shape, n, maxBins);
    }

    function validate(uint24[] memory offsets, uint64[] memory weights, uint256 floorBins, uint256 maxBins, uint256 amount)
        external
        pure
    {
        BinLaunchShapes.validate(offsets, weights, floorBins, maxBins, amount);
    }
}

/// @notice Launch parameters fuzzed inside their bounds: every accepted launch leaves every leg flagged, locked,
/// born at zero, with the declared split and nothing left on the kit.
contract LaunchpadKitV2FuzzTest is KitV2Fixture {
    ShapesHarness internal shapes;

    function setUp() public {
        _deployAll();
        shapes = new ShapesHarness();
    }

    /// @dev Every named shape at every legal size satisfies R1-R6 by construction, for any seeded amount that
    /// leaves each bin at least one unit.
    function testFuzz_SHAPES_namedShapesAlwaysValidate(uint8 shapeRaw, uint16 nRaw, uint128 amount) public view {
        BinShape shape = BinShape(bound(shapeRaw, 1, 4));
        uint256 n = bound(nRaw, 1, 256);
        amount = uint128(bound(amount, 1e24, type(uint128).max));
        (uint24[] memory offsets, uint64[] memory weights, uint16 floorBins) = shapes.build(shape, n, 256);
        shapes.validate(offsets, weights, floorBins, 256, amount);
        uint256 sum;
        for (uint256 k; k < n; ++k) {
            sum += weights[k];
            if (k != 0 && shape != BinShape.Flat && shape != BinShape.Stepped) {
                // Linear and exponential never put more weight farther from the price (last bin takes the dust).
                if (k + 1 < n) assertLe(weights[k], weights[k - 1]);
            }
        }
        assertEq(sum, 1e18);
    }

    /// forge-config: default.fuzz.runs = 40
    /// forge-config: legacy.fuzz.runs = 40
    function testFuzz_LAUNCH_withinBounds(
        uint256 seed,
        uint8 legsRaw,
        uint96 seedFraction,
        uint16 protocolBps,
        uint16 integratorBps,
        uint64 integratorFee,
        uint32 startDelay
    ) public {
        uint256 n = bound(legsRaw, 1, MAX_LEGS);
        address[4] memory quotes = [address(quote), address(0), address(stock), address(weth)];
        bytes32 salt = keccak256(abi.encode("fuzz", seed));
        address token = _token(salt);

        LegParams[] memory legs = new LegParams[](n);
        uint256 weightLeft = 10_000;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint16 w = i + 1 == n ? uint16(weightLeft) : uint16(bound(r >> 8, 1, weightLeft - (n - 1 - i)));
            weightLeft -= w;
            if (r & 1 == 0) {
                legs[i] = _clLeg(token, quotes[i], w);
                legs[i].maxBuyPerTx = uint128(r >> 128) % 2 == 0 ? 0 : uint128(bound(r >> 64, 1, 1e24));
            } else {
                BinShape shape = BinShape(bound(r >> 16, 1, 4));
                legs[i] = _binLeg(quotes[i], w, shape, uint16(bound(r >> 32, 1, MAX_BINS_PER_LEG)));
            }
        }

        LaunchParamsV2 memory p = _params(salt, legs);
        p.seedSupply = bound(seedFraction, TOTAL_SUPPLY / 1_000, TOTAL_SUPPLY);
        p.protocolBps = uint16(bound(protocolBps, 2_000, 5_000));
        p.integratorBps = uint16(bound(integratorBps, 0, 2_000));
        p.creatorBps = 10_000 - p.protocolBps - p.integratorBps;
        p.integratorLaunchFeeWei = bound(integratorFee, 0, MAX_INTEGRATOR_FEE);
        p.schedule.startDelaySeconds = uint32(bound(startDelay, 0, 30 days));
        uint256 pr = seed % 3;
        p.schedule.preset = pr == 0 ? Preset.FairLaunch : pr == 1 ? Preset.NoTax : Preset.Custom;
        if (p.schedule.preset == Preset.Custom) {
            p.schedule.initialFeeBips = uint24(bound(seed >> 100, 20_000, 100_000));
            p.schedule.finalFeeBips = uint24(bound(seed >> 140, 0, 20_000));
            p.schedule.decaySeconds = uint32(bound(seed >> 180, 60, 30 days));
            p.schedule.enabled = (seed >> 220) & 1 == 1;
        }

        LaunchResultV2 memory res = _launch(p);

        assertEq(IERC20(res.token).balanceOf(address(kit)), 0, "kit holds no launch token");
        assertEq(address(kit).balance, kit.totalFeesOwed(), "kit native == fees owed");
        uint256 inPools;
        for (uint256 i; i < n; ++i) {
            bytes32 id = res.poolIds[i];
            assertTrue(kit.isLockedLaunch(id));
            assertEq(kit.getLeg(id).lockId, res.lockIds[i]);
            if (legs[i].kind == LegKind.CL) {
                Lock memory lk = clLocker.getLock(res.lockIds[i]);
                assertEq(PoolId.unwrap(lk.poolId), id);
                assertEq(lk.protocolBps, p.protocolBps);
                assertEq(_clProtocolFee(id), 0);
            } else {
                BinLock memory bl = binLocker.getLock(res.lockIds[i]);
                assertEq(PoolId.unwrap(bl.poolId), id);
                assertEq(bl.protocolBps, p.protocolBps);
                assertEq(_binProtocolFee(id), 0);
            }
        }
        inPools = TOTAL_SUPPLY - IERC20(res.token).balanceOf(ALLOCATION);
        assertLe(inPools, p.seedSupply, "never seeds more than declared");
        assertGe(inPools + 1e6, p.seedSupply, "seeds all of it, up to rounding dust");
    }
}
