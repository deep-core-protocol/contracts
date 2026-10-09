// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice The two CreateX functions DeepCore uses. CreateX (pcaversaccio, AGPL-3.0) is a permissionless,
/// ownerless deployer at the SAME address on 190+ chains. DeepCore only CALLS it; nothing of it is vendored
/// here - this interface and the address math below are written from its published behaviour and are
/// checked against the live contract (every deploy script compares `computeCreate3Address` with ours, and
/// the rehearsals use CreateX's real runtime bytecode on anvil).
interface ICreateX {
    /// @notice CREATE3: a CREATE2 proxy at `_guard(salt)`, which CREATEs `initCode` (nonce 1).
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    /// @notice Pure: the CREATE3 address for an ALREADY-GUARDED salt and a deployer (CreateX itself).
    function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computedAddress);
}

/// @notice Address math for a CreateX CREATE3 deployment with a PERMISSIONED, CROSS-CHAIN salt:
///   salt[0:20]  = the deployer (only that sender can use the salt: nobody can front-run or squat it)
///   salt[20]    = 0x00 (no redeploy protection: the chain id is NOT mixed in, so the address is the same
///                 on every chain)
///   salt[21:32] = free (11 bytes)
/// CreateX then guards it as `keccak256(abi.encode(bytes32(uint256(uint160(sender))), salt))` and the
/// deployed address is `keccak256(0xd694 ++ proxy ++ 0x01)` with `proxy = CREATE2(createX, guarded,
/// keccak256(PROXY_CHILD_BYTECODE))`. The constructor arguments of the deployed contract play no part.
///
/// THIS LAYOUT IS A SECURITY PROPERTY, NOT A CONVENTION. The leading deployer is what stops anyone else
/// using DeepCore's salts to squat DeepCore's addresses on a chain DeepCore has not reached yet; the zero byte is
/// what makes the address identical across chains. `ops/deploy/tools/mine-createx-salt.mjs` mines inside
/// it and nothing may widen it.
library CreateXCreate3 {
    /// @notice CreateX's address on every chain it is deployed to (verified on Robinhood 4663, Base 8453
    /// and Sepolia).
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    /// @notice `keccak256` of CreateX's runtime bytecode, read with `cast code` on Robinhood (4663),
    /// Ethereum Sepolia (11155111) on 2026-09-19 and Base mainnet (8453) on 2026-09-20: identical on all
    /// three. A deploy refuses a CreateX with any other code.
    bytes32 internal constant CREATEX_RUNTIME_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    /// @notice `keccak256(hex"67363d3d37363d34f03d5260086018f3")`, the CREATE3 proxy child's init code.
    bytes32 internal constant PROXY_CHILD_INITCODE_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @notice A salt only `deployer` can use, with no chain id: `deployer ++ 0x00 ++ tail`.
    function permissionedCrossChainSalt(address deployer, bytes11 tail) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(deployer, bytes1(0x00), tail));
    }

    /// @notice True when `salt` is permissioned to `deployer` and carries no chain id.
    function isPermissionedCrossChain(bytes32 salt, address deployer) internal pure returns (bool) {
        return address(bytes20(salt)) == deployer && salt[20] == 0x00;
    }

    /// @notice CreateX's `_guard` for a permissioned salt without redeploy protection.
    function guardedSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(bytes32(uint256(uint160(deployer))), salt));
    }

    /// @notice The CREATE3 address for an already-guarded salt, deployed by `createX`.
    function create3Address(address createX, bytes32 guarded) internal pure returns (address) {
        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), createX, guarded, PROXY_CHILD_INITCODE_HASH)))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), proxy, bytes1(0x01))))));
    }

    /// @notice Where `deployCreate3(salt, anything)` sent by `deployer` to `createX` lands.
    function predict(address createX, address deployer, bytes32 salt) internal pure returns (address) {
        return create3Address(createX, guardedSalt(deployer, salt));
    }
}

/**
 * @notice The one way a DeepCore release contract reaches a chain: CreateX `deployCreate3` at a mined,
 * permissioned, chain-id-free salt, asserted to land on the address the salts file says.
 *
 * WHY EVERY RELEASE SCRIPT USES THIS. Owner decisions 2026-09-19/20: every mainnet contract's address is
 * `0x7878…78`, the same on every chain, and **HyperEVM (999) is the launch chain**, so its addresses
 * become canonical for any later chain. A plain `new` gives an address that depends on
 * the deployer's NONCE, which is neither vanity nor reproducible on a second chain - one extra transaction
 * anywhere in the order and every address after it moves.
 *
 * WHERE THE SALTS COME FROM. `ops/deploy/tools/mine-createx-salt.mjs --labels ops/deploy/salts/labels.txt`
 * mines one salt per contract for ONE deployer address and writes
 * `ops/deploy/salts/salts.<deployer>.json`. `ops/deploy/tools/salts-env.mjs` re-derives every address from
 * (CreateX, deployer, salt) and prints the `DEEPCORE_SALT_*` / `DEEPCORE_ADDRESS_*` exports the scripts read.
 * **The file is per-deployer: change the deployer key and every salt and every address must be re-mined.**
 *
 * WHAT THIS REFUSES TO DO, and why each one is a real failure that has happened or nearly happened:
 *   - broadcast when CreateX has no code on the chain (a bare `EvmError: Revert` against an empty address
 *     is what G-3 spent an afternoon on);
 *   - broadcast when the code at CreateX's address is not CreateX (a same-address-different-code chain);
 *   - accept a salt that is not permissioned to this deployer, or that mixes the chain id in - either one
 *     silently gives up the cross-chain address or lets a stranger take it on the next chain;
 *   - accept OUR address math without asking the live CreateX for the same answer;
 *   - deploy to an address that already has code;
 *   - deploy anywhere other than the address the salts file names.
 */
library DeepCoreDeploy {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @param createX CreateX's address. The canonical one in production; a stand-in in forge tests.
    /// @param createXCodeHash The runtime code hash that address must have.
    /// @param deployer The key that signs the deployment. The salt is permissioned to exactly this address.
    /// @param salt `deployer ++ 0x00 ++ 11 mined bytes`.
    /// @param expected The address the salts file predicts. Zero skips the comparison (never in production).
    struct Target {
        address createX;
        bytes32 createXCodeHash;
        address deployer;
        bytes32 salt;
        address expected;
    }

    /// @notice The target for `label`, from `DEEPCORE_SALT_<label>` and `DEEPCORE_ADDRESS_<label>`.
    /// @dev Reads the environment and nothing else, so `runWith` entry points stay drivable from tests.
    /// BOTH variables are REQUIRED here (`vm.envBytes32` / `vm.envAddress` revert when unset), because an
    /// unset expected address would silently turn the "it landed where the mine said" check off, and a
    /// vanity deployment that quietly lands somewhere else is worse than no vanity at all.
    /// `ops/deploy/tools/salts-env.mjs` always exports the pair. `DEEPCORE_SALTS_DEPLOYER`, when set, must be
    /// the deployer the salts were mined for - a mismatch means somebody sourced another key's salts file.
    function fromEnv(string memory label, address deployer) internal view returns (Target memory t) {
        address mined = VM.envOr("DEEPCORE_SALTS_DEPLOYER", address(0));
        require(
            mined == address(0) || mined == deployer,
            string.concat("DEEPCORE_SALTS_DEPLOYER is not this deployer: the salts file was mined for another key (", label, ")")
        );
        t = Target({
            createX: CreateXCreate3.CREATEX,
            createXCodeHash: CreateXCreate3.CREATEX_RUNTIME_HASH,
            deployer: deployer,
            salt: VM.envBytes32(string.concat("DEEPCORE_SALT_", label)),
            expected: VM.envAddress(string.concat("DEEPCORE_ADDRESS_", label))
        });
    }

    /// @notice Where this target deploys: a function of (CreateX, deployer, salt) ALONE. Neither the
    /// contract's bytecode nor its constructor arguments move it, which is why one mined salt serves the
    /// same contract on every chain even though its constructor arguments differ per chain.
    function predict(Target memory t) internal pure returns (address) {
        return CreateXCreate3.predict(t.createX, t.deployer, t.salt);
    }

    /// @notice Every check that must pass before anything is broadcast. `label` only names the contract in
    /// the revert strings.
    function preflight(Target memory t, string memory label) internal view {
        require(t.createX.code.length > 0, string.concat("CreateX has no code on this chain (", label, ")"));
        require(
            t.createX.codehash == t.createXCodeHash,
            string.concat("CreateX runtime code is not the canonical CreateX (", label, ")")
        );
        require(
            CreateXCreate3.isPermissionedCrossChain(t.salt, t.deployer),
            string.concat("DEEPCORE_SALT_", label, " must be <deployer> ++ 0x00 ++ 11 bytes (permissioned, no chain id)")
        );
        address predicted = predict(t);
        require(
            ICreateX(t.createX).computeCreate3Address(CreateXCreate3.guardedSalt(t.deployer, t.salt), t.createX)
                == predicted,
            string.concat("CreateX disagrees with the predicted address (", label, ")")
        );
        require(predicted.code.length == 0, string.concat("the predicted address already has code on this chain (", label, ")"));
        if (t.expected != address(0)) {
            require(
                predicted == t.expected,
                string.concat("predicted address differs from DEEPCORE_ADDRESS_", label, " (other deployer or salt?)")
            );
        }
    }

    /// @notice Deploy `initCode` through CreateX and prove it landed where it was predicted to.
    /// @dev Call inside `vm.startBroadcast(pk)` / `vm.stopBroadcast()`: this library never broadcasts for
    /// the caller, so a script keeps one visible broadcast window per process.
    function deploy(Target memory t, bytes memory initCode, string memory label) internal returns (address deployed) {
        address predicted = predict(t);
        deployed = ICreateX(t.createX).deployCreate3(t.salt, initCode);
        require(deployed == predicted, string.concat("CreateX deployed somewhere other than predicted (", label, ")"));
        require(deployed.code.length > 0, string.concat("nothing deployed at the predicted address (", label, ")"));
    }
}
