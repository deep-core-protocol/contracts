/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILaunchpadKitV2, TenantConfig} from "../interfaces/ILaunchpadKitV2.sol";
import {IDeepCorePad} from "./IDeepCorePad.sol";

/// @title DeepCorePad - a transferable `LaunchpadKitV2` tenant
/// @notice One EIP-1167 clone per pad, deployed by `DeepCorePadFactory`. See `IDeepCorePad` for what a pad is.
///
/// Why a hand-rolled two-step owner instead of OpenZeppelin's: `Ownable` sets the owner in a constructor,
/// and a clone has no constructor. The names and events are OpenZeppelin's so any tool that reads
/// `owner()` / `pendingOwner()` / `OwnershipTransferred` reads this too. `renounceOwnership` exists only to
/// revert, keeping the selector on the same do-not-call list as every other DeepCore contract.
///
/// Storage (a clone's storage starts empty; the implementation locks itself in its constructor):
///   slot 0 `_owner`   slot 1 `_pendingOwner`   slot 2 `_name`   slot 3 `_metadataURI`
///
/// `KIT` is an immutable and therefore part of the implementation's CODE, shared by every clone: a factory
/// serves exactly one kit, and a pad can never be pointed at another.
///
/// FUNDS CAN NEVER BE STUCK (CLAUDE.md acceptance bar). Nothing pays the pad: the kit and the lockers credit
/// `integrator`, which `configure` refuses to be the pad. What CAN still reach it is misdirection - a plain
/// ERC-20 `transfer`, an ERC-721 `transferFrom` (a `safeTransferFrom` reverts: no receiver hook), or native
/// via `selfdestruct` (there is no `receive`/`fallback`) - and each has exactly one path out: the owner-only
/// `rescue*` functions, which can move nothing that was ever anyone else's because nothing else is here.
contract DeepCorePad is IDeepCorePad {
    using SafeERC20 for IERC20;

    ILaunchpadKitV2 public immutable KIT;
    /// @notice The factory that clones this implementation. Only it may initialize a pad.
    address public immutable FACTORY;

    uint256 public constant MIN_NAME_BYTES = 1;
    uint256 public constant MAX_NAME_BYTES = 40;
    /// @dev Enough for an inline `data:application/json;base64,...` brand of ~3 KB; anything larger is a pointer.
    uint256 public constant MAX_METADATA_URI_BYTES = 4096;

    address private _owner;
    address private _pendingOwner;
    string private _name;
    string private _metadataURI;

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    /// @param kit The one kit this implementation's clones are tenants of.
    /// @param factory The deployer of clones. The implementation itself is locked: its `_owner` is set so
    /// `initialize` reverts on it, and nothing ever makes it a tenant.
    constructor(ILaunchpadKitV2 kit, address factory) {
        if (address(kit) == address(0) || factory == address(0)) revert ZeroAddress();
        KIT = kit;
        FACTORY = factory;
        _owner = address(0xdead);
    }

    /// @notice Called once by the factory in the same transaction as the clone.
    /// @dev `config` is forwarded to the kit as-is (`msg.sender` there is this pad, so this pad becomes the
    /// tenant). The kit validates the caps; this pad only refuses to be its own integrator.
    function initialize(
        address owner_,
        string calldata name_,
        string calldata metadataURI_,
        TenantConfig calldata config,
        address[] calldata allowedQuotes
    ) external {
        if (msg.sender != FACTORY) revert NotOwner();
        if (_owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        _owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        _setMetadata(name_, metadataURI_);
        _configure(config);
        for (uint256 i; i < allowedQuotes.length; ++i) {
            KIT.setTenantQuote(allowedQuotes[i], true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function owner() public view returns (address) {
        return _owner;
    }

    function pendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function metadataURI() external view returns (string memory) {
        return _metadataURI;
    }

    function tenantConfig() external view returns (TenantConfig memory) {
        return KIT.tenantConfig(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    function configure(TenantConfig calldata config) external onlyOwner {
        _configure(config);
    }

    function setQuote(address quote, bool allowed) external onlyOwner {
        KIT.setTenantQuote(quote, allowed);
    }

    function setMetadata(string calldata name_, string calldata metadataURI_) external onlyOwner {
        _setMetadata(name_, metadataURI_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(_owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert NotPendingOwner();
        address previous = _owner;
        _owner = msg.sender;
        delete _pendingOwner;
        emit OwnershipTransferred(previous, msg.sender);
    }

    function renounceOwnership() external pure {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                                 RESCUE
    //////////////////////////////////////////////////////////////*/

    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    function rescueERC721(address token, uint256 tokenId, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        // `transferFrom`, not `safeTransferFrom`: the owner chose `to`, and a `to` that cannot receive
        // would revert either way; the plain form also works for receivers without the hook.
        IERC721(token).transferFrom(address(this), to, tokenId);
        emit Rescued(token, to, tokenId);
    }

    function rescueNative(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToRescue();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Rescued(address(0), to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _configure(TenantConfig calldata config) internal {
        if (config.integrator == address(this)) revert PadCannotBeIntegrator();
        KIT.setTenantConfig(config);
    }

    function _setMetadata(string calldata name_, string calldata metadataURI_) internal {
        uint256 nameLength = bytes(name_).length;
        if (nameLength < MIN_NAME_BYTES || nameLength > MAX_NAME_BYTES) {
            revert NameLength(nameLength, MIN_NAME_BYTES, MAX_NAME_BYTES);
        }
        if (bytes(metadataURI_).length > MAX_METADATA_URI_BYTES) {
            revert MetadataTooLong(bytes(metadataURI_).length, MAX_METADATA_URI_BYTES);
        }
        _name = name_;
        _metadataURI = metadataURI_;
        emit MetadataUpdated(name_, metadataURI_);
    }
}
