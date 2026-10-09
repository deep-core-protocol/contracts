// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";

import {BinLaunchShapes} from "../../src/libraries/BinLaunchShapes.sol";
import {LegKind, BinShape, CLLegParams, BinLegParams, LegParams} from "../../src/interfaces/ILaunchpadKitV2.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev External wrapper so a revert of the internal library can be caught and its selector recorded.
contract BinShapesHarness {
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

/// @dev External wrapper for the two core/periphery math routines the SDK re-implements.
contract ClMathHarness {
    function tickAt(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function sqrtAt(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function liquidity(uint160 p, int24 lower, int24 upper, uint256 a0, uint256 a1) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            p, TickMath.getSqrtRatioAtTick(lower), TickMath.getSqrtRatioAtTick(upper), a0, a1
        );
    }
}

/// @title SdkVectors
/// @notice Golden vectors for `@deepcoreprotocol/sdk` (packages/sdk/test/fixtures/kitV2Vectors.json), read off the
/// REAL contracts: `BinLaunchShapes.build/validate`, `LaunchpadKitV2.predictLaunchToken/computeLegKey`,
/// `TickMath` and `LiquidityAmounts`. Regenerate with:
///   forge test --match-contract SdkVectors -vv
/// and copy the line after `SDK_VECTORS_JSON` into the fixture. The assertions below pin the few values the
/// SDK test depends on most, so a change to the Solidity fails HERE as well as in the SDK suite.
contract SdkVectors is KitV2Fixture {
    BinShapesHarness internal shapes;
    ClMathHarness internal clMath;

    function setUp() public {
        _deployAll();
        shapes = new BinShapesHarness();
        clMath = new ClMathHarness();
    }

    function test_SDK_vectors() public view {
        string memory json = string.concat(
            "{",
            _q("shapes"),
            ":",
            _shapes(),
            ",",
            _q("validate"),
            ":",
            _validateCases(),
            ",",
            _q("predict"),
            ":",
            _predict(),
            ",",
            _q("legKeys"),
            ":",
            _legKeys(),
            ",",
            _q("tickMath"),
            ":",
            _tickMath(),
            "}"
        );
        console2.log("SDK_VECTORS_JSON");
        console2.log(json);

        // Pins. Linear n=4: raw 4,3,2,1 of 10 -> 0.4, 0.3, 0.2 and the remainder.
        (uint24[] memory o, uint64[] memory w, uint16 f) = shapes.build(BinShape.Linear, 4, 256);
        assertEq(o.length, 4);
        assertEq(w[0], 0.4e18);
        assertEq(w[3], 0.1e18);
        assertEq(f, 4);
        (o,, f) = shapes.build(BinShape.Stepped, 10, 256);
        assertEq(o[4], 7); // second tier starts after a two-bin gap
        assertEq(f, 4);
    }

    /*//////////////////////////////////////////////////////////////
                                 SHAPES
    //////////////////////////////////////////////////////////////*/

    function _shapes() internal view returns (string memory out) {
        uint16[10] memory counts = [uint16(1), 2, 3, 4, 5, 7, 10, 13, 20, 32];
        out = "[";
        bool first = true;
        for (uint8 s = 1; s <= 4; ++s) {
            for (uint256 i; i < counts.length; ++i) {
                (uint24[] memory o, uint64[] memory w, uint16 f) = shapes.build(BinShape(s), counts[i], 256);
                out = string.concat(
                    out,
                    first ? "" : ",",
                    "{",
                    _q("shape"),
                    ":",
                    vm.toString(uint256(s)),
                    ",",
                    _q("binCount"),
                    ":",
                    vm.toString(uint256(counts[i])),
                    ",",
                    _q("offsets"),
                    ":",
                    _u24s(o),
                    ",",
                    _q("weights"),
                    ":",
                    _u64s(w),
                    ",",
                    _q("floorBins"),
                    ":",
                    vm.toString(uint256(f)),
                    "}"
                );
                first = false;
            }
        }
        out = string.concat(out, "]");
    }

    function _validateCases() internal view returns (string memory out) {
        out = "[";
        // 0: valid 3-bin custom with a gap after the floor
        out = string.concat(out, _case(_o3(1, 2, 5), _w3(0.5e18, 0.3e18, 0.2e18), 2, 20, 1e18), ",");
        // 1: R1 offset 0
        out = string.concat(out, _case(_o3(0, 1, 2), _w3(0.5e18, 0.3e18, 0.2e18), 1, 20, 1e18), ",");
        // 2: R2 not monotonic
        out = string.concat(out, _case(_o3(1, 3, 3), _w3(0.5e18, 0.3e18, 0.2e18), 1, 20, 1e18), ",");
        // 3: R3 gap below the floor
        out = string.concat(out, _case(_o3(1, 3, 4), _w3(0.5e18, 0.3e18, 0.2e18), 2, 20, 1e18), ",");
        // 4: R3 floorBins 0
        out = string.concat(out, _case(_o3(1, 2, 3), _w3(0.5e18, 0.3e18, 0.2e18), 0, 20, 1e18), ",");
        // 5: R3 floorBins > n
        out = string.concat(out, _case(_o3(1, 2, 3), _w3(0.5e18, 0.3e18, 0.2e18), 4, 20, 1e18), ",");
        // 6: R4 too many bins for the cap
        out = string.concat(out, _case(_o3(1, 2, 3), _w3(0.5e18, 0.3e18, 0.2e18), 3, 2, 1e18), ",");
        // 7: R4 length mismatch
        {
            uint64[] memory w2 = new uint64[](2);
            w2[0] = 0.5e18;
            w2[1] = 0.5e18;
            out = string.concat(out, _case(_o3(1, 2, 3), w2, 3, 20, 1e18), ",");
        }
        // 8: R4 empty
        out = string.concat(out, _case(new uint24[](0), new uint64[](0), 0, 20, 1e18), ",");
        // 9: R5 weights sum below 1e18
        out = string.concat(out, _case(_o3(1, 2, 3), _w3(0.5e18, 0.3e18, 0.1e18), 3, 20, 1e18), ",");
        // 10: R6 zero weight
        out = string.concat(out, _case(_o3(1, 2, 3), _w3(0.7e18, 0.3e18, 0), 3, 20, 1e18), ",");
        // 11: R6 dust bin: 1 unit of supply, weight below 100%
        out = string.concat(out, _case(_o3(1, 2, 3), _w3(0.5e18, 0.3e18, 0.2e18), 3, 20, 4), ",");
        // 12: R1 reported at the first failing index (index 0 passes with weight 1 of a 1e18 supply)
        out = string.concat(out, _case(_o3(1, 0, 3), _w3(1, 0.5e18, 0.5e18 - 1), 1, 20, 1e18));
        out = string.concat(out, "]");
    }

    function _case(uint24[] memory o, uint64[] memory w, uint256 floorBins, uint256 maxBins, uint256 amount)
        internal
        view
        returns (string memory)
    {
        bytes memory revertData;
        try shapes.validate(o, w, floorBins, maxBins, amount) {}
        catch (bytes memory data) {
            revertData = data;
        }
        return string.concat(
            "{",
            _q("offsets"),
            ":",
            _u24s(o),
            ",",
            _q("weights"),
            ":",
            _u64s(w),
            ",",
            _q("floorBins"),
            ":",
            vm.toString(floorBins),
            ",",
            _q("maxBins"),
            ":",
            vm.toString(maxBins),
            ",",
            _q("amount"),
            ":",
            _q(vm.toString(amount)),
            ",",
            _q("revertData"),
            ":",
            _q(vm.toString(revertData)),
            "}"
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ADDRESSES AND KEYS
    //////////////////////////////////////////////////////////////*/

    function _predict() internal view returns (string memory out) {
        address[3] memory launchers = [LAUNCHER, ATTACKER, address(0x1234567890123456789012345678901234567890)];
        bytes32[3] memory salts = [bytes32(0), keccak256("deepcore"), bytes32(type(uint256).max)];
        out = string.concat(
            "{",
            _q("kit"),
            ":",
            _q(vm.toString(address(kit))),
            ",",
            _q("factory"),
            ":",
            _q(vm.toString(address(factory))),
            ",",
            _q("initCodeHash"),
            ":",
            _q(vm.toString(factory.launchTokenInitCodeHash())),
            ",",
            _q("cases"),
            ":["
        );
        for (uint256 i; i < 3; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                "{",
                _q("launcher"),
                ":",
                _q(vm.toString(launchers[i])),
                ",",
                _q("userSalt"),
                ":",
                _q(vm.toString(salts[i])),
                ",",
                _q("token"),
                ":",
                _q(vm.toString(kit.predictLaunchToken(launchers[i], salts[i]))),
                "}"
            );
        }
        out = string.concat(out, "]}");
    }

    function _legKeys() internal view returns (string memory out) {
        address token = kit.predictLaunchToken(LAUNCHER, keccak256("deepcore"));
        out = string.concat(
            "{",
            _q("clHook"),
            ":",
            _q(vm.toString(address(clHook))),
            ",",
            _q("binHook"),
            ":",
            _q(vm.toString(address(binHook))),
            ",",
            _q("clPoolManager"),
            ":",
            _q(vm.toString(address(clPM))),
            ",",
            _q("binPoolManager"),
            ":",
            _q(vm.toString(address(binPM))),
            ",",
            _q("cases"),
            ":["
        );
        address[3] memory quotes =
            [address(quote), address(0), address(type(uint160).max)];
        bool first = true;
        for (uint256 i; i < 3; ++i) {
            LegParams memory cl = _clLeg(token, quotes[i], 10_000);
            LegParams memory bin = _binLeg(quotes[i], 10_000, BinShape.Flat, 5);
            out = string.concat(out, first ? "" : ",", _legKey(token, cl, 60), ",", _legKey(token, bin, 10));
            first = false;
        }
        out = string.concat(out, "]}");
    }

    function _legKey(address token, LegParams memory leg, uint256 spacingOrStep) internal view returns (string memory) {
        (PoolKey memory key, bytes32 poolId, bool is0) = kit.computeLegKey(token, leg);
        return string.concat(
            "{",
            _q("token"),
            ":",
            _q(vm.toString(token)),
            ",",
            _q("quote"),
            ":",
            _q(vm.toString(leg.quote)),
            ",",
            _q("kind"),
            ":",
            vm.toString(uint256(uint8(leg.kind))),
            ",",
            _q("tickSpacingOrBinStep"),
            ":",
            vm.toString(spacingOrStep),
            ",",
            _q("currency0"),
            ":",
            _q(vm.toString(Currency.unwrap(key.currency0))),
            ",",
            _q("currency1"),
            ":",
            _q(vm.toString(Currency.unwrap(key.currency1))),
            ",",
            _q("hooks"),
            ":",
            _q(vm.toString(address(key.hooks))),
            ",",
            _q("poolManager"),
            ":",
            _q(vm.toString(address(key.poolManager))),
            ",",
            _q("fee"),
            ":",
            vm.toString(uint256(key.fee)),
            ",",
            _q("parameters"),
            ":",
            _q(vm.toString(key.parameters)),
            ",",
            _q("poolId"),
            ":",
            _q(vm.toString(poolId)),
            ",",
            _q("launchTokenIsCurrency0"),
            ":",
            is0 ? "true" : "false",
            "}"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                TICK MATH
    //////////////////////////////////////////////////////////////*/

    function _tickMath() internal view returns (string memory out) {
        int24[9] memory ticks = [int24(-887272), -600000, -60001, -1, 0, 1, 59, 60000, 887272];
        out = string.concat("{", _q("sqrtAtTick"), ":[");
        for (uint256 i; i < ticks.length; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                "[",
                vm.toString(int256(ticks[i])),
                ",",
                _q(vm.toString(uint256(clMath.sqrtAt(ticks[i])))),
                "]"
            );
        }
        uint160[8] memory prices = [
            uint160(4295128739),
            4295128740,
            79228162514264337593543950336 - 1,
            79228162514264337593543950336,
            79228162514264337593543950336 + 1,
            1461446703485210103287273052203988822378723970341,
            TickMath.getSqrtRatioAtTick(60) - 1,
            250541448375047931186413801569 // ~ price 10
        ];
        out = string.concat(out, "],", _q("tickAtSqrt"), ":[");
        for (uint256 i; i < prices.length; ++i) {
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                "[",
                _q(vm.toString(uint256(prices[i]))),
                ",",
                vm.toString(int256(clMath.tickAt(prices[i]))),
                "]"
            );
        }
        // Single-sided liquidity: launch = currency0 below range, launch = currency1 above range.
        out = string.concat(
            out,
            "],",
            _q("liquidity"),
            ":[",
            _liq(79228162514264337593543950336, 60, 60000, 800_000_000 ether, 0),
            ",",
            _liq(79228162514264337593543950336, -60000, 0, 0, 800_000_000 ether),
            ",",
            _liq(79228162514264337593543950336, -887220, -887160, 0, 1),
            "]}"
        );
    }

    function _liq(uint160 p, int24 lower, int24 upper, uint256 a0, uint256 a1) internal view returns (string memory) {
        return string.concat(
            "{",
            _q("sqrtPriceX96"),
            ":",
            _q(vm.toString(uint256(p))),
            ",",
            _q("tickLower"),
            ":",
            vm.toString(int256(lower)),
            ",",
            _q("tickUpper"),
            ":",
            vm.toString(int256(upper)),
            ",",
            _q("amount0"),
            ":",
            _q(vm.toString(a0)),
            ",",
            _q("amount1"),
            ":",
            _q(vm.toString(a1)),
            ",",
            _q("liquidity"),
            ":",
            _q(vm.toString(uint256(clMath.liquidity(p, lower, upper, a0, a1)))),
            "}"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  JSON
    //////////////////////////////////////////////////////////////*/

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat("\"", s, "\"");
    }

    function _u24s(uint24[] memory a) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < a.length; ++i) {
            out = string.concat(out, i == 0 ? "" : ",", vm.toString(uint256(a[i])));
        }
        out = string.concat(out, "]");
    }

    function _u64s(uint64[] memory a) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < a.length; ++i) {
            out = string.concat(out, i == 0 ? "" : ",", _q(vm.toString(uint256(a[i]))));
        }
        out = string.concat(out, "]");
    }

    function _o3(uint24 a, uint24 b, uint24 c) internal pure returns (uint24[] memory o) {
        o = new uint24[](3);
        (o[0], o[1], o[2]) = (a, b, c);
    }

    function _w3(uint64 a, uint64 b, uint64 c) internal pure returns (uint64[] memory w) {
        w = new uint64[](3);
        (w[0], w[1], w[2]) = (a, b, c);
    }
}
