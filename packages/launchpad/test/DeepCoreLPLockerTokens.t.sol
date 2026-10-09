// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {IERC20Minimal} from "infinity-core/src/interfaces/IERC20Minimal.sol";

import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {IDeepCoreLPLocker, LockParams} from "../src/interfaces/IDeepCoreLPLocker.sol";

import {LockerFixture, FeeOnTransferToken, PausableStockToken} from "./utils/LockerFixture.sol";

/// @dev Re-enters the locker from inside its own `transfer`, the moment the locker is mid-`collectFees`
/// (Vault -> locker) or mid-`claim` (locker -> recipient). Records what the re-entry returned and then
/// completes the transfer normally, so the test can check both that re-entry was refused AND that the
/// outer call's accounting is still exact.
contract ReentrantToken is MockERC20 {
    enum Mode {
        None,
        Collect,
        Claim,
        Skim
    }

    DeepCoreLPLocker public locker;
    Mode public mode;
    uint256 public targetTokenId;
    bool public attempted;
    bytes public reentryRevertData;
    bool public reentrySucceeded;

    constructor() MockERC20("Reentrant", "RE", 18) {}

    function arm(DeepCoreLPLocker locker_, Mode mode_, uint256 targetTokenId_) external {
        locker = locker_;
        mode = mode_;
        targetTokenId = targetTokenId_;
        attempted = false;
        reentrySucceeded = false;
        delete reentryRevertData;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool fromLocker = msg.sender == address(locker);
        bool toLocker = to == address(locker);
        if (mode != Mode.None && !attempted && (fromLocker || toLocker)) {
            attempted = true;
            bytes memory call;
            if (mode == Mode.Collect) call = abi.encodeCall(DeepCoreLPLocker.collectFees, (targetTokenId));
            else if (mode == Mode.Claim) call = abi.encodeCall(DeepCoreLPLocker.claim, (Currency.wrap(address(this)), address(this)));
            else call = abi.encodeCall(DeepCoreLPLocker.skim, (Currency.wrap(address(this))));
            (bool ok, bytes memory ret) = address(locker).call(call);
            reentrySucceeded = ok;
            reentryRevertData = ret;
        }
        return super.transfer(to, amount);
    }
}

contract DeepCoreLPLockerTokensTest is LockerFixture {
    using CurrencyLibrary for Currency;

    MockERC20 plain;

    function setUp() public {
        _deployCore();
        plain = new MockERC20("Plain", "PLN", 18);
        plain.mint(address(this), 1e30);
        _approveAll(address(plain));
    }

    function _pairWith(address token) internal returns (PoolKey memory key, uint256 tokenId) {
        MockERC20(token).mint(address(this), 1e30);
        _approveAll(token);
        key = _initPool(address(plain), token);
        tokenId = _mintFullRange(key);
        _lock(tokenId, _defaultParams());
    }

    function _sumClaimable(Currency c) internal view returns (uint256) {
        return locker.claimable(CREATOR, c) + locker.claimable(INTEGRATOR, c) + locker.claimable(PROTOCOL, c);
    }

    /*//////////////////////////////////////////////////////////////
                          FEE-ON-TRANSFER QUOTE
    //////////////////////////////////////////////////////////////*/

    /// @dev The Vault sends X of the taxed token; the locker receives 99% of X and credits exactly that.
    /// Crediting X would make the locker insolvent by 1% on every collection.
    function test_feeOnTransfer_creditsWhatArrivedNotWhatWasSent() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(address(vault));
        (PoolKey memory key, uint256 tokenId) = _pairWith(address(fot));
        _trade(key, 10 ether);

        Currency taxed = Currency.wrap(address(fot));
        vm.recordLogs();
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        uint256 credited = key.currency0 == taxed ? a0 : a1;

        // What the position manager says the Vault paid out for this position.
        BalanceDelta fees = _feesFromLogs(vm.getRecordedLogs());
        int128 sentSigned = key.currency0 == taxed ? BalanceDeltaLibrary.amount0(fees) : BalanceDeltaLibrary.amount1(fees);
        uint256 sent = uint256(uint128(sentSigned));

        assertGt(sent, 0);
        assertEq(credited, sent - sent / 100, "credited the net amount");
        assertEq(_sumClaimable(taxed), credited);
        assertEq(fot.balanceOf(address(locker)), locker.totalOwed(taxed), "solvent");

        // Claims drain exactly to zero despite the tax on the way out.
        address[3] memory parties = [CREATOR, INTEGRATOR, PROTOCOL];
        for (uint256 i; i < 3; ++i) {
            vm.prank(parties[i]);
            locker.claim(taxed, parties[i]);
        }
        assertEq(fot.balanceOf(address(locker)), 0);
        assertEq(locker.totalOwed(taxed), 0);
    }

    function _feesFromLogs(Vm.Log[] memory logs) internal view returns (BalanceDelta fees) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(posm) && logs[i].topics[0] == ICLPositionManager.ModifyLiquidity.selector) {
                (, fees) = abi.decode(logs[i].data, (int256, BalanceDelta));
                return fees;
            }
        }
        revert("no ModifyLiquidity log");
    }

    /*//////////////////////////////////////////////////////////////
                         STOCK TOKEN: PAUSE / BURN
    //////////////////////////////////////////////////////////////*/

    /// @dev While the stock is paused the Vault cannot pay the locker, so collection reverts as a whole.
    /// Nothing is lost: fees remain inside the position and are all collected after unpause.
    function test_stockPause_duringCollect_revertsThenRecoversEverything() public {
        PausableStockToken stock = new PausableStockToken();
        (PoolKey memory key, uint256 tokenId) = _pairWith(address(stock));
        _trade(key, 5 ether);

        uint256 snap = vm.snapshotState();
        (uint256 u0, uint256 u1) = locker.collectFees(tokenId);
        vm.revertToState(snap);

        stock.pause(true);
        (bool ok,) = address(locker).call(abi.encodeCall(DeepCoreLPLocker.collectFees, (tokenId)));
        assertFalse(ok, "collect must fail while the stock is paused");
        assertEq(locker.totalOwed(key.currency0) + locker.totalOwed(key.currency1), 0);

        stock.pause(false);
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        assertEq(a0, u0, "no fee lost across the pause");
        assertEq(a1, u1, "no fee lost across the pause");
        assertEq(posm.getPositionLiquidity(tokenId), LIQUIDITY);
    }

    /// @dev A pause after crediting blocks only claims of THAT token; the credit survives the failed claim,
    /// and the other currency of the same lock stays claimable.
    function test_stockPause_duringClaim_blocksOnlyThatToken() public {
        PausableStockToken stock = new PausableStockToken();
        (PoolKey memory key, uint256 tokenId) = _pairWith(address(stock));
        _trade(key, 5 ether);
        locker.collectFees(tokenId);

        Currency stockC = Currency.wrap(address(stock));
        Currency plainC = Currency.wrap(address(plain));
        uint256 owedStock = locker.claimable(CREATOR, stockC);
        uint256 owedPlain = locker.claimable(CREATOR, plainC);
        assertGt(owedStock, 0);

        stock.pause(true);
        vm.prank(CREATOR);
        (bool ok,) = address(locker).call(abi.encodeCall(DeepCoreLPLocker.claim, (stockC, CREATOR)));
        assertFalse(ok, "claim must fail while paused");
        assertEq(locker.claimable(CREATOR, stockC), owedStock, "credit not consumed");

        vm.prank(CREATOR);
        locker.claim(plainC, CREATOR);
        assertEq(plain.balanceOf(CREATOR), owedPlain);

        stock.pause(false);
        vm.prank(CREATOR);
        locker.claim(stockC, CREATOR);
        assertEq(stock.balanceOf(CREATOR), owedStock);
    }

    /// @dev An issuer blocking one recipient cannot block the others; the blocked party can redirect.
    function test_stockBlocklist_blocksOnlyThatRecipient() public {
        PausableStockToken stock = new PausableStockToken();
        (PoolKey memory key, uint256 tokenId) = _pairWith(address(stock));
        _trade(key, 5 ether);
        locker.collectFees(tokenId);
        Currency stockC = Currency.wrap(address(stock));

        stock.setBlocked(CREATOR, true);
        vm.prank(CREATOR);
        // Core's CurrencyLibrary wraps the token's own revert (ERC-7751) - the issuer's reason survives.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(stock),
                IERC20Minimal.transfer.selector,
                abi.encodeWithSelector(PausableStockToken.Blocked.selector, CREATOR),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        locker.claim(stockC, CREATOR);

        uint256 owedProtocol = locker.claimable(PROTOCOL, stockC);
        vm.prank(PROTOCOL);
        locker.claim(stockC, PROTOCOL);
        assertEq(stock.balanceOf(PROTOCOL), owedProtocol);

        uint256 owedCreator = locker.claimable(CREATOR, stockC);
        vm.prank(CREATOR);
        locker.claim(stockC, address(0xC0FFEE));
        assertEq(stock.balanceOf(address(0xC0FFEE)), owedCreator);
        assertEq(key.currency0 == stockC || key.currency1 == stockC, true);
    }

    /// @dev `adminBurn` against the locker makes that token insolvent here. Documented, not prevented:
    /// claims pay first-come, the last one reverts, and the OTHER currency is untouched.
    function test_stockAdminBurn_insolvencyIsIsolatedToTheBurnedToken() public {
        PausableStockToken stock = new PausableStockToken();
        (PoolKey memory key, uint256 tokenId) = _pairWith(address(stock));
        _trade(key, 5 ether);
        locker.collectFees(tokenId);
        Currency stockC = Currency.wrap(address(stock));
        Currency plainC = Currency.wrap(address(plain));

        uint256 creatorOwed = locker.claimable(CREATOR, stockC);
        uint256 protocolOwed = locker.claimable(PROTOCOL, stockC);
        // Leave the locker exactly one unit short of the creator's credit.
        stock.adminBurn(address(locker), stock.balanceOf(address(locker)) - creatorOwed + 1);

        // First come, first paid: the protocol's smaller credit still fits.
        vm.prank(PROTOCOL);
        locker.claim(stockC, PROTOCOL);
        assertEq(stock.balanceOf(PROTOCOL), protocolOwed);

        // The creator arrives to a balance that can no longer cover their credit.
        vm.prank(CREATOR);
        (bool ok,) = address(locker).call(abi.encodeCall(DeepCoreLPLocker.claim, (stockC, CREATOR)));
        assertFalse(ok, "creator's claim is now unpayable");
        assertEq(locker.claimable(CREATOR, stockC), creatorOwed, "credit stays recorded");
        assertLt(stock.balanceOf(address(locker)), locker.totalOwed(stockC), "insolvent in the burned token");

        vm.expectRevert(IDeepCoreLPLocker.NothingToSkim.selector);
        locker.skim(stockC);

        uint256 plainOwed = locker.claimable(PROTOCOL, plainC);
        vm.prank(PROTOCOL);
        locker.claim(plainC, PROTOCOL);
        assertEq(plain.balanceOf(PROTOCOL), plainOwed);
        assertTrue(key.currency0 == stockC || key.currency1 == stockC);
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function _reentrantSetup() internal returns (ReentrantToken re, PoolKey memory key, uint256 tokenId) {
        re = new ReentrantToken();
        (key, tokenId) = _pairWith(address(re));
        _trade(key, 5 ether);
    }

    function _assertReentryRefused(ReentrantToken re) internal view {
        assertTrue(re.attempted(), "re-entry was attempted");
        assertFalse(re.reentrySucceeded(), "re-entry must fail");
        assertEq(re.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_reentrancy_collectIntoCollect() public {
        (ReentrantToken re, PoolKey memory key, uint256 tokenId) = _reentrantSetup();
        uint256 snap = vm.snapshotState();
        (uint256 u0, uint256 u1) = locker.collectFees(tokenId);
        vm.revertToState(snap);

        re.arm(locker, ReentrantToken.Mode.Collect, tokenId);
        (uint256 a0, uint256 a1) = locker.collectFees(tokenId);
        _assertReentryRefused(re);
        assertEq(a0, u0);
        assertEq(a1, u1);
        assertEq(_sumClaimable(key.currency0), a0);
        assertEq(_sumClaimable(key.currency1), a1);
    }

    function test_reentrancy_collectIntoClaimAndSkim() public {
        (ReentrantToken re,, uint256 tokenId) = _reentrantSetup();
        re.arm(locker, ReentrantToken.Mode.Claim, tokenId);
        locker.collectFees(tokenId);
        _assertReentryRefused(re);

        _trade(_keyOf(tokenId), 1 ether);
        re.arm(locker, ReentrantToken.Mode.Skim, tokenId);
        locker.collectFees(tokenId);
        _assertReentryRefused(re);
    }

    function test_reentrancy_claimIntoCollect() public {
        (ReentrantToken re, PoolKey memory key, uint256 tokenId) = _reentrantSetup();
        locker.collectFees(tokenId);
        Currency reC = Currency.wrap(address(re));
        uint256 owed = locker.claimable(CREATOR, reC);
        uint256 owedTotal = locker.totalOwed(reC);

        _trade(key, 1 ether); // so a re-entrant collect would have something to credit
        re.arm(locker, ReentrantToken.Mode.Collect, tokenId);
        vm.prank(CREATOR);
        locker.claim(reC, CREATOR);
        _assertReentryRefused(re);
        assertEq(re.balanceOf(CREATOR), owed);
        assertEq(locker.totalOwed(reC), owedTotal - owed);
        assertEq(re.balanceOf(address(locker)), locker.totalOwed(reC));
    }

    function _keyOf(uint256 tokenId) internal view returns (PoolKey memory key) {
        (key,) = posm.getPoolAndPositionInfo(tokenId);
    }
}
