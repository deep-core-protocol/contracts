// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {LockParams} from "../src/interfaces/IDeepCoreLPLocker.sol";

import {LockerFixture} from "./utils/LockerFixture.sol";

/// @dev Drives the locker with everything a hostile world can do to it: swaps that move fees and price,
/// permissionless collections from anyone, claims by every party to arbitrary addresses, creator
/// rotations, donations plus skims, and direct attacks on the position manager. Ghost variables are
/// measured from TOKEN BALANCES, not from the locker's own return values, so the accounting invariant
/// cannot be satisfied by the locker agreeing with itself.
contract LockerHandler is Test {
    using CurrencyLibrary for Currency;

    DeepCoreLPLocker public immutable locker;
    CLPositionManager public immutable posm;
    CLPoolManagerRouter public immutable router;

    PoolKey[] internal _keys;
    uint256[] public tokenIds;
    Currency[] public currencies;
    address[] public parties;

    mapping(Currency => uint256) public ghostCollected;
    mapping(Currency => uint256) public ghostClaimed;
    mapping(Currency => uint256) public ghostSkimmed;
    mapping(address => bool) public isParty;

    /// @dev Set if ANY attack on a locked position ever succeeds.
    bool public breach;

    uint256 public calls;

    constructor(DeepCoreLPLocker locker_, CLPositionManager posm_, CLPoolManagerRouter router_) {
        locker = locker_;
        posm = posm_;
        router = router_;
    }

    function register(PoolKey memory key, uint256[] memory ids, Currency[] memory cs, address[] memory ps) external {
        _keys.push(key);
        for (uint256 i; i < ids.length; ++i) tokenIds.push(ids[i]);
        for (uint256 i; i < cs.length; ++i) {
            bool seen;
            for (uint256 j; j < currencies.length; ++j) if (currencies[j] == cs[i]) seen = true;
            if (!seen) {
                currencies.push(cs[i]);
                MockERC20(Currency.unwrap(cs[i])).approve(address(router), type(uint256).max);
            }
        }
        for (uint256 i; i < ps.length; ++i) {
            if (!isParty[ps[i]]) {
                isParty[ps[i]] = true;
                parties.push(ps[i]);
            }
        }
    }

    function tokenIdCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function currencyCount() external view returns (uint256) {
        return currencies.length;
    }

    function partyCount() external view returns (uint256) {
        return parties.length;
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/

    function swap(uint256 keySeed, bool zeroForOne, uint256 amount) external {
        calls++;
        PoolKey memory key = _keys[keySeed % _keys.length];
        amount = bound(amount, 1e6, 20 ether);
        try router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        ) {} catch {}
    }

    function collect(uint256 idSeed, uint256 callerSeed) external {
        calls++;
        uint256 tokenId = tokenIds[idSeed % tokenIds.length];
        (Currency c0, Currency c1) = _currenciesOf(tokenId);
        uint256 b0 = c0.balanceOf(address(locker));
        uint256 b1 = c1.balanceOf(address(locker));
        vm.prank(address(uint160(bound(callerSeed, 1, type(uint160).max))));
        locker.collectFees(tokenId);
        ghostCollected[c0] += c0.balanceOf(address(locker)) - b0;
        ghostCollected[c1] += c1.balanceOf(address(locker)) - b1;
    }

    function claim(uint256 partySeed, uint256 currencySeed, uint256 toSeed) external {
        calls++;
        address party = parties[partySeed % parties.length];
        Currency c = currencies[currencySeed % currencies.length];
        address to = address(uint160(bound(toSeed, 1, type(uint160).max)));
        if (to == address(locker) || to == address(this)) to = address(0xBEEF);
        if (locker.claimable(party, c) == 0) return;
        uint256 before = c.balanceOf(address(locker));
        vm.prank(party);
        locker.claim(c, to);
        ghostClaimed[c] += before - c.balanceOf(address(locker));
    }

    function rotateCreator(uint256 idSeed, uint256 partySeed) external {
        calls++;
        uint256 tokenId = tokenIds[idSeed % tokenIds.length];
        address next = parties[partySeed % parties.length];
        address current = locker.getLock(tokenId).creator;
        vm.prank(current);
        locker.transferCreator(tokenId, next);
        vm.prank(next);
        locker.acceptCreator(tokenId);
    }

    function donateAndSkim(uint256 currencySeed, uint256 amount) external {
        calls++;
        Currency c = currencies[currencySeed % currencies.length];
        amount = bound(amount, 1, 1 ether);
        MockERC20(Currency.unwrap(c)).transfer(address(locker), amount);
        uint256 surplus = locker.skim(c);
        ghostSkimmed[c] += surplus;
    }

    /// @dev Every route to move or shrink a locked position. Any success flips `breach`.
    function attack(uint256 idSeed, uint8 mode) external {
        calls++;
        uint256 tokenId = tokenIds[idSeed % tokenIds.length];
        address attacker = locker.getLock(tokenId).creator; // the most privileged non-locker actor
        mode = mode % 5;

        vm.startPrank(attacker);
        if (mode == 0) {
            try posm.transferFrom(address(locker), attacker, tokenId) {
                breach = true;
            } catch {}
        } else if (mode == 1) {
            try posm.approve(attacker, tokenId) {
                breach = true;
            } catch {}
        } else {
            (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
            Plan memory plan = Planner.init();
            if (mode == 2) {
                plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(1), uint128(0), uint128(0), bytes("")));
                plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, attacker));
            } else if (mode == 3) {
                plan.add(Actions.CL_BURN_POSITION, abi.encode(tokenId, uint128(0), uint128(0), bytes("")));
                plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, attacker));
            } else {
                plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")));
                plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, attacker));
            }
            try posm.modifyLiquidities(plan.encode(), block.timestamp) {
                breach = true;
            } catch {}
        }
        vm.stopPrank();
    }

    function _currenciesOf(uint256 tokenId) internal view returns (Currency, Currency) {
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        return (key.currency0, key.currency1);
    }
}

contract DeepCoreLPLockerInvariantTest is LockerFixture {
    using CurrencyLibrary for Currency;

    LockerHandler handler;
    mapping(uint256 => uint128) initialLiquidity;

    address constant CREATOR_2 = address(0xC0002);
    address constant INTEGRATOR_2 = address(0x10002);
    address constant SPARE = address(0x5BA4E);

    function setUp() public {
        _deployCore();
        handler = new LockerHandler(locker, posm, router);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        MockERC20 c = new MockERC20("C", "C", 18);
        MockERC20[3] memory ts = [a, b, c];
        for (uint256 i; i < 3; ++i) {
            ts[i].mint(address(this), 1e36);
            ts[i].mint(address(handler), 1e36);
            _approveAll(address(ts[i]));
        }

        address[] memory ps = new address[](6);
        (ps[0], ps[1], ps[2], ps[3], ps[4], ps[5]) = (CREATOR, CREATOR_2, INTEGRATOR, INTEGRATOR_2, PROTOCOL, SPARE);

        // Pool AB: a full-range lock and a narrow single-sided-ish lock with different splits.
        PoolKey memory ab = _initPool(address(a), address(b));
        uint256[] memory ids = new uint256[](2);
        ids[0] = _mintFullRange(ab);
        _lock(ids[0], _defaultParams());
        ids[1] = _mint(ab, -1200, 1200, 200 ether);
        LockParams memory p = _params(5_000, 0, 5_000);
        p.creator = CREATOR_2;
        _lock(ids[1], p);
        Currency[] memory cs = new Currency[](2);
        (cs[0], cs[1]) = (ab.currency0, ab.currency1);
        handler.register(ab, ids, cs, ps);

        // Pool AC shares currency A with AB, so per-currency accounting must hold across locks.
        PoolKey memory ac = _initPool(address(a), address(c));
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = _mintFullRange(ac);
        LockParams memory p2 = _params(4_500, 1_500, 4_000);
        p2.integrator = INTEGRATOR_2;
        _lock(ids2[0], p2);
        (cs[0], cs[1]) = (ac.currency0, ac.currency1);
        handler.register(ac, ids2, cs, ps);

        for (uint256 i; i < handler.tokenIdCount(); ++i) {
            uint256 id = handler.tokenIds(i);
            initialLiquidity[id] = posm.getPositionLiquidity(id);
        }

        // Only the action functions. `register` is setup plumbing: left targetable, the fuzzer would push
        // unminted token ids into the handler and "fail" the custody invariant on NOT_MINTED.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LockerHandler.swap.selector;
        selectors[1] = LockerHandler.collect.selector;
        selectors[2] = LockerHandler.claim.selector;
        selectors[3] = LockerHandler.rotateCreator.selector;
        selectors[4] = LockerHandler.donateAndSkim.selector;
        selectors[5] = LockerHandler.attack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Guards against a vacuous pass: each run must actually have moved fees through the locker and
    /// out to parties, or the conservation invariant below proved nothing.
    function afterInvariant() public view {
        uint256 collected;
        uint256 claimed;
        for (uint256 k; k < handler.currencyCount(); ++k) {
            collected += handler.ghostCollected(handler.currencies(k));
            claimed += handler.ghostClaimed(handler.currencies(k));
        }
        assertGt(collected, 0, "run never collected");
        assertGt(claimed, 0, "run never claimed");
    }

    /// @dev The no-withdraw guarantee: custody, liquidity, and no successful attack, ever.
    function invariant_positionsNeverLeaveOrShrink() public view {
        for (uint256 i; i < handler.tokenIdCount(); ++i) {
            uint256 id = handler.tokenIds(i);
            assertEq(posm.ownerOf(id), address(locker), "custody");
            assertEq(posm.getPositionLiquidity(id), initialLiquidity[id], "liquidity never decreases");
            assertEq(posm.getApproved(id), address(0), "no approval");
        }
        assertFalse(handler.breach(), "an attack on a locked position succeeded");
    }

    /// @dev sum(claimable) + claimed == collected + skimmed, per currency, from balance-measured ghosts.
    function invariant_accountingConservesEveryUnit() public view {
        for (uint256 k; k < handler.currencyCount(); ++k) {
            Currency c = handler.currencies(k);
            uint256 sumClaimable;
            for (uint256 j; j < handler.partyCount(); ++j) {
                sumClaimable += locker.claimable(handler.parties(j), c);
            }
            assertEq(
                sumClaimable + handler.ghostClaimed(c),
                handler.ghostCollected(c) + handler.ghostSkimmed(c),
                "claimable + claimed == collected + skimmed"
            );
            assertEq(locker.totalOwed(c), sumClaimable, "totalOwed is the sum of claimable");
            assertGe(c.balanceOf(address(locker)), locker.totalOwed(c), "solvent");
        }
    }
}
