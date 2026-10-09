// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

/**
 * Who signs a release script: a raw key in `PRIVATE_KEY`, or a NAMED address in `DEPLOYER` that
 * forge signs for through its own wallet flags (`--account <keystore>`, `--ledger`, `--trezor`, or
 * `--unlocked` against an anvil fork).
 *
 * WHY THE SECOND FORM EXISTS.
 *   1. The mainnet deployer key never has to sit in a shell variable. With `--account` it stays in
 *      forge's encrypted keystore and is unlocked by a password prompt; with `--ledger` it never
 *      leaves the device.
 *   2. The mainnet session can be rehearsed end to end on a fork FROM THE REAL DEPLOYER ADDRESS
 *      (`anvil_impersonateAccount` + `--unlocked`). The CreateX salts are bound to that address, so
 *      a rehearsal from any other key proves nothing about the production addresses.
 *
 * HOW A SCRIPT USES IT, without changing `runWith`'s signature (tests and the dev stacks drive
 * `runWith` with a real key and are unaffected): `run()` takes `pk = _pkFromEnv()`, which is 0 in
 * the named form; everywhere the script used `vm.addr(pk)` it calls `_signerOf(pk)`, and
 * `vm.startBroadcast(pk)` becomes `_startBroadcastAs(pk)`. A zero `pk` with no named deployer
 * reverts rather than broadcasting from forge's default sender.
 */
abstract contract DeepCoreSignerScript is Script {
    /// @dev Set by `_pkFromEnv` in the named form only; zero otherwise.
    address internal _namedDeployer;

    /// @notice `PRIVATE_KEY` if set (and `DEPLOYER`, if also set, must agree); else 0 with the
    /// named `DEPLOYER` recorded for `_signerOf` / `_startBroadcastAs`.
    function _pkFromEnv() internal returns (uint256 pk) {
        pk = vm.envOr("PRIVATE_KEY", uint256(0));
        _namedDeployer = _resolveSigner(pk, vm.envOr("DEPLOYER", address(0)));
    }

    /// @notice The rule, without the environment (so it can be tested without `vm.setEnv`, which is
    /// process-wide): returns the named deployer to record, zero when the key signs.
    function _resolveSigner(uint256 pk, address named) internal pure returns (address) {
        if (pk != 0) {
            require(named == address(0) || named == vm.addr(pk), "DEPLOYER does not match PRIVATE_KEY");
            return address(0);
        }
        require(named != address(0), "set PRIVATE_KEY, or DEPLOYER with --account/--ledger/--unlocked");
        return named;
    }

    function _signerOf(uint256 pk) internal view returns (address) {
        if (pk != 0) return vm.addr(pk);
        require(_namedDeployer != address(0), "no signer: PRIVATE_KEY and DEPLOYER are both unset");
        return _namedDeployer;
    }

    function _startBroadcastAs(uint256 pk) internal {
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            require(_namedDeployer != address(0), "no signer: PRIVATE_KEY and DEPLOYER are both unset");
            vm.startBroadcast(_namedDeployer);
        }
    }
}
