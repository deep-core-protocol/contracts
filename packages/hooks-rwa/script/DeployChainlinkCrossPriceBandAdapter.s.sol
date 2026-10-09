// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {ChainlinkCrossPriceBandAdapter} from "../src/oracles/ChainlinkCrossPriceBandAdapter.sol";
import {RwaReleaseBase, IUptimeFeedRead} from "./RwaReleaseBase.sol";

/**
 * Deploys `ChainlinkCrossPriceBandAdapter` (CreateX label 34, `CHAINLINK_CROSS_PRICE_BAND_ADAPTER`): the
 * two-feed adapter for a stock pool whose quote is not worth a dollar, such as one paired with the
 * chain's native currency. Reference = (stock / USD) / (quote / USD).
 *
 * OWNER: THE SAFE, for the reason the one-feed adapter's script gives: `configureFeed` accepts any
 * contract that answers `decimals()`, so the owner chooses what prices a pool; the same Safe already
 * owns every consuming hook and can repoint a pool's oracle in one transaction, so a delay here would
 * bound nothing. If the hooks ever move to Custody, this adapter moves with them.
 *
 * THE SEQUENCER-UPTIME FEED IS IMMUTABLE, and the per-chain policy is `RwaReleaseBase.sequencerPolicyFor`:
 * a production chain with no row there is refused.
 *
 * Env: PRIVATE_KEY | DEPLOYER, the CHAINLINK_CROSS_PRICE_BAND_ADAPTER salt pair, RWA_OWNER,
 *      RWA_SEQUENCER_UPTIME_FEED (0x0 for none), RWA_SEQUENCER_GRACE_SECONDS (0 when there is no feed).
 */
contract DeployChainlinkCrossPriceBandAdapterScript is RwaReleaseBase {
    string internal constant LABEL = "CHAINLINK_CROSS_PRICE_BAND_ADAPTER";

    struct Params {
        Signer signer;
        address owner;
        address uptimeFeed;
        uint32 gracePeriod;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (ChainlinkCrossPriceBandAdapter adapter) {
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
            type(ChainlinkCrossPriceBandAdapter).creationCode, abi.encode(p.uptimeFeed, p.gracePeriod, p.owner)
        );
    }

    /// @notice The per-chain sequencer policy (`RwaReleaseBase`). Public so a test can drive it without a deploy.
    function checkSequencerPolicy(address uptimeFeed, uint32 gracePeriod) public view {
        _checkSequencerPolicy(uptimeFeed, gracePeriod);
    }

    function runWith(Params memory p) public returns (ChainlinkCrossPriceBandAdapter adapter) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        _requireOwner(p.owner, deployer);
        checkSequencerPolicy(p.uptimeFeed, p.gracePeriod);

        console.log("=== ChainlinkCrossPriceBandAdapter ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Safe)    ", p.owner);
        console.log("  uptime feed     ", p.uptimeFeed);
        console.log("  grace, s        ", p.gracePeriod);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        adapter = ChainlinkCrossPriceBandAdapter(DeepCoreDeploy.deploy(p.target, code, LABEL));
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

        console.log("ChainlinkCrossPriceBandAdapter", address(adapter));
        console.log("  owner           ", adapter.owner());
        console.log("  sequencer check ", adapter.sequencerCheckEnabled());
        console.log("  runtime bytes   ", address(adapter).code.length);
    }
}
