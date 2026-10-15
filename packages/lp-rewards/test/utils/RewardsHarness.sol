// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {DeepCoreLiquidityRewardsHook} from "../../src/DeepCoreLiquidityRewardsHook.sol";

/// @dev TEST ONLY. The real hook plus setters that corrupt its mirror, so the removal-never-reverts
/// property can be proven with a mirror that is WRONG, not only with one that is right.
contract RewardsHookHarness is DeepCoreLiquidityRewardsHook {
    constructor(ICLPoolManager pm, ModuleParams memory mp) DeepCoreLiquidityRewardsHook(pm, mp) {}

    function corruptEligible(PoolId id, uint128 v) external {
        _pools[id].eligibleLiquidity = v;
    }

    function corruptMirroredTotal(PoolId id, uint128 v) external {
        _pools[id].mirroredTotal = v;
    }

    function corruptLastTick(PoolId id, int24 v) external {
        _pools[id].lastTick = v;
    }

    function corruptTick(PoolId id, int24 tick, uint128 gross, int128 net, uint256 outside0) external {
        TickInfo storage t = _ticks[id][tick];
        t.gross = gross;
        t.net = net;
        t.outside[0] = outside0;
    }

    function corruptPosition(PoolId id, bytes32 pid, uint128 liquidity, uint256 insideLast0, uint256 earned0) external {
        Position storage p = _positions[id][pid];
        p.liquidity = liquidity;
        p.insideLast[0] = insideLast0;
        p.earned[0] = earned0;
    }

    function corruptGrowth(PoolId id, uint256 i, uint256 v) external {
        _growth[id][i] = v;
    }

    function corruptStream(PoolId id, uint256 i, uint128 und, uint128 accrued, uint256 rateX64) external {
        Stream storage s = _streams[id][i];
        s.undistributed = und;
        s.accruedUnpaid = accrued;
        s.rateX64 = rateX64;
    }

    function corruptBitmapWord(PoolId id, int16 word, uint256 v) external {
        _bitmap[id][word] = v;
    }

    function growthGlobal(PoolId id, uint256 i) external view returns (uint256) {
        return _growth[id][i];
    }

    function streamRaw(PoolId id, uint256 i)
        external
        view
        returns (uint128 und, uint128 accrued, uint256 rate, uint64 last, uint64 finish, uint256 storedEarned)
    {
        Stream storage s = _streams[id][i];
        return (s.undistributed, s.accruedUnpaid, s.rateX64, s.lastUpdate, s.periodFinish, s.storedEarned);
    }
}
