/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {TenantConfig} from "../interfaces/ILaunchpadKitV2.sol";

/// @title IDeepCorePad - one tenant of `LaunchpadKitV2`, as a transferable contract
/// @notice A pad is a `LaunchpadKitV2` tenant that a wallet OWNS rather than IS. The kit keys every tenant
/// config by `msg.sender`, so a tenant that is a raw wallet cannot be handed to another wallet without every
/// launch that named it pointing at the old address forever. A pad puts a tiny, transferable contract in
/// that position: the pad is the tenant, the owner configures it, and ownership moves two-step.
///
/// The pad holds NOTHING. Its integrator wallet (where locked-LP fee shares and launch fees are credited by
/// the lockers and the kit) is whatever the owner names, never the pad itself, which `configure` refuses.
/// There is no receive, no fallback, no token path and no claim function to add later.
interface IDeepCorePad {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Two-step ownership, with OpenZeppelin's event names so the same tooling reads both.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice The pad's public identity changed. `metadataURI` carries the brand (a `data:` or `ipfs://` URI).
    event MetadataUpdated(string name, string metadataURI);
    /// @notice Value that reached the pad by mistake was sent on. `token` is zero for native.
    event Rescued(address indexed token, address indexed to, uint256 amountOrId);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyInitialized();
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error RenounceDisabled();
    /// @notice The integrator may not be the pad: the pad custodies nothing, by design.
    error PadCannotBeIntegrator();
    error NameLength(uint256 length, uint256 min, uint256 max);
    error MetadataTooLong(uint256 length, uint256 max);
    error NothingToRescue();
    error NativeTransferFailed();

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function name() external view returns (string memory);
    function metadataURI() external view returns (string memory);
    /// @notice `kit.tenantConfig(address(this))`, for convenience.
    function tenantConfig() external view returns (TenantConfig memory);

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Writes the pad's tenant config on the kit. The kit validates caps; the pad refuses itself as integrator.
    function configure(TenantConfig calldata config) external;
    /// @notice `kit.setTenantQuote` for the pad. Only consulted by the kit when `restrictQuotes` is set.
    function setQuote(address quote, bool allowed) external;
    function setMetadata(string calldata name_, string calldata metadataURI_) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    /// @notice Always reverts. A pad with no owner is a tenant nobody can reconfigure or hand on.
    function renounceOwnership() external;

    /*//////////////////////////////////////////////////////////////
                                 RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends an ERC-20 balance the pad should never have (nothing pays the pad) to `to`.
    /// @dev The pad holds nothing of anyone's, so this moves only misdirected value; it is not a treasury.
    function rescueERC20(address token, address to) external;
    /// @notice Sends an ERC-721 (a position sent here with `transferFrom`) to `to`.
    function rescueERC721(address token, uint256 tokenId, address to) external;
    /// @notice Sends native forced in (there is no `receive`; only `selfdestruct` can put it here) to `to`.
    function rescueNative(address to) external;
}
