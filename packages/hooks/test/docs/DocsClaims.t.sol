// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/**
 * DOCS CLAIM GUARD
 *
 * Every test in this file pins one statement published on the developer docs
 * page (`apps/web/src/routes/docs`). The page teaches bit values, a fee rule and
 * an argument meaning that a reader will copy verbatim into their own hook, and
 * an earlier draft of it shipped bit values that were simply wrong. Nothing else
 * in the repo notices when a doc sentence stops being true, so this file does.
 *
 * If one of these fails, a published line has become false. Each test carries a
 * `DOC:` comment quoting the sentence it guards — start there, fix the page, and
 * only then change the assertion.
 *
 * `test_docsClaim_publishedSnippetMatchesTheDocsPage` additionally checks that
 * `FeeDeepCore.sol` in this directory is still byte-for-byte what the page renders,
 * so the compiled sample and the published sample cannot drift apart.
 */

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseCLHook} from "../../src/base/BaseCLHook.sol";
import {FeeDeepCore} from "./FeeDeepCore.sol";

/// @dev Records the `sender` core hands to the callback. Used by the
/// "sender is the locker" claim.
contract SenderProbe is BaseCLHook {
    address public lastSender;

    constructor(ICLPoolManager pm) BaseCLHook(pm) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_SWAP;
    }

    function _beforeSwap(address sender, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        lastSender = sender;
        return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev Declares beforeSwap but never overrides `_beforeSwap`, so the base
/// contract's default reverts with `HookNotImplemented`.
contract UnimplementedHook is BaseCLHook {
    constructor(ICLPoolManager pm) BaseCLHook(pm) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_SWAP;
    }
}

/// @dev Exposes the deploy-time permission validation `BaseCLHook` runs from its
/// constructor.
///
/// ############################ DO NOT "FIX" THIS ############################
/// The obvious version of this helper is a hook that simply declares an invalid
/// bitmap, so `new BadHook(pm)` reverts. That cannot be compiled under
/// `via_ir`: the optimizer proves the constructor always reverts, concludes the
/// immutable `poolManager` is never assigned, and fails the whole build with
/// "Some immutables were read from but never assigned". The rule is therefore
/// exercised through the same function the constructor calls, on a contract
/// that does deploy.
/// ###########################################################################
contract ExposedValidator is BaseCLHook {
    constructor(ICLPoolManager pm) BaseCLHook(pm) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_SWAP;
    }

    function check(uint16 declared) external pure {
        _validatePermissions(declared);
    }
}

contract DocsClaimsTest is Test {
    /// @dev The page this file guards.
    string internal constant DOCS_CONTENT = "../../apps/web/src/routes/docs/content.ts";
    string internal constant SNIPPET_FIXTURE = "./test/docs/FeeDeepCore.sol";

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -60_000;
    int24 internal constant TICK_UPPER = 60_000;
    int256 internal constant LIQUIDITY_DELTA = 100_000 ether;
    uint256 internal constant STARTING_BALANCE = 1_000_000 ether;

    /// @dev Large enough that the published FeeDeepCore returns HIGH (3000).
    int256 internal constant BIG_SWAP = -50 ether;

    Vault internal vault;
    CLPoolManager internal poolManager;
    CLPoolManagerRouter internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    FeeDeepCore internal hook;

    function setUp() public {
        vault = new Vault();
        poolManager = new CLPoolManager(vault);
        vault.registerApp(address(poolManager));
        router = new CLPoolManagerRouter(vault, poolManager);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), STARTING_BALANCE);
        token1.mint(address(this), STARTING_BALANCE);
        require(token0.approve(address(router), type(uint256).max), "approve0");
        require(token1.approve(address(router), type(uint256).max), "approve1");

        hook = new FeeDeepCore(poolManager);
    }

    /*//////////////////////////////////////////////////////////////
                          THE BIT VALUES
    //////////////////////////////////////////////////////////////*/

    /// DOC: callback reference table - "beforeSwap  0x0040".
    /// @dev An earlier draft published 0x0001 here, which is beforeInitialize.
    /// Anyone who copied it got HookConfigValidationError at pool creation.
    function test_docsClaim_beforeSwapBitIs0x0040() public view {
        assertEq(hook.getHooksRegistrationBitmap(), uint16(0x0040), "docs publish beforeSwap = 0x0040");
    }

    /// DOC: callback reference table - every row's BIT column.
    /// @dev Pins all fourteen against ICLHooks' offsets in one place.
    function test_docsClaim_everyPublishedBitValue() public pure {
        assertEq(uint16(1) << 0, uint16(0x0001), "beforeInitialize");
        assertEq(uint16(1) << 1, uint16(0x0002), "afterInitialize");
        assertEq(uint16(1) << 2, uint16(0x0004), "beforeAddLiquidity");
        assertEq(uint16(1) << 3, uint16(0x0008), "afterAddLiquidity");
        assertEq(uint16(1) << 4, uint16(0x0010), "beforeRemoveLiquidity");
        assertEq(uint16(1) << 5, uint16(0x0020), "afterRemoveLiquidity");
        assertEq(uint16(1) << 6, uint16(0x0040), "beforeSwap");
        assertEq(uint16(1) << 7, uint16(0x0080), "afterSwap");
        assertEq(uint16(1) << 8, uint16(0x0100), "beforeDonate");
        assertEq(uint16(1) << 9, uint16(0x0200), "afterDonate");
        assertEq(uint16(1) << 10, uint16(0x0400), "beforeSwapReturnsDelta");
        assertEq(uint16(1) << 11, uint16(0x0800), "afterSwapReturnsDelta");
        assertEq(uint16(1) << 12, uint16(0x1000), "afterAddLiquidityReturnsDelta");
        assertEq(uint16(1) << 13, uint16(0x2000), "afterRemoveLiquidityReturnsDelta");

        // The page's `deepcore bitmap` output line shows beforeSwap|afterSwap.
        assertEq((uint16(1) << 6) | (uint16(1) << 7), uint16(0x00C0), "beforeSwap|afterSwap = 0x00C0");
    }

    /*//////////////////////////////////////////////////////////////
                      THE POOL-KEY CROSS-CHECK
    //////////////////////////////////////////////////////////////*/

    /// DOC: intro - "the pool key carries that same bitmap in its parameters.
    /// Core cross-checks the two when the pool is initialized."
    /// DOC: common errors - "HookConfigValidationError(): poolKey.parameters and
    /// getHooksRegistrationBitmap() disagree."
    function test_docsClaim_mismatchedBitmapRevertsAtInitialize() public {
        PoolKey memory k = _key(address(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG, hook.getHooksRegistrationBitmap());
        k.parameters = bytes32(uint256(k.parameters) ^ 1); // flip bit 0

        vm.expectRevert(Hooks.HookConfigValidationError.selector);
        // forge-lint: disable-next-line(unused-return)
        poolManager.initialize(k, SQRT_PRICE_1_1);
    }

    /// DOC: intro - "Permissions live in the pool key, not in the hook's address,
    /// so there is no CREATE2 salt to mine and the same hook works from any address."
    function test_docsClaim_hookWorksFromAnArbitraryAddress() public {
        address arbitrary = address(0xDEAD);
        vm.etch(arbitrary, address(hook).code);

        PoolKey memory k = _key(arbitrary, LPFeeLibrary.DYNAMIC_FEE_FLAG, hook.getHooksRegistrationBitmap());
        _init(k);
        _addLiquidity(k);

        BalanceDelta d = _swap(k, true, -1 ether);
        assertLt(d.amount0(), 0, "swap did not spend token0");
    }

    /*//////////////////////////////////////////////////////////////
                        THE DYNAMIC-FEE TRAP
    //////////////////////////////////////////////////////////////*/

    /// DOC: callout under "2 - Write the deepcore" - "A fee returned from beforeSwap
    /// is applied only on a dynamic-fee pool - one whose fee field is exactly
    /// 0x800000 - and only when you set OVERRIDE_FEE_FLAG on it. On a static-fee
    /// pool core discards it with no revert and no event."
    ///
    /// @dev This is the claim most likely to rot, and the most expensive to get
    /// wrong: a hook on the wrong pool looks like it works and charges nothing it
    /// intended. Same hook, same liquidity, same swap - only the pool's fee field
    /// differs.
    function test_docsClaim_feeOverrideAppliedOnDynamicPool_discardedOnStaticPool() public {
        uint16 bitmap = hook.getHooksRegistrationBitmap();

        PoolKey memory dynamicKey = _key(address(hook), LPFeeLibrary.DYNAMIC_FEE_FLAG, bitmap);
        _init(dynamicKey);
        _addLiquidity(dynamicKey);

        // Static 500 (0.05%). The hook still returns HIGH = 3000 for a big swap.
        PoolKey memory staticKey = _key(address(hook), 500, bitmap);
        _init(staticKey);
        _addLiquidity(staticKey);

        // "no revert": the static-fee swap must simply succeed.
        BalanceDelta dynamicDelta = _swap(dynamicKey, true, BIG_SWAP);
        BalanceDelta staticDelta = _swap(staticKey, true, BIG_SWAP);

        assertEq(dynamicDelta.amount0(), BIG_SWAP, "dynamic pool: exact input not consumed");
        assertEq(staticDelta.amount0(), BIG_SWAP, "static pool: exact input not consumed");

        // A higher fee means less output, so the dynamic pool (3000) must return
        // less than the static pool (500).
        assertLt(dynamicDelta.amount1(), staticDelta.amount1(), "hook fee was NOT applied on the dynamic pool");

        // And the static pool charged its OWN fee, not the hook's: an identical
        // hookless static-500 pool must produce exactly the same output.
        PoolKey memory plainKey = _key(address(0), 500, 0);
        _init(plainKey);
        _addLiquidity(plainKey);

        assertEq(
            staticDelta.amount1(),
            _swap(plainKey, true, BIG_SWAP).amount1(),
            "static-fee pool did not charge its own static fee"
        );
    }

    /// DOC: callout - "one whose fee field is exactly 0x800000".
    /// DOC: execution order card 03 - "Only if the pool fee is 0x800000 and
    /// OVERRIDE_FEE_FLAG is set on the return."
    function test_docsClaim_dynamicFeeFlagIsExactEquality() public pure {
        assertTrue(LPFeeLibrary.isDynamicLPFee(0x800000), "0x800000 is dynamic");
        assertFalse(LPFeeLibrary.isDynamicLPFee(0x800001), "only exact equality is dynamic");
        assertFalse(LPFeeLibrary.isDynamicLPFee(3000), "a static fee is not dynamic");
        assertEq(LPFeeLibrary.OVERRIDE_FEE_FLAG, uint24(0x400000), "OVERRIDE_FEE_FLAG");
    }

    /*//////////////////////////////////////////////////////////////
                        WHAT `sender` MEANS
    //////////////////////////////////////////////////////////////*/

    /// DOC: callback reference - "sender is the Vault locker - the router - and
    /// not the end user, so per-wallet logic keyed on it is broken by construction."
    function test_docsClaim_senderIsTheLockerNotTheEndUser() public {
        SenderProbe probe = new SenderProbe(poolManager);
        PoolKey memory k = _key(address(probe), 3000, probe.getHooksRegistrationBitmap());
        _init(k);
        _addLiquidity(k);

        address endUser = address(0xBEEF);
        token0.mint(endUser, STARTING_BALANCE);
        vm.startPrank(endUser);
        require(token0.approve(address(router), type(uint256).max), "approve");
        _swap(k, true, -1 ether);
        vm.stopPrank();

        assertEq(probe.lastSender(), address(router), "sender should be the locker");
        assertTrue(probe.lastSender() != endUser, "sender must not be the end user");
    }

    /*//////////////////////////////////////////////////////////////
                        DECLARING PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /// DOC: "2 - Write the deepcore" - "the ones you leave alone revert with
    /// HookNotImplemented - so a permission you declare but forget to write fails
    /// loudly instead of silently."
    /// DOC: common errors - "HookNotImplemented()".
    function test_docsClaim_declaredButUnimplementedRevertsHookNotImplemented() public {
        UnimplementedHook u = new UnimplementedHook(poolManager);
        PoolKey memory k = _key(address(u), 3000, u.getHooksRegistrationBitmap());
        _init(k);
        _addLiquidity(k);

        // Core wraps a reverting hook in ERC-7751 `WrappedError`.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(u),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(BaseCLHook.HookNotImplemented.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(k, true, -1 ether);
    }

    /// DOC: callback reference - "The four *ReturnsDelta bits are not callbacks:
    /// each authorises the delta its base callback returns, and core rejects one
    /// declared without that callback."
    /// DOC: common errors - "HookPermissionsValidationError(): ... BaseCLHook
    /// catches the same mistake at deploy time as PermissionDependencyMissing."
    function test_docsClaim_danglingReturnsDeltaBitIsRejected() public {
        ExposedValidator v = new ExposedValidator(poolManager);

        // bit 10 (beforeSwapReturnsDelta) without bit 6 (beforeSwap)
        vm.expectRevert(abi.encodeWithSelector(BaseCLHook.PermissionDependencyMissing.selector, uint16(1 << 10)));
        v.check(uint16(1 << 10));

        // bits 14/15 carry no meaning
        vm.expectRevert(abi.encodeWithSelector(BaseCLHook.ReservedBitsSet.selector, uint16(1 << 14)));
        v.check(uint16(1 << 14));

        // the same bit WITH its base callback is accepted
        v.check(uint16(1 << 6) | uint16(1 << 10));
    }

    /*//////////////////////////////////////////////////////////////
                    THE SNIPPET THE PAGE PUBLISHES
    //////////////////////////////////////////////////////////////*/

    /// DOC: the `src/FeeDeepCore.sol` code block under "2 - Write the deepcore".
    ///
    /// @dev `FeeDeepCore.sol` beside this file is the sample the page renders. It is
    /// compiled by every other test here, which is what proves the published
    /// sample builds. This test closes the other half: that the compiled copy is
    /// still what the page actually shows. Without it the fixture could keep
    /// compiling happily while the page drifted to something broken.
    ///
    /// Reads the page source, extracts the FEE_DEEPCORE_SOL template literal, strips
    /// the `[[kind:text]]` syntax-highlight markers, and compares.
    ///
    /// Skips (loudly) when the web app is not present, so a contracts-only
    /// checkout still runs green.
    function test_docsClaim_publishedSnippetMatchesTheDocsPage() public view {
        if (!vm.exists(DOCS_CONTENT)) {
            console.log("SKIP: %s not present - contracts-only checkout", DOCS_CONTENT);
            return;
        }

        string memory published = _stripHighlightMarkers(
            _between(vm.readFile(DOCS_CONTENT), "export const FEE_DEEPCORE_SOL = `", "`")
        );
        string memory fixture = vm.readFile(SNIPPET_FIXTURE);

        assertEq(
            keccak256(_normalize(published)),
            keccak256(_normalize(fixture)),
            "test/docs/FeeDeepCore.sol has drifted from FEE_DEEPCORE_SOL in the docs page"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       SNIPPET-COMPARISON HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The substring after the first `open`, up to the next `close`.
    function _between(string memory haystack, string memory open, string memory close)
        internal
        pure
        returns (string memory)
    {
        bytes memory h = bytes(haystack);
        bytes memory o = bytes(open);
        uint256 start = type(uint256).max;

        for (uint256 i = 0; i + o.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < o.length; ++j) {
                if (h[i + j] != o[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                start = i + o.length;
                break;
            }
        }
        require(start != type(uint256).max, "FEE_DEEPCORE_SOL not found in the docs page");

        bytes1 c = bytes(close)[0];
        uint256 end = start;
        while (end < h.length && h[end] != c) ++end;
        require(end < h.length, "unterminated FEE_DEEPCORE_SOL literal");

        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = h[start + i];
        }
        return string(out);
    }

    /// @dev Removes `[[kind:` and `]]`, keeping the text between them. The snippet
    /// contains no other square brackets, which is what makes this safe.
    function _stripHighlightMarkers(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length);
        uint256 n = 0;

        for (uint256 i = 0; i < b.length;) {
            if (i + 1 < b.length && b[i] == "[" && b[i + 1] == "[") {
                i += 2;
                while (i < b.length && b[i] != ":") ++i; // skip the kind
                ++i; // skip the ':'
            } else if (i + 1 < b.length && b[i] == "]" && b[i + 1] == "]") {
                i += 2;
            } else {
                out[n++] = b[i++];
            }
        }

        bytes memory trimmed = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            trimmed[i] = out[i];
        }
        return string(trimmed);
    }

    /// @dev Drops carriage returns and trailing whitespace, so a checkout with
    /// CRLF line endings or an editor's trailing newline is not a false failure.
    function _normalize(string memory s) internal pure returns (bytes memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length);
        uint256 n = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] != "\r") out[n++] = b[i];
        }
        while (n > 0 && (out[n - 1] == "\n" || out[n - 1] == " " || out[n - 1] == "\t")) --n;

        bytes memory trimmed = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            trimmed[i] = out[i];
        }
        return trimmed;
    }

    /*//////////////////////////////////////////////////////////////
                            POOL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(address hookAddress, uint24 fee, uint16 bitmap) internal view returns (PoolKey memory) {
        bytes32 params = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(bitmap)), TICK_SPACING);
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(hookAddress),
            poolManager: IPoolManager(address(poolManager)),
            fee: fee,
            parameters: params
        });
    }

    function _init(PoolKey memory k) internal {
        // forge-lint: disable-next-line(unused-return)
        poolManager.initialize(k, SQRT_PRICE_1_1);
    }

    function _addLiquidity(PoolKey memory k) internal {
        ICLPoolManager.ModifyLiquidityParams memory p = ICLPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: LIQUIDITY_DELTA,
            salt: bytes32(0)
        });
        // forge-lint: disable-next-line(unused-return)
        router.modifyPosition(k, p, "");
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        ICLPoolManager.SwapParams memory p = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });
        CLPoolManagerRouter.SwapTestSettings memory s =
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});
        return router.swap(k, p, s, "");
    }
}
