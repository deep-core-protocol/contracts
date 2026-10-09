/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ILaunchTokenFactory} from "./interfaces/ILaunchTokenFactory.sol";

/// @title LaunchToken
/// @notice A plain, fixed-supply ERC-20. Nothing else.
///
/// @dev What it deliberately does NOT have, because each is something a buyer would have to trust:
///   * no owner, no roles, no admin of any kind;
///   * no mint after construction - `totalSupply` is fixed in the constructor forever;
///   * no burn function, no pause, no blacklist, no transfer limit;
///   * no tax and no transfer hook - `_update` is not overridden, so a transfer moves exactly the
///     amount asked, which is what every AMM, router and locker in this repository assumes;
///   * no upgrade path and no proxy.
///
/// The constructor takes NO arguments; it reads them back from the deploying factory. That keeps the
/// creation code - and therefore its CREATE2 init-code hash - identical for every token, so:
///   1. the address depends only on (factory, deployer, salt), which is what lets a vanity salt be
///      mined off chain once and reused with any name; and
///   2. the MIT SDK can predict addresses from a 32-byte hash it reads on chain, without shipping
///      this contract's GPL-derived bytecode.
contract LaunchToken is ERC20 {
    /// @notice The contract that deployed this token. Provenance is `factory == <canonical factory>`
    /// together with `ILaunchTokenFactory(factory).isLaunchToken(address(this))`.
    address public immutable factory;

    string private _tokenName;
    string private _tokenSymbol;
    string private _metadataURI;

    constructor() ERC20("", "") {
        factory = msg.sender;
        (string memory name_, string memory symbol_, string memory uri_, address recipient, uint256 supply) =
            ILaunchTokenFactory(msg.sender).launchTokenParameters();
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _metadataURI = uri_;
        _mint(recipient, supply);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice Off-chain metadata (image, description). Set once at creation; there is no setter.
    /// @dev Attacker-controlled content from a UI's point of view: proxy it, never hotlink it, and never
    /// treat it as a statement by the protocol. An empty string means none.
    function metadataURI() external view returns (string memory) {
        return _metadataURI;
    }
}
