/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IComplianceOracle, ComplianceAction} from "../interfaces/IComplianceOracle.sol";

/// @title AllowlistComplianceOracle
/// @notice A minimal, self-custodied `IComplianceOracle`: an on-chain register of accounts an
/// issuer's off-chain KYC process has cleared, with an expiry and a jurisdiction per account.
///
/// @dev ############################ WHAT THIS IS FOR ############################
///
/// This is the REFERENCE implementation and the fallback for an issuer who runs their own
/// investor onboarding and simply needs somewhere to publish the result. It is intentionally the
/// dumbest thing that can work: a mapping, an owner, and events.
///
/// It is not a KYC provider, it does not verify anything, and it makes no assertion about whether
/// its contents reflect reality. It reports what its owner wrote into it. An issuer with a real
/// attestation provider should point the hook at THAT provider's contract instead - the whole
/// point of `IComplianceOracle` being an interface is that this contract is replaceable.
///
/// Nothing here is legal advice, and the existence of an entry in this register is not a
/// determination that any trade it enables is lawful anywhere. See `IComplianceOracle`.
///
/// ############################ DESIGN NOTES ############################
///
///  * The whole check is ONE storage read, deliberately. `PermissionedPoolHook` calls this inside
///    a Vault lock under a hard gas cap; an implementation that loops, or that calls out to a
///    registry which loops, gets denied by that cap and takes the pool's trading with it.
///
///  * `poolId` and `action` are accepted and ignored. This register is global to the issuer. An
///    implementation that needs per-offering or per-action rules should branch on them; the
///    parameters exist in the interface so that it can.
///
///  * Records are never deleted, only set to `permitted = false`. An empty slot and a revoked slot
///    would otherwise be indistinguishable on-chain, and revocation is the more important of the
///    two events to be able to prove after the fact.
///
///  * `expiresAt` is enforced by the CONSUMER (the hook), not here. This contract reports the
///    expiry it was given and lets the caller decide what staleness means. That keeps the answer
///    to "what did the register say" independent of when it was asked.
///
///  * Ownership is `Ownable2Step`. On mainnet the owner should be a timelock or multisig - see
///    `packages/governance/src/DeepCoreTimelock.sol`. Note the timelock delay applies to REVOCATIONS
///    too, which is a real trade-off for a sanctions response; an issuer who needs immediate
///    revocation should keep a fast-path denial in the hook's own denylist, which is separate.
contract AllowlistComplianceOracle is IComplianceOracle, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The zero address cannot hold a compliance record
    error ZeroAddress();

    /// @notice Batch arguments had mismatched lengths
    error LengthMismatch(uint256 accountsLength, uint256 recordsLength);

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every write, including a revocation (`permitted == false`)
    event ComplianceRecordSet(
        address indexed account, bool permitted, uint64 expiresAt, uint16 indexed jurisdiction
    );

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @param permitted Whether the issuer's process has cleared this account.
    /// @param expiresAt Unix timestamp after which the consumer should treat the record as stale.
    ///        0 means no expiry.
    /// @param jurisdiction ISO-3166-1 numeric country code, or 0 for "not asserted".
    struct Record {
        bool permitted;
        uint64 expiresAt;
        uint16 jurisdiction;
    }

    /// @notice The register. A never-written account reads back as `(false, 0, 0)`.
    mapping(address account => Record) internal _records;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Write or revoke one account's record
    function setRecord(address account, Record calldata record) external onlyOwner {
        _setRecord(account, record);
    }

    /// @notice Write or revoke many records in one call
    function setRecords(address[] calldata accounts, Record[] calldata records) external onlyOwner {
        if (accounts.length != records.length) revert LengthMismatch(accounts.length, records.length);
        for (uint256 i = 0; i < accounts.length; ++i) {
            _setRecord(accounts[i], records[i]);
        }
    }

    /// @notice Revoke many accounts at once, leaving expiry and jurisdiction as they were.
    /// @dev The sanctions/withdrawal path, kept separate so it needs no record construction and
    /// so its events are trivially greppable.
    function revoke(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();
            Record storage r = _records[account];
            r.permitted = false;
            emit ComplianceRecordSet(account, false, r.expiresAt, r.jurisdiction);
        }
    }

    /**
     * @notice Permanently disabled. Reverts for every caller.
     *
     * @dev CLAUDE.md § "Deployed and unfixable" makes this the house rule for every contract
     * deployed from here on, and `MerkleEpochDistributor` is the reference.
     *
     * `setRecord`, `setRecords` and `revoke` are the only `onlyOwner` functions, and they are the
     * only writers of the register. Renouncing freezes it exactly as it stands:
     *
     *   * No account can ever be REVOKED. A sanctioned investor, or one whose KYC was withdrawn,
     *     stays permitted for as long as their record's `expiresAt` allows — forever, for a record
     *     written with `expiresAt == 0`.
     *   * No new investor can ever be onboarded, and no expiring record renewed, so the permitted
     *     set only ever shrinks toward nobody.
     *
     * A consuming hook's own denylist can still refuse an account, but only while THAT hook has an
     * owner; this register would no longer be a compliance source anyone controls.
     * `transferOwnership` is itself `onlyOwner`, so none of this is recoverable.
     *
     * The bounded form of the same intent already exists and is unaffected: an owner who wants out
     * transfers to the address that should have it. `Ownable2Step` means that cannot land somewhere
     * unreachable by typo.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev A compliance oracle holds nothing by design, so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function _setRecord(address account, Record calldata record) internal {
        if (account == address(0)) revert ZeroAddress();
        _records[account] = record;
        emit ComplianceRecordSet(account, record.permitted, record.expiresAt, record.jurisdiction);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The raw record for an account
    function record(address account) external view returns (Record memory) {
        return _records[account];
    }

    /// @notice Convenience predicate applying this contract's own expiry, for off-chain callers.
    /// @dev The hook does NOT use this - it calls `checkCompliance` and applies expiry itself.
    function isPermitted(address account) external view returns (bool) {
        Record storage r = _records[account];
        if (!r.permitted) return false;
        return r.expiresAt == 0 || block.timestamp <= r.expiresAt;
    }

    /// @inheritdoc IComplianceOracle
    function checkCompliance(address account, PoolId, /* poolId */ ComplianceAction /* action */ )
        external
        view
        override
        returns (bool permitted, uint64 expiresAt, uint16 jurisdiction)
    {
        Record storage r = _records[account];
        return (r.permitted, r.expiresAt, r.jurisdiction);
    }
}
