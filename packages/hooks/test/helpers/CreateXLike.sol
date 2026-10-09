// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {CreateXCreate3, DeepCoreDeploy} from "../../script/DeepCoreCreateX.sol";

/// @notice TEST ONLY. A self-authored stand-in for CreateX's CREATE3 path, etched at CreateX's address in
/// forge tests (CreateX is not on the in-EVM test chain, and it is AGPL-3.0, so it is not vendored). It
/// reproduces the behaviour DeepCore depends on and nothing else:
///   * `deployCreate3(salt, initCode)` with CreateX's salt guard for the two forms that matter here:
///     permissioned (salt[0:20] == msg.sender) without redeploy protection (salt[20] == 0x00) guards as
///     `keccak256(abi.encode(bytes32(sender), salt))`; any salt whose first 20 bytes are neither the sender
///     nor zero is "random" and guards as `keccak256(abi.encode(salt))`. Other forms revert.
///   * the proxy child `0x67363d3d37363d34f03d5260086018f3` CREATE2'd at the guarded salt, called with
///     `initCode`, and the result required to have code;
///   * `computeCreate3Address(guardedSalt, deployer)`.
/// The live rehearsal replaces this with CreateX's REAL runtime bytecode (read from a live chain with
/// `cast code`, codehash checked against `CreateXCreate3.CREATEX_RUNTIME_HASH`) and checks the same
/// addresses come out.
contract CreateXLike {
    error InvalidSalt();
    error FailedContractCreation();

    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract) {
        bytes32 guarded = _guard(salt);
        bytes memory child = hex"67363d3d37363d34f03d5260086018f3";
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(child, 32), mload(child), guarded)
        }
        if (proxy == address(0)) revert FailedContractCreation();
        newContract = computeCreate3Address(guarded, address(this));
        (bool ok,) = proxy.call{value: msg.value}(initCode);
        if (!ok || newContract.code.length == 0) revert FailedContractCreation();
    }

    function computeCreate3Address(bytes32 salt, address deployer) public pure returns (address) {
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, bytes32(0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f))
                    )
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), proxy, bytes1(0x01))))));
    }

    function _guard(bytes32 salt) internal view returns (bytes32) {
        address head = address(bytes20(salt));
        if (head == msg.sender) {
            if (salt[20] != 0x00) revert InvalidSalt(); // chain-bound forms are not used by DeepCore
            return keccak256(abi.encode(bytes32(uint256(uint160(msg.sender))), salt));
        }
        if (head == address(0)) revert InvalidSalt();
        return keccak256(abi.encode(salt));
    }
}

/// @notice TEST ONLY. The two lines every deploy-script test needs now that every release script deploys
/// through CreateX: put a CreateX at CreateX's address, and build the salt target a `runWith` takes.
/// Kept beside the stand-in so a test never hand-rolls either and never hard-codes a code hash.
library CreateXTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Etch the stand-in at CreateX's canonical address. Idempotent.
    function etch() internal returns (address) {
        VM.etch(CreateXCreate3.CREATEX, address(new CreateXLike()).code);
        return CreateXCreate3.CREATEX;
    }

    /// @notice A target for `deployer`, tagged so two contracts in one test never share a salt.
    /// @dev `createXCodeHash` is read from the etched stand-in, so the production constant stays the
    /// production constant and a test cannot accidentally assert against a stand-in's hash on a real chain.
    function target(address deployer, bytes11 tag) internal view returns (DeepCoreDeploy.Target memory) {
        return DeepCoreDeploy.Target({
            createX: CreateXCreate3.CREATEX,
            createXCodeHash: CreateXCreate3.CREATEX.codehash,
            deployer: deployer,
            salt: CreateXCreate3.permissionedCrossChainSalt(deployer, tag),
            expected: address(0)
        });
    }
}
