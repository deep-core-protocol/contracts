// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {ChainlinkPriceBandAdapter} from "../src/oracles/ChainlinkPriceBandAdapter.sol";
import {RwaReleaseBase, IUptimeFeedRead} from "./RwaReleaseBase.sol";

/**
 * Deploys `ChainlinkPriceBandAdapter` (CreateX label 20, `CHAINLINK_PRICE_BAND_ADAPTER`).
 *
 * ####################### OWNER: THE SAFE, AND WHY NOT CUSTODY #######################
 *
 * The adapter's own constructor note and the `PythPriceBandAdapter` row say Safe. The hazard worth
 * naming: `configureFeed` accepts ANY contract that answers `decimals()`, so an owner can point a pool
 * at an "aggregator" it controls and move that pool's band — the power that put
 * `ManualPriceBandOracle` under Custody. It stays on the Safe because the SAME Safe already owns every
 * consuming hook, and `configureMarket` can repoint a pool's oracle or switch its band off in one
 * transaction. A 48 h delay on the adapter would bound nothing the hook owner cannot already do.
 * Consequence to keep: if the hooks ever move to Custody, this adapter must move with them.
 *
 * ####################### THE SEQUENCER-UPTIME FEED IS IMMUTABLE #######################
 *
 * `sequencerUptimeFeed` and `sequencerGracePeriod` are constructor arguments with no setter (a setter
 * would be a one-transaction way to switch a safety check off). A wrong value is a redeploy AND a new
 * CreateX salt, because the mined address is then taken. So this script fixes the policy per chain and
 * FAILS CLOSED on a chain it has no row for:
 *
 *   any production chain  REFUSED until a row is added here, with the chain's feed policy read on
 *                     chain (a published Chainlink uptime feed, or zero where none applies, in which
 *                     case the adapter emits `SequencerCheckAbsent` and every pool must lean on the
 *                     feed heartbeat). DeepCore has no row yet: HyperEVM (999) is not decided.
 *   local / test chains  take what env says, through the same feed checks.
 *
 * Env: PRIVATE_KEY | DEPLOYER, the CHAINLINK_PRICE_BAND_ADAPTER salt pair, RWA_OWNER,
 *      RWA_SEQUENCER_UPTIME_FEED (0x0 for none), RWA_SEQUENCER_GRACE_SECONDS (0 when there is no feed).
 */
contract DeployChainlinkPriceBandAdapterScript is RwaReleaseBase {
    string internal constant LABEL = "CHAINLINK_PRICE_BAND_ADAPTER";

    string internal constant UPTIME_DESCRIPTION = "L2 Sequencer Uptime Status Feed";
    uint32 internal constant MIN_GRACE = 600;
    uint32 internal constant MAX_GRACE = 24 hours;

    struct Params {
        Signer signer;
        address owner;
        address uptimeFeed;
        uint32 gracePeriod;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (ChainlinkPriceBandAdapter adapter) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        Signer memory s = _signerFromEnv();
        uint256 grace = vm.envUint("RWA_SEQUENCER_GRACE_SECONDS");
        require(grace <= type(uint32).max, "RWA_SEQUENCER_GRACE_SECONDS overflows uint32");
        return runWith(
            Params({
                signer: s,
                owner: vm.envAddress("RWA_OWNER"),
                uptimeFeed: vm.envAddress("RWA_SEQUENCER_UPTIME_FEED"),
                gracePeriod: uint32(grace),
                target: DeepCoreDeploy.fromEnv(LABEL, s.deployer)
            })
        );
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(ChainlinkPriceBandAdapter).creationCode, abi.encode(p.uptimeFeed, p.gracePeriod, p.owner)
        );
    }

    /// @notice The per-chain sequencer policy above. Public so a test can drive it without a deploy.
    function checkSequencerPolicy(address uptimeFeed, uint32 gracePeriod) public view {
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            revert("no sequencer-uptime policy is recorded for this production chain; add a row to this script");
        }

        if (uptimeFeed == address(0)) {
            require(gracePeriod == 0, "RWA_SEQUENCER_GRACE_SECONDS must be 0 when there is no uptime feed");
            return;
        }
        require(gracePeriod >= MIN_GRACE && gracePeriod <= MAX_GRACE, "RWA_SEQUENCER_GRACE_SECONDS outside [600, 86400]");
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

    function runWith(Params memory p) public returns (ChainlinkPriceBandAdapter adapter) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        _requireOwner(p.owner, deployer);
        checkSequencerPolicy(p.uptimeFeed, p.gracePeriod);

        console.log("=== ChainlinkPriceBandAdapter ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Safe)    ", p.owner);
        console.log("  uptime feed     ", p.uptimeFeed);
        console.log("  grace, s        ", p.gracePeriod);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        adapter = ChainlinkPriceBandAdapter(DeepCoreDeploy.deploy(p.target, code, LABEL));
        vm.stopBroadcast();

        require(address(adapter) == DeepCoreDeploy.predict(p.target), "adapter is not at the predicted address");
        require(address(adapter).code.length > 0, "adapter has no code");
        _requireOwnership(address(adapter), p.owner);
        require(adapter.sequencerUptimeFeed() == p.uptimeFeed, "sequencerUptimeFeed mismatch");
        require(adapter.sequencerGracePeriod() == p.gracePeriod, "sequencerGracePeriod mismatch");
        require(adapter.sequencerCheckEnabled() == (p.uptimeFeed != address(0)), "sequencerCheckEnabled mismatch");
        if (p.uptimeFeed != address(0)) {
            (bool enabled,,) = adapter.sequencerStatus();
            require(enabled, "sequencerStatus reports the check disabled");
        }

        console.log("ChainlinkPriceBandAdapter", address(adapter));
        console.log("  owner           ", adapter.owner());
        console.log("  sequencer check ", adapter.sequencerCheckEnabled());
        console.log("  runtime bytes   ", address(adapter).code.length);
    }
}
