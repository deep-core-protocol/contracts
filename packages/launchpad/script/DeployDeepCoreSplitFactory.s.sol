// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {DeepCoreSplit} from "../src/split/DeepCoreSplit.sol";
import {DeepCoreSplitFactory} from "../src/split/DeepCoreSplitFactory.sol";

/**
 * Deploys `DeepCoreSplitFactory` (and, inside its constructor, the `DeepCoreSplit` implementation), owned by the
 * governance Safe from birth, with the two revenue levers the owner decided (2026-09-19, "can we monetize
 * this"): a flat creation fee in native and a protocol share of each split's inflow.
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 *
 * The recipient (`PROTOCOL_RECIPIENT` is an immutable in the implementation's code, so every split this
 * factory ever makes pays its protocol share there), both caps and the notice. Only the two VALUES move, by
 * the Safe, inside the caps: decreases at once, increases after the notice, and a split keeps forever the
 * share it was born with.
 *
 * THE DECISION (owner, 2026-09-19): "fee $1 per split and .5% fee" - SPLIT_FEE_WEI is $1 of native,
 * SPLIT_SHARE_BPS = 50, caps 10x the fee and 100 bps. Asserted on every production chain.
 *
 * THE FEE. The contract stores wei; any dollar figure is converted OFF CHAIN, exactly as for the site fee
 * (DeployDeepCorePadFactory.s.sol): quote the native asset, SPLIT_FEE_WEI = round(usd / price, 3 s.f.) * 1e18,
 * SPLIT_FEE_CAP_WEI = 10 * SPLIT_FEE_WEI, record the quote source and time in the deploy log.
 *
 * THE SHARE. Basis points of everything that later flows through a split. The contract's hard ceiling is
 * 500 (5%); SPLIT_SHARE_CAP_BPS is this deployment's immutable cap at or below it.
 *
 * THE ADDRESS. CreateX `deployCreate3` at `DEEPCORE_SALT_DEEPCORE_SPLIT_FACTORY` - mined for the deployer,
 * chain-id free, the same on every chain (`ops/deploy/salts/README.md`). The `DeepCoreSplit` implementation is
 * the factory's own first CREATE, so it follows the factory and is the same on every chain too.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   SPLIT_OWNER_SAFE=<governance Safe> \
 *   SPLIT_FEE_WEI=<wei> SPLIT_FEE_CAP_WEI=<10x> SPLIT_SHARE_BPS=<bps> SPLIT_SHARE_CAP_BPS=<cap> \
 *   SPLIT_NOTICE_SECONDS=604800 forge script script/DeployDeepCoreSplitFactory.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreSplitFactoryScript is Script {
    uint32 internal constant MAINNET_NOTICE_SECONDS = 7 days;
    /// @dev Owner decision 2026-09-19 ("fee $1 per split and .5% fee"): 50 bps, immutable cap 100 bps.
    uint16 internal constant DECIDED_SHARE_BPS = 50;
    uint16 internal constant DECIDED_SHARE_CAP_BPS = 100;

    string internal constant LABEL = "DEEPCORE_SPLIT_FACTORY";

    struct Wiring {
        uint256 pk;
        /// The Safe: owner AND recipient.
        address safe;
        uint256 feeWei;
        uint256 feeCapWei;
        uint16 shareBps;
        uint16 shareCapBps;
        uint32 noticeSeconds;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreSplitFactory factory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        return runWith(
            Wiring({
                pk: pk,
                safe: vm.envAddress("SPLIT_OWNER_SAFE"),
                feeWei: vm.envUint("SPLIT_FEE_WEI"),
                feeCapWei: vm.envUint("SPLIT_FEE_CAP_WEI"),
                shareBps: uint16(vm.envUint("SPLIT_SHARE_BPS")),
                shareCapBps: uint16(vm.envUint("SPLIT_SHARE_CAP_BPS")),
                noticeSeconds: uint32(vm.envOr("SPLIT_NOTICE_SECONDS", uint256(MAINNET_NOTICE_SECONDS))),
                target: DeepCoreDeploy.fromEnv(LABEL, vm.addr(pk))
            })
        );
    }

    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreSplitFactory).creationCode,
            abi.encode(w.safe, w.safe, w.feeWei, w.feeCapWei, w.shareBps, w.shareCapBps, w.noticeSeconds)
        );
    }

    function runWith(Wiring memory w) public returns (DeepCoreSplitFactory factory) {
        preflight(w);

        bytes memory code = initCode(w);
        vm.startBroadcast(w.pk);
        factory = DeepCoreSplitFactory(DeepCoreDeploy.deploy(w.target, code, LABEL));
        vm.stopBroadcast();

        postflight(factory, w);

        console.log("=== DeepCoreSplitFactory ===");
        console.log("  chain id        ", block.chainid);
        console.log("  factory         ", address(factory), "(CREATE3 via CreateX: same on every chain)");
        console.log("  implementation  ", address(factory.IMPLEMENTATION()));
        console.log("  owner/recipient ", w.safe);
        console.log("  fee (wei)       ", w.feeWei);
        console.log("  fee cap (wei)   ", w.feeCapWei);
        console.log("  share (bps)     ", w.shareBps);
        console.log("  share cap (bps) ", w.shareCapBps);
        console.log("  notice (s)      ", w.noticeSeconds);
        console.log("  NEXT: record `splitFactory` in @deepcoreprotocol/sdk deployments, the fee quote source + time.");
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        address deployer = vm.addr(w.pk);
        require(w.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);

        // The owner's terms on a production chain (checked before ownership, so testable on their own).
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(w.noticeSeconds == MAINNET_NOTICE_SECONDS, "SPLIT_NOTICE_SECONDS is not 7 days on mainnet");
            require(w.shareBps == DECIDED_SHARE_BPS, "SPLIT_SHARE_BPS is not the decided 50 bps");
            require(w.shareCapBps == DECIDED_SHARE_CAP_BPS, "SPLIT_SHARE_CAP_BPS is not the decided 100 bps");
            require(w.feeWei > 0 && w.feeCapWei == w.feeWei * 10, "SPLIT_FEE_CAP_WEI must be 10x a non-zero SPLIT_FEE_WEI");
        }

        require(w.safe != address(0), "SPLIT_OWNER_SAFE unset");
        require(w.safe.code.length > 0, "SPLIT_OWNER_SAFE has no code - a Safe is a contract");
        require(w.safe != deployer, "SPLIT_OWNER_SAFE is the deployer");
        DeepCoreGovernance.requireGovernanceSafe(w.safe, deployer, "SPLIT_OWNER_SAFE");

        require(w.feeWei <= w.feeCapWei, "SPLIT_FEE_WEI above the cap");
        require(w.shareCapBps <= 500, "SPLIT_SHARE_CAP_BPS above the contract's 5% ceiling");
        require(w.shareBps <= w.shareCapBps, "SPLIT_SHARE_BPS above the cap");
        require(w.noticeSeconds >= 1 days && w.noticeSeconds <= 30 days, "SPLIT_NOTICE_SECONDS outside 1..30 days");
    }

    /// @notice Read back the deployed reality. Public so tests drive it.
    function postflight(DeepCoreSplitFactory factory, Wiring memory w) public {
        DeepCoreSplit impl = factory.IMPLEMENTATION();
        require(address(factory) == DeepCoreDeploy.predict(w.target), "factory is not at the predicted address");
        require(address(factory).code.length > 0 && address(factory).code.length <= 24_576, "factory code size");
        require(address(impl).code.length > 0 && address(impl).code.length <= 24_576, "implementation code size");
        require(impl.FACTORY() == address(factory), "implementation factory");
        require(impl.PROTOCOL_RECIPIENT() == w.safe, "implementation recipient");
        require(address(impl) == vm.computeCreateAddress(address(factory), 1), "implementation is not the factory's nonce-1 CREATE");
        require(factory.splitCount() == 0, "fresh factory");

        require(factory.owner() == w.safe, "owner is not the Safe");
        require(factory.pendingOwner() == address(0), "unexpected pending owner");
        require(factory.protocolFeeRecipient() == w.safe, "protocolFeeRecipient");
        require(factory.splitFeeWei() == w.feeWei, "splitFeeWei");
        require(factory.maxSplitFeeWei() == w.feeCapWei, "maxSplitFeeWei");
        require(factory.protocolShareBps() == w.shareBps, "protocolShareBps");
        require(factory.maxProtocolShareBps() == w.shareCapBps, "maxProtocolShareBps");
        require(factory.noticeSeconds() == w.noticeSeconds, "noticeSeconds");
        (uint256 pf, uint64 pfa) = factory.pendingSplitFee();
        (uint16 ps, uint64 psa) = factory.pendingProtocolShare();
        require(pf == 0 && pfa == 0 && ps == 0 && psa == 0, "born with a pending change");
        require(factory.protocolFeesOwed() == 0 && address(factory).balance == 0, "factory not empty");
        try factory.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}
        (bool accepted,) = address(factory).call{value: 0}("");
        require(!accepted, "factory accepted a plain call - it must have no fallback");
    }
}
