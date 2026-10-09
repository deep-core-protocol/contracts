/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {
    HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {ICLSubscriber} from "infinity-periphery/src/pool-cl/interfaces/ICLSubscriber.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {IDeepCoreLPLocker, LockParams, Lock} from "./interfaces/IDeepCoreLPLocker.sol";

/// @title DeepCoreLPLocker
/// @notice A one-way door for concentrated-liquidity position NFTs. A position that enters is never
/// withdrawn, transferred, burned or reduced by one unit of liquidity. Its swap fees keep flowing,
/// and are split between the launch's creator, an optional integrator (the tenant's fee wallet) and
/// the protocol, in proportions fixed at the moment the position arrived.
///
/// @dev ############################ THE NO-WITHDRAW GUARANTEE ############################
///
/// It is structural, not a policy check that could be mis-edited, and it rests on five facts about
/// `CLPositionManager` (read from the fork, not assumed from Uniswap):
///
///   1. Only the owner or an approved spender/operator can decrease, burn, subscribe, or transfer a
///      position (`onlyIfApproved`, solmate `transferFrom`). This contract is the owner.
///   2. This contract never calls `approve`, `setApprovalForAll`, `transferFrom`, `safeTransferFrom`,
///      `subscribe` or `burn`. There is no generic call/execute/multicall path either.
///   3. The ONE call it makes to the position manager is `modifyLiquidities` with a plan built in
///      `collectFees` from literals: `CL_DECREASE_LIQUIDITY(tokenId, 0, 0, 0, "")` then
///      `TAKE_PAIR(currency0, currency1, address(this))`. A zero-liquidity decrease only credits
///      accrued fees; the amount is a literal, not a parameter.
///   4. `ERC721Permit.permit` / `permitForAll` verify an ERC-1271 signature when the owner is a
///      contract. This contract does NOT implement `isValidSignature`, so no signature can ever be
///      valid for it. Adding ERC-1271 here would break the guarantee - do not.
///   5. Arriving via `transferFrom` clears `getApproved[tokenId]` and unsubscribes any subscriber, so
///      nothing an earlier owner configured survives the transfer in.
///
/// `test/DeepCoreLPLocker.invariant.t.sol` asserts it under random swaps, collections, claims, creator
/// rotations and direct attacker calls against the position manager.
///
/// ############################### ACCOUNTING ###############################
///
///   * PULL, never push. `collectFees` only credits `claimable[account][currency]`. A recipient that
///     reverts, is blacklisted, or is a contract that burns gas can only fail its OWN `claim`.
///   * Credit is what ARRIVED: `balanceAfter - balanceBefore` around the position-manager call, never
///     the amount the Vault was told to send. A fee-on-transfer quote token credits its net amount.
///   * `totalOwed[currency]` is the sum of every account's claimable balance. `skim` credits anything
///     above it to `protocolRecipient`, so donations and positive rebases are never stranded.
///   * Rounding: the creator and integrator shares are floored; the PROTOCOL receives the remainder.
///     The three shares always sum to the collected amount exactly, so no unit is lost or locked, and
///     the dust recipient is fixed rather than caller-dependent. The protocol therefore never receives
///     less than its bps and at most 2 base units more per currency per collection, which is also why
///     calling `collectFees` repeatedly cannot round the enforced protocol floor away.
///
/// ########################## WHAT IT DOES NOT PROTECT ##########################
///
///   * A token's issuer. Robinhood stock tokens can `pause`, `adminBurn` and be upgraded. While a
///     token in the pair is PAUSED, `collectFees` for that position reverts (the Vault's transfer to
///     this contract reverts); the fees stay inside the position, keep accruing, and are collectable
///     after unpause - nothing is lost, and positions in other pairs are unaffected. A PAUSED token's
///     already-credited balance cannot be claimed until unpause; the credit is not consumed by the
///     failed attempt. An `adminBurn` against this contract's balance makes that token INSOLVENT
///     here: claims are paid first-come until the balance runs out. The locker cannot prevent that
///     and does not pretend to; it isolates it to the burned token.
///   * A pool's economics. Positions are REFUSED when the pool's hook registers `beforeRemoveLiquidity`
///     or `afterRemoveLiquidity` (and therefore `afterRemoveLiquidityReturnsDelta`, which core only
///     permits alongside it): a zero-liquidity decrease runs those callbacks, so such a hook could
///     revert to block collection forever, or return a delta that takes the fees before they reach
///     this contract and so route around `minProtocolBps`. What the locker cannot see is a hook that
///     keeps the LP fee near zero and charges its own swap fee instead - the protocol floor applies to
///     LP fees, and only a kit that restricts which hooks it launches on can protect that base.
///   * Positions minted or plain-`transferFrom`-ed straight to this address. They arrive without
///     `onERC721Received` and therefore without a lock record, and nobody can ever attach one - an
///     unauthenticated "attach" would let the first caller name themselves creator. Such a position is
///     as unrecoverable as one sent to a dead address. Always use `safeTransferFrom` with `LockParams`.
///   * Bin positions, deliberately. Bin shares (`BinFungibleToken`) have no receiver callback, so a lock
///     cannot be authenticated by the transfer itself; and bin LP fees compound into `reserveOfBin`
///     (`BinPool.sol`, swap path) instead of accruing per position, so collecting them means BURNING
///     shares. That turns "liquidity never decreases" from a structural fact into an arithmetic claim.
///     It belongs in a separate contract - see `docs/kit-v2-integration.md`, section "Bin positions".
///
/// ############################### NO ADMIN ###############################
///
/// No owner, no pause, no upgrade, no setter. `protocolRecipient`, the protocol-bps bounds and the
/// integrator-bps cap are immutables chosen at deployment; the split of a lock is written once. The
/// only mutable role is a lock's `creator`, which only that creator can hand on.
contract DeepCoreLPLocker is IDeepCoreLPLocker, IERC721Receiver, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis-point denominator. A unit, not configuration.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @dev `abi.encode(LockParams)`: five static words.
    uint256 private constant LOCK_PARAMS_LENGTH = 5 * 32;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The only position manager whose NFTs this locker accepts, and the only contract it
    /// ever calls with a state-changing call.
    ICLPositionManager public immutable positionManager;

    /// @notice The Vault behind `positionManager`. The only address allowed to send native currency.
    address public immutable vault;

    /// @notice Receives `protocolBps` of every collection, and every `skim`.
    /// @dev Immutable on purpose - see the design notes in `docs/kit-v2-integration.md`. Deploy it as a
    /// Safe: the Safe's signers can be rotated without its address changing, so immutability of the
    /// ADDRESS costs little, while a setter would need an owner key able to redirect the protocol share
    /// of every lock at once.
    address public immutable protocolRecipient;

    /// @notice Lowest `protocolBps` a lock may declare.
    uint16 public immutable minProtocolBps;

    /// @notice Highest `protocolBps` a lock may declare. The deployment's hard cap on the protocol cut.
    uint16 public immutable maxProtocolBps;

    /// @notice Highest `integratorBps` a lock may declare.
    uint16 public immutable maxIntegratorBps;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 tokenId => Lock) private _locks;

    /// @inheritdoc IDeepCoreLPLocker
    mapping(uint256 tokenId => address) public override pendingCreator;

    mapping(address account => mapping(Currency currency => uint256 amount)) private _claimable;

    /// @inheritdoc IDeepCoreLPLocker
    mapping(Currency currency => uint256 amount) public override totalOwed;

    /// @notice Number of positions ever locked. Monotonic.
    uint256 public lockCount;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param positionManager_ The CL position manager of the shared core on this chain.
    /// @param protocolRecipient_ The protocol's fee address. Must be able to call `claim` (a Safe).
    /// @param minProtocolBps_ Floor on every lock's protocol share. The tenant's enforced minimum.
    /// @param maxProtocolBps_ Ceiling on every lock's protocol share.
    /// @param maxIntegratorBps_ Ceiling on every lock's integrator share.
    constructor(
        ICLPositionManager positionManager_,
        address protocolRecipient_,
        uint16 minProtocolBps_,
        uint16 maxProtocolBps_,
        uint16 maxIntegratorBps_
    ) {
        if (address(positionManager_) == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        if (protocolRecipient_ == address(this)) revert ProtocolRecipientIsLocker();
        // `minProtocolBps_ <= maxProtocolBps_ <= DENOMINATOR` also guarantees at least one valid split
        // exists (protocol = min, integrator = 0, creator = the rest), so no deployment is unusable.
        if (
            minProtocolBps_ > maxProtocolBps_ || maxProtocolBps_ > BPS_DENOMINATOR
                || maxIntegratorBps_ > BPS_DENOMINATOR
        ) {
            revert InvalidBpsBounds(minProtocolBps_, maxProtocolBps_, maxIntegratorBps_);
        }
        address vault_ = address(IImmutableState(address(positionManager_)).vault());
        if (vault_ == address(0)) revert PositionManagerHasNoVault();

        positionManager = positionManager_;
        vault = vault_;
        protocolRecipient = protocolRecipient_;
        minProtocolBps = minProtocolBps_;
        maxProtocolBps = maxProtocolBps_;
        maxIntegratorBps = maxIntegratorBps_;
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice The only entrance. Called by the position manager inside `safeTransferFrom`.
    /// @dev Reverting here reverts the transfer, so an invalid lock leaves the position with its sender.
    /// @param operator Caller of `safeTransferFrom` (owner or approved operator of the position).
    /// @param from Previous owner.
    /// @param data `abi.encode(LockParams)`.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert NotPositionManager(msg.sender);
        if (data.length != LOCK_PARAMS_LENGTH) revert InvalidLockData(data.length);
        LockParams memory p = abi.decode(data, (LockParams));

        // ---- validate the declared split, before any external read ----
        if (p.creator == address(0) || p.creator == address(this)) revert InvalidCreator(p.creator);
        if ((p.integrator == address(0)) != (p.integratorBps == 0) || p.integrator == address(this)) {
            revert InvalidIntegrator(p.integrator, p.integratorBps);
        }
        if (p.protocolBps < minProtocolBps || p.protocolBps > maxProtocolBps) {
            revert ProtocolBpsOutOfRange(p.protocolBps, minProtocolBps, maxProtocolBps);
        }
        if (p.integratorBps > maxIntegratorBps) revert IntegratorBpsTooHigh(p.integratorBps, maxIntegratorBps);
        uint256 sum = uint256(p.creatorBps) + p.integratorBps + p.protocolBps;
        if (sum != BPS_DENOMINATOR) revert BpsDoNotSumToDenominator(sum);

        // Token ids are never reused by the position manager and a locked NFT can never leave, so this
        // is unreachable through the real contract. Cheap, and it makes "written once" local.
        if (_locks[tokenId].creator != address(0)) revert AlreadyLocked(tokenId);

        // ---- validate the position against chain state ----
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert NotOwnedByLocker(tokenId);
        // Shape read off CLPositionManager: (key, tickLower, tickUpper, liquidity, fg0, fg1, subscriber).
        (PoolKey memory key,,, uint128 liquidity,,, ICLSubscriber subscriber) = positionManager.positions(tokenId);
        // A zero-liquidity position cannot be poked (`CannotUpdateEmptyPosition`), so it could never
        // yield a fee. Refusing it keeps every lock collectable for as long as its hook allows.
        if (liquidity == 0) revert EmptyPosition(tokenId);
        // A hook that runs on removal could block or skim every future collection. Checked on the pool's
        // immutable `parameters` bitmap, which core cross-checks against the hook at initialize.
        if (
            Hooks.hasOffsetEnabled(key.parameters, HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET)
                || Hooks.hasOffsetEnabled(key.parameters, HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET)
        ) {
            revert HookInterceptsRemoval(tokenId, address(key.hooks));
        }
        // Cleared by the position manager on transfer; asserted because a subscriber is notified of
        // every liquidity change and could revert to block collection.
        if (address(subscriber) != address(0)) revert SubscriberAttached(tokenId, address(subscriber));

        // ---- effects ----
        _locks[tokenId] = Lock({
            creator: p.creator,
            creatorBps: p.creatorBps,
            integratorBps: p.integratorBps,
            protocolBps: p.protocolBps,
            // Wall clock. block.timestamp fits uint48 until the year 8.9 million.
            lockedAt: uint48(block.timestamp),
            integrator: p.integrator,
            currency0: key.currency0,
            currency1: key.currency1,
            poolId: key.toId()
        });
        unchecked {
            ++lockCount;
        }

        emit PositionLocked(
            tokenId,
            key.toId(),
            p.creator,
            p.integrator,
            p.creatorBps,
            p.integratorBps,
            p.protocolBps,
            liquidity,
            from,
            operator
        );
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                                COLLECT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull a locked position's accrued fees into this contract and credit the three parties.
    /// @dev Permissionless: it can only move value from the position into claimable balances fixed at
    /// lock time, so the caller's identity is irrelevant. Front ends can `eth_call` it to preview the
    /// currently collectable amounts.
    ///
    /// Not strictly checks-effects-interactions: the credit depends on what the interaction delivered,
    /// so it has to follow it. The whole function is `nonReentrant` (shared with `claim`, `skim` and
    /// `onERC721Received`), and the only state read before the call is the immutable lock record.
    function collectFees(uint256 tokenId) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        Lock memory lock = _locks[tokenId];
        if (lock.creator == address(0)) revert NotLocked(tokenId);

        uint256 before0 = lock.currency0.balanceOfSelf();
        uint256 before1 = lock.currency1.balanceOfSelf();

        Plan memory plan = Planner.init();
        // The liquidity argument is the literal 0. This line is the entire no-withdraw surface.
        plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")));
        plan.add(Actions.TAKE_PAIR, abi.encode(lock.currency0, lock.currency1, address(this)));
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);

        amount0 = _received(lock.currency0, before0);
        amount1 = _received(lock.currency1, before1);

        _credit(tokenId, lock, lock.currency0, amount0);
        _credit(tokenId, lock, lock.currency1, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw the caller's entire credited balance of one currency to `to`.
    /// @dev Per currency, so a paused or reverting token blocks only its own claims. `to` lets an
    /// account whose own address a token blacklists still take delivery elsewhere.
    function claim(Currency currency, address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = _claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        _claimable[msg.sender][currency] = 0;
        totalOwed[currency] -= amount;

        emit Claimed(msg.sender, currency, to, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  SKIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Credit any balance above `totalOwed` to `protocolRecipient`.
    /// @dev Permissionless. Only ever credits true surplus (donations, positive rebases, stray native
    /// from a self-destruct), so it cannot touch a single unit owed to anybody.
    function skim(Currency currency) external override nonReentrant returns (uint256 surplus) {
        uint256 balance = currency.balanceOfSelf();
        uint256 owed = totalOwed[currency];
        if (balance <= owed) revert NothingToSkim();
        unchecked {
            surplus = balance - owed;
        }
        _claimable[protocolRecipient][currency] += surplus;
        totalOwed[currency] = balance;
        emit Skimmed(currency, msg.sender, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                            CREATOR ROTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Nominate a new creator for one lock. `address(0)` cancels a pending nomination.
    /// @dev Two-step so a typo cannot send the right somewhere unreachable. No delay: see the design
    /// notes - whoever holds the creator key can already claim every future credit, so a delay would
    /// protect nothing a thief does not already have, while blocking an honest move to a Safe.
    function transferCreator(uint256 tokenId, address newCreator) external override {
        address current = _locks[tokenId].creator;
        if (current == address(0)) revert NotLocked(tokenId);
        if (msg.sender != current) revert NotCreator(tokenId, msg.sender);
        if (newCreator == address(this)) revert InvalidCreator(newCreator);
        pendingCreator[tokenId] = newCreator;
        emit CreatorTransferStarted(tokenId, current, newCreator);
    }

    /// @notice Accept a nomination. Future collections credit the new creator; balances already
    /// credited stay claimable by the previous creator.
    function acceptCreator(uint256 tokenId) external override {
        address pending = pendingCreator[tokenId];
        if (pending == address(0) || msg.sender != pending) revert NotPendingCreator(tokenId, msg.sender);
        address previous = _locks[tokenId].creator;
        _locks[tokenId].creator = pending;
        delete pendingCreator[tokenId];
        emit CreatorTransferred(tokenId, previous, pending);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDeepCoreLPLocker
    function getLock(uint256 tokenId) external view override returns (Lock memory) {
        return _locks[tokenId];
    }

    /// @inheritdoc IDeepCoreLPLocker
    function isLocked(uint256 tokenId) external view override returns (bool) {
        return _locks[tokenId].creator != address(0);
    }

    /// @inheritdoc IDeepCoreLPLocker
    function claimable(address account, Currency currency) external view override returns (uint256) {
        return _claimable[account][currency];
    }

    /// @notice The exact split `collectFees` applies. Creator and integrator shares floor; the protocol
    /// takes the remainder (its own bps share plus every unit of rounding dust), so the three always
    /// sum to `amount`. The protocol's bps are implied: `DENOMINATOR - creatorBps - integratorBps`.
    function splitAmount(uint256 amount, uint16 creatorBps, uint16 integratorBps)
        public
        pure
        override
        returns (uint256 creatorShare, uint256 integratorShare, uint256 protocolShare)
    {
        uint256 bps = uint256(creatorBps) + integratorBps;
        if (bps > BPS_DENOMINATOR) revert BpsDoNotSumToDenominator(bps);
        creatorShare = FullMath.mulDiv(amount, creatorBps, BPS_DENOMINATOR);
        integratorShare = FullMath.mulDiv(amount, integratorBps, BPS_DENOMINATOR);
        // Cannot underflow: floor(a*c/D) + floor(a*i/D) <= floor(a*(c+i)/D) <= a when c+i <= D.
        unchecked {
            protocolShare = amount - creatorShare - integratorShare;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Saturating: a token whose balance FELL across the call (a burn landing mid-call, or a
    /// malicious token) credits zero rather than bricking collection for this lock.
    function _received(Currency currency, uint256 balanceBefore) private view returns (uint256) {
        uint256 balanceAfter = currency.balanceOfSelf();
        unchecked {
            return balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        }
    }

    function _credit(uint256 tokenId, Lock memory lock, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        (uint256 creatorShare, uint256 integratorShare, uint256 protocolShare) =
            splitAmount(amount, lock.creatorBps, lock.integratorBps);

        if (creatorShare != 0) _claimable[lock.creator][currency] += creatorShare;
        if (integratorShare != 0) _claimable[lock.integrator][currency] += integratorShare;
        if (protocolShare != 0) _claimable[protocolRecipient][currency] += protocolShare;
        totalOwed[currency] += amount;

        emit FeesCollected(tokenId, currency, msg.sender, amount, creatorShare, integratorShare, protocolShare);
    }

    /*//////////////////////////////////////////////////////////////
                                RECEIVE
    //////////////////////////////////////////////////////////////*/

    /// @dev Native fees arrive from `Vault.take` during `collectFees`. Anything else is refused, so the
    /// only native surplus `skim` ever sees is value forced in without a call.
    receive() external payable {
        if (msg.sender != vault) revert UnexpectedNativeSender(msg.sender);
    }
}
