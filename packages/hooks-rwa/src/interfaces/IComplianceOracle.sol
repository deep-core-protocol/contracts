/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @notice The pool operation an account is being checked for.
/// @dev Passed to the oracle so an issuer can apply different rules to different actions - for
/// example permitting an existing holder to exit a position they may no longer add to.
enum ComplianceAction {
    Swap,
    AddLiquidity,
    RemoveLiquidity
}

/// @title IComplianceOracle
/// @notice The pluggable KYC / accreditation / sanctions source consulted by `PermissionedPoolHook`.
///
/// @dev ############################ IMPLEMENTER'S CONTRACT ############################
///
/// This interface is deliberately tiny and deliberately a `view`. The hook calls it inside
/// `beforeSwap` and `beforeAddLiquidity`, i.e. inside a Vault lock, on the critical path of every
/// trade. Four rules follow and none of them are optional:
///
///   1. `checkCompliance` MUST be a `view` and MUST NOT depend on the caller. The hook queries it
///      with a `staticcall`, so any state write reverts the call and the hook will treat that as
///      "oracle unavailable" and DENY the trade.
///
///   2. `checkCompliance` MUST fit inside `PermissionedPoolHook.ORACLE_GAS_LIMIT`. The hook caps
///      the gas it forwards precisely so a broken or malicious oracle cannot consume the whole
///      transaction. An oracle that runs out of that budget reads as unavailable, and the trade is
///      denied. Do not iterate unbounded arrays; do not call out to further contracts that might.
///
///   3. The return MUST be exactly the three values below, ABI-encoded (96 bytes). The hook checks
///      `returndatasize` and rejects anything else, which also defeats a return-data bomb. If you
///      add a field, you have made a DIFFERENT interface - deploy an adapter, do not widen this.
///
///   4. Reverting is a legitimate answer, but understand what it means: the hook fails CLOSED for
///      trading and for adding liquidity. It never fails closed for REMOVING liquidity - exits do
///      not consult this oracle at all. See the hook's contract-level documentation.
///
/// ############################ WHAT THIS IS NOT ############################
///
/// Nothing here constitutes legal advice, and nothing here asserts that any particular oracle
/// implementation, or any configuration of the hook that consumes it, satisfies any securities
/// law, sanctions regime, transfer-agent rule or exchange registration requirement in any
/// jurisdiction. That determination is for the issuer's counsel. This interface is a mechanism for
/// asking an address-shaped question and receiving an address-shaped answer.
/// ##########################################################################
interface IComplianceOracle {
    /// @notice Decide whether `account` may perform `action` on the pool identified by `poolId`.
    /// @param account The end user whose eligibility is being checked. NOTE: the hook obtains this
    ///        from a trusted router's attestation, not from the callback's `sender`; see the hook.
    /// @param poolId The pool the action targets, so one oracle can serve several offerings.
    /// @param action Which operation is being attempted.
    /// @return permitted True if the account may perform the action.
    /// @return expiresAt Unix timestamp after which this answer must be treated as stale, or 0 for
    ///         "no expiry". The hook enforces this itself, so an oracle that cannot cheaply track
    ///         attestation freshness may safely return 0 and rely on `permitted` alone.
    /// @return jurisdiction ISO-3166-1 numeric country code for the account, or 0 for "unknown /
    ///         not asserted". The hook only consults this when the pool enables jurisdiction
    ///         screening; when it does, a jurisdiction of 0 is screened like any other value, so an
    ///         issuer that wants "unknown is not acceptable" blocks code 0 explicitly.
    function checkCompliance(address account, PoolId poolId, ComplianceAction action)
        external
        view
        returns (bool permitted, uint64 expiresAt, uint16 jurisdiction);
}
