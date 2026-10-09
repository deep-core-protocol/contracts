// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {DeepCoreFeeGate} from "../src/fees/DeepCoreFeeGate.sol";
import {DeepCorePositionLock} from "../src/lock/DeepCorePositionLock.sol";
import {DeepCoreTokenLock} from "../src/lock/DeepCoreTokenLock.sol";
import {DeepCoreMultisend} from "../src/drop/DeepCoreMultisend.sol";
import {DeepCoreDropFactory} from "../src/drop/DeepCoreDropFactory.sol";

/**
 * Deploys the four fee-gated utilities: `DeepCorePositionLock` (CL liquidity locks), `DeepCoreTokenLock` (token locks and
 * vesting), `DeepCoreMultisend` and `DeepCoreDropFactory` (Merkle airdrops), each owned by the governance Safe from birth
 * and each at its OWN mined CreateX salt - four contracts, four salts, four `0x7878…78` addresses that are the
 * same on every chain (`ops/deploy/salts/README.md`).
 *
 * THE PRICE (owner decision 2026-09-19): "25% cheaper than classic.multisender.app". The classic multisender
 * contract charges 0.1 ETH per multisend transaction on Ethereum (`fee()` read on chain, 2026-09-19); ours is
 * 0.075 ETH-equivalent per action (a multisend, a drop, a lock), converted to the chain's native at deploy time
 * exactly as the site fee is (round to 3 s.f. of `0.075 * ETH_USD / NATIVE_USD`; on an ETH-native chain it is
 * 75000000000000000 wei). UTIL_FEE_CAP_WEI = 10 x the fee, immutable. Notice 7 days on every production chain.
 *
 * The fee is charged by the contracts, so a developer who uses them through the MIT SDK, their own code or an
 * explorer pays it too; only a fork that deploys its own contracts pays nothing (the GPL permits that).
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   UTIL_OWNER_SAFE=<governance Safe> CL_POSITION_MANAGER=0x... \
 *   UTIL_FEE_WEI=<0.075 ETH-equivalent in native wei> UTIL_FEE_CAP_WEI=<10x> UTIL_NOTICE_SECONDS=604800 \
 *   forge script script/DeployDeepCoreUtilities.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreUtilitiesScript is Script {
    uint32 internal constant MAINNET_NOTICE_SECONDS = 7 days;

    string internal constant POSITION_LOCK_LABEL = "DEEPCORE_POSITION_LOCK";
    string internal constant TOKEN_LOCK_LABEL = "DEEPCORE_TOKEN_LOCK";
    string internal constant MULTISEND_LABEL = "DEEPCORE_MULTISEND";
    string internal constant DROP_FACTORY_LABEL = "DEEPCORE_DROP_FACTORY";

    struct Wiring {
        uint256 pk;
        address safe;
        address positionManager;
        uint256 feeWei;
        uint256 feeCapWei;
        uint32 noticeSeconds;
        DeepCoreDeploy.Target positionLockTarget;
        DeepCoreDeploy.Target tokenLockTarget;
        DeepCoreDeploy.Target multisendTarget;
        DeepCoreDeploy.Target dropFactoryTarget;
    }

    struct Deployed {
        DeepCorePositionLock positionLock;
        DeepCoreTokenLock tokenLock;
        DeepCoreMultisend multisend;
        DeepCoreDropFactory dropFactory;
    }

    function run() public returns (Deployed memory d) {
        return runWith(_envWiring());
    }

    /// @dev The environment read in one place. Also keeps `run` down to a single call: building this
    /// ten-field literal inside `run` put via-IR one slot too deep once four salt targets joined it
    /// ("Variable var_d_mpos is 1 too deep in the stack").
    function _envWiring() private view returns (Wiring memory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        return Wiring({
            pk: pk,
            safe: vm.envAddress("UTIL_OWNER_SAFE"),
            positionManager: vm.envAddress("CL_POSITION_MANAGER"),
            feeWei: vm.envUint("UTIL_FEE_WEI"),
            feeCapWei: vm.envUint("UTIL_FEE_CAP_WEI"),
            noticeSeconds: uint32(vm.envOr("UTIL_NOTICE_SECONDS", uint256(MAINNET_NOTICE_SECONDS))),
            positionLockTarget: DeepCoreDeploy.fromEnv(POSITION_LOCK_LABEL, deployer),
            tokenLockTarget: DeepCoreDeploy.fromEnv(TOKEN_LOCK_LABEL, deployer),
            multisendTarget: DeepCoreDeploy.fromEnv(MULTISEND_LABEL, deployer),
            dropFactoryTarget: DeepCoreDeploy.fromEnv(DROP_FACTORY_LABEL, deployer)
        });
    }

    function runWith(Wiring memory w) public returns (Deployed memory d) {
        preflight(w);
        d = _deployAll(w);
        _postflight(d, w);
    }

    /// @dev The four deployments and the broadcast window. Kept out of `runWith`, one helper per
    /// contract, each returning a single address: holding the four creation blobs - or even four
    /// two-argument helper calls - alongside `d` and `w` put via-IR one slot too deep ("Variable
    /// var_d_mpos is 1 too deep in the stack").
    function _deployAll(Wiring memory w) private returns (Deployed memory d) {
        vm.startBroadcast(w.pk);
        d.positionLock = DeepCorePositionLock(payable(_deployPositionLock(w)));
        d.tokenLock = DeepCoreTokenLock(payable(_deployTokenLock(w)));
        d.multisend = DeepCoreMultisend(payable(_deployMultisend(w)));
        d.dropFactory = DeepCoreDropFactory(payable(_deployDropFactory(w)));
        vm.stopBroadcast();
    }

    /// @dev `DeepCorePositionLock` alone takes the position manager ahead of the shared fee-gate arguments.
    function _deployPositionLock(Wiring memory w) private returns (address) {
        bytes memory code = abi.encodePacked(
            type(DeepCorePositionLock).creationCode,
            abi.encode(ICLPositionManager(w.positionManager), w.safe, w.safe, w.feeWei, w.feeCapWei, w.noticeSeconds)
        );
        return DeepCoreDeploy.deploy(w.positionLockTarget, code, POSITION_LOCK_LABEL);
    }

    function _deployTokenLock(Wiring memory w) private returns (address) {
        return DeepCoreDeploy.deploy(w.tokenLockTarget, _gateCode(type(DeepCoreTokenLock).creationCode, w), TOKEN_LOCK_LABEL);
    }

    function _deployMultisend(Wiring memory w) private returns (address) {
        return DeepCoreDeploy.deploy(w.multisendTarget, _gateCode(type(DeepCoreMultisend).creationCode, w), MULTISEND_LABEL);
    }

    function _deployDropFactory(Wiring memory w) private returns (address) {
        return DeepCoreDeploy.deploy(w.dropFactoryTarget, _gateCode(type(DeepCoreDropFactory).creationCode, w), DROP_FACTORY_LABEL);
    }

    /// @dev The three `DeepCoreFeeGate`-only utilities share one constructor shape.
    function _gateCode(bytes memory creationCode, Wiring memory w) private pure returns (bytes memory) {
        return abi.encodePacked(creationCode, abi.encode(w.safe, w.safe, w.feeWei, w.feeCapWei, w.noticeSeconds));
    }

    /// @dev Split up for the same stack reason as `runWith`.
    function _postflight(Deployed memory d, Wiring memory w) private {
        _predicted(d, w);
        _postEach(d, w);
        _postShared(d, w.positionManager);
        _log(d, w);
    }

    function _postEach(Deployed memory d, Wiring memory w) private {
        _post(address(d.positionLock), w);
        _post(address(d.tokenLock), w);
        _post(address(d.multisend), w);
        _post(address(d.dropFactory), w);
    }

    function _predicted(Deployed memory d, Wiring memory w) private pure {
        require(address(d.positionLock) == DeepCoreDeploy.predict(w.positionLockTarget), "positionLock address");
        require(address(d.tokenLock) == DeepCoreDeploy.predict(w.tokenLockTarget), "tokenLock address");
        require(address(d.multisend) == DeepCoreDeploy.predict(w.multisendTarget), "multisend address");
        require(address(d.dropFactory) == DeepCoreDeploy.predict(w.dropFactoryTarget), "dropFactory address");
    }

    function _postShared(Deployed memory d, address positionManager) private view {
        require(address(d.positionLock.positionManager()) == positionManager, "position manager");
        require(d.dropFactory.IMPLEMENTATION().FACTORY() == address(d.dropFactory), "drop implementation factory");
        require(
            d.dropFactory.dropCount() == 0 && d.positionLock.lockCount() == 0 && d.tokenLock.lockCount() == 0, "fresh"
        );
    }

    function _log(Deployed memory d, Wiring memory w) private pure {
        console.log("=== DeepCore utilities (CREATE3 via CreateX: the same four addresses on every chain) ===");
        console.log("  positionLock    ", address(d.positionLock));
        console.log("  tokenLock       ", address(d.tokenLock));
        console.log("  multisend       ", address(d.multisend));
        console.log("  dropFactory     ", address(d.dropFactory));
        console.log("  owner/recipient ", w.safe);
        console.log("  fee (wei)       ", w.feeWei);
        console.log("  fee cap (wei)   ", w.feeCapWei);
        console.log("  NEXT: record the four in @deepcoreprotocol/sdk deployments, and the fee quote source + time.");
    }

    function preflight(Wiring memory w) public view {
        address deployer = vm.addr(w.pk);

        DeepCoreDeploy.Target[4] memory targets =
            [w.positionLockTarget, w.tokenLockTarget, w.multisendTarget, w.dropFactoryTarget];
        string[4] memory labels = [POSITION_LOCK_LABEL, TOKEN_LOCK_LABEL, MULTISEND_LABEL, DROP_FACTORY_LABEL];
        for (uint256 i; i < 4; ++i) {
            require(targets[i].deployer == deployer, "a salt target is not this deployer");
            DeepCoreDeploy.preflight(targets[i], labels[i]);
            for (uint256 j = i + 1; j < 4; ++j) {
                require(targets[i].salt != targets[j].salt, "two utilities share one salt - only one could exist");
            }
        }

        require(w.safe != address(0) && w.safe.code.length > 0, "UTIL_OWNER_SAFE must be a contract (the Safe)");
        require(w.safe != deployer, "UTIL_OWNER_SAFE is the deployer");
        require(w.positionManager.code.length > 0, "CL_POSITION_MANAGER has no code");
        (bool ok, bytes memory ret) = w.positionManager.staticcall(abi.encodeWithSignature("nextTokenId()"));
        require(ok && ret.length == 32, "CL_POSITION_MANAGER does not answer nextTokenId()");
        require(w.feeWei <= w.feeCapWei, "UTIL_FEE_WEI above the cap");
        require(w.noticeSeconds >= 1 days && w.noticeSeconds <= 30 days, "UTIL_NOTICE_SECONDS outside 1..30 days");
        /* EVERY production chain. These are the owner's terms — the Safe owns it, the notice is 7 days,
           the cap is 10x. The gate is inverted in DeepCoreGovernance: it names the chains to SKIP (local
           and public testnets) and asserts everywhere else, so a new chain is covered without anyone
           remembering. */
        DeepCoreGovernance.requireGovernanceSafe(w.safe, vm.addr(w.pk), "UTIL_OWNER_SAFE");
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(w.noticeSeconds == MAINNET_NOTICE_SECONDS, "UTIL_NOTICE_SECONDS is not 7 days on a production chain");
            require(w.feeWei > 0 && w.feeCapWei == w.feeWei * 10, "UTIL_FEE_CAP_WEI must be 10x a non-zero UTIL_FEE_WEI");
        }
    }

    function _post(address a, Wiring memory w) private {
        DeepCoreFeeGate g = DeepCoreFeeGate(a);
        require(a.code.length > 0 && a.code.length <= 24_576, "code size");
        require(g.owner() == w.safe && g.pendingOwner() == address(0), "owner is not the Safe");
        require(g.protocolFeeRecipient() == w.safe, "recipient");
        require(g.feeWei() == w.feeWei && g.maxFeeWei() == w.feeCapWei && g.feeNoticeSeconds() == w.noticeSeconds, "fee terms");
        (uint256 p, uint64 at) = g.pendingFee();
        require(p == 0 && at == 0 && g.protocolFeesOwed() == 0 && a.balance == 0, "born clean");
        try g.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}
        (bool accepted,) = a.call{value: 0}("");
        require(!accepted, "accepted a plain call - it must have no receive/fallback");
    }
}
