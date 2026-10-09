// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/**
 * ###################### THE CONTRACT CLOCK, CHECKED AT DEPLOY TIME ######################
 *
 * HISTORY, kept because it is why this file exists. DeepCore contracts used to turn durations into
 * `block.number` counts through a `blockTimeCentis` constructor argument. On Robinhood Chain (4663,
 * Arbitrum Nitro) that argument was set to 10 (0.1 s), the RPC's L2 block time, while `block.number`
 * INSIDE THE EVM is Ethereum's ~12 s block. Every window ran ~120x long. This file then measured
 * NUMBER against TIMESTAMP over a three-minute wait and refused a wrong declaration.
 *
 * DECIDED 2026-09-13 (Option B): every duration moved to `block.timestamp`. No contract takes a
 * block time any more, so there is nothing left to declare wrongly and the cadence measurement is
 * gone. What remains is the check a TIMESTAMP-based deployment actually needs:
 *
 *   IS THE EVM'S `block.timestamp` REAL TIME?
 *
 * Asked the same way as before, by running `CONTRACT_CLOCK_PROBE` as a contract-creation `eth_call`,
 * which returns `(NUMBER, TIMESTAMP)` exactly as a contract at `latest` sees them. It is compared
 * against two independent references:
 *
 *   1. the RPC header time of the block the script forked (`block.timestamp` in the script), which
 *      catches a probe answered from different state than the fork - a load-balanced RPC whose
 *      backends disagree, or an archive node serving a stale head;
 *   2. the operator's own wall clock (`vm.unixTime`), which catches a chain whose clock is not
 *      tracking real time. On Nitro the sequencer may run up to 24 h BEHIND real time (after an
 *      outage, while it catches up) or 1 h AHEAD. Deploying time-bounded contracts into either
 *      state means the post-deploy assertions and the fork rehearsal describe a world that is about
 *      to shift underneath them.
 *
 * Both are refusals, not warnings. A deployment that trips one waits and reruns; nothing about a
 * correct deployment is urgent enough to ship into a clock that is visibly off.
 *
 * `ContractClockMath` is pure and unit-tested with mutation checks in
 * `test/script/ContractClockMath.t.sol`. `ContractClockProbe` is the RPC half and only runs inside
 * `forge script --rpc-url`.
 * ########################################################################################
 */
library ContractClockMath {
    /// @notice Largest disagreement tolerated between the probed EVM timestamp and the forked
    /// block's header timestamp. The probe runs at `latest`, a few blocks after the fork point, so
    /// a few seconds are expected; a minute is a different chain state.
    uint256 internal constant MAX_HEADER_SKEW_SECONDS = 60;

    /// @notice Largest disagreement tolerated between the EVM timestamp and the operator's wall
    /// clock, either direction. Five minutes absorbs an unsynchronised laptop clock and RPC latency;
    /// it refuses a sequencer running an hour ahead or catching up from an outage.
    uint256 internal constant MAX_WALLCLOCK_SKEW_SECONDS = 300;

    error EvmTimestampDisagreesWithHeader(uint256 evmTimestamp, uint256 headerTimestamp);
    error ChainClockOffWallClock(uint256 evmTimestamp, uint256 wallClockSeconds);

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @notice Reverts unless the EVM's timestamp is sane against both references.
    function requireSaneTimestamp(uint256 evmTimestamp, uint256 headerTimestamp, uint256 wallClockSeconds)
        internal
        pure
    {
        if (absDiff(evmTimestamp, headerTimestamp) > MAX_HEADER_SKEW_SECONDS) {
            revert EvmTimestampDisagreesWithHeader(evmTimestamp, headerTimestamp);
        }
        if (absDiff(evmTimestamp, wallClockSeconds) > MAX_WALLCLOCK_SKEW_SECONDS) {
            revert ChainClockOffWallClock(evmTimestamp, wallClockSeconds);
        }
    }
}

library ContractClockProbe {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice NUMBER, MSTORE 0, TIMESTAMP, MSTORE 32, RETURN 64. Identical to the SDK's
    /// `CONTRACT_CLOCK_PROBE_CALLDATA`.
    string internal constant CONTRACT_CLOCK_PROBE = "0x436000524260205260406000f3";

    struct Reading {
        /// @dev `block.timestamp` as a contract at `latest` sees it.
        uint256 evmTimestamp;
        /// @dev `block.timestamp` of the block the script forked, i.e. the RPC header's time.
        uint256 headerTimestamp;
        /// @dev The operator's wall clock, seconds.
        uint256 wallClockSeconds;
        /// @dev Contract-visible `block.number`. INFORMATIONAL ONLY: on Nitro it is the parent
        /// chain's block. No DeepCore contract deployed by these scripts reads it.
        uint256 evmBlockNumber;
    }

    /// @notice `(NUMBER, TIMESTAMP)` as a contract at `latest` sees them, from the fork's RPC.
    function read() internal returns (uint256 number, uint256 timestamp) {
        bytes memory raw = VM.rpc("eth_call", string.concat('[{"data":"', CONTRACT_CLOCK_PROBE, '"},"latest"]'));
        require(raw.length == 64, "clock probe did not return two words");
        (number, timestamp) = abi.decode(raw, (uint256, uint256));
    }

    /// @notice REHEARSAL ONLY. A fork whose clock was moved with `evm_increaseTime` (a rehearsal of a
    /// 48 h custody wait) can never agree with the operator's wall clock, so the rehearsal names the
    /// EXACT offset it applied and the probe measures `wall clock + offset`. Honoured only when the RPC
    /// identifies itself as anvil (`web3_clientVersion` begins with "anvil"); a real chain's RPC never
    /// does, so setting this against a production endpoint changes nothing but the refusal message.
    /// Added 2026-10-07 when the HyperEVM fork rehearsal reached the first script after its time travel.
    string internal constant REHEARSAL_OFFSET_ENV = "DEEPCORE_REHEARSAL_CLOCK_OFFSET_SECONDS";

    /// @notice Whether the RPC behind this script is a local anvil (by its own `web3_clientVersion`).
    function isAnvil() internal returns (bool) {
        // forge returns a JSON string result ABI-encoded (offset, length, bytes), so look for the
        // word anywhere in the first 128 bytes rather than at a fixed position.
        bytes memory v = VM.rpc("web3_clientVersion", "[]");
        bytes5 word = "anvil";
        uint256 limit = v.length < 128 ? v.length : 128;
        for (uint256 i = 0; i + 5 <= limit; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 5; j++) {
                if (v[i + j] != word[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    /// @notice Probes the chain and reverts unless its timestamp is sane. No waiting.
    /// @dev Only meaningful inside `forge script --rpc-url`.
    function check() internal returns (Reading memory r) {
        (r.evmBlockNumber, r.evmTimestamp) = read();
        r.headerTimestamp = block.timestamp;
        r.wallClockSeconds = VM.unixTime() / 1000;
        uint256 rehearsalOffset = VM.envOr(REHEARSAL_OFFSET_ENV, uint256(0));
        if (rehearsalOffset != 0) {
            require(isAnvil(), "DEEPCORE_REHEARSAL_CLOCK_OFFSET_SECONDS is honoured only against a local anvil");
            r.wallClockSeconds += rehearsalOffset;
        }
        ContractClockMath.requireSaneTimestamp(r.evmTimestamp, r.headerTimestamp, r.wallClockSeconds);
    }
}
