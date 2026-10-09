/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {LaunchToken} from "./LaunchToken.sol";
import {ILaunchTokenFactory} from "./interfaces/ILaunchTokenFactory.sol";

/// @title LaunchTokenFactory
/// @notice Deploys `LaunchToken`s at deterministic, unsquattable CREATE2 addresses.
///
/// @dev ############################ ADDRESSES ############################
///
/// `address = CREATE2(factory, keccak256(abi.encode(msg.sender, salt)), keccak256(creationCode))`.
///
/// Folding `msg.sender` into the salt is the whole anti-squatting design: a front-runner who copies a
/// pending `createToken` transaction lands on a DIFFERENT address, because their `msg.sender` differs.
/// Nobody can occupy an address another deployer mined. Consequence for integrators: a CONTRACT that
/// calls this factory on behalf of many users (a launchpad kit) shares one namespace across all of
/// them, and must fold its own caller into the salt it passes, or its users can squat each other.
///
/// ############################ WHY FULL DEPLOYS, NOT EIP-1167 CLONES ############################
///
///   * Clones put a DELEGATECALL (+ a cold account access on first touch) in front of EVERY transfer
///     for the life of the token. A traded token pays that on every swap; a full deploy pays once.
///   * Clones need an initializer - an extra function in the token's ABI, and a class of bug
///     (uninitialized implementation, re-initialization) that a constructor cannot have.
///   * Clones' one real advantage - a constant init-code hash for off-chain address mining - is kept
///     here anyway, by having the constructor read its parameters back from the factory.
///   * Verification: every token has identical creation AND runtime bytecode, so one verified source
///     matches all of them; explorers that match by bytecode verify each automatically.
///
/// ############################ NO ADMIN ############################
///
/// No owner, no fee, no allowlist, no setter. The length bounds below are abuse limits on a shared,
/// permissionless factory - they bound storage a stranger can make a UI fetch - not tenant economics,
/// which is why they are constants rather than constructor arguments.
contract LaunchTokenFactory is ILaunchTokenFactory {
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 32;
    uint256 public constant MAX_METADATA_URI_BYTES = 512;

    /// @inheritdoc ILaunchTokenFactory
    bytes32 public immutable override launchTokenInitCodeHash;

    /// @inheritdoc ILaunchTokenFactory
    mapping(address token => address deployer) public override deployerOf;

    struct Parameters {
        string name;
        string symbol;
        string metadataURI;
        address recipient;
        uint256 totalSupply;
    }

    /// @dev Populated only for the duration of one `createToken`, then deleted. Ordinary storage rather
    /// than EIP-1153 so both build profiles behave identically.
    Parameters private _params;

    constructor() {
        launchTokenInitCodeHash = keccak256(type(LaunchToken).creationCode);
    }

    /// @inheritdoc ILaunchTokenFactory
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint256 totalSupply,
        address recipient,
        bytes32 salt
    ) external override returns (address token) {
        uint256 nameLength = bytes(name).length;
        uint256 symbolLength = bytes(symbol).length;
        if (nameLength == 0) revert EmptyName();
        if (symbolLength == 0) revert EmptySymbol();
        if (nameLength > MAX_NAME_BYTES) revert NameTooLong(nameLength, MAX_NAME_BYTES);
        if (symbolLength > MAX_SYMBOL_BYTES) revert SymbolTooLong(symbolLength, MAX_SYMBOL_BYTES);
        if (bytes(metadataURI).length > MAX_METADATA_URI_BYTES) {
            revert MetadataURITooLong(bytes(metadataURI).length, MAX_METADATA_URI_BYTES);
        }
        if (totalSupply == 0) revert ZeroSupply();
        if (recipient == address(0)) revert ZeroRecipient();
        // The token constructor cannot call back into createToken (it only mints), but the guard makes
        // "parameters belong to exactly one creation" a local property rather than an argument.
        if (_params.recipient != address(0)) revert DeploymentInProgress();

        bytes32 effectiveSalt = _effectiveSalt(msg.sender, salt);
        address predicted = Create2.computeAddress(effectiveSalt, launchTokenInitCodeHash);
        if (predicted.code.length != 0) revert TokenAlreadyDeployed(predicted);

        _params = Parameters({
            name: name, symbol: symbol, metadataURI: metadataURI, recipient: recipient, totalSupply: totalSupply
        });
        token = address(new LaunchToken{salt: effectiveSalt}());
        delete _params;

        // Holds by construction; asserted so a compiler or EVM divergence cannot silently desync the SDK.
        assert(token == predicted);
        deployerOf[token] = msg.sender;

        emit LaunchTokenCreated(token, msg.sender, recipient, salt, name, symbol, metadataURI, totalSupply);
    }

    /// @inheritdoc ILaunchTokenFactory
    function launchTokenParameters()
        external
        view
        override
        returns (string memory, string memory, string memory, address, uint256)
    {
        Parameters memory p = _params;
        if (p.recipient == address(0)) revert NoDeploymentInProgress();
        return (p.name, p.symbol, p.metadataURI, p.recipient, p.totalSupply);
    }

    /// @inheritdoc ILaunchTokenFactory
    function predictTokenAddress(address deployer, bytes32 salt) external view override returns (address) {
        return Create2.computeAddress(_effectiveSalt(deployer, salt), launchTokenInitCodeHash);
    }

    /// @inheritdoc ILaunchTokenFactory
    function isLaunchToken(address token) external view override returns (bool) {
        return deployerOf[token] != address(0);
    }

    function _effectiveSalt(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }
}
