// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";

import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {ILaunchpadKitV2} from "../src/interfaces/ILaunchpadKitV2.sol";
import {DeepCorePad} from "../src/pad/DeepCorePad.sol";
import {DeepCorePadFactory} from "../src/pad/DeepCorePadFactory.sol";

/**
 * Deploys `DeepCorePadFactory` (and, inside its constructor, the `DeepCorePad` implementation) bound to an
 * EXISTING `LaunchpadKitV2`, owned by the governance Safe from birth, charging the site fee the owner
 * decided (2026-09-18: "$10 per chain for dex and launchpad, to Safe wallet").
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 *
 * The kit binding. `KIT` is an immutable in the implementation's code, shared by every clone the factory
 * ever makes, so a factory pointed at the wrong kit creates pads that are tenants of the wrong kit,
 * forever. The fee recipient, the fee cap and the notice are immutables too. Only the fee VALUE moves,
 * inside the cap, by the Safe: decreases at once, increases after the notice.
 *
 * THE $10. The contract stores wei; the dollar figure is converted OFF CHAIN when the value is set:
 *   1. Quote the chain's native asset in USD at that moment (HYPE on HyperEVM, ETH on an ETH chain, ...; on a chain whose native IS a dollar - Arc, Stable - the fee is 10e18).
 *   2. PAD_FEE_WEI = round(10 / price, 3 significant figures) * 1e18.
 *   3. PAD_FEE_CAP_WEI = 10 * PAD_FEE_WEI: a $100-equivalent ceiling, immutable.
 *   4. Record the quote source and time in the deploy log. Re-price later with `setPadFee` from the Safe.
 * The per-chain table lives in ops/deploy/mainnet-release.md (§5). Nothing here holds a price.
 *
 * THE SAME ADDRESS ON EVERY CHAIN (owner decision 2026-09-19: a Launchpad / DEX is multi-chain and keeps one
 * address; extended 2026-09-20 to every release contract, at `0x7878…78`). The factory is deployed through
 * CreateX's CREATE3 (`0xba5Ed099...ba5Ed`, permissionless, same address and same runtime code on every chain
 * it is deployed to; `DeepCoreDeploy` checks its code hash before use) with a PERMISSIONED, CROSS-CHAIN salt:
 * `DEEPCORE_SALT_DEEPCORE_PAD_FACTORY_QF = <deployer, 20 bytes> ++ 0x00 ++ <11 mined bytes>`. Only that deployer can
 * use the salt (nobody can take the factory's address on a chain DeepCore has not reached), and no chain id is
 * mixed in, so the factory address is a function of (CreateX, deployer, salt) ALONE - the constructor
 * arguments (kit, fee, cap, notice), which differ per chain, do not move it. The implementation is the
 * factory's first CREATE, so it follows. Therefore:
 *   - use the SAME deployer key and the SAME salts file on every chain (`ops/deploy/salts/README.md`);
 *   - `DEEPCORE_ADDRESS_DEEPCORE_PAD_FACTORY_QF` is the address the mine predicts; every chain refuses to
 *     broadcast unless it predicts exactly that address;
 *   - a chain where the predicted address already has code is refused (never "reuse whatever is there").
 * The deployer key therefore matters AFTER deployment too: it is the only key that can open the DeepCore factory
 * address on a NEW chain. It holds no power over any deployed factory. Keep it off the shared VPS.
 *
 * OWNERSHIP: the Safe from birth; never the deployer (asserted). Recorded in CLAUDE.md's Ownership table
 * (`DeepCorePadFactory` owner -> Safe, fee only, inside an immutable cap). The owner cannot gate who may create
 * a pad, touch a pad or a pad's terms; the script proves the absence of any such path by reading back.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   LAUNCHPAD_KIT_V2=0x... PAD_FEE_RECIPIENT=<governance Safe> \
 *   PAD_FEE_WEI=<10 USD in wei> PAD_FEE_CAP_WEI=<10x> PAD_FEE_NOTICE_SECONDS=604800 \
 *   forge script script/DeployDeepCorePadFactory.s.sol --rpc-url $RPC
 */
contract DeployDeepCorePadFactoryScript is DeepCoreSignerScript {
    /// @dev The owner-decided notice on increases on a production chain: the kit's, seven days.
    uint32 internal constant MAINNET_NOTICE_SECONDS = 7 days;

    string internal constant LABEL = "DEEPCORE_PAD_FACTORY_QF";

    struct Wiring {
        uint256 pk;
        address kit;
        /// The Safe: owner AND fee recipient. One address, both roles, asserted equal to the Safe of record on every production chain.
        address safe;
        uint256 padFeeWei;
        uint256 padFeeCapWei;
        uint32 padFeeNoticeSeconds;
        /// The mined CreateX salt and the address it must land on, the same on every chain.
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCorePadFactory factory) {
        uint256 pk = _pkFromEnv();
        return runWith(
            Wiring({
                pk: pk,
                kit: vm.envAddress("LAUNCHPAD_KIT_V2"),
                safe: vm.envAddress("PAD_FEE_RECIPIENT"),
                padFeeWei: vm.envUint("PAD_FEE_WEI"),
                padFeeCapWei: vm.envUint("PAD_FEE_CAP_WEI"),
                padFeeNoticeSeconds: uint32(vm.envOr("PAD_FEE_NOTICE_SECONDS", uint256(MAINNET_NOTICE_SECONDS))),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    /// @notice Where this wiring deploys the factory: a function of (CreateX, deployer, salt) only.
    function predictFactory(Wiring memory w) public pure returns (address) {
        return DeepCoreDeploy.predict(w.target);
    }

    /// @notice The factory's creation code with this chain's constructor arguments. Changes per chain; the
    /// address does not.
    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCorePadFactory).creationCode,
            abi.encode(ILaunchpadKitV2(w.kit), w.safe, w.safe, w.padFeeWei, w.padFeeCapWei, w.padFeeNoticeSeconds)
        );
    }

    function runWith(Wiring memory w) public returns (DeepCorePadFactory factory) {
        preflight(w);

        bytes memory code = initCode(w);
        _startBroadcastAs(w.pk);
        factory = DeepCorePadFactory(DeepCoreDeploy.deploy(w.target, code, LABEL));
        vm.stopBroadcast();

        postflight(factory, w);

        console.log("=== DeepCorePadFactory ===");
        console.log("  chain id       ", block.chainid);
        console.log("  factory        ", address(factory), "(CREATE3 via CreateX: same on every chain for this deployer + salt)");
        console.log("  deployer       ", _signerOf(w.pk));
        console.log("  salt");
        console.logBytes32(w.target.salt);
        console.log("  implementation ", address(factory.IMPLEMENTATION()));
        console.log("  kit            ", w.kit);
        console.log("  owner / fee to ", w.safe);
        console.log("  site fee (wei) ", w.padFeeWei);
        console.log("  fee cap (wei)  ", w.padFeeCapWei);
        console.log("  notice (s)     ", w.padFeeNoticeSeconds);
        console.log("  Owner = the Safe, fee only. No pause, no allowlist, no upgrade. Nothing to transfer.");
        console.log("  NEXT: record the factory in @deepcoreprotocol/sdk deployments (launchpadV2.padFactory),");
        console.log("        the quote source + time behind PAD_FEE_WEI in the deploy log, and the keeper's padFactory.");
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        address deployer = _signerOf(w.pk);

        // ---- the deterministic deployer and the address: the multi-chain identity ----
        require(w.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);

        require(w.kit.code.length > 0, "LAUNCHPAD_KIT_V2 has no code");
        // A kit answers these; anything else is not a LaunchpadKitV2 and must not be bound forever.
        require(ILaunchpadKitV2(w.kit).launchFeeWei() <= 1 ether, "LAUNCHPAD_KIT_V2 does not answer launchFeeWei()");
        (bool ok, bytes memory ret) = w.kit.staticcall(abi.encodeWithSignature("CLOCK_MODE()"));
        require(ok && ret.length > 0, "LAUNCHPAD_KIT_V2 does not answer CLOCK_MODE()");
        string memory mode = abi.decode(ret, (string));
        require(keccak256(bytes(mode)) == keccak256("mode=timestamp"), "LAUNCHPAD_KIT_V2 is not the timestamp kit");

        // ---- the owner's terms on a production chain (checked before ownership, so testable on its own) ----
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(w.padFeeNoticeSeconds == MAINNET_NOTICE_SECONDS, "PAD_FEE_NOTICE_SECONDS is not 7 days on mainnet");
        }

        // ---- ownership and recipient: the Safe from birth, and the same Safe the kit pays ----
        require(w.safe != address(0), "PAD_FEE_RECIPIENT unset");
        require(w.safe.code.length > 0, "PAD_FEE_RECIPIENT has no code - a Safe is a contract");
        require(w.safe != deployer, "PAD_FEE_RECIPIENT is the deployer");
        DeepCoreGovernance.requireGovernanceSafe(w.safe, deployer, "PAD_FEE_RECIPIENT");
        (bool okR, bytes memory retR) = w.kit.staticcall(abi.encodeWithSignature("protocolFeeRecipient()"));
        require(okR && retR.length == 32 && abi.decode(retR, (address)) == w.safe, "the kit pays a different recipient");

        // ---- fees: the owner's numbers ----
        require(w.padFeeCapWei > 0, "PAD_FEE_CAP_WEI is zero - the owner could never charge");
        require(w.padFeeWei <= w.padFeeCapWei, "PAD_FEE_WEI above the cap");
        // No upper sanity bound on the cap: "$100" is 0.03 ETH on one chain and thousands of a cheap native on
        // another. The table in the runbook is the check; the simulation prints the numbers for a human.
        require(
            w.padFeeNoticeSeconds >= 1 days && w.padFeeNoticeSeconds <= 30 days,
            "PAD_FEE_NOTICE_SECONDS outside 1..30 days"
        );
    }

    /// @notice Read back the deployed reality. Public so tests drive it.
    function postflight(DeepCorePadFactory factory, Wiring memory w) public {
        DeepCorePad impl = factory.IMPLEMENTATION();
        require(address(factory).code.length > 0 && address(factory).code.length <= 24_576, "factory code size");
        require(address(factory.KIT()) == w.kit, "factory kit");
        require(address(impl.KIT()) == w.kit, "implementation kit");
        require(impl.FACTORY() == address(factory), "implementation factory");
        require(impl.owner() == address(0xdead), "implementation must be locked");
        // The implementation is the factory's first CREATE, so it too is the same on every chain.
        require(address(impl) == vm.computeCreateAddress(address(factory), 1), "implementation is not the factory's nonce-1 CREATE");
        require(address(factory) == predictFactory(w), "factory is not at the predicted address");
        // A pad address is a pure function of (factory, creator, salt): same inputs, same answer.
        address probe = factory.predictPad(w.safe, bytes32(0));
        require(probe != address(0) && probe.code.length == 0 && !factory.isPad(probe), "predictPad sanity");
        require(factory.padCount() == 0, "fresh factory");

        require(factory.owner() == w.safe, "owner is not the Safe");
        require(factory.pendingOwner() == address(0), "unexpected pending owner");
        require(factory.protocolFeeRecipient() == w.safe, "protocolFeeRecipient");
        require(factory.padFeeWei() == w.padFeeWei, "padFeeWei");
        require(factory.maxPadFeeWei() == w.padFeeCapWei, "maxPadFeeWei");
        require(factory.padFeeNoticeSeconds() == w.padFeeNoticeSeconds, "padFeeNoticeSeconds");
        (uint256 pendingWei, uint64 pendingAt) = factory.pendingPadFee();
        require(pendingWei == 0 && pendingAt == 0, "born with a pending fee change");
        require(factory.protocolFeesOwed() == 0 && address(factory).balance == 0, "factory not empty");
        try factory.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}
        // No receive / fallback: a plain transfer must fail, so the only way in is createPad's value.
        (bool accepted,) = address(factory).call{value: 0}("");
        require(!accepted, "factory accepted a plain call - it must have no fallback");
    }
}
