// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
// Copyright (C) 2026 HookProtocol — portable transient backend + explicit clear()
pragma solidity ^0.8.24;

import {Currency} from "../types/Currency.sol";
import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @notice Records a single <currency, amount> reserve per sync, used to derive how many
/// tokens were transferred into the vault between `sync` and `settle`.
///
/// @dev SECURITY: `Vault._settle` computes `paid = balanceOfSelf() - reservesBefore`.
/// A stale non-zero `reservesBefore` surviving into a later transaction lets an attacker
/// settle without paying and be credited the difference. Under the EIP-1153 backend the
/// EVM clears these slots at end of transaction; under the storage backend it does not,
/// so `clear()` MUST be called before every lock exits, and `sync()` is gated by
/// `isLocked` so no reserve is ever written outside a lock.
library VaultReserve {
    // uint256 constant RESERVE_TYPE_SLOT = uint256(keccak256("reserveType")) - 1;
    uint256 internal constant RESERVE_TYPE_SLOT = 0x52a1be34b47478d7c75e2b6c3eea1e05dcb8dbb8c6a42c6482d0dca0df53cb27;

    // uint256 constant RESERVE_AMOUNT_SLOT = uint256(keccak256("reserveAmount")) - 1;
    uint256 internal constant RESERVE_AMOUNT_SLOT = 0xb0879d96d58bcff08d1fd45590200072d5a8c380da0b5aa1052b48b84e115207;

    /// @notice Store the currency reserve for the duration of the lock
    /// @param currency The currency to be saved
    /// @param amount The amount of the currency to be saved
    function setVaultReserve(Currency currency, uint256 amount) internal {
        TransientSlot.setAddress(RESERVE_TYPE_SLOT, Currency.unwrap(currency));
        TransientSlot.setUint(RESERVE_AMOUNT_SLOT, amount);
    }

    /// @notice Load the currency reserve most recently saved
    /// @return currency The currency that was most recently saved
    /// @return amount The amount of the currency that was most recently saved
    function getVaultReserve() internal view returns (Currency currency, uint256 amount) {
        currency = Currency.wrap(TransientSlot.getAddress(RESERVE_TYPE_SLOT));
        amount = TransientSlot.getUint(RESERVE_AMOUNT_SLOT);
    }

    /// @notice Zero both reserve slots. MUST be called before a lock exits.
    /// @dev Under the EIP-1153 backend this is redundant but harmless (~200 gas) and is kept
    /// unconditional so both builds follow the identical code path. Under the storage backend
    /// it is what prevents the stale-reserve drain described above.
    function clear() internal {
        TransientSlot.setAddress(RESERVE_TYPE_SLOT, address(0));
        TransientSlot.setUint(RESERVE_AMOUNT_SLOT, 0);
    }
}
