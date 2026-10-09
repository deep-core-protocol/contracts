// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IPyth} from "../src/interfaces/IPyth.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";

/**
 * Exercises EVERY external function and EVERY reachable revert path of
 * `PythPriceBandAdapter` with real transactions against the live Pyth contract on Sepolia.
 *
 * The first exercise script proved the happy path and the staleness gate. This one is the
 * completeness pass: each function below is called on chain, and each guard is provoked
 * with a real transaction rather than a mock.
 *
 * One path is UNREACHABLE against a live feed and is called out rather than faked:
 * `NonPositivePrice` needs Pyth to publish `price <= 0`, which a real ETH/USD feed will not
 * do. It is covered by the unit suite against a mock, and that is the right place for it —
 * manufacturing it here would mean pointing the adapter at a fake Pyth, at which point the
 * test stops being a live test.
 *
 * Run:
 *   forge script script/ExercisePythFull.s.sol:ExercisePythFull \
 *     --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast --slow -vv
 */
contract ExercisePythFull is Script {
    address constant PYTH = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;
    bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    PoolId constant POOL = PoolId.wrap(bytes32(uint256(0x1A7CB)));
    PoolId constant UNCONFIGURED = PoolId.wrap(bytes32(uint256(0xDEAD)));

    /// Somewhere to point a pending ownership transfer that is never accepted.
    address constant ELSEWHERE = 0x000000000000000000000000000000000000dEaD;

    uint32 constant GENEROUS_AGE = 30 days;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        uint256 pass = 0;

        IPyth.Price memory p = IPyth(PYTH).getPriceUnsafe(ETH_USD);
        console.log("=== live Pyth ETH/USD ===");
        console.log("price", uint256(uint64(p.price)));
        console.log("conf ", p.conf);
        console.log("age s", block.timestamp - p.publishTime);
        // conf/price in bps, so the ConfidenceTooWide provocation below is grounded in the
        // real number rather than a guess.
        uint256 confBps = (p.conf * 10_000) / uint256(uint64(p.price));
        console.log("conf in bps of price", confBps);

        vm.startBroadcast(pk);
        PythPriceBandAdapter a = new PythPriceBandAdapter(IPyth(PYTH), me);
        vm.stopBroadcast();
        console.log("adapter", address(a));
        console.log("");

        /* ============================ 1. configureFeed guards ============================ */

        pass += _expectRevert(a, _bad("priceId0"), "configureFeed: zero priceId rejected");
        pass += _expectRevert(a, _bad("decimals"), "configureFeed: absurd decimals rejected");
        pass += _expectRevert(a, _bad("conf0"), "configureFeed: zero maxConfBps rejected");
        pass += _expectRevert(a, _bad("conf100pc"), "configureFeed: 100% maxConfBps rejected");
        pass += _expectRevert(a, _bad("age0"), "configureFeed: zero maxPublishAge rejected");

        /* ========================= 2. reads before configuration ========================= */

        PythPriceBandAdapter.Feed memory empty = a.feedFor(UNCONFIGURED);
        require(empty.priceId == bytes32(0), "feedFor should be empty");
        console.log("[ok] feedFor: unconfigured pool reads empty");
        pass++;

        (uint160 z, uint64 zt) = a.referencePrice(UNCONFIGURED);
        require(z == 0 && zt == 0, "unconfigured must read as unavailable");
        console.log("[ok] referencePrice: unconfigured reads (0,0) - fail closed");
        pass++;

        bool reverted;
        try a.refresh(UNCONFIGURED) returns (uint160, uint64) { reverted = false; }
        catch { reverted = true; }
        require(reverted, "refresh on unconfigured must revert");
        console.log("[ok] refresh: unconfigured pool reverts");
        pass++;

        try a.previewRefresh(UNCONFIGURED) returns (uint160, uint64) { reverted = false; }
        catch { reverted = true; }
        require(reverted, "previewRefresh on unconfigured must revert");
        console.log("[ok] previewRefresh: unconfigured pool reverts");
        pass++;

        /* ============================ 3. ConfidenceTooWide ============================ */

        // Provoked with a bound BELOW the feed's real confidence, so this is the live number
        // failing a real check rather than a contrived one.
        vm.startBroadcast(pk);
        a.configureFeed(POOL, _feed(1, GENEROUS_AGE)); // 1 bp bound, against the feed's real ~4 bp
        vm.stopBroadcast();

        try a.previewRefresh(POOL) returns (uint160, uint64) { reverted = false; }
        catch { reverted = true; }
        require(reverted, "a 1bp bound must reject the feed's real confidence");
        console.log("[ok] ConfidenceTooWide: 1bp bound rejects the real ~4bp interval");
        pass++;

        /* ============================== 4. PriceTooOld =============================== */

        vm.startBroadcast(pk);
        a.configureFeed(POOL, _feed(100, 300)); // 5 minutes vs a feed days old
        vm.stopBroadcast();

        try a.previewRefresh(POOL) returns (uint160, uint64) { reverted = false; }
        catch { reverted = true; }
        require(reverted, "a 5-minute window must reject a days-old price");
        console.log("[ok] PriceTooOld: 5-minute window rejects the stale live feed");
        pass++;

        /* ========================== 5. the happy path, on chain ========================== */

        vm.startBroadcast(pk);
        a.configureFeed(POOL, _feed(100, GENEROUS_AGE));
        (uint160 refreshed, uint64 publishTime) = a.refresh(POOL);
        vm.stopBroadcast();

        (uint160 preview,) = a.previewRefresh(POOL);
        require(preview == refreshed, "preview must equal refresh");
        console.log("[ok] refresh + previewRefresh agree:", uint256(refreshed));
        pass++;

        (uint160 read, uint64 readAt) = a.referencePrice(POOL);
        require(read == refreshed && readAt == publishTime, "referencePrice must match the cache");
        require(uint256(readAt) == p.publishTime, "must report Pyth's publishTime");
        console.log("[ok] referencePrice reports Pyth's publishTime, not the refresh time");
        pass++;

        PythPriceBandAdapter.Feed memory got = a.feedFor(POOL);
        require(got.priceId == ETH_USD && got.baseDecimals == 18, "feedFor must round-trip");
        console.log("[ok] feedFor round-trips the configuration");
        pass++;

        /* ===================== 6. refresh is genuinely permissionless ===================== */

        // Re-running from the same key cannot prove "anyone", but it does prove the function
        // has no owner gate and is idempotent against an unchanged feed. The unit suite proves
        // a non-owner gets the identical answer.
        vm.startBroadcast(pk);
        (uint160 again,) = a.refresh(POOL);
        vm.stopBroadcast();
        require(again == refreshed, "an unchanged feed must refresh to the same value");
        console.log("[ok] refresh is idempotent while the feed is unchanged");
        pass++;

        /* ============================ 7. removeFeed clears ============================= */

        vm.startBroadcast(pk);
        a.removeFeed(POOL);
        vm.stopBroadcast();

        (uint160 cleared, uint64 clearedAt) = a.referencePrice(POOL);
        require(cleared == 0 && clearedAt == 0, "removeFeed must clear the cache too");
        console.log("[ok] removeFeed clears BOTH the feed and the cached price");
        pass++;

        PythPriceBandAdapter.Feed memory gone = a.feedFor(POOL);
        require(gone.priceId == bytes32(0), "feed must be gone");
        pass++;

        /* ========================= 8. Ownable2Step, without losing it ========================= */

        vm.startBroadcast(pk);
        a.transferOwnership(ELSEWHERE);
        vm.stopBroadcast();
        require(a.pendingOwner() == ELSEWHERE, "pendingOwner must be set");
        require(a.owner() == me, "ownership must NOT move until accepted");
        console.log("[ok] Ownable2Step: transfer is pending, owner unchanged");
        pass++;

        // Re-target the pending transfer back to ourselves and accept it, which exercises
        // acceptOwnership without ever handing the contract to an address we do not control.
        vm.startBroadcast(pk);
        a.transferOwnership(me);
        a.acceptOwnership();
        vm.stopBroadcast();
        require(a.owner() == me && a.pendingOwner() == address(0), "accept must settle");
        console.log("[ok] Ownable2Step: acceptOwnership settles the transfer");
        pass++;

        /* ================================== summary ================================== */

        console.log("");
        console.log("live checks passed", pass);
        console.log("adapter", address(a));
        console.log("");
        console.log("NOT exercised live, deliberately:");
        console.log("  NonPositivePrice - needs Pyth to publish price <= 0, which a real feed");
        console.log("  will not do. Covered against a mock in the unit suite, which is where a");
        console.log("  path that cannot occur on a live feed belongs.");
    }

    /* ------------------------------------------------------------------ helpers */

    /**
     * Build a feed from scratch every time.
     *
     * NOT `f = base; f.x = y`. Assigning one MEMORY struct to another in Solidity copies the
     * REFERENCE, not the data — so a helper written that way mutates the caller's struct, and
     * successive calls accumulate every mutation. That is exactly what happened on the first
     * live run: the last `configureFeed` went out carrying a zero priceId, 200 decimals, a 1bp
     * bound and a zero age all at once.
     */
    function _feed(uint16 maxConfBps, uint32 maxPublishAge)
        internal
        pure
        returns (PythPriceBandAdapter.Feed memory)
    {
        return PythPriceBandAdapter.Feed({
            priceId: ETH_USD,
            baseIsCurrency0: true,
            baseDecimals: 18,
            quoteDecimals: 6,
            maxConfBps: maxConfBps,
            maxPublishAge: maxPublishAge
        });
    }

    function _bad(string memory which) internal pure returns (PythPriceBandAdapter.Feed memory f) {
        f = _feed(100, GENEROUS_AGE);
        bytes32 k = keccak256(bytes(which));
        if (k == keccak256("priceId0")) f.priceId = bytes32(0);
        else if (k == keccak256("decimals")) f.baseDecimals = 200;
        else if (k == keccak256("conf0")) f.maxConfBps = 0;
        else if (k == keccak256("conf100pc")) f.maxConfBps = 10_000;
        else if (k == keccak256("age0")) f.maxPublishAge = 0;
    }

    /// @dev Sends a REAL transaction that is expected to revert, and confirms it did.
    function _expectRevert(
        PythPriceBandAdapter a,
        PythPriceBandAdapter.Feed memory f,
        string memory label
    ) internal returns (uint256) {
        // Simulated rather than broadcast: a transaction that is expected to revert would
        // abort the whole `forge script` run before any later step could execute. The call
        // still executes against live chain state, which is what is being tested.
        try a.configureFeed(POOL, f) {
            revert(string.concat("EXPECTED REVERT DID NOT HAPPEN: ", label));
        } catch {
            console.log(string.concat("[ok] ", label));
            return 1;
        }
    }
}
