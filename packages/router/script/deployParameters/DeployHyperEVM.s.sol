// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {DeployUniversalRouter} from "../DeployUniversalRouter.s.sol";
import {RouterParameters} from "../../src/base/RouterImmutables.sol";

/**
 * UniversalRouter for DeepCore Protocol on HyperEVM (999). MAINNET. Nothing is deployed yet.
 *
 * Only the DeepCore (infi*) legs are wired. v2 / v3 / stable stay at address(0), which the base script
 * maps to UnsupportedProtocol: DeepCore has no v2 or v3 deployment here, and pointing those legs at some
 * other protocol's factory would silently route a user's swap into pools this router has no
 * relationship with.
 *
 * The core addresses do not exist until core is deployed on 999, so they are read from the environment
 * (filled from core's READ-BACKS), never typed into this file. Each must have code on this chain, and
 * CREATE3_FACTORY must be set explicitly (the base script refuses an unset factory).
 *
 *   VAULT, CL_POOL_MANAGER, BIN_POOL_MANAGER, CREATE3_FACTORY, PRIVATE_KEY
 *
 * ADDRESSES that are fixed (ops/deploy/hyperevm-deploy.md section 0):
 *   permit2  0x000000000022D473030F116dDEE9F6B43aC78BA3 (canonical Permit2; checked for code below)
 *   weth9    0x5555555555555555555555555555555555555555 (WHYPE, Hyperliquid's WHYPE9 system contract;
 *            symbol WHYPE, 18 decimals; deposit()/withdraw() to be confirmed by the owner before broadcast)
 */
contract DeployHyperEVM is DeployUniversalRouter {
    uint256 internal constant HYPEREVM_CHAIN_ID = 999;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WHYPE = 0x5555555555555555555555555555555555555555;

    function setUp() public override {
        require(block.chainid == HYPEREVM_CHAIN_ID, "DeployHyperEVM: not HyperEVM (999)");
        require(PERMIT2.code.length > 0, "Permit2 has no code on HyperEVM");
        require(WHYPE.code.length > 0, "WHYPE has no code on HyperEVM");

        address vault = vm.envAddress("VAULT");
        address cl = vm.envAddress("CL_POOL_MANAGER");
        address bin = vm.envAddress("BIN_POOL_MANAGER");
        require(vault.code.length > 0, "VAULT has no code on HyperEVM");
        require(cl.code.length > 0, "CL_POOL_MANAGER has no code on HyperEVM");
        require(bin.code.length > 0, "BIN_POOL_MANAGER has no code on HyperEVM");

        params = RouterParameters({
            permit2: PERMIT2,
            weth9: WHYPE,
            v2Factory: address(0),
            v3Factory: address(0),
            v3Deployer: address(0),
            v2InitCodeHash: bytes32(0),
            v3InitCodeHash: bytes32(0),
            stableFactory: address(0),
            stableInfo: address(0),
            infiVault: vault,
            infiClPoolManager: cl,
            infiBinPoolManager: bin
        });
        unsupported = address(0);
    }

    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("DEEPCORE-UNIVERSAL-ROUTER/1.0.0");
    }
}
