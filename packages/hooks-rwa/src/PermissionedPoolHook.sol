/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

import {IComplianceOracle, ComplianceAction} from "./interfaces/IComplianceOracle.sol";

/// @title PermissionedPoolHook
/// @notice A compliance-gated CL pool for tokenized real-world assets: every swap and every
/// liquidity addition must be performed on behalf of an account a pluggable compliance oracle
/// says is permitted.
///
/// @dev ################### NO LEGAL ADVICE IS GIVEN OR IMPLIED ###################
///
/// This contract is a MECHANISM. It gates pool operations on the answer an issuer-chosen oracle
/// gives about an issuer-chosen identity. Whether any particular configuration of it satisfies any
/// particular securities law, sanctions regime, transfer-agent obligation, exchange-registration
/// requirement, or investor-suitability rule in any jurisdiction is a question for the issuer's
/// counsel. It is not answered here, it is not answered by the code, and no statement in this
/// repository should be read as answering it.
///
/// #####################################################################################
/// ############ THE CONSTRAINT THAT DETERMINES THIS ENTIRE DESIGN ############
/// #####################################################################################
///
///   THE `sender` ARGUMENT OF EVERY HOOK CALLBACK IS THE VAULT LOCKER, NOT THE END USER.
///
/// `CLHooks.beforeSwap` invokes this hook with `abi.encodeCall(ICLHooks.beforeSwap, (msg.sender,
/// key, params, hookData))`, where `msg.sender` is whoever locked the Vault - the router. Every
/// swap routed through one shared router arrives with the SAME `sender`. And `hookData` is
/// arbitrary attacker-controlled calldata, because anybody may bypass a router entirely, lock the
/// Vault themselves and call `poolManager.swap` with whatever bytes they like.
///
/// Therefore the naive compliance hook - "decode a user out of `hookData` and check it against an
/// allowlist" - ENFORCES NOTHING. An unpermitted party simply names a permitted party in their own
/// `hookData` and trades. Shipping that and calling it compliance is worse than shipping nothing,
/// because it manufactures a false assurance.
///
/// ------------------------------ THE MODEL THIS HOOK USES ------------------------------
///
/// TRUSTED-ROUTER ATTESTATION, with an owner-curated router set:
///
///   1. `beforeSwap` and `beforeAddLiquidity` REVERT unless `sender` is in `isTrustedRouter`.
///      `sender` is the one identity in the callback that cannot be forged: it is established by
///      the Vault lock, not supplied as data. Locking the Vault directly, or routing through any
///      contract the owner has not designated, therefore cannot reach the pool at all.
///
///   2. A trusted router places the end user it authenticated into `hookData`, as a bare
///      `abi.encode(address)`. The hook checks THAT account against the denylist, the local
///      allowlist and the compliance oracle.
///
///   3. `beforeRemoveLiquidity` is deliberately NOT gated this way. See "EXIT IS NEVER TRAPPED".
///
/// WHO YOU ARE TRUSTING, STATED PLAINLY:
///
///   * Every address in `isTrustedRouter`, completely. A trusted router can attest any address it
///     likes and the hook will believe it. If a trusted router is malicious, buggy, upgradeable to
///     something malicious, or merely permissionless in a way the issuer did not intend, then the
///     compliance gate on this pool is void. Adding a router to this set is the single
///     highest-consequence action the owner can take. Treat it like `Vault.registerApp`.
///
///   * The compliance oracle, for the accuracy and freshness of its answers.
///
///   * The owner, who controls both of the above.
///
/// THIS DESIGN WAS CHOSEN OVER THE ALTERNATIVES DELIBERATELY:
///
///   * "Gate liquidity only, leave swaps open" is honest but does not produce a permissioned
///     market: anyone could still buy the security. Rejected as insufficient for the stated goal.
///
///   * Token-level enforcement (ERC-1404 / ERC-3643 style, where the RWA token's own `transfer`
///     rejects non-permitted holders) is STRICTLY STRONGER than anything a hook can do, because it
///     binds to custody rather than to a call path. It is not an alternative to this hook, it is
///     the layer this hook should sit on top of. See "USE A PERMISSIONED TOKEN AS WELL" below.
///
/// ------------------------------ WHAT IS ACTUALLY ENFORCED ------------------------------
///
///  * No swap and no liquidity addition can occur except through an owner-designated router.
///    Enforced unconditionally, against the unforgeable `sender`. This is the load-bearing part.
///  * For every swap and addition, the account the router attests is checked: not on the denylist,
///    and either on the local allowlist or approved by the oracle, with an unexpired attestation,
///    and (optionally) not in a blocked jurisdiction.
///  * A per-pool per-investor cap on cumulative liquidity contributed under one attested identity.
///  * A per-pool cap on the input notional of a single swap.
///  * A global pause that stops trading and additions, and an `enabled` flag per pool.
///  * The pool cannot be initialized at all until the owner has configured it, and cannot be a
///    dynamic-fee pool (this hook returns no fee override, which would leave such a pool at 0 fee).
///
/// ------------------------------ WHAT IS NOT ENFORCED ------------------------------
///
///  * ANYTHING AT ALL, if a trusted router lies. The hook cannot audit its routers. See above.
///  * The identity of the party who ultimately RECEIVES the swap output. The hook sees the pool
///    delta, not the router's internal settlement, so a permitted account can trade on behalf of
///    an unpermitted one. Only the token's own transfer restrictions can close this.
///  * Onward transfer after the trade. Once tokens leave the pool this hook has no further say.
///  * Acquisition through any other venue: another pool (including an unpermissioned pool over the
///    same token pair), an OTC trade, a bridge, or a centralised exchange.
///  * Holder counts, holding periods, lock-ups, cap-table limits, dividend/corporate-action
///    handling, or anything else that is a property of the TOKEN rather than of this pool.
///  * Exit by a denied party through an untrusted route. See below.
///  * Whether the pool's liquidity providers are themselves permitted to be market-makers in a
///    security in their jurisdiction. That is a question about them, not about the pool.
///
/// ------------------------------ EXIT IS NEVER TRAPPED ------------------------------
///
/// A compliance oracle is off-chain infrastructure operated by a third party. It will, at some
/// point, be down, misconfigured, or replaced. The consequences of that must be asymmetric:
///
///   ENTRY FAILS CLOSED.  If the oracle reverts, runs out of the gas budget, returns the wrong
///   number of bytes, or is not a contract, `beforeSwap` and `beforeAddLiquidity` REVERT. A
///   compliance gate whose failure mode is "let everyone in" is not a gate.
///
///   EXIT FAILS OPEN.  `beforeRemoveLiquidity` never calls the oracle, never checks the pause,
///   never checks `enabled`, and never requires a trusted router. Withdrawing is therefore
///   unaffected by oracle downtime, by a pause, by the owner de-trusting a router, or by the owner
///   abandoning the contract entirely.
///
/// The reasoning: withdrawing liquidity cannot be used to ACQUIRE the security from a third party.
/// Core keys a CL position by `(locker, tickLower, tickUpper, salt)`, so an arbitrary caller who
/// locks the Vault directly has no position and can remove nothing. The only thing an open exit
/// path permits is a party recovering assets that are already theirs. Weighed against that, the
/// alternative - an oracle outage or a lapsed owner key permanently confiscating LP capital - is
/// far worse, and it is a failure mode a compliance control should never be able to cause.
///
/// The one exception is deliberate and per-pool: `freezeDeniedExits`. When set, an account on the
/// LOCAL denylist cannot remove liquidity via a trusted router. This is the sanctions-freeze lever.
/// It is PARTIAL BY CONSTRUCTION - it cannot stop the same party exiting through a route the hook
/// cannot identify - and it is a genuine centralisation risk, since the owner can add any address
/// to the denylist. It is off by default.
///
/// Note that a fee collection (`modifyLiquidity` with `liquidityDelta == 0`) is routed by core to
/// `beforeRemoveLiquidity`, so accrued fees are claimable under exactly the same guarantee.
///
/// ------------------------------ USE A PERMISSIONED TOKEN AS WELL ------------------------------
///
/// This hook governs one pool. It does not govern the asset. An issuer who needs the transfer
/// restriction to survive outside this pool must put it in the token (ERC-1404 / ERC-3643 style),
/// at which point the token blocks non-permitted holders everywhere and this hook's job narrows to
/// gating pool ENTRY and enforcing pool-specific limits - which is exactly the division of labour
/// it is designed for. A permissioned pool over an unrestricted token restricts one venue and
/// nothing else.
///
/// ------------------------------ ADMIN ------------------------------
///
/// `Ownable2Step`. On mainnet the owner MUST be `packages/governance/src/DeepCoreTimelock.sol` (or an
/// equivalent multisig + timelock), never an EOA: the owner can change the oracle, change the
/// trusted-router set, and - if `freezeDeniedExits` is on - freeze an LP's exit. Every state change
/// emits an event so the timelock queue and the resulting state are both auditable off-chain.
/// #####################################################################################
contract PermissionedPoolHook is BaseCLHook, Ownable2Step, Pausable {
    using LPFeeLibrary for uint24;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool key does not name this contract as its hook
    error HookMismatch(address declared);

    /// @notice The pool key names a different pool manager than this hook serves
    error PoolManagerMismatch(address declared);

    /// @notice This hook returns no LP fee override, so a dynamic-fee pool would sit at 0 fee
    /// forever. Reject such a pool rather than silently running a free market in a security.
    error PoolMustUseStaticFee(uint24 fee);

    /// @notice The owner has not configured this pool id
    error PoolNotConfigured(PoolId poolId);

    /// @notice The pool is configured but the owner has disabled trading on it
    error TradingDisabled(PoolId poolId);

    /// @notice The Vault locker is not an owner-designated router, so no identity can be trusted
    /// @dev THE load-bearing check. See the contract-level note.
    error UntrustedLocker(address sender);

    /// @notice `hookData` is not exactly one ABI-encoded address
    error MalformedAttestation(uint256 length);

    /// @notice `hookData` decodes to the zero address or has dirty high-order bits
    error InvalidAttestation(bytes32 raw);

    /// @notice The attested account is on this hook's local denylist
    error AccountDenied(address account);

    /// @notice The compliance oracle says the attested account may not perform this action
    error AccountNotPermitted(address account);

    /// @notice The oracle's answer carried an expiry that has passed
    error AttestationExpired(address account, uint64 expiresAt);

    /// @notice The account's jurisdiction is blocked for this pool
    error JurisdictionBlocked(address account, uint16 jurisdiction);

    /// @notice The oracle reverted, exceeded its gas budget, returned the wrong number of bytes,
    /// or is not a contract. Entry fails closed; see the contract-level note.
    error ComplianceOracleUnavailable(address oracle, address account);

    /// @notice A swap's input amount exceeded the pool's per-transaction cap
    error SwapExceedsMaxPerTx(uint256 amountIn, uint128 maxSwapPerTx);

    /// @notice An exact-output swap was attempted while a per-transaction input cap is active.
    /// @dev `beforeSwap` cannot know the input amount of an exact-output swap, so the cap cannot be
    /// checked on one. Waving it through would be a one-line bypass, so it is rejected instead.
    error ExactOutputBlockedByTradeCap();

    /// @notice Cumulative liquidity attributed to this investor would exceed the pool's cap
    error InvestorLiquidityCapExceeded(address account, uint256 attempted, uint128 cap);

    /// @notice A zero address was supplied where a real one is required
    error ZeroAddress();

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every accepted pool configuration write, including the first
    event PoolConfigured(
        PoolId indexed poolId,
        address indexed oracle,
        uint128 maxSwapPerTx,
        uint128 maxLiquidityPerInvestor,
        bool enabled,
        bool checkJurisdiction,
        bool freezeDeniedExits
    );

    /// @notice Emitted when a router is added to or removed from the trusted set.
    /// @dev The highest-consequence event this contract emits. A trusted router IS the compliance
    /// boundary; an indexer watching this hook should surface these first.
    event TrustedRouterSet(address indexed router, bool trusted);

    /// @notice Emitted when an account is added to or removed from the local allowlist
    event AllowlistSet(address indexed account, bool allowed);

    /// @notice Emitted when an account is added to or removed from the local denylist
    event DenylistSet(address indexed account, bool denied);

    /// @notice Emitted when a jurisdiction is blocked or unblocked for a pool
    event JurisdictionBlockSet(PoolId indexed poolId, uint16 indexed jurisdiction, bool blocked);

    /// @notice Emitted when the owner overrides an investor's tracked liquidity accumulator
    event InvestorLiquidityReset(PoolId indexed poolId, address indexed investor, uint256 previous, uint256 current);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas forwarded to the compliance oracle, per query.
    /// @dev Capped so a broken or hostile oracle cannot burn the caller's whole gas budget, and so
    /// an oracle cannot grief the pool by looping. An oracle that needs more than this is denied,
    /// which is the fail-closed direction. Generous enough for several storage reads plus a
    /// delegated lookup; far too small to loop over an unbounded set.
    uint256 public constant ORACLE_GAS_LIMIT = 250_000;

    /// @notice Exact ABI return size of `IComplianceOracle.checkCompliance`: three words.
    /// @dev Checked before any return data is copied, which is also what defeats a return bomb.
    uint256 internal constant ORACLE_RETURN_SIZE = 0x60;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @param configured Set by `configurePool`. `beforeInitialize` refuses an unconfigured pool,
    ///        so an initialized pool on this hook is always a configured one.
    /// @param enabled Per-pool trading switch, independent of the global pause. Blocks swaps and
    ///        additions. Never blocks removals.
    /// @param checkJurisdiction Whether to screen the oracle's reported jurisdiction against this
    ///        pool's blocked list. Off means the reported code is ignored entirely.
    /// @param freezeDeniedExits Whether a denylisted account may be blocked from REMOVING
    ///        liquidity through a trusted router. Off by default; see the contract-level note.
    /// @param oracle The compliance source. `address(0)` is legal and means "local allowlist only":
    ///        every account that is not explicitly allowlisted is refused.
    /// @param maxSwapPerTx Cap on the INPUT amount of one swap, in the input currency's units.
    ///        0 disables the cap. While non-zero, exact-output swaps are rejected.
    /// @param maxLiquidityPerInvestor Cap on cumulative liquidity attributed to one attested
    ///        identity in this pool. 0 disables the cap.
    struct PoolConfig {
        // ---- slot 0: 8 + 8 + 8 + 8 + 160 = 192 bits ----
        bool configured;
        bool enabled;
        bool checkJurisdiction;
        bool freezeDeniedExits;
        IComplianceOracle oracle;
        // ---- slot 1: 128 + 128 = 256 bits ----
        uint128 maxSwapPerTx;
        uint128 maxLiquidityPerInvestor;
    }

    /// @notice Owner-supplied configuration. Mirrors `PoolConfig` minus the field the hook owns.
    struct PoolSettings {
        IComplianceOracle oracle;
        uint128 maxSwapPerTx;
        uint128 maxLiquidityPerInvestor;
        bool enabled;
        bool checkJurisdiction;
        bool freezeDeniedExits;
    }

    /// @notice Per-pool configuration
    mapping(PoolId poolId => PoolConfig) internal _pools;

    /// @notice Per-pool jurisdiction denylist, keyed by ISO-3166-1 numeric code
    mapping(PoolId poolId => mapping(uint16 jurisdiction => bool)) internal _blockedJurisdictions;

    /// @notice Cumulative liquidity attributed to an attested identity in a pool.
    /// @dev An ACCUMULATOR, not a position record: this hook cannot see core's position ownership.
    /// It rises on every attested add and falls on every attested remove, saturating at zero. A
    /// removal the hook cannot attribute (untrusted locker, or malformed `hookData` on the exit
    /// path) does not decrement it, so the value is an OVER-estimate of what the investor still
    /// holds. It therefore errs toward being too restrictive, never too permissive.
    mapping(PoolId poolId => mapping(address investor => uint256)) internal _investorLiquidity;

    /// @notice Routers the owner designates as able to attest an end user's identity.
    /// @dev The compliance boundary of the whole design. Read the contract-level note before
    /// adding anything to this set.
    mapping(address router => bool) public isTrustedRouter;

    /// @notice Accounts the owner permits without consulting the oracle (issuer treasury, AP,
    /// designated market maker). A local allowlist entry SHORT-CIRCUITS the oracle entirely.
    mapping(address account => bool) public isAllowlisted;

    /// @notice Accounts refused unconditionally, ahead of every other check, including the
    /// allowlist and the oracle. The sanctions lever.
    mapping(address account => bool) public isDenied;

    /// @param _poolManager The CL pool manager this hook serves.
    /// @param initialOwner Ownership seat. On mainnet this MUST be a timelock, not an EOA.
    constructor(ICLPoolManager _poolManager, address initialOwner)
        BaseCLHook(_poolManager)
        Ownable(initialOwner)
    {}

    /// @inheritdoc IHooks
    /// @dev `beforeInitialize` gates pool creation; `beforeSwap` and `beforeAddLiquidity` gate
    /// entry; `beforeRemoveLiquidity` maintains the investor accumulator and applies the optional
    /// exit freeze. No returns-delta permission: this hook takes no value from the pool.
    function getHooksRegistrationBitmap() public pure virtual override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP;
    }

    /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Create or replace the configuration for `key`'s pool.
    /// @dev Must be called before the pool can be initialized. May be called again afterwards to
    /// rotate the oracle or adjust limits; there is intentionally no way to UNconfigure a pool,
    /// because doing so would brick swaps on a live pool while leaving exits open in a way nobody
    /// could have anticipated from the events. Use `enabled = false` to halt a pool instead.
    function configurePool(PoolKey calldata key, PoolSettings calldata settings) external onlyOwner {
        if (address(key.hooks) != address(this)) revert HookMismatch(address(key.hooks));
        if (address(key.poolManager) != address(poolManager)) {
            revert PoolManagerMismatch(address(key.poolManager));
        }
        // Mirrors `beforeInitialize`, so a misconfiguration surfaces here rather than at pool
        // creation, when the issuer has already published the key.
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee(key.fee);

        PoolId poolId = key.toId();
        PoolConfig storage cfg = _pools[poolId];

        cfg.configured = true;
        cfg.enabled = settings.enabled;
        cfg.checkJurisdiction = settings.checkJurisdiction;
        cfg.freezeDeniedExits = settings.freezeDeniedExits;
        cfg.oracle = settings.oracle;
        cfg.maxSwapPerTx = settings.maxSwapPerTx;
        cfg.maxLiquidityPerInvestor = settings.maxLiquidityPerInvestor;

        emit PoolConfigured(
            poolId,
            address(settings.oracle),
            settings.maxSwapPerTx,
            settings.maxLiquidityPerInvestor,
            settings.enabled,
            settings.checkJurisdiction,
            settings.freezeDeniedExits
        );
    }

    /// @notice Designate (or undesignate) a router as able to attest end-user identity.
    /// @dev Undesignating a router does NOT trap the liquidity held through it: removals do not
    /// require a trusted locker. It does stop that router opening new positions or trading.
    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isTrustedRouter[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    /// @notice Batch form of `setTrustedRouter`
    function setTrustedRouters(address[] calldata routers, bool trusted) external onlyOwner {
        for (uint256 i = 0; i < routers.length; ++i) {
            address router = routers[i];
            if (router == address(0)) revert ZeroAddress();
            isTrustedRouter[router] = trusted;
            emit TrustedRouterSet(router, trusted);
        }
    }

    /// @notice Permit `account` without consulting the oracle.
    /// @dev The denylist still takes precedence, so an allowlist entry cannot un-deny an account.
    function setAllowlisted(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isAllowlisted[account] = allowed;
        emit AllowlistSet(account, allowed);
    }

    /// @notice Batch form of `setAllowlisted`
    function setAllowlistedBatch(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();
            isAllowlisted[account] = allowed;
            emit AllowlistSet(account, allowed);
        }
    }

    /// @notice Refuse `account` unconditionally, ahead of the allowlist and the oracle.
    function setDenied(address account, bool denied) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isDenied[account] = denied;
        emit DenylistSet(account, denied);
    }

    /// @notice Batch form of `setDenied`
    function setDeniedBatch(address[] calldata accounts, bool denied) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();
            isDenied[account] = denied;
            emit DenylistSet(account, denied);
        }
    }

    /// @notice Block or unblock an ISO-3166-1 numeric country code for one pool.
    /// @dev Only consulted when the pool sets `checkJurisdiction`. Code 0 means "the oracle did not
    /// assert a jurisdiction"; block it explicitly if unknown is unacceptable.
    function setBlockedJurisdiction(PoolId poolId, uint16 jurisdiction, bool blocked) external onlyOwner {
        _blockedJurisdictions[poolId][jurisdiction] = blocked;
        emit JurisdictionBlockSet(poolId, jurisdiction, blocked);
    }

    /// @notice Overwrite the tracked liquidity accumulator for one investor in one pool.
    /// @dev The accumulator drifts upward whenever a removal cannot be attributed (see the mapping
    /// doc), so an issuer needs a way to correct it. This affects ONLY the per-investor cap; it can
    /// neither move funds nor alter any position. It is still an admin power over an investor's
    /// ability to add, and it is therefore evented.
    function resetInvestorLiquidity(PoolId poolId, address investor, uint256 amount) external onlyOwner {
        uint256 previous = _investorLiquidity[poolId][investor];
        _investorLiquidity[poolId][investor] = amount;
        emit InvestorLiquidityReset(poolId, investor, previous, amount);
    }

    /// @notice Halt swaps and liquidity additions across every pool on this hook.
    /// @dev Does NOT halt removals or fee collection - by design, and permanently so. See the
    /// contract-level note on exits.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume swaps and liquidity additions
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Permanently disabled. Reverts for every caller.
     *
     * @dev CLAUDE.md § "Deployed and unfixable" makes this the house rule for every contract
     * deployed from here on, and `MerkleEpochDistributor` is the reference.
     *
     * Every administrative function on this hook is `onlyOwner`, and most of them are the
     * RESTRICTING levers a compliance venue needs in an incident. Renouncing removes all of them at
     * once, permanently:
     *
     *   * `pause` becomes one-way. A hook renounced while paused refuses every swap and every
     *     liquidity addition forever, because `unpause` is `onlyOwner`.
     *   * The denylist freezes. No account can ever be added to it again, so the sanctions lever
     *     is gone, and a denied account can never be released either.
     *   * The trusted-router set freezes. A router later found to forward caller-supplied bytes —
     *     which voids the identity gate entirely — can never be removed.
     *   * The compliance oracle, the trade caps and the jurisdiction list can never change.
     *
     * LP exits survive, as the contract-level note guarantees. It is still an irreversible loss
     * of every control this contract exists to provide, and `transferOwnership` is itself
     * `onlyOwner`.
     *
     * Deliberately NOT `virtual`: `StockPairHook` inherits this override, and a subclass should
     * not be able to re-enable renouncing by accident.
     *
     * The bounded form of the same intent already exists and is unaffected: an owner who wants out
     * transfers to the address that should have it. `Ownable2Step` means that cannot land somewhere
     * unreachable by typo.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev This hook takes no hook delta and has no `receive`: it never holds value by design, so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Full configuration record for a pool id
    function poolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _pools[poolId];
    }

    /// @notice Cumulative liquidity this hook attributes to `investor` in `poolId`
    function investorLiquidity(PoolId poolId, address investor) external view returns (uint256) {
        return _investorLiquidity[poolId][investor];
    }

    /// @notice Whether an ISO-3166-1 numeric code is blocked for a pool
    function isJurisdictionBlocked(PoolId poolId, uint16 jurisdiction) external view returns (bool) {
        return _blockedJurisdictions[poolId][jurisdiction];
    }

    /// @notice The `hookData` a trusted router must pass to attest `account`
    function encodeAttestation(address account) external pure returns (bytes memory) {
        return abi.encode(account);
    }

    /// @notice Dry-run the compliance decision for `account`, without the router or pause checks.
    /// @dev For routers and front-ends to pre-flight a trade. It answers ONLY the identity
    /// question; a `true` here does not mean the swap will succeed, because the caller must still
    /// be a trusted router and the pool must be enabled, unpaused and within its caps.
    /// @return permitted Whether the identity checks pass.
    /// @return reason Empty on success; otherwise the ABI-encoded custom error that
    ///         `beforeSwap` would have reverted with, so a caller can surface the exact cause.
    function previewCompliance(PoolId poolId, address account, ComplianceAction action)
        external
        view
        returns (bool permitted, bytes memory reason)
    {
        PoolConfig storage cfg = _pools[poolId];
        if (!cfg.configured) return (false, abi.encodeWithSelector(PoolNotConfigured.selector, poolId));
        return _checkPermitted(poolId, cfg, account, action);
    }

    /*//////////////////////////////////////////////////////////////
                          COMPLIANCE EVALUATION
    //////////////////////////////////////////////////////////////*/

    /// @dev The whole identity decision, in one place, so the swap path, the add path and the
    /// preview view can never disagree about what "permitted" means.
    ///
    /// Order matters and is deliberate:
    ///   1. DENYLIST first. It overrides everything, including the allowlist. A sanctions hit must
    ///      not be defeatable by a stale allowlist entry the issuer forgot to clear.
    ///   2. ALLOWLIST next, short-circuiting the oracle. This is what keeps the issuer's own
    ///      treasury able to operate during an oracle outage.
    ///   3. ORACLE last, and only if the first two did not decide. An unset oracle is not an
    ///      error: it means "allowlist only", and everyone else is simply not permitted.
    function _checkPermitted(PoolId poolId, PoolConfig storage cfg, address account, ComplianceAction action)
        internal
        view
        returns (bool, bytes memory)
    {
        if (isDenied[account]) return (false, abi.encodeWithSelector(AccountDenied.selector, account));
        if (isAllowlisted[account]) return (true, "");

        IComplianceOracle oracle = cfg.oracle;
        if (address(oracle) == address(0)) {
            return (false, abi.encodeWithSelector(AccountNotPermitted.selector, account));
        }

        (bool callOk, bool permitted, uint64 expiresAt, uint16 jurisdiction) =
            _queryOracle(oracle, account, poolId, action);

        // Fails CLOSED: a revert, an out-of-gas inside the budget, a non-contract, or any return
        // that is not exactly three words all land here.
        if (!callOk) {
            return (false, abi.encodeWithSelector(ComplianceOracleUnavailable.selector, address(oracle), account));
        }
        if (!permitted) return (false, abi.encodeWithSelector(AccountNotPermitted.selector, account));
        if (expiresAt != 0 && block.timestamp > expiresAt) {
            return (false, abi.encodeWithSelector(AttestationExpired.selector, account, expiresAt));
        }
        if (cfg.checkJurisdiction && _blockedJurisdictions[poolId][jurisdiction]) {
            return (false, abi.encodeWithSelector(JurisdictionBlocked.selector, account, jurisdiction));
        }
        return (true, "");
    }

    /// @dev `_checkPermitted`, but reverting with the reason instead of returning it.
    function _requirePermitted(PoolId poolId, PoolConfig storage cfg, address account, ComplianceAction action)
        internal
        view
    {
        (bool permitted, bytes memory reason) = _checkPermitted(poolId, cfg, account, action);
        if (!permitted) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    /// @notice Query the oracle without letting it damage the caller.
    ///
    /// @dev A raw `staticcall` rather than `try/catch` for three specific reasons:
    ///
    ///   * GAS. `ORACLE_GAS_LIMIT` bounds what a looping oracle can burn. (EIP-150 also retains
    ///     1/64th of the remaining gas for this frame regardless, so an oracle that consumes its
    ///     whole budget still leaves the hook able to revert cleanly rather than dying too.)
    ///
    ///   * RETURN BOMBS. `returndatasize` is compared to the exact expected size BEFORE anything is
    ///     copied. A hostile oracle returning megabytes cannot force this contract to pay for the
    ///     memory expansion, which a `try/catch` decoding into `bytes memory` would.
    ///
    ///   * DIRTY BITS. Values are masked to their declared widths on the way out, so a
    ///     non-canonically-encoded return cannot smuggle high-order bits into a `uint64`/`uint16`
    ///     and produce nonsense in downstream comparisons.
    ///
    /// A `staticcall` to an address with no code succeeds with `returndatasize == 0`, which fails
    /// the size check, so "oracle is an EOA / self-destructed / not yet deployed" is reported as
    /// unavailable rather than silently succeeding.
    ///
    /// @return callOk False if the oracle reverted, exceeded its budget, is not a contract, or
    ///         returned anything other than exactly three words.
    function _queryOracle(IComplianceOracle oracle, address account, PoolId poolId, ComplianceAction action)
        internal
        view
        returns (bool callOk, bool permitted, uint64 expiresAt, uint16 jurisdiction)
    {
        bytes memory callData = abi.encodeCall(IComplianceOracle.checkCompliance, (account, poolId, action));

        // Bound to locals: inline assembly reads stack slots, not the constant table.
        uint256 gasBudget = ORACLE_GAS_LIMIT;
        uint256 returnSize = ORACLE_RETURN_SIZE;

        assembly ("memory-safe") {
            // Scratch above the free-memory pointer; never read after this block, and the pointer
            // is not advanced, so no allocation is disturbed.
            let out := mload(0x40)
            let ok := staticcall(gasBudget, oracle, add(callData, 0x20), mload(callData), out, returnSize)

            if and(ok, eq(returndatasize(), returnSize)) {
                callOk := 1
                permitted := iszero(iszero(mload(out)))
                expiresAt := and(mload(add(out, 0x20)), 0xffffffffffffffff)
                jurisdiction := and(mload(add(out, 0x40)), 0xffff)
            }
        }
    }

    /// @notice Decode a trusted router's attestation, strictly.
    /// @dev Strict on the ENTRY paths: anything other than exactly one clean, non-zero
    /// ABI-encoded address is rejected, so a router cannot accidentally attest `address(0)` (which
    /// an issuer might have allowlisted by mistake) or smuggle meaning in the high-order bits.
    ///
    /// This strictness is safe here precisely because it fails closed. It is NOT used on the exit
    /// path, where a revert would trap capital.
    function _attestedAccount(bytes calldata hookData) internal pure returns (address account) {
        if (hookData.length != 32) revert MalformedAttestation(hookData.length);
        bytes32 raw;
        assembly ("memory-safe") {
            raw := calldataload(hookData.offset)
        }
        if (uint256(raw) >> 160 != 0) revert InvalidAttestation(raw);
        account = address(uint160(uint256(raw)));
        if (account == address(0)) revert InvalidAttestation(raw);
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Refuses a pool the owner has not configured, and refuses a dynamic-fee pool.
    ///
    /// `sender` is ignored on purpose: it is whoever called `initialize`, which may be any
    /// periphery contract, and is not a trustworthy identity. Nothing is gated on it; the gate is
    /// that the OWNER must have configured this exact pool id first, which cannot be forged
    /// because the pool id is the hash of the key core is initializing.
    function _beforeInitialize(address, /* sender */ PoolKey calldata key, uint160 /* sqrtPriceX96 */ )
        internal
        view
        virtual
        override
        returns (bytes4)
    {
        // A dynamic-fee pool stores an LP fee of 0 at initialization. This hook returns no override
        // and never calls `updateDynamicLPFee`, so such a pool would trade at zero fee forever.
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee(key.fee);

        PoolId poolId = key.toId();
        if (!_pools[poolId].configured) revert PoolNotConfigured(poolId);

        return ICLHooks.beforeInitialize.selector;
    }

    /// @dev ENTRY. Fails closed on every uncertainty.
    ///
    /// `sender` is the Vault locker. It is checked against `isTrustedRouter` and that check is the
    /// reason anything else here means anything: without it, `hookData` would be attacker-supplied
    /// and the account it names would be a fiction.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal view virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        PoolConfig storage cfg = _pools[poolId];

        if (!cfg.configured) revert PoolNotConfigured(poolId);
        if (paused()) revert EnforcedPause();
        if (!cfg.enabled) revert TradingDisabled(poolId);
        if (!isTrustedRouter[sender]) revert UntrustedLocker(sender);

        _requirePermitted(poolId, cfg, _attestedAccount(hookData), ComplianceAction.Swap);

        uint128 maxSwapPerTx = cfg.maxSwapPerTx;
        if (maxSwapPerTx != 0) {
            // Exact output: the input amount is unknown until the swap has been computed, so the
            // cap cannot be checked. Reject rather than wave through.
            if (params.amountSpecified > 0) revert ExactOutputBlockedByTradeCap();
            // `amountSpecified` is strictly negative here and the negation is CHECKED, so the one
            // pathological input, `type(int256).min`, reverts rather than wrapping.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amountIn = uint256(-params.amountSpecified);
            if (amountIn > maxSwapPerTx) revert SwapExceedsMaxPerTx(amountIn, maxSwapPerTx);
        }

        // The pool is static-fee (enforced at initialization), so core ignores the returned fee.
        return _passthroughSwap();
    }

    /// @dev ENTRY. Same gate as a swap, plus the per-investor concentration cap.
    ///
    /// Core routes here only when `liquidityDelta > 0`.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolConfig storage cfg = _pools[poolId];

        if (!cfg.configured) revert PoolNotConfigured(poolId);
        if (paused()) revert EnforcedPause();
        if (!cfg.enabled) revert TradingDisabled(poolId);
        if (!isTrustedRouter[sender]) revert UntrustedLocker(sender);

        address account = _attestedAccount(hookData);
        _requirePermitted(poolId, cfg, account, ComplianceAction.AddLiquidity);

        int256 liquidityDelta = params.liquidityDelta;
        if (liquidityDelta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 added = uint256(liquidityDelta);
            // Checked addition: an overflowing accumulator reverts, which is the closed direction.
            uint256 total = _investorLiquidity[poolId][account] + added;
            uint128 cap = cfg.maxLiquidityPerInvestor;
            if (cap != 0 && total > cap) revert InvestorLiquidityCapExceeded(account, total, cap);
            _investorLiquidity[poolId][account] = total;
        }

        return ICLHooks.beforeAddLiquidity.selector;
    }

    /// @dev EXIT. Fails OPEN, permanently and by design.
    ///
    /// This function must be readable as "it cannot revert unless the owner explicitly froze this
    /// specific account in this specific pool". It therefore:
    ///   * does not check `configured`, `enabled` or the pause;
    ///   * does not call the oracle;
    ///   * does not require a trusted locker;
    ///   * decodes `hookData` LENIENTLY, ignoring anything it cannot parse, so that a router
    ///     passing unexpected bytes cannot brick withdrawals.
    ///
    /// Core routes here whenever `liquidityDelta <= 0`, which includes a fee collection
    /// (`liquidityDelta == 0`). Both are covered by the same guarantee.
    ///
    /// Rationale for leaving it open to untrusted lockers: core keys a CL position by
    /// `(locker, tickLower, tickUpper, salt)`. An arbitrary caller who locks the Vault directly
    /// owns no position and so can remove nothing. Nothing is given away by permitting them to try.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolConfig storage cfg = _pools[poolId];

        // Only an attributable exit - trusted router, well-formed attestation - is accounted for
        // or eligible for the freeze. Everything else passes through untouched.
        if (cfg.configured && isTrustedRouter[sender] && hookData.length == 32) {
            bytes32 raw;
            assembly ("memory-safe") {
                raw := calldataload(hookData.offset)
            }
            // Lenient: mask rather than reject. Dirty high bits are ignored, so this cannot be used
            // to dodge the freeze, and a malformed attestation cannot block a withdrawal.
            address account = address(uint160(uint256(raw)));

            if (account != address(0)) {
                // The ONLY condition under which this hook refuses an exit.
                if (cfg.freezeDeniedExits && isDenied[account]) revert AccountDenied(account);

                int256 liquidityDelta = params.liquidityDelta;
                if (liquidityDelta < 0) {
                    uint256 removed;
                    unchecked {
                        // Unchecked on purpose: `type(int256).min` would revert a checked negation
                        // and thereby block an exit. Wrapping instead yields an absurdly large
                        // `removed`, which merely saturates the accumulator to zero. Harmless.
                        removed = uint256(-liquidityDelta);
                    }
                    uint256 current = _investorLiquidity[poolId][account];
                    _investorLiquidity[poolId][account] = removed >= current ? 0 : current - removed;
                }
            }
        }

        return ICLHooks.beforeRemoveLiquidity.selector;
    }
}
