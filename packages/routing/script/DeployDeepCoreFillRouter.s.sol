// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {DeepCoreFillRouter} from "../src/DeepCoreFillRouter.sol";
import {DeepCoreFillExecutor} from "../src/DeepCoreFillExecutor.sol";

/**
 * Deploys `DeepCoreFillRouter` (and, inside its constructor, its `DeepCoreFillExecutor`) owned by the
 * governance Safe from birth, charging the routed-fill fee the owner decided (2026-09-20: "10 bps on
 * a routed fill, 0 on a DeepCore pool, the same on every chain").
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 *
 * `protocolFeeRecipient`, `WNATIVE`, `maxFeeBps`, `feeNoticeSeconds` and `EXECUTOR` are immutables.
 * Only the fee VALUE moves, inside the cap, by the Safe: decreases at once, increases after the
 * notice. A fee exemption, once granted, is permanent. Nothing here can be patched - a change to the
 * fill logic is a new address and a re-approval by every user.
 *
 * THE FEE IS THE SAME ON EVERY CHAIN, on purpose: one value, not per chain, which only creates drift
 * nobody notices. `ROUTING_FEE_BPS` is 15 (owner, 2026-09-26: "i want .15% fee") and `ROUTING_FEE_CAP_BPS` is 50 unless the Safe has decided
 * otherwise; the contract's own ceiling on the cap is `ABSOLUTE_MAX_FEE_BPS` (100 = 1%).
 *
 * THE SAME ADDRESS ON EVERY CHAIN, by the same mechanism every other DeepCore release contract uses:
 * CreateX CREATE3 with a PERMISSIONED, CROSS-CHAIN salt (`<deployer, 20 bytes> ++ 0x00 ++ 11 mined
 * bytes`). The address is a function of (CreateX, deployer, salt) ALONE, so the per-chain constructor
 * arguments - the wrapped-native address in particular - do not move it. The executor is the router's
 * own first CREATE (nonce 1), so it follows the router and is identical across chains too.
 *
 * THE DEPLOYMENT-RULE TRAP, 2026-09-19: a contract deployed through a script whose compilation unit
 * includes a contract with `compilation_restrictions` gets DIFFERENT BYTECODE AT THE SAME ADDRESS.
 * This package carries no compilation restrictions and this script imports nothing that does, but the
 * rule stands: deploy this contract from THIS script and verify with `--compilation-profile default`.
 *
 * OWNERSHIP: the Safe from birth; never the deployer (asserted). The owner's only powers are
 * `setFeeBps` inside the immutable cap, `cancelPendingFee` and `exemptVenue`; there is no pause, no
 * allowlist and no path to a user's funds. `renounceOwnership` reverts, which this script proves by
 * reading it back rather than by trusting the source.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   ROUTING_FEE_RECIPIENT=0x<safe> ROUTING_WRAPPED_NATIVE=0x<wnative or 0x0> \
 *   ROUTING_FEE_BPS=15 ROUTING_FEE_CAP_BPS=50 ROUTING_FEE_NOTICE_SECONDS=604800 \
 *   forge script script/DeployDeepCoreFillRouter.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreFillRouterScript is Script {
    /// @dev The owner's decisions (2026-09-20; fee raised to 15 bps 2026-09-26). Defaults, not constants in the contract.
    uint16 internal constant DEFAULT_FEE_BPS = 15;
    uint16 internal constant DEFAULT_CAP_BPS = 50;
    uint32 internal constant MAINNET_NOTICE_SECONDS = 7 days;

    string internal constant LABEL = "DEEPCORE_FILL_ROUTER";

    struct Wiring {
        uint256 pk;
        /// The Safe: owner AND fee recipient. One address, both roles.
        address safe;
        address wrappedNative;
        uint16 feeBps;
        uint16 capBps;
        uint32 noticeSeconds;
        /// DeepCore's own router on this chain, fee-exempt from birth. Zero is allowed and means
        /// nothing is exempt yet; it is a decision the runbook must record either way.
        address deepcoreVenue;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreFillRouter router) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Wiring memory w = Wiring({
            pk: pk,
            safe: vm.envAddress("ROUTING_FEE_RECIPIENT"),
            wrappedNative: vm.envOr("ROUTING_WRAPPED_NATIVE", address(0)),
            feeBps: uint16(vm.envOr("ROUTING_FEE_BPS", uint256(DEFAULT_FEE_BPS))),
            capBps: uint16(vm.envOr("ROUTING_FEE_CAP_BPS", uint256(DEFAULT_CAP_BPS))),
            noticeSeconds: uint32(vm.envOr("ROUTING_FEE_NOTICE_SECONDS", uint256(MAINNET_NOTICE_SECONDS))),
            deepcoreVenue: vm.envOr("ROUTING_DEEPCORE_VENUE", address(0)),
            target: DeepCoreDeploy.fromEnv(LABEL, deployer)
        });
        return runWith(w);
    }

    /// @dev Split out so a test can drive the whole thing without the environment.
    function runWith(Wiring memory w) public returns (DeepCoreFillRouter router) {
        address deployer = vm.addr(w.pk);
        _checkBefore(w, deployer);

        bytes memory initCode = abi.encodePacked(
            type(DeepCoreFillRouter).creationCode,
            abi.encode(w.safe, w.safe, w.wrappedNative, w.feeBps, w.capBps, w.noticeSeconds, w.deepcoreVenue)
        );

        vm.startBroadcast(w.pk);
        router = DeepCoreFillRouter(payable(DeepCoreDeploy.deploy(w.target, initCode, LABEL)));
        vm.stopBroadcast();

        _checkAfter(w, router, deployer);

        console2.log("DeepCoreFillRouter   ", address(router));
        console2.log("DeepCoreFillExecutor ", address(router.EXECUTOR()));
        console2.log("owner / recipient ", w.safe);
        console2.log("feeBps / cap      ", w.feeBps, w.capBps);
        console2.log("notice (seconds)  ", w.noticeSeconds);
        console2.log("wrapped native    ", w.wrappedNative);
        console2.log("exempt venue      ", w.deepcoreVenue);
    }

    /*//////////////////////////////////////////////////////////////
                              ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    function _checkBefore(Wiring memory w, address deployer) internal view {
        require(w.safe != address(0), "ROUTING_FEE_RECIPIENT is zero");
        require(w.safe != deployer, "the owner must never be the deployer");
        require(w.safe.code.length > 0, "the owner must be a contract (the governance Safe), not an EOA");
        // EVERY production chain — see DeepCoreGovernance. This router holds user funds
        // mid-swap and its owner sets the fee, so "some contract that is not the deployer" was never
        // a strong enough check anywhere the money is real.
        DeepCoreGovernance.requireGovernanceSafe(w.safe, deployer, "ROUTER_OWNER_SAFE");
        require(w.capBps != 0, "a zero cap would make the fee unraisable forever");
        require(w.capBps <= 100, "the cap is above the contract ceiling ABSOLUTE_MAX_FEE_BPS");
        require(w.feeBps <= w.capBps, "the initial fee is above the cap");
        require(
            w.noticeSeconds >= 1 days && w.noticeSeconds <= 30 days, "the notice is outside the contract's bounds"
        );
        // Zero is legitimate (the router simply refuses to wrap on that chain), but it must be a
        // decision rather than a forgotten variable, so a non-zero value is checked for code.
        require(
            w.wrappedNative == address(0) || w.wrappedNative.code.length > 0,
            "ROUTING_WRAPPED_NATIVE has no code on this chain"
        );
        // An exemption is permanent, so a typo here is permanent. It must at least be a contract.
        require(
            w.deepcoreVenue == address(0) || w.deepcoreVenue.code.length > 0,
            "ROUTING_DEEPCORE_VENUE has no code on this chain"
        );
        require(w.deepcoreVenue != w.safe, "the Safe is not a venue");
        DeepCoreDeploy.preflight(w.target, LABEL);
    }

    function _checkAfter(Wiring memory w, DeepCoreFillRouter router, address deployer) internal view {
        require(router.owner() == w.safe, "owner is not the Safe");
        require(router.pendingOwner() == address(0), "an ownership transfer is pending: it should not be");
        require(router.owner() != deployer, "the deployer owns the router");
        require(router.protocolFeeRecipient() == w.safe, "fee recipient is not the Safe");
        require(router.WNATIVE() == w.wrappedNative, "wrapped native is not what was configured");
        require(router.feeBps() == w.feeBps, "the fee in force is not what was configured");
        require(router.maxFeeBps() == w.capBps, "the cap is not what was configured");
        require(router.feeNoticeSeconds() == w.noticeSeconds, "the notice is not what was configured");
        (uint16 pendingBps, uint64 at) = router.pendingFee();
        require(pendingBps == 0 && at == 0, "a fee increase is already scheduled at birth");

        require(
            w.deepcoreVenue == address(0) || router.isFeeExempt(w.deepcoreVenue),
            "DeepCore's own router is not fee-exempt: a DeepCore pool would be charged"
        );

        DeepCoreFillExecutor executor = router.EXECUTOR();
        require(address(executor) != address(0), "no executor");
        require(executor.ROUTER() == address(router), "the executor is bound to another router");
        require(executor.protocolFeeRecipient() == w.safe, "the executor would sweep strays elsewhere");
        require(address(executor) != address(router), "the executor must be a separate contract");

        // Read the refusal back rather than trusting the source: an owner that could renounce would
        // freeze the fee where it stands forever.
        (bool ok,) = address(router).staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!ok, "renounceOwnership did not revert");
    }
}
