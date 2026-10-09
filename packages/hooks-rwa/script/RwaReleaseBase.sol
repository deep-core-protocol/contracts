// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

/// @notice The two `Ownable2Step` getters every RWA release contract exposes.
interface IOwnable2StepRead {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/// @notice `DeepCoreRegistry`'s `DeepCoreMetadata`, field for field. Declared here rather than imported so
/// `packages/hooks-rwa` does not gain a `deepcore-registry/` remapping for one struct. The ABI tuple is
/// what fixes the selector (`register(address,(string,string,string,string,uint256[]))`), and a
/// mismatch cannot be silent: the post-flight reads the listing back through `getDeepCore`.
struct RwaDeepCoreMetadata {
    string name;
    string description;
    string sourceURI;
    string auditURI;
    uint256[] chainIds;
}

/// @notice `DeepCoreRegistry`'s `DeepCoreRecord`, field for field (enums as `uint8`, which is their ABI).
struct RwaDeepCoreRecord {
    address submitter;
    uint64 submittedAt;
    uint16 permissions;
    uint8 verification;
    uint8 listing;
    address steward;
    uint64 updatedAt;
    bool permissionsValid;
    bool permissionsReadable;
    uint16 attestedPermissions;
    bytes32 codehash;
    address attestedPoolManager;
    uint64 attestedAt;
    uint32 attestationCount;
    bytes32 attestedPoolId;
    RwaDeepCoreMetadata metadata;
}

/// @notice The four `DeepCoreRegistry` functions the hook scripts use.
interface IDeepCoreRegistryListing {
    function register(address hook, RwaDeepCoreMetadata calldata metadata) external;
    function transferSteward(address hook, address newSteward) external;
    function isRegistered(address hook) external view returns (bool);
    function getDeepCore(address hook) external view returns (RwaDeepCoreRecord memory);
}

/// @notice Minimal Chainlink reads for the sequencer-uptime check.
interface IUptimeFeedRead {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
    function aggregator() external view returns (address);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ITypeAndVersionRead {
    function typeAndVersion() external view returns (string memory);
}

/**
 * ####################### THE RWA SECOND DEPLOYMENT, SHARED PLUMBING #######################
 *
 * CLAUDE.md "Stock pairs ship on every chain" (owner, 2026-09-20): `MarketHoursHook`, `StockPairHook`,
 * `ChainlinkPriceBandAdapter` and `AllowlistComplianceOracle` ship as a SECOND deployment after core
 * and the DeepCore layer are live and read back on a chain. Each contract has its OWN script and runs in
 * its OWN `forge script` process (the deployment rule: a contract deployed through a script that
 * compiles something else can come out as different bytecode at the same address).
 *
 * What every one of the four scripts shares, and why it is here rather than copied four times:
 *
 *   SIGNER. `PRIVATE_KEY` when it is set (the house pattern). When it is NOT set, `DEPLOYER` names the
 *   sending address and the broadcast is `vm.startBroadcast(address)`, which signs with whatever
 *   `forge script` was given (`--account`, `--ledger`, or `--unlocked` against an anvil fork). The fork
 *   rehearsal uses the latter to deploy from the REAL deployer address, so the CreateX addresses it
 *   proves are the production ones, without the key ever being read.
 *
 *   CORE. The CL pool manager must have code, its Vault must have code, and the manager must be
 *   registered in that Vault; the registry must have code. A hook address is part of pool identity,
 *   so a hook bound to the wrong manager is a redeploy. DeepCore has no core of record on any chain
 *   yet, so the addresses are not pinned; the operator supplies them from the chain's read-back.
 *
 *   OWNER. `DeepCoreGovernance.requireGovernanceSafe`: a contract, not the deployer, and on every
 *   production chain the Safe of record. All four constructors take the owner directly
 *   (`Ownable(initialOwner)`), so there is NO transfer window and nothing for the Safe to accept.
 *
 *   RENOUNCE. Each contract overrides `renounceOwnership` as `pure` and reverting `RenounceDisabled()`.
 *   The post-flight proves it by staticcall AND checks the revert selector, so an unrelated revert
 *   (wrong address, no code) cannot pass as the override.
 */
abstract contract RwaReleaseBase is Script {
    /// @dev Where every DeepCore listing points (owner decision D5, 2026-09-27).
    string internal constant SOURCE_URI = "https://deepcore.fun/docs#contracts";

    bytes4 internal constant RENOUNCE_DISABLED = bytes4(keccak256("RenounceDisabled()"));

    struct Signer {
        /// @dev Zero when signing through `DEPLOYER` + a forge wallet flag.
        uint256 pk;
        address deployer;
    }

    /// @notice `PRIVATE_KEY` if set, else `DEPLOYER`. Never both silently: if both are set they must agree.
    function _signerFromEnv() internal view returns (Signer memory s) {
        s.pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address named = vm.envOr("DEPLOYER", address(0));
        if (s.pk != 0) {
            s.deployer = vm.addr(s.pk);
            require(named == address(0) || named == s.deployer, "DEPLOYER does not match PRIVATE_KEY");
        } else {
            require(named != address(0), "set PRIVATE_KEY, or DEPLOYER with --account/--ledger/--unlocked");
            s.deployer = named;
        }
    }

    function _begin(Signer memory s) internal {
        if (s.pk != 0) vm.startBroadcast(s.pk);
        else vm.startBroadcast(s.deployer);
    }

    /*//////////////////////////////////////////////////////////////
        THE SEQUENCER-UPTIME POLICY, PER CHAIN - one table for every adapter
    //////////////////////////////////////////////////////////////*/

    string internal constant UPTIME_DESCRIPTION = "L2 Sequencer Uptime Status Feed";
    uint32 internal constant MIN_SEQUENCER_GRACE = 600;
    uint32 internal constant MAX_SEQUENCER_GRACE = 24 hours;

    /// @notice What a production chain's adapters must be constructed with.
    /// @dev `sequencerUptimeFeed` is an immutable constructor argument with no setter, so a wrong value
    /// is a redeploy AND a new CreateX salt. Each row is a fact read on that chain, and a production
    /// chain with no row is REFUSED rather than guessed:
    ///
    ///   Base 8453      Chainlink's L2 Sequencer Uptime Status Feed, read 2026-10-09:
    ///                  `description()` = "L2 Sequencer Uptime Status Feed", `decimals()` = 0, answer 0 (up).
    ///   Ethereum 1     an L1: there is no sequencer. Zero, and the adapter says so (`SequencerCheckAbsent`).
    ///   BNB Chain 56   an L1: there is no sequencer. Zero.
    ///
    /// Not recorded, so still refused: Robinhood 4663 (an Arbitrum Nitro chain; whether a Chainlink
    /// uptime feed exists there has not been read on chain), HyperEVM 999, and every other chain.
    function sequencerPolicyFor(uint256 chainId) public pure returns (bool recorded, address uptimeFeed) {
        if (chainId == 8453) return (true, 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);
        if (chainId == 1 || chainId == 56) return (true, address(0));
        return (false, address(0));
    }

    /// @notice The checks every feed adapter's deploy script runs on its sequencer arguments.
    function _checkSequencerPolicy(address uptimeFeed, uint32 gracePeriod) internal view {
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            (bool recorded, address want) = sequencerPolicyFor(block.chainid);
            if (!recorded) {
                revert("no sequencer-uptime policy is recorded for this production chain; add a row to this script");
            }
            require(uptimeFeed == want, "RWA_SEQUENCER_UPTIME_FEED is not the feed recorded for this chain");
        }

        if (uptimeFeed == address(0)) {
            require(gracePeriod == 0, "RWA_SEQUENCER_GRACE_SECONDS must be 0 when there is no uptime feed");
            return;
        }
        require(
            gracePeriod >= MIN_SEQUENCER_GRACE && gracePeriod <= MAX_SEQUENCER_GRACE,
            "RWA_SEQUENCER_GRACE_SECONDS outside [600, 86400]"
        );
        require(uptimeFeed.code.length > 0, "RWA_SEQUENCER_UPTIME_FEED has no code");
        require(
            keccak256(bytes(IUptimeFeedRead(uptimeFeed).description())) == keccak256(bytes(UPTIME_DESCRIPTION)),
            "uptime feed description is not Chainlink's"
        );
        require(IUptimeFeedRead(uptimeFeed).decimals() == 0, "uptime feed decimals is not 0");
        (, int256 answer, uint256 startedAt,,) = IUptimeFeedRead(uptimeFeed).latestRoundData();
        require(startedAt != 0, "uptime feed has no initialised round");
        require(answer == 0, "the sequencer reads DOWN right now; do not deploy into an outage");
    }

    /// @notice The CL pool manager must be DeepCore core, registered in its Vault.
    function _requireCore(address poolManager) internal view {
        require(poolManager.code.length > 0, "RWA_CL_POOL_MANAGER has no code");
        address vault = address(ICLPoolManager(poolManager).vault());
        require(vault.code.length > 0, "the pool manager's vault has no code");
        (bool ok, bytes memory ret) =
            vault.staticcall(abi.encodeWithSignature("isAppRegistered(address)", poolManager));
        require(ok && ret.length == 32 && abi.decode(ret, (bool)), "the pool manager is not registered in its vault");
    }

    function _requireRegistry(address registry) internal view {
        require(registry.code.length > 0, "RWA_REGISTRY has no code");
    }

    function _requireOwner(address owner_, address deployer) internal view {
        DeepCoreGovernance.requireGovernanceSafe(owner_, deployer, "RWA_OWNER");
    }

    /// @notice Owner is exactly `owner_`, nobody is pending, and renounce reverts `RenounceDisabled()`.
    function _requireOwnership(address target, address owner_) internal view {
        require(IOwnable2StepRead(target).owner() == owner_, "owner() is not RWA_OWNER");
        require(IOwnable2StepRead(target).pendingOwner() == address(0), "a pending owner exists at birth");
        (bool renounced, bytes memory reason) = target.staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!renounced, "renounceOwnership did not revert");
        require(reason.length == 4 && bytes4(reason) == RENOUNCE_DISABLED, "renounceOwnership reverted with the wrong error");
    }

    /// @notice List a hook in the same transaction window it was deployed in, then hand the steward to
    /// Ops. Listing is PERMISSIONLESS: left for later, a stranger can list DeepCore's own hook first with
    /// hostile metadata (the same join as the launch guards' R5').
    function _list(address registry, address hook, address steward, address deployer, string memory name, string memory description)
        internal
    {
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        IDeepCoreRegistryListing(registry).register(
            hook,
            RwaDeepCoreMetadata({name: name, description: description, sourceURI: SOURCE_URI, auditURI: "", chainIds: chains})
        );
        if (steward != deployer) IDeepCoreRegistryListing(registry).transferSteward(hook, steward);
    }

    function _requireListed(address registry, address hook, address steward, uint16 bitmap) internal view {
        require(IDeepCoreRegistryListing(registry).isRegistered(hook), "hook is not listed");
        RwaDeepCoreRecord memory r = IDeepCoreRegistryListing(registry).getDeepCore(hook);
        require(r.steward == steward, "listing steward is not RWA_STEWARD");
        require(r.permissions == bitmap, "listing permissions differ from the hook bitmap");
        require(r.listing == 0, "listing is not Active");
        require(keccak256(bytes(r.metadata.sourceURI)) == keccak256(bytes(SOURCE_URI)), "listing sourceURI");
    }

    function _preflightTarget(DeepCoreDeploy.Target memory t, address deployer, string memory label) internal view {
        require(t.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(t, label);
    }
}
