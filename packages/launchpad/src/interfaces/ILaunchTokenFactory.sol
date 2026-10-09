/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

/// @title ILaunchTokenFactory
/// @notice Deterministic factory for plain, fixed-supply launch tokens.
interface ILaunchTokenFactory {
    event LaunchTokenCreated(
        address indexed token,
        address indexed deployer,
        address indexed recipient,
        bytes32 salt,
        string name,
        string symbol,
        string metadataURI,
        uint256 totalSupply
    );

    error EmptyName();
    error EmptySymbol();
    error NameTooLong(uint256 length, uint256 max);
    error SymbolTooLong(uint256 length, uint256 max);
    error MetadataURITooLong(uint256 length, uint256 max);
    error ZeroSupply();
    error ZeroRecipient();
    /// @notice The address this (deployer, salt) maps to already holds code.
    error TokenAlreadyDeployed(address token);
    /// @notice `launchTokenParameters` was read outside a `createToken` call.
    error NoDeploymentInProgress();
    /// @notice `createToken` was entered while another creation was in progress.
    error DeploymentInProgress();

    /// @notice Deploys a token at `predictTokenAddress(msg.sender, salt)` and mints `totalSupply` to
    /// `recipient`.
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint256 totalSupply,
        address recipient,
        bytes32 salt
    ) external returns (address token);

    /// @notice Where `deployer` calling `createToken` with `salt` lands. Independent of the token's
    /// name, symbol, supply and recipient, so a vanity salt can be mined once and reused.
    function predictTokenAddress(address deployer, bytes32 salt) external view returns (address);

    /// @notice keccak256 of the token's creation code. Constant for a given factory build: the SDK can
    /// compute addresses off chain from this 32-byte value without shipping any bytecode.
    function launchTokenInitCodeHash() external view returns (bytes32);

    /// @notice Read by the token's constructor. Reverts outside a creation.
    function launchTokenParameters()
        external
        view
        returns (string memory name, string memory symbol, string memory metadataURI, address recipient, uint256 totalSupply);

    function isLaunchToken(address token) external view returns (bool);

    function deployerOf(address token) external view returns (address);
}
