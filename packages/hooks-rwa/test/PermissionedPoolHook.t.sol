// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {PermissionedPoolHook} from "../src/PermissionedPoolHook.sol";
import {IComplianceOracle, ComplianceAction} from "../src/interfaces/IComplianceOracle.sol";
import {AllowlistComplianceOracle} from "../src/oracles/AllowlistComplianceOracle.sol";

import {AttestingRouter} from "./mocks/AttestingRouter.sol";
import {DirectLockAttacker} from "./mocks/DirectLockAttacker.sol";
import {
    ConfigurableComplianceOracle,
    RevertingComplianceOracle,
    GasBombComplianceOracle,
    ReturnBombComplianceOracle,
    ShortReturnComplianceOracle,
    StateWritingComplianceOracle
} from "./mocks/ComplianceOracleMocks.sol";

/// @title PermissionedPoolHookTest
/// @notice Proves the gate holds, and - just as importantly - proves the boundaries the hook's own
/// documentation claims for itself, so that a future change which quietly moves one of them fails
/// here rather than in production.
///
/// The load-bearing tests are the three in ATTACKS: an unpermitted party forging a permitted
/// identity by locking the Vault directly, the same forgery through an untrusted router, and the
/// demonstration that `sender` is the locker and never the trader.
contract PermissionedPoolHookTest is Test, Deployers, TokenFixture {
    using LPFeeLibrary for uint24;

    Vault vault;
    CLPoolManager poolManager;
    PermissionedPoolHook hook;
    AllowlistComplianceOracle oracle;

    /// @dev Trusted, and safe: builds `hookData` from `msg.sender`.
    AttestingRouter trustedRouter;
    /// @dev Identical code, deliberately NOT in `isTrustedRouter`.
    AttestingRouter untrustedRouter;
    /// @dev Trusted, and UNSAFE: forwards whatever `hookData` its caller supplies. Present to
    /// demonstrate the documented trust assumption, not as a router anyone should deploy.
    CLPoolManagerRouter permissiveTrustedRouter;
    /// @dev Not a router at all: locks the Vault itself.
    DirectLockAttacker attacker;

    PoolKey key;
    PoolId poolId;

    address constant INVESTOR = address(0xA11CE);
    address constant LP = address(0x11B0);
    address constant OUTSIDER = address(0x00757);
    address constant NOBODY = address(0xDEAD);

    uint24 constant STATIC_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    int256 constant LIQUIDITY = 1000 ether;
    int256 constant SWAP_IN = -1 ether;

    uint16 constant JURISDICTION_US = 840;
    uint16 constant JURISDICTION_KP = 408;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new PermissionedPoolHook(poolManager, address(this));
        oracle = new AllowlistComplianceOracle(address(this));

        trustedRouter = new AttestingRouter(vault, poolManager);
        untrustedRouter = new AttestingRouter(vault, poolManager);
        permissiveTrustedRouter = new CLPoolManagerRouter(vault, poolManager);
        attacker = new DirectLockAttacker(vault, poolManager);

        initializeTokens();
        mint(1_000_000 ether);

        key = _key(STATIC_FEE);
        poolId = key.toId();

        hook.configurePool(key, _defaultSettings());
        hook.setTrustedRouter(address(trustedRouter), true);
        hook.setTrustedRouter(address(permissiveTrustedRouter), true);

        _permit(INVESTOR, JURISDICTION_US);
        _permit(LP, JURISDICTION_US);

        poolManager.initialize(key, SQRT_RATIO_1_1);

        _fund(LP, 100_000 ether);
        _fund(INVESTOR, 100_000 ether);
        _fund(OUTSIDER, 100_000 ether);
        _fund(address(this), 0);

        _addLiquidityAs(LP, LIQUIDITY);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: fee,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });
    }

    function _defaultSettings() internal view returns (PermissionedPoolHook.PoolSettings memory) {
        return PermissionedPoolHook.PoolSettings({
            oracle: IComplianceOracle(address(oracle)),
            maxSwapPerTx: 0,
            maxLiquidityPerInvestor: 0,
            enabled: true,
            checkJurisdiction: false,
            freezeDeniedExits: false
        });
    }

    function _permit(address account, uint16 jurisdiction) internal {
        oracle.setRecord(
            account,
            AllowlistComplianceOracle.Record({permitted: true, expiresAt: 0, jurisdiction: jurisdiction})
        );
    }

    function _fund(address who, uint256 amount) internal {
        if (amount != 0 && who != address(this)) {
            IERC20(Currency.unwrap(currency0)).transfer(who, amount);
            IERC20(Currency.unwrap(currency1)).transfer(who, amount);
        }
        vm.startPrank(who);
        IERC20(Currency.unwrap(currency0)).approve(address(trustedRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(trustedRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(untrustedRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(untrustedRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(permissiveTrustedRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(permissiveTrustedRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (ICLPoolManager.SwapParams memory)
    {
        return ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _liquidityParams(int256 liquidityDelta)
        internal
        pure
        returns (ICLPoolManager.ModifyLiquidityParams memory)
    {
        return ICLPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: liquidityDelta,
            salt: 0
        });
    }

    function _swapAs(address who, AttestingRouter router) internal returns (BalanceDelta) {
        vm.prank(who);
        return router.swap(key, _swapParams(true, SWAP_IN));
    }

    function _addLiquidityAs(address who, int256 liquidityDelta) internal {
        vm.prank(who);
        trustedRouter.modifyPosition(key, _liquidityParams(liquidityDelta));
    }

    /// @dev A swap through a TRUSTED router that forwards caller-chosen `hookData` verbatim.
    function _swapWithHookData(address who, bytes memory hookData) internal returns (BalanceDelta) {
        vm.prank(who);
        return permissiveTrustedRouter.swap(
            key,
            _swapParams(true, SWAP_IN),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            hookData
        );
    }

    /// @dev Core wraps a reverting hook in ERC-7751 `WrappedError`. Rebuild that envelope so tests
    /// assert on the hook's own error rather than on a generic failure.
    function _expectHookRevert(bytes4 hookFn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookFn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _expectSwapRevert(bytes memory inner) internal {
        _expectHookRevert(ICLHooks.beforeSwap.selector, inner);
    }

    /*//////////////////////////////////////////////////////////////
        ATTACKS - the three tests this contract exists for
    //////////////////////////////////////////////////////////////*/

    /// @notice THE ATTACK. An unpermitted party locks the Vault directly and names a permitted
    /// investor in `hookData`. Against a hook that decodes an identity out of `hookData` and
    /// checks it against an allowlist, this trades. It must not trade here.
    ///
    /// The revert must name the ATTACKER's own address, which is what proves the check ran against
    /// the Vault locker rather than against anything the attacker supplied.
    function test_attack_forgedIdentity_viaDirectVaultLock_reverts() public {
        // The forged identity is genuinely permitted. That is the point: the attestation is
        // "valid" in every respect except that nobody the owner trusts made it.
        (bool permitted,) = hook.previewCompliance(poolId, INVESTOR, ComplianceAction.Swap);
        assertTrue(permitted, "precondition: forged identity is a permitted one");

        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.UntrustedLocker.selector, address(attacker))
        );
        vm.prank(OUTSIDER);
        attacker.attackSwap(key, _swapParams(true, SWAP_IN), INVESTOR);
    }

    /// @notice The same forgery on the liquidity path. Adding liquidity is entry too.
    function test_attack_forgedIdentity_viaDirectVaultLock_addLiquidity_reverts() public {
        _expectHookRevert(
            ICLHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(PermissionedPoolHook.UntrustedLocker.selector, address(attacker))
        );
        vm.prank(OUTSIDER);
        attacker.attackAddLiquidity(key, _liquidityParams(1 ether), LP);
        // Nothing was minted under the forged identity.
        assertEq(hook.investorLiquidity(poolId, LP), uint256(LIQUIDITY));
    }

    /// @notice An UNTRUSTED router is rejected even when it attests perfectly.
    ///
    /// `untrustedRouter` is byte-for-byte identical to `trustedRouter` and attests the real caller.
    /// The only difference is that the owner never designated it. That difference alone must be
    /// enough, because "the code looks right" is not something the hook can verify.
    function test_attack_untrustedRouter_isRejected_evenWithAValidAttestation() public {
        // Identical call through the trusted router first, so the failure below cannot be blamed
        // on anything except the router's designation.
        _swapAs(INVESTOR, trustedRouter);

        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.UntrustedLocker.selector, address(untrustedRouter))
        );
        _swapAs(INVESTOR, untrustedRouter);
    }

    /// @notice `sender` is the Vault locker, never the trader. Proved twice, in both directions.
    ///
    /// This is the constraint the hook's entire design rests on. If it ever stopped holding, a
    /// per-wallet gate keyed on `sender` would start looking correct, which is how the naive
    /// version of this hook gets written.
    function test_sender_isTheLockerNotTheTrader() public {
        // 1. An EOA with no standing whatsoever drives the router. The trade succeeds, because the
        //    identity the hook judges came out of the attestation, not out of `sender` and not out
        //    of who sent the transaction.
        assertFalse(hook.isAllowlisted(OUTSIDER));
        vm.prank(OUTSIDER);
        permissiveTrustedRouter.swap(
            key,
            _swapParams(true, SWAP_IN),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            abi.encode(INVESTOR)
        );

        // 2. Denying the ROUTER's own address changes nothing, because the router's address is not
        //    the identity being checked. If `sender` were the trader, this would now revert.
        hook.setDenied(address(permissiveTrustedRouter), true);
        vm.prank(OUTSIDER);
        permissiveTrustedRouter.swap(
            key,
            _swapParams(true, SWAP_IN),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            abi.encode(INVESTOR)
        );
    }

    /// @notice The documented trust assumption, made explicit and asserted.
    ///
    /// A TRUSTED router that forwards caller-supplied `hookData` voids the gate completely: any
    /// caller names any permitted account and trades. The hook's header says this in words; this
    /// test says it in code, so that nobody reads "trusted router" as "audited router".
    ///
    /// It passing is not a bug. It failing would mean the trust model had silently changed.
    function test_trustModel_aTrustedRouterThatForwardsCallerBytes_voidsTheGate() public {
        assertFalse(hook.isAllowlisted(OUTSIDER));
        (bool outsiderPermitted,) = hook.previewCompliance(poolId, OUTSIDER, ComplianceAction.Swap);
        assertFalse(outsiderPermitted, "precondition: the caller is not permitted");

        // ...and yet:
        _swapWithHookData(OUTSIDER, abi.encode(INVESTOR));

        // The lesson, asserted: what protects the pool is the SET, not the code in it.
        hook.setTrustedRouter(address(permissiveTrustedRouter), false);
        _expectSwapRevert(
            abi.encodeWithSelector(
                PermissionedPoolHook.UntrustedLocker.selector, address(permissiveTrustedRouter)
            )
        );
        _swapWithHookData(OUTSIDER, abi.encode(INVESTOR));
    }

    /*//////////////////////////////////////////////////////////////
                       ATTESTATION DECODING
    //////////////////////////////////////////////////////////////*/

    function test_attestation_wrongLength_reverts() public {
        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.MalformedAttestation.selector, uint256(0)));
        _swapWithHookData(INVESTOR, "");

        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.MalformedAttestation.selector, uint256(64)));
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR, INVESTOR));
    }

    function test_attestation_dirtyHighBits_reverts() public {
        bytes32 raw = bytes32((uint256(1) << 200) | uint256(uint160(INVESTOR)));
        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.InvalidAttestation.selector, raw));
        _swapWithHookData(INVESTOR, abi.encodePacked(raw));
    }

    function test_attestation_zeroAddress_reverts() public {
        // The zero address is refused before the lists are consulted, so an issuer who allowlisted
        // it by accident is not exposed by that mistake.
        hook.setAllowlisted(address(1), true);
        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.InvalidAttestation.selector, bytes32(0)));
        _swapWithHookData(INVESTOR, abi.encode(address(0)));
    }

    /// @dev Any 32-byte word whose top 96 bits are clean and whose low 160 are non-zero decodes to
    /// exactly that address; anything else is refused. Fuzzed because this is the one place
    /// attacker-controlled bytes are parsed.
    function testFuzz_attestation_onlyCleanNonZeroAddressesAreAccepted(bytes32 raw) public {
        address decoded = address(uint160(uint256(raw)));
        bool clean = (uint256(raw) >> 160) == 0 && decoded != address(0);

        if (clean) {
            _permit(decoded, JURISDICTION_US);
            _swapWithHookData(INVESTOR, abi.encodePacked(raw));
        } else if (decoded == address(0) || (uint256(raw) >> 160) != 0) {
            _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.InvalidAttestation.selector, raw));
            _swapWithHookData(INVESTOR, abi.encodePacked(raw));
        }
    }

    /*//////////////////////////////////////////////////////////////
                       IDENTITY DECISION ORDER
    //////////////////////////////////////////////////////////////*/

    function test_denylist_overridesAllowlist() public {
        hook.setAllowlisted(OUTSIDER, true);
        _swapWithHookData(INVESTOR, abi.encode(OUTSIDER));

        hook.setDenied(OUTSIDER, true);
        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.AccountDenied.selector, OUTSIDER));
        _swapWithHookData(INVESTOR, abi.encode(OUTSIDER));
    }

    function test_allowlist_shortCircuitsADeadOracle() public {
        _setOracle(address(new RevertingComplianceOracle()));

        // The oracle is dead, so an account that depends on it is refused...
        _expectSwapRevert(
            abi.encodeWithSelector(
                PermissionedPoolHook.ComplianceOracleUnavailable.selector,
                address(hook.poolConfig(poolId).oracle),
                INVESTOR
            )
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));

        // ...while the issuer's own allowlisted desk keeps operating. This is what the allowlist
        // is for, and it is why it is consulted before the oracle rather than after it.
        hook.setAllowlisted(INVESTOR, true);
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_noOracle_meansAllowlistOnly() public {
        _setOracle(address(0));

        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.AccountNotPermitted.selector, INVESTOR));
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));

        hook.setAllowlisted(INVESTOR, true);
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    /*//////////////////////////////////////////////////////////////
                    ORACLE FAILURE MODES - ALL CLOSED
    //////////////////////////////////////////////////////////////*/

    function test_oracle_revertingFailsClosed() public {
        address bad = address(new RevertingComplianceOracle());
        _setOracle(bad);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.ComplianceOracleUnavailable.selector, bad, INVESTOR)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    /// @notice An oracle that burns every wei it is given must not take the transaction with it.
    /// EIP-150 leaves this frame 1/64 of its gas, which is what lets the hook revert cleanly.
    function test_oracle_gasBombFailsClosed_andIsBounded() public {
        address bad = address(new GasBombComplianceOracle());
        _setOracle(bad);

        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.ComplianceOracleUnavailable.selector, bad, INVESTOR)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_oracle_returnBombFailsClosed() public {
        address bad = address(new ReturnBombComplianceOracle());
        _setOracle(bad);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.ComplianceOracleUnavailable.selector, bad, INVESTOR)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_oracle_shortReturnFailsClosed() public {
        address bad = address(new ShortReturnComplianceOracle());
        _setOracle(bad);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.ComplianceOracleUnavailable.selector, bad, INVESTOR)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_oracle_notAContractFailsClosed() public {
        // A `staticcall` to an address with no code SUCCEEDS with empty return data. Without the
        // size check that would read as `permitted == false`... which is still closed, but for the
        // wrong reason. The size check is what makes it report unavailability honestly.
        address bad = address(0xBEEF);
        _setOracle(bad);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.ComplianceOracleUnavailable.selector, bad, INVESTOR)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_oracle_stateWritingFailsClosed() public {
        address bad = address(new StateWritingComplianceOracle());
        _setOracle(bad);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.ComplianceOracleUnavailable.selector, bad, INVESTOR)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_oracle_expiredAttestationIsRefused() public {
        ConfigurableComplianceOracle configurable = new ConfigurableComplianceOracle();
        _setOracle(address(configurable));

        uint64 expiry = uint64(block.timestamp + 1 days);
        configurable.set(true, expiry, JURISDICTION_US);
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));

        vm.warp(uint256(expiry) + 1);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.AttestationExpired.selector, INVESTOR, expiry)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    /// @notice A non-canonical return must not smuggle bits into the narrow fields.
    ///
    /// The oracle returns `expiresAt` with every high bit set above the low 64. If those bits were
    /// not masked, the expiry would read as astronomically far in the future and a genuinely
    /// expired attestation would pass.
    function test_oracle_dirtyReturnBitsAreMasked() public {
        ConfigurableComplianceOracle configurable = new ConfigurableComplianceOracle();
        _setOracle(address(configurable));

        uint64 expiry = uint64(block.timestamp + 1 days);
        bytes32 dirtyExpiry = bytes32((type(uint256).max << 64) | uint256(expiry));
        configurable.setRaw(bytes32(uint256(1)), dirtyExpiry, bytes32(uint256(JURISDICTION_US)));

        vm.warp(uint256(expiry) + 1);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.AttestationExpired.selector, INVESTOR, expiry)
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    /*//////////////////////////////////////////////////////////////
                            JURISDICTION
    //////////////////////////////////////////////////////////////*/

    function test_jurisdiction_ignoredUnlessEnabled() public {
        hook.setBlockedJurisdiction(poolId, JURISDICTION_US, true);
        // checkJurisdiction is off by default, so the code is not consulted at all.
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_jurisdiction_blockedWhenEnabled() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.checkJurisdiction = true;
        hook.configurePool(key, settings);

        hook.setBlockedJurisdiction(poolId, JURISDICTION_KP, true);
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));

        hook.setBlockedJurisdiction(poolId, JURISDICTION_US, true);
        _expectSwapRevert(
            abi.encodeWithSelector(
                PermissionedPoolHook.JurisdictionBlocked.selector, INVESTOR, JURISDICTION_US
            )
        );
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    /// @notice Code 0 is "not asserted", and it is screened like any other value. An issuer for
    /// whom "unknown" is unacceptable blocks it explicitly, and this is what that looks like.
    function test_jurisdiction_unknownIsScreenedLikeAnyOther() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.checkJurisdiction = true;
        hook.configurePool(key, settings);

        _permit(OUTSIDER, 0);
        _swapWithHookData(INVESTOR, abi.encode(OUTSIDER));

        hook.setBlockedJurisdiction(poolId, 0, true);
        _expectSwapRevert(
            abi.encodeWithSelector(PermissionedPoolHook.JurisdictionBlocked.selector, OUTSIDER, uint16(0))
        );
        _swapWithHookData(INVESTOR, abi.encode(OUTSIDER));
    }

    /*//////////////////////////////////////////////////////////////
                                 CAPS
    //////////////////////////////////////////////////////////////*/

    function test_maxSwapPerTx_enforced() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.maxSwapPerTx = 1 ether;
        hook.configurePool(key, settings);

        _swapWithHookData(INVESTOR, abi.encode(INVESTOR)); // exactly at the cap

        _expectSwapRevert(
            abi.encodeWithSelector(
                PermissionedPoolHook.SwapExceedsMaxPerTx.selector, uint256(1 ether + 1), uint128(1 ether)
            )
        );
        vm.prank(INVESTOR);
        permissiveTrustedRouter.swap(
            key,
            _swapParams(true, -(1 ether + 1)),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            abi.encode(INVESTOR)
        );
    }

    /// @notice `beforeSwap` cannot know the input of an exact-output swap, so while the cap is
    /// active such a swap is rejected outright rather than waved through.
    function test_exactOutput_blockedWhileTradeCapActive() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.maxSwapPerTx = 1 ether;
        hook.configurePool(key, settings);

        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.ExactOutputBlockedByTradeCap.selector));
        vm.prank(INVESTOR);
        permissiveTrustedRouter.swap(
            key,
            _swapParams(true, 0.1 ether),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            abi.encode(INVESTOR)
        );
    }

    function test_exactOutput_allowedWhenNoTradeCap() public {
        vm.prank(INVESTOR);
        permissiveTrustedRouter.swap(
            key,
            _swapParams(true, 0.1 ether),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            abi.encode(INVESTOR)
        );
    }

    function test_investorLiquidityCap_enforcedAndAccumulated() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.maxLiquidityPerInvestor = uint128(uint256(LIQUIDITY) + 10 ether);
        hook.configurePool(key, settings);

        assertEq(hook.investorLiquidity(poolId, LP), uint256(LIQUIDITY));

        _addLiquidityAs(LP, 10 ether);
        assertEq(hook.investorLiquidity(poolId, LP), uint256(LIQUIDITY) + 10 ether);

        _expectHookRevert(
            ICLHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(
                PermissionedPoolHook.InvestorLiquidityCapExceeded.selector,
                LP,
                uint256(LIQUIDITY) + 11 ether,
                uint128(uint256(LIQUIDITY) + 10 ether)
            )
        );
        _addLiquidityAs(LP, 1 ether);
    }

    /// @notice The accumulator falls on an attributable exit and saturates at zero. It is an
    /// over-estimate by design: an exit the hook cannot attribute does not decrement it.
    function test_investorLiquidityAccumulator_fallsOnAttributedExit() public {
        assertEq(hook.investorLiquidity(poolId, LP), uint256(LIQUIDITY));
        _addLiquidityAs(LP, -LIQUIDITY);
        assertEq(hook.investorLiquidity(poolId, LP), 0);
    }

    function test_resetInvestorLiquidity_onlyOwnerAndEvented() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));
        hook.resetInvestorLiquidity(poolId, LP, 0);

        hook.resetInvestorLiquidity(poolId, LP, 5);
        assertEq(hook.investorLiquidity(poolId, LP), 5);
    }

    /*//////////////////////////////////////////////////////////////
                    EXIT IS NEVER TRAPPED
    //////////////////////////////////////////////////////////////*/

    /// @notice The central promise of the design: none of the levers that stop ENTRY may stop an
    /// EXIT. Every one of them is switched on at once here, and the withdrawal still works.
    function test_exit_survivesEverySwitchBeingOff() public {
        _setOracle(address(new RevertingComplianceOracle())); // oracle dead
        hook.pause(); // global pause on
        hook.setTrustedRouter(address(trustedRouter), false); // router de-trusted
        hook.setDenied(LP, true); // LP denylisted (freeze is OFF)

        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.enabled = false; // pool disabled
        settings.oracle = IComplianceOracle(address(new RevertingComplianceOracle()));
        hook.configurePool(key, settings);

        // ...and the LP still gets their capital back.
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(LP);
        _addLiquidityAs(LP, -LIQUIDITY);
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(LP), before0);
    }

    /// @notice A fee collection is `modifyLiquidity` with `liquidityDelta == 0`, which core routes
    /// to `beforeRemoveLiquidity`. It is covered by the same guarantee.
    function test_exit_feeCollectionSurvivesAPause() public {
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR)); // generate fees
        hook.pause();
        _addLiquidityAs(LP, 0);
    }

    /// @notice Garbage `hookData` on the way out must not brick a withdrawal. The exit path
    /// decodes leniently for exactly this reason.
    function test_exit_malformedHookDataDoesNotBlockWithdrawal() public {
        vm.prank(LP);
        permissiveTrustedRouter.modifyPosition(key, _liquidityParams(LIQUIDITY), abi.encode(LP));

        vm.prank(LP);
        permissiveTrustedRouter.modifyPosition(key, _liquidityParams(-LIQUIDITY), hex"deadbeef");
    }

    /// @notice `freezeDeniedExits` is the one exception, and it is partial by construction.
    function test_exit_freezeDeniedExits_blocksOnlyTheAttributableRoute() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.freezeDeniedExits = true;
        hook.configurePool(key, settings);
        hook.setDenied(LP, true);

        _expectHookRevert(
            ICLHooks.beforeRemoveLiquidity.selector,
            abi.encodeWithSelector(PermissionedPoolHook.AccountDenied.selector, LP)
        );
        _addLiquidityAs(LP, -LIQUIDITY);

        // The freeze binds to the ATTESTED identity, so a route the hook cannot attribute is not
        // frozen. This is a limitation the hook documents; it is asserted so nobody mistakes the
        // freeze for a custody-level control.
        hook.setTrustedRouter(address(trustedRouter), false);
        _addLiquidityAs(LP, -LIQUIDITY);
    }

    /// @notice An untrusted locker may reach the removal path, and gains nothing by it: core keys
    /// a position by `(locker, tickLower, tickUpper, salt)` and this locker owns none.
    function test_exit_untrustedLockerReachesRemovalAndRemovesNothing() public {
        uint128 liquidityBefore = poolManager.getLiquidity(poolId);
        vm.expectRevert(); // core rejects the position math; the hook waved it through
        vm.prank(OUTSIDER);
        attacker.attackRemoveLiquidity(key, _liquidityParams(-LIQUIDITY), abi.encode(LP));
        assertEq(poolManager.getLiquidity(poolId), liquidityBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        POOL LIFECYCLE / ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_initialize_rejectsUnconfiguredPool() public {
        PoolKey memory other = _key(STATIC_FEE + 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(PermissionedPoolHook.PoolNotConfigured.selector, other.toId()),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(other, SQRT_RATIO_1_1);
    }

    /// @notice A dynamic-fee pool is refused at BOTH the configuration and the initialization
    /// step, because this hook returns no fee override and such a pool would trade at zero fee
    /// forever. `isDynamicLPFee` is exact equality with 0x800000, not a bitmask.
    function test_dynamicFeePool_isRefusedTwice() public {
        PoolKey memory dynamicKey = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);

        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionedPoolHook.PoolMustUseStaticFee.selector, LPFeeLibrary.DYNAMIC_FEE_FLAG
            )
        );
        hook.configurePool(dynamicKey, _defaultSettings());
    }

    /// @notice A fee that merely SHARES bits with the dynamic marker is an ordinary static fee.
    /// Testing `fee & FLAG != 0` instead of `fee == FLAG` would reject it, and would also mean a
    /// fee override was being returned on a pool core would ignore it on.
    function test_staticFeeSharingBitsWithTheDynamicMarker_isAccepted() public {
        uint24 shares = LPFeeLibrary.DYNAMIC_FEE_FLAG | uint24(500);
        assertTrue(shares & LPFeeLibrary.DYNAMIC_FEE_FLAG != 0, "shares bits with the marker");
        assertFalse(shares == LPFeeLibrary.DYNAMIC_FEE_FLAG, "but is not the marker");

        // Not a dynamic pool, so configuration is permitted. A bitmask test would have refused it.
        PoolKey memory sharedBits = _key(shares);
        hook.configurePool(sharedBits, _defaultSettings());
        assertTrue(hook.poolConfig(sharedBits.toId()).configured);
    }

    function test_configurePool_rejectsForeignKeys() public {
        PoolKey memory foreign = _key(STATIC_FEE);
        foreign.hooks = IHooks(address(0xF00));
        vm.expectRevert(abi.encodeWithSelector(PermissionedPoolHook.HookMismatch.selector, address(0xF00)));
        hook.configurePool(foreign, _defaultSettings());

        foreign = _key(STATIC_FEE);
        foreign.poolManager = ICLPoolManager(address(0xF01));
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedPoolHook.PoolManagerMismatch.selector, address(0xF01))
        );
        hook.configurePool(foreign, _defaultSettings());
    }

    function test_admin_onlyOwner() public {
        vm.startPrank(OUTSIDER);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER);

        vm.expectRevert(denied);
        hook.configurePool(key, _defaultSettings());
        vm.expectRevert(denied);
        hook.setTrustedRouter(OUTSIDER, true);
        vm.expectRevert(denied);
        hook.setAllowlisted(OUTSIDER, true);
        vm.expectRevert(denied);
        hook.setDenied(INVESTOR, true);
        vm.expectRevert(denied);
        hook.setBlockedJurisdiction(poolId, JURISDICTION_US, true);
        vm.expectRevert(denied);
        hook.pause();
        vm.stopPrank();
    }

    function test_pause_stopsEntryNotExit() public {
        hook.pause();

        _expectSwapRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));

        _expectHookRevert(
            ICLHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        _addLiquidityAs(LP, 1 ether);

        _addLiquidityAs(LP, -1 ether); // exit unaffected

        hook.unpause();
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));
    }

    function test_enabledFlag_stopsEntryNotExit() public {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.enabled = false;
        hook.configurePool(key, settings);

        _expectSwapRevert(abi.encodeWithSelector(PermissionedPoolHook.TradingDisabled.selector, poolId));
        _swapWithHookData(INVESTOR, abi.encode(INVESTOR));

        _addLiquidityAs(LP, -1 ether);
    }

    function test_setTrustedRouter_rejectsZeroAndEmits() public {
        vm.expectRevert(abi.encodeWithSelector(PermissionedPoolHook.ZeroAddress.selector));
        hook.setTrustedRouter(address(0), true);
    }

    function test_registrationBitmap_matchesTheCallbacksImplemented() public view {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        assertEq(bitmap, uint16(1 | 4 | 16 | 64), "beforeInitialize|beforeAdd|beforeRemove|beforeSwap");
        // No returns-delta bits (10-13) and no reserved bits (14-15): this hook takes no value
        // from the pool, and core would reject the pool key if it claimed otherwise.
        assertEq(bitmap & uint16(0xFC00), 0, "no delta or reserved bits");
    }

    /*//////////////////////////////////////////////////////////////
                          PREVIEW CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice `previewCompliance` must agree with what `beforeSwap` actually does, or every
    /// front-end built on it is lying to users.
    function testFuzz_preview_agreesWithEnforcement(bool denied, bool allowed, bool oraclePermits, uint64 expiry)
        public
    {
        ConfigurableComplianceOracle configurable = new ConfigurableComplianceOracle();
        _setOracle(address(configurable));
        configurable.set(oraclePermits, expiry, JURISDICTION_US);

        if (denied) hook.setDenied(OUTSIDER, true);
        if (allowed) hook.setAllowlisted(OUTSIDER, true);

        (bool permitted, bytes memory reason) = hook.previewCompliance(poolId, OUTSIDER, ComplianceAction.Swap);

        if (permitted) {
            assertEq(reason.length, 0);
            _swapWithHookData(INVESTOR, abi.encode(OUTSIDER));
        } else {
            _expectSwapRevert(reason);
            _swapWithHookData(INVESTOR, abi.encode(OUTSIDER));
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setOracle(address newOracle) internal {
        PermissionedPoolHook.PoolSettings memory settings = _defaultSettings();
        settings.oracle = IComplianceOracle(newOracle);
        hook.configurePool(key, settings);
    }
}
