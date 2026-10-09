// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";
import {RwaReleaseBase} from "./RwaReleaseBase.sol";

/**
 * Deploys `PythPriceBandAdapter` (CreateX label `PYTH_PRICE_BAND_ADAPTER`).
 *
 * OWNER: THE SAFE, for the reason `DeployChainlinkPriceBandAdapter` gives: the same Safe owns every
 * consuming hook and can repoint a pool's oracle in one transaction, so a delay on the adapter would
 * bound nothing. `refresh()` is permissionless; the owner only chooses feeds (`configureFeed`).
 *
 * ####################### PYTH IS IMMUTABLE, SO IT IS PINNED PER CHAIN #######################
 *
 * `pyth` is a constructor immutable with no setter. A wrong address is a redeploy AND a new salt.
 * So the address is fixed here per chain and the script FAILS CLOSED on a production chain with no row:
 *
 *   any production chain  REFUSED until a row is added here with Pyth's address on that chain, read
 *                     on chain. DeepCore has no row yet: HyperEVM (999) is not decided.
 *   local / test chains  take what env says, through the same liveness probe.
 *
 * Pyth is a pull oracle: where nobody has pushed an update recently the publish time is old. That is
 * why `refresh` exists, and why a pool's `maxAge` is the real guard.
 *
 * Before broadcast the script calls `getPriceUnsafe` on ETH/USD and requires a positive price with an
 * exponent the adapter accepts, so a contract that merely has code at that address cannot pass.
 *
 * Env: PRIVATE_KEY | DEPLOYER, the PYTH_PRICE_BAND_ADAPTER salt pair, RWA_OWNER, RWA_PYTH.
 */
contract DeployPythPriceBandAdapterScript is RwaReleaseBase {
    string internal constant LABEL = "PYTH_PRICE_BAND_ADAPTER";

    /// @dev Pyth's ETH/USD feed id: present on every Pyth deployment, used only as a liveness probe.
    bytes32 internal constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    struct Params {
        Signer signer;
        address owner;
        address pyth;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (PythPriceBandAdapter adapter) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        Signer memory s = _signerFromEnv();
        return runWith(
            Params({
                signer: s,
                owner: vm.envAddress("RWA_OWNER"),
                pyth: vm.envAddress("RWA_PYTH"),
                target: DeepCoreDeploy.fromEnv(LABEL, s.deployer)
            })
        );
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(type(PythPriceBandAdapter).creationCode, abi.encode(p.pyth, p.owner));
    }

    /// @notice The per-chain Pyth rule above. Public so a test can drive it without a deploy.
    function checkPyth(address pyth) public view {
        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            revert("no Pyth address is recorded for this production chain; add a row to this script");
        }
        require(pyth.code.length > 0, "RWA_PYTH has no code");
        IPyth.Price memory p = IPyth(pyth).getPriceUnsafe(ETH_USD);
        require(p.price > 0, "Pyth ETH/USD reads no positive price");
        require(p.expo >= -30 && p.expo <= 12, "Pyth ETH/USD exponent is outside what the adapter accepts");
        require(p.publishTime != 0, "Pyth ETH/USD has never been published");
    }

    function runWith(Params memory p) public returns (PythPriceBandAdapter adapter) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        _requireOwner(p.owner, deployer);
        checkPyth(p.pyth);

        console.log("=== PythPriceBandAdapter ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Safe)    ", p.owner);
        console.log("  pyth            ", p.pyth);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        adapter = PythPriceBandAdapter(DeepCoreDeploy.deploy(p.target, code, LABEL));
        vm.stopBroadcast();

        require(address(adapter) == DeepCoreDeploy.predict(p.target), "adapter is not at the predicted address");
        require(address(adapter).code.length > 0, "adapter has no code");
        _requireOwnership(address(adapter), p.owner);
        require(address(adapter.pyth()) == p.pyth, "pyth mismatch");

        console.log("PythPriceBandAdapter", address(adapter));
        console.log("  owner           ", adapter.owner());
        console.log("  runtime bytes   ", address(adapter).code.length);
    }
}
