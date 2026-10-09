// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {ManualPriceBandOracle} from "../src/oracles/ManualPriceBandOracle.sol";
import {RwaReleaseBase} from "./RwaReleaseBase.sol";

/// @notice The two `TimelockController` reads that identify the custody tier.
interface ITimelockRead {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * Deploys `ManualPriceBandOracle` (CreateX label `MANUAL_PRICE_BAND_ORACLE`).
 *
 * ####################### OWNER: CUSTODY, NOT THE SAFE #######################
 *
 * The owner is EXEMPT from `maxPublisherDeviationBps` and can move any pool's reference, and with it
 * the band, arbitrarily. That is a price-manipulation key, so CLAUDE.md's ownership table puts it on
 * the 48 h custody timelock. On every production chain this script re-reads it before broadcast: a
 * timelock with at least a 48 h minimum delay and the governance Safe of record (`DeepCoreGovernance`;
 * refused while unset) holding `PROPOSER_ROLE`. Local and test chains take any contract that is not
 * the deployer.
 *
 * ####################### BORN WITH NO PUBLISHER, AND THAT IS THE SAFETY #######################
 *
 * The constructor sets `maxPublisherDeviationBps` to 1000 and leaves `minPublisherInterval` at 0. At
 * 0 the per-update bound can be walked across many transactions, so a live oracle MUST carry a
 * non-zero interval (CLAUDE.md, finding HIGH 2026-09-10). Here that is safe at birth for one reason:
 * the owner is born as custody, so no publisher can exist until custody adds one, and the SAME
 * custody batch sets the interval first. This script prints that batch (`setPublisherBounds`, then
 * `setPublisher`) and never sends it; the Safe queues it when a stock pool first needs a manual
 * reference. `RWA_PUBLISHER_INTERVAL_SECONDS` must be non-zero or nothing is printed.
 * The deployer never owns the oracle, not for one block, so there is no ownership transfer to accept.
 *
 * Env: PRIVATE_KEY | DEPLOYER, the MANUAL_PRICE_BAND_ORACLE salt pair, RWA_CUSTODY_OWNER,
 *      RWA_PUBLISHER (Ops), RWA_PUBLISHER_INTERVAL_SECONDS (non-zero; 3600 suggested).
 */
contract DeployManualPriceBandOracleScript is RwaReleaseBase {
    string internal constant LABEL = "MANUAL_PRICE_BAND_ORACLE";

    uint256 internal constant CUSTODY_MIN_DELAY = 48 hours;
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    uint256 internal constant EXPECTED_DEFAULT_DEVIATION_BPS = 1000;

    struct Params {
        Signer signer;
        address owner;
        address publisher;
        uint64 publisherInterval;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (ManualPriceBandOracle oracle) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        Signer memory s = _signerFromEnv();
        uint256 interval = vm.envUint("RWA_PUBLISHER_INTERVAL_SECONDS");
        require(interval <= type(uint64).max, "RWA_PUBLISHER_INTERVAL_SECONDS overflows uint64");
        return runWith(
            Params({
                signer: s,
                owner: vm.envAddress("RWA_CUSTODY_OWNER"),
                publisher: vm.envAddress("RWA_PUBLISHER"),
                publisherInterval: uint64(interval),
                target: DeepCoreDeploy.fromEnv(LABEL, s.deployer)
            })
        );
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(type(ManualPriceBandOracle).creationCode, abi.encode(p.owner));
    }

    /// @notice The custody rule above. Public so a test can drive it without a deploy.
    function checkCustodyOwner(address owner_, address deployer) public view {
        require(owner_ != address(0), "RWA_CUSTODY_OWNER is unset");
        require(owner_.code.length > 0, "RWA_CUSTODY_OWNER has no code - the custody timelock, not an EOA");
        require(owner_ != deployer, "RWA_CUSTODY_OWNER is the deployer");
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(ITimelockRead(owner_).getMinDelay() >= CUSTODY_MIN_DELAY, "RWA_CUSTODY_OWNER delay is under 48 h");
            require(DeepCoreGovernance.SAFE != address(0), "DeepCoreGovernance: governance Safe of record is not set");
            require(
                ITimelockRead(owner_).hasRole(PROPOSER_ROLE, DeepCoreGovernance.SAFE),
                "the Safe of record is not a proposer on RWA_CUSTODY_OWNER"
            );
        }
    }

    function runWith(Params memory p) public returns (ManualPriceBandOracle oracle) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        checkCustodyOwner(p.owner, deployer);
        require(p.publisherInterval != 0, "RWA_PUBLISHER_INTERVAL_SECONDS must be non-zero on a live oracle");
        require(p.publisher != address(0), "RWA_PUBLISHER is unset");
        require(p.publisher != p.owner, "RWA_PUBLISHER is the owner, who is exempt from every bound");

        console.log("=== ManualPriceBandOracle ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Custody) ", p.owner);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        oracle = ManualPriceBandOracle(DeepCoreDeploy.deploy(p.target, code, LABEL));
        vm.stopBroadcast();

        require(address(oracle) == DeepCoreDeploy.predict(p.target), "oracle is not at the predicted address");
        require(address(oracle).code.length > 0, "oracle has no code");
        _requireOwnership(address(oracle), p.owner);
        require(oracle.maxPublisherDeviationBps() == EXPECTED_DEFAULT_DEVIATION_BPS, "maxPublisherDeviationBps is not 1000");
        require(!oracle.isPublisher(deployer), "the deployer is a publisher at birth");
        require(!oracle.isPublisher(p.publisher), "RWA_PUBLISHER is a publisher at birth");

        console.log("ManualPriceBandOracle", address(oracle));
        console.log("  owner           ", oracle.owner());
        console.log("  runtime bytes   ", address(oracle).code.length);
        console.log("");
        console.log("Custody batch, NOT sent: queue it on the custody timelock when a stock pool first needs a");
        console.log("manual reference. The interval comes first so no publisher ever exists without it.");
        console.log("  target          ", address(oracle));
        console.log("  call 1: setPublisherBounds(1000, interval)");
        console.logBytes(abi.encodeCall(ManualPriceBandOracle.setPublisherBounds, (EXPECTED_DEFAULT_DEVIATION_BPS, p.publisherInterval)));
        console.log("  call 2: setPublisher(publisher, true)", p.publisher);
        console.logBytes(abi.encodeCall(ManualPriceBandOracle.setPublisher, (p.publisher, true)));
    }
}
