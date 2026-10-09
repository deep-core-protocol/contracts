// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";

/**
 * Points `PythPriceBandAdapter` at the REAL Pyth contract on Ethereum Sepolia.
 *
 * ############################ WHAT THIS PROVES ############################
 *
 * The adapter has 17 passing unit tests, all against a mock. This runs it against the live
 * Pyth deployment, which behaves in one way no mock would have suggested:
 *
 *   THE SEPOLIA FEEDS ARE STALE. Pyth is pull-based, so a price only exists on chain once
 *   somebody pays to post it — and on a testnet nobody does. ETH/USD was last published
 *   more than a week ago at the time this was written.
 *
 * That is not a problem to work around; it is the single most important thing to verify.
 * A price-band oracle whose failure mode is "let a week-old price through" is not a
 * circuit breaker. So the script asserts the adapter REJECTS it, and only then relaxes
 * `maxPublishAge` to prove the conversion math is right on the same real data.
 *
 * Run:
 *   forge script script/ExercisePythSepolia.s.sol:ExercisePythSepolia \
 *     --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast --slow -vv
 */
contract ExercisePythSepolia is Script {
    /// Pyth's live Sepolia deployment. Verified by calling it, not taken from a doc page.
    address constant PYTH = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

    /// Pyth's ETH/USD feed. A crypto feed rather than an equity one deliberately: it is the
    /// feed most likely to have ANY data on a testnet, and the conversion under test is the
    /// same arithmetic either way.
    bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    /// A pool id to key the feed against. Arbitrary here — the adapter never dereferences it.
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(0x1A7CB)));

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        /* ------------------------------------------------- 0. what does Pyth actually hold */

        IPyth.Price memory p = IPyth(PYTH).getPriceUnsafe(ETH_USD);
        console.log("=== live Pyth on Sepolia ===");
        console.log("price      ", uint256(uint64(p.price)));
        console.log("conf       ", p.conf);
        console.log("publishTime", p.publishTime);
        console.log("block time ", block.timestamp);
        console.log("age (s)    ", block.timestamp - p.publishTime);

        vm.startBroadcast(pk);
        PythPriceBandAdapter adapter = new PythPriceBandAdapter(IPyth(PYTH), me);

        /* --------------------------------- 1. a REALISTIC window must reject a stale feed */

        // 5 minutes, which is what a real equity offering would use.
        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: ETH_USD,
                baseIsCurrency0: true,
                baseDecimals: 18,
                quoteDecimals: 6,
                maxConfBps: 100, // 1%
                maxPublishAge: 300
            })
        );
        vm.stopBroadcast();

        bool rejected;
        try adapter.previewRefresh(POOL) returns (uint160, uint64) {
            rejected = false;
        } catch {
            rejected = true;
        }
        console.log("");
        console.log("with a 5-minute window, stale feed rejected:", rejected);
        require(rejected, "SECURITY: a week-old price passed a 5-minute staleness window");

        /* ------------------------- 2. relax the window, prove the conversion on real data */

        // 30 days, purely so the arithmetic can be exercised against a genuine Pyth reading.
        // NEVER ship a window like this: it is the difference between a circuit breaker and
        // a decoration.
        vm.startBroadcast(pk);
        adapter.configureFeed(
            POOL,
            PythPriceBandAdapter.Feed({
                priceId: ETH_USD,
                baseIsCurrency0: true,
                baseDecimals: 18,
                quoteDecimals: 6,
                maxConfBps: 100,
                maxPublishAge: 30 days
            })
        );
        (uint160 preview,) = adapter.previewRefresh(POOL);
        (uint160 stored, uint64 publishTime) = adapter.refresh(POOL);
        vm.stopBroadcast();

        console.log("");
        console.log("previewRefresh sqrtPriceX96", uint256(preview));
        console.log("refresh        sqrtPriceX96", uint256(stored));
        require(preview == stored, "preview and refresh disagree");

        (uint160 read, uint64 readAt) = adapter.referencePrice(POOL);
        require(read == stored, "referencePrice does not match what refresh wrote");
        require(readAt == publishTime, "referencePrice must report Pyth's publish time");
        require(uint256(readAt) == p.publishTime, "reported time must be Pyth's, not the refresh time");

        console.log("referencePrice             ", uint256(read));
        console.log("reported updatedAt         ", readAt);
        console.log("  (Pyth's publishTime, not the refresh time - a cache written now from a");
        console.log("   week-old price is still a week-old price, and the consumer must see that)");

        console.log("");
        console.log("adapter", address(adapter));
    }
}
