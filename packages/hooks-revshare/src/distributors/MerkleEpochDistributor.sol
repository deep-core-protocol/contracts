/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IRevShareHook} from "../interfaces/IRevShareHook.sol";
import {IEpochDistributor, EpochDistributorKind} from "../interfaces/IEpochDistributor.sol";

/// @title MerkleEpochDistributor
/// @notice Route 3 for an ordinary ERC20 with no snapshot support: pay arbitrary token holders a
/// share of trading volume by closing an epoch, publishing a Merkle root of the holder set, and
/// letting holders claim against it.
///
/// @dev ############################ WHY A MERKLE ROOT AT ALL ############################
///
/// A plain ERC20 records no history. `balanceOf` today says nothing about who held the token
/// while the volume that generated this epoch's fees was traded, and there is no on-chain way to
/// ask. Iterating holders is impossible for the reasons set out on `RevShareHook`. So the holder
/// set is computed off-chain over the epoch's block range, committed as one 32-byte root, and
/// each holder proves their own entry when they claim. On-chain cost is O(log n) per claimer and
/// zero for everybody else - including for the swap that funded it.
///
/// ------------------------------- THE TRUST ASSUMPTION -------------------------------
///
/// THIS CONTRACT IS NOT TRUSTLESS AND MUST NOT BE MARKETED AS IF IT WERE. Somebody computes the
/// root off-chain, and this contract cannot check that the root reflects the real holder set. A
/// dishonest root poster can assign an epoch's entire pot to themselves.
///
/// What IS enforced on-chain, and bounds the damage:
///
///   * PER-EPOCH ESCROW. `claimed` is tracked per epoch per currency and can never exceed that
///     epoch's own `amount`. A bad root steals at most the epoch it was posted for. It cannot
///     reach into another epoch, the pot still accruing in the hook, or any other pool.
///   * ONE ROOT PER EPOCH. `postRoot` reverts if a root is already set, so a poster cannot swap
///     an honest root for a hostile one after claims begin.
///   * A CHALLENGE WINDOW. Claims open only `challengeDelay` seconds after the root is posted.
///     During that window `cancelRoot` (owner or guardian) clears the root so a corrected one can
///     be posted. After it, the root is final and even the owner cannot touch the funds.
///   * NO ADMIN WITHDRAWAL. There is no function that moves an epoch's balance to the owner.
///     Unclaimed value goes to `rollover`, which returns it to the next epoch's holders. The owner
///     can stall the process; the owner cannot take the money.
///
/// Deploy this with the root poster behind the same multisig + timelock that governs
/// `Vault.registerApp`, publish the epoch's block range and the generator, and say plainly that
/// holder payouts depend on an off-chain computation. If you need a trustless guarantee instead,
/// the paired token must support ERC-5805 checkpoints - use `SnapshotEpochDistributor`.
///
/// ------------------------------- LEAF ENCODING -------------------------------
///
///   leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount0, amount1))))
///
/// Double hashing, and `abi.encode` (fixed 128-byte preimage) rather than `abi.encodePacked`, so
/// no leaf can be confused with an internal node and no two distinct claims can share an encoding.
/// `index` is the claimant's position in the generated tree and is what the claim bitmap keys on.
///
/// ------------------------------- FINDING THE TREE -------------------------------
///
/// A root is 32 bytes and a claim needs a PROOF, so a root on its own is unclaimable by anyone who
/// was not handed the tree out of band. `postRoot` therefore takes a pointer to where the tree is
/// published, stored per epoch and readable through `getRootSource`. It is a pointer and nothing
/// more - see the notes on that function for what it is and is not evidence of.
/// ###############################################################################
contract MerkleEpochDistributor is IEpochDistributor, Ownable2Step, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidHook();
    error InvalidPoolKey();
    error InvalidWindows();
    error EpochTooSoon(uint64 earliest);
    error NothingToDistribute();
    error UnknownEpoch(uint256 epochId);
    error RootAlreadyPosted(uint256 epochId);
    error RootNotPosted(uint256 epochId);
    error InvalidRoot();
    error RootURIRequired();
    error RootURITooLong(uint256 length, uint256 maximum);
    error ClaimNotOpenYet(uint256 epochId, uint64 claimableAt);
    error ClaimWindowClosed(uint256 epochId, uint64 expiresAt);
    error ChallengeWindowClosed(uint256 epochId, uint64 claimableAt);
    error AlreadyClaimed(uint256 epochId, uint256 index);
    error InvalidProof();
    error EpochOverAllocated(uint256 epochId);
    error NotExpiredYet(uint256 epochId, uint64 expiresAt);
    error AlreadyRolledOver(uint256 epochId);
    error NotGuardianOrOwner();
    error NativeNotAccepted();
    /// @notice `sweepSurplus` found nothing above the tracked escrow in either currency
    error NothingToSweep();

    /// @notice A leaf paying an account with code was submitted by someone other than that account.
    /// @dev Same rule and reason as `SnapshotEpochDistributor.claim`.
    error ContractAccountMustClaimItself(address account, address caller);

    /// @notice `minEpochDuration` is below `MIN_EPOCH_DURATION_FLOOR`.
    error MinEpochDurationTooShort(uint64 provided, uint64 required);

    /// @notice `rootGracePeriod` is outside [`ROOT_GRACE_PERIOD_FLOOR`, `ROOT_GRACE_PERIOD_CEILING`]
    error InvalidRootGracePeriod(uint64 provided, uint64 floorValue, uint64 ceilingValue);

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event EpochClosed(uint256 indexed epochId, uint256 amount0, uint256 amount1, uint64 closedAt);
    event RootPosted(uint256 indexed epochId, bytes32 root, uint64 claimableAt, uint64 expiresAt);
    event RootCancelled(uint256 indexed epochId, bytes32 root);

    /// @notice The epoch's tree pointer changed. Also emitted on first publication (`previousURI`
    /// empty, `revisions` zero) and on `cancelRoot` (`newURI` empty).
    /// @dev Every write to the pointer goes through one topic, so an indexer that keeps only the
    /// LATEST `RootURIUpdated` per epoch always holds the current value and never has to replay
    /// the history to find it.
    event RootURIUpdated(uint256 indexed epochId, string previousURI, string newURI, uint32 revisions);
    event EpochClaimed(
        uint256 indexed epochId, uint256 indexed index, address indexed account, uint256 amount0, uint256 amount1
    );
    event EpochRolledOver(uint256 indexed epochId, uint256 amount0, uint256 amount1);
    /// @notice Value found above the tracked escrow was moved into the next epoch's carry-over.
    event SurplusSwept(uint256 amount0, uint256 amount1);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);

    /// @notice The earliest `rollover(epochId)` may run has been pushed forward.
    /// @dev Emitted by `cancelRoot`, which is the only thing that moves it. Read alongside
    /// `rolloverEligibleAt`, which is the value a keeper should actually schedule against.
    event RolloverDeferred(uint256 indexed epochId, uint64 notBefore);

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @param amount0 Escrowed currency0 for this epoch.
    /// @param amount1 Escrowed currency1 for this epoch.
    /// @param claimed0 Claimed so far. Never exceeds `amount0`.
    /// @param claimed1 Claimed so far. Never exceeds `amount1`.
    /// @param root Merkle root of the holder set. Zero until posted.
    /// @param closedAt Timestamp the epoch was closed and funded.
    /// @param claimableAt Timestamp claims open. Zero until a root is posted.
    /// @param expiresAt Timestamp claims close and `rollover` becomes available.
    /// @param rolledOver Whether the remainder has already been returned to the open pot.
    struct Epoch {
        uint256 amount0;
        uint256 amount1;
        uint256 claimed0;
        uint256 claimed1;
        bytes32 root;
        uint64 closedAt;
        uint64 claimableAt;
        uint64 expiresAt;
        bool rolledOver;
    }

    /// @notice Where an epoch's Merkle tree is published, and how often that pointer has moved.
    ///
    /// @dev Deliberately NOT a field on `Epoch`. A `string` would make `Epoch` a dynamic type, which
    /// changes the encoding of `getEpoch` - the one call keepers and indexers poll on a timer, and
    /// the one whose return shape three consumers already have hand-written ABIs for. A separate
    /// mapping keeps `getEpoch` nine static words and puts the cost of reading the pointer on the
    /// claim UI that actually wants it.
    ///
    /// @param uri Where the tree is published. SUBMITTER-SUPPLIED. See `getRootSource`.
    /// @param revisions How many times `setRootURI` has moved this pointer since the current root
    /// was posted. Zero on a freshly posted root, and reset by `cancelRoot`.
    struct RootSource {
        string uri;
        uint32 revisions;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Longest tree pointer accepted, in bytes.
    /// @dev Matches `DeepCoreRegistry.MAX_URI_BYTES`. Bounded so one admin call cannot write unbounded
    /// storage or emit an unbounded log; generous enough that no honest CID or URL comes close.
    uint256 public constant MAX_ROOT_URI_BYTES = 512;

    /// @notice Shortest `minEpochDuration` this contract will accept at construction.
    ///
    /// @dev A floor against a DEGENERATE configuration, not a recommendation. `minEpochDuration`
    /// used to be validated not at all, so `0` was accepted and produced a distributor whose pot
    /// could be shredded into one epoch per block - each of which then needs its own root, its own
    /// challenge window and its own claim transaction, which is exactly the griefing this parameter
    /// exists to stop. The same class of hole as `TimelockController` accepting `minDelay = 0`, and
    /// refused here for the same reason: a parameter whose safe value is only written in a comment
    /// eventually ships as zero. Pick a value measured in days for a real deployment.
    uint64 public constant MIN_EPOCH_DURATION_FLOOR = 1 hours;

    /// @notice Extra time added to the no-root rollover deadline, during which a late `postRoot`
    /// cannot be front-run by a `rollover`.
    ///
    /// @dev THE RACE THIS CLOSES. An epoch that never received a root becomes sweepable at
    /// `closedAt + minEpochDuration + claimWindow`, and `postRoot` refuses an epoch that has
    /// already rolled over. Without a buffer those two are back to back, so anybody could watch the
    /// mempool for the owner's `postRoot` near the deadline, land `rollover(id)` in front of it, and
    /// void an allocation that took an off-chain job to compute. Nothing is stolen - the value goes
    /// to the next epoch's holders - but the work is wasted and the griefer pays only gas.
    ///
    /// The grace does not make the race impossible at every timestamp; it moves the sweep back so
    /// that a poster aiming at the published deadline has a window behind it in which `rollover`
    /// reverts for everyone. It must be longer than the owner's own governance delay: the owner is
    /// meant to be a multisig behind a timelock, so "the root is queued and maturing" must not be
    /// a losing position.
    ///
    /// @dev THE FLOOR, not the value. 3 days was chosen against DEEPCORE'S timelock
    /// (`CUSTODY_MIN_DELAY`, 48h) and shipped as a `constant`, which quietly made one protocol's
    /// governance schedule a property of every tenant's distributor. A tenant running a 7-day
    /// timelock gets exactly the race this parameter exists to close, and cannot do anything about
    /// it. The value is a constructor argument now; this is the line below which no deployment may
    /// go, because a grace shorter than DeepCore's own delay was never defensible for anyone.
    uint64 public constant ROOT_GRACE_PERIOD_FLOOR = 3 days;

    /// @notice Longest grace this contract will accept at construction.
    /// @dev The grace DELAYS `rollover`, which is the permissionless path that returns an
    /// unclaimed epoch's value to the next one. An absurd value therefore strands holder money
    /// behind an owner who has stopped posting roots, and there is no admin call that can shorten
    /// it afterwards. Bounded generously - a 30-day governance delay is already extraordinary -
    /// but bounded.
    uint64 public constant ROOT_GRACE_PERIOD_CEILING = 30 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook that accrues this distributor's share.
    IRevShareHook public immutable hook;

    /// @notice Minimum seconds between epoch closes. Stops an attacker shredding the pot into
    /// thousands of epochs, each of which would need its own root and its own claim transaction.
    uint64 public immutable minEpochDuration;

    /// @notice Seconds between a root being posted and claims opening. The window in which a wrong
    /// root can still be cancelled.
    uint64 public immutable challengeDelay;

    /// @notice Seconds claims stay open after `claimableAt`. Unclaimed value rolls to the next
    /// epoch rather than being stranded.
    uint64 public immutable claimWindow;

    /// @notice Extra time added to the no-root rollover deadline. See `ROOT_GRACE_PERIOD_FLOOR`
    /// for what it closes and why it must exceed the OWNER'S governance delay, not DeepCore's.
    /// @dev IMMUTABLE, NOT CONSTANT, and the SCREAMING_CASE name is kept because it is already an
    /// ABI name three consumers read. Set it to at least the delay of whatever timelock owns this
    /// distributor.
    uint64 public immutable ROOT_GRACE_PERIOD;

    /// @notice May cancel a root inside the challenge window, and nothing else.
    /// @dev A wrong root is an emergency, and routing the fix through a timelock guarantees it
    /// arrives after claims have already opened. The guardian can only ever DELAY a payout; it
    /// cannot post a root, cannot claim, and cannot move funds.
    address public guardian;

    /// @notice The pool whose distributor share this contract collects.
    PoolKey internal _key;

    /// @notice Number of epochs closed so far. Ids are `0 .. epochCount - 1`.
    uint256 public epochCount;

    /// @notice Timestamp of the most recent close.
    uint64 public lastCloseAt;

    /// @notice Value returned by `rollover`, folded into the next epoch that closes.
    uint256 public carryOver0;
    uint256 public carryOver1;

    /// @notice Everything this contract is meant to hold, per currency: every live epoch's unclaimed
    /// remainder plus the carry-over. Balance above it is surplus - see `sweepSurplus`.
    /// @dev Increments by exactly what `closeEpoch` pulls from the hook, decrements by exactly what
    /// `claim` pays; `rollover` moves value between an epoch and the carry-over and leaves it unchanged.
    uint256 public escrowed0;
    uint256 public escrowed1;

    mapping(uint256 epochId => Epoch) internal _epochs;

    /// @dev Written only alongside a root, and cleared with it. See `getRootSource`.
    mapping(uint256 epochId => RootSource) internal _rootSources;

    /**
     * A floor on `rollover`, written by `cancelRoot` and read by `rolloverEligibleAt`.
     * Zero means "no floor".
     *
     * Deliberately a separate mapping rather than a tenth field on `Epoch`, for
     * the reason spelled out on `RootSource`: `getEpoch` returns nine all-static
     * words, three consumers have hand-written ABIs for that shape, and widening
     * it would break every one of them for a value only `rollover` and a keeper
     * ever read.
     */
    mapping(uint256 epochId => uint64 notBefore) internal _rolloverFloor;

    /// @dev epochId => word index => bitmap of claimed leaf indices.
    mapping(uint256 epochId => mapping(uint256 word => uint256 bits)) private _claimedBitmap;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param hook_ The `RevShareHook` instance holding this pool's distributor pot.
    /// @param key_ The pool. Must already name `hook_` as its distributor, or `closeEpoch` can
    /// never pull anything.
    /// @param owner_ The root poster. Should be a multisig + timelock, never an EOA.
    /// @param guardian_ May cancel a root inside the challenge window. May be zero.
    /// @param rootGracePeriod_ Buffer in front of the no-root sweep. Set it to AT LEAST the delay
    /// of the timelock that owns this contract, or a root queued at the published deadline can be
    /// front-run by `rollover`. Bounded by `ROOT_GRACE_PERIOD_FLOOR`/`_CEILING`.
    constructor(
        IRevShareHook hook_,
        PoolKey memory key_,
        address owner_,
        address guardian_,
        uint64 minEpochDuration_,
        uint64 challengeDelay_,
        uint64 claimWindow_,
        uint64 rootGracePeriod_
    ) Ownable(owner_) {
        if (address(hook_) == address(0)) revert InvalidHook();
        if (address(key_.hooks) != address(hook_)) revert InvalidPoolKey();
        // A zero claim window would close claims in the same block they opened. A zero challenge
        // delay would make `cancelRoot` unreachable and the root final on arrival.
        if (claimWindow_ == 0 || challengeDelay_ == 0) revert InvalidWindows();
        if (minEpochDuration_ < MIN_EPOCH_DURATION_FLOOR) {
            revert MinEpochDurationTooShort(minEpochDuration_, MIN_EPOCH_DURATION_FLOOR);
        }
        if (rootGracePeriod_ < ROOT_GRACE_PERIOD_FLOOR || rootGracePeriod_ > ROOT_GRACE_PERIOD_CEILING) {
            revert InvalidRootGracePeriod(rootGracePeriod_, ROOT_GRACE_PERIOD_FLOOR, ROOT_GRACE_PERIOD_CEILING);
        }

        hook = hook_;
        _key = key_;
        guardian = guardian_;
        minEpochDuration = minEpochDuration_;
        challengeDelay = challengeDelay_;
        claimWindow = claimWindow_;
        ROOT_GRACE_PERIOD = rootGracePeriod_;

        // The clock starts at deployment, not at the first close. `closeEpoch` used to exempt
        // epoch 0 from `minEpochDuration` entirely (`epochCount != 0 && ...`), because with
        // `lastCloseAt == 0` the comparison was against a 1970 timestamp and could never bite.
        // Seeding it here deletes that carve-out and the branch that implemented it: EVERY close,
        // including the first, is at least `minEpochDuration` after the one before it.
        lastCloseAt = uint64(block.timestamp);

        emit GuardianUpdated(address(0), guardian_);
    }

    /**
     * Permanently disabled. Reverts for everybody, including the owner.
     *
     * OpenZeppelin ships `renounceOwnership` as a safety feature, on the premise
     * that an owner who can no longer act is safer than an owner who can. That
     * premise is inverted here, and the asymmetry is the whole reason for this
     * override: THE OWNER IS THE ONLY PARTY THAT CAN PAY ANYBODY.
     *
     *   * `postRoot` is `onlyOwner`, and it is the only writer of `Epoch.root`.
     *   * `claim` reverts `RootNotPosted` while that root is zero.
     *
     * So renouncing does not remove a power that could be abused, it removes the
     * ONLY power that can release escrowed holder money. Every epoch already
     * closed, and every epoch that closes afterwards, would run out its claim
     * window with no root, become sweepable, and `rollover` into the next
     * epoch — which is equally unpayable. The pot churns forever and no holder is
     * ever paid a wei. There is no unrenounce and no re-owner: `transferOwnership`
     * is itself `onlyOwner`.
     *
     * The bounded version of the same intent already exists and is not affected:
     * an owner who wants out transfers to the address that should have it
     * (`Ownable2Step`, so it cannot be sent somewhere unreachable by typo), and an
     * owner who wants to STOP paying simply stops posting roots, which lets
     * `rollover` — permissionless — return the value to the next epoch.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Accepts native currency pulled from the hook.
    /// @dev Only from the hook: this contract pays out of per-epoch escrow, so an unsolicited send
    /// would be unaccounted for and permanently stuck.
    receive() external payable {
        if (msg.sender != address(hook)) revert NativeNotAccepted();
    }

    function setGuardian(address guardian_) external onlyOwner {
        address previous = guardian;
        guardian = guardian_;
        emit GuardianUpdated(previous, guardian_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEpochDistributor
    /// @dev Answer this before touching `getEpoch`. This contract's `Epoch` and the snapshot
    /// distributor's are both nine all-static fields, so the wrong ABI does not fail, it returns
    /// `root` where a caller expected `totalVotingSupply`.
    function kind() external pure returns (bytes32) {
        return EpochDistributorKind.MERKLE;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _key;
    }

    function poolId() public view returns (PoolId) {
        return _key.toId();
    }

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        return _epochs[epochId];
    }

    /**
     * Where `epochId`'s Merkle tree is published, and how many times that pointer
     * has been moved since the current root was posted.
     *
     * `claim` needs `(index, account, amount0, amount1, proof)`, and a 32-byte
     * root commits to all of that without revealing any of it. Nothing on chain
     * published the leaves, so a self-service claim UI was not buildable at all:
     * it would have had to invent a proof source. This is the epoch's own answer
     * to "where is the tree", written by the same transaction that posted the
     * root it belongs to.
     *
     * ---------------------------------------------------------------------
     * THIS IS A POINTER, NOT EVIDENCE. IT IS NEVER VERIFIED BY THIS CONTRACT.
     * ---------------------------------------------------------------------
     *
     * The owner types this string. There is no scheme check, no content
     * addressing check, no reachability check - a contract cannot tell an IPFS
     * CID from a phishing URL, and pretending to check would be worse than not
     * checking, because it would imply a guarantee that is not there. Treat it
     * exactly as the registry's `sourceURI` is treated: submitter-supplied,
     * displayed as such, never rendered as verified or auto-trusted.
     *
     * What bounds the damage is that THE ROOT IS THE AUTHORITY, not this string.
     * A tree served from a hostile pointer produces proofs that fail
     * `MerkleProof.verifyCalldata`, so the worst a bad URI achieves on chain is
     * denial of service - which the owner already has by never posting a root -
     * and off chain, a phishing page. It cannot move one wei.
     *
     * `revisions` is the anti-phishing surface: a pointer that has moved since
     * the root was posted is a fact a claim UI should show, and counting
     * `RootURIUpdated` logs to learn it would bound the answer by however far
     * back an RPC serves logs. It is on chain for the same reason
     * `RevShareHook.totalTaken` is.
     *
     * Reverts for an epoch that does not exist. An epoch with no root returns an
     * empty `uri`: `postRoot` requires a non-empty one, so `root != 0` and
     * `bytes(uri).length != 0` always agree.
     */
    function getRootSource(uint256 epochId) external view returns (RootSource memory) {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        return _rootSources[epochId];
    }

    /// @notice Whether leaf `index` of `epochId` has already been claimed.
    function isClaimed(uint256 epochId, uint256 index) public view returns (bool) {
        uint256 word = index >> 8;
        uint256 bit = index & 0xff;
        return (_claimedBitmap[epochId][word] >> bit) & 1 == 1;
    }

    /// @notice Recomputes the leaf hash a claim must prove. Exposed so a root generator and this
    /// contract can be checked against each other without guessing at the encoding.
    function leafHash(uint256 index, address account, uint256 amount0, uint256 amount1)
        public
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount0, amount1))));
    }

    /*//////////////////////////////////////////////////////////////
                                 EPOCHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Close the current epoch: pull everything the hook has accrued for this pool and
    /// escrow it under a new epoch id.
    /// @dev Permissionless. Anybody may close an epoch; only the owner can decide who it pays.
    /// `minEpochDuration` is what stops that being a griefing vector.
    function closeEpoch() external nonReentrant returns (uint256 epochId) {
        // `lastCloseAt` is seeded at construction, so the first close waits exactly like every
        // other one. There is no first-epoch exemption.
        uint64 earliest = lastCloseAt + minEpochDuration;
        if (block.timestamp < earliest) revert EpochTooSoon(earliest);

        // Carry-over is consumed BEFORE the external pull, so a reentrant close could not count it
        // twice even if the hook's own guard were absent.
        uint256 amount0 = carryOver0;
        uint256 amount1 = carryOver1;
        carryOver0 = 0;
        carryOver1 = 0;

        // The hook transfers real tokens here and returns 0 rather than reverting when a currency
        // accrued nothing, so a one-sided epoch closes cleanly.
        uint256 pulled0 = hook.pullDistributorShare(_key, _key.currency0);
        uint256 pulled1 = hook.pullDistributorShare(_key, _key.currency1);
        amount0 += pulled0;
        amount1 += pulled1;
        escrowed0 += pulled0;
        escrowed1 += pulled1;
        if (amount0 == 0 && amount1 == 0) revert NothingToDistribute();

        epochId = epochCount;
        epochCount = epochId + 1;
        lastCloseAt = uint64(block.timestamp);

        Epoch storage epoch = _epochs[epochId];
        epoch.amount0 = amount0;
        epoch.amount1 = amount1;
        epoch.closedAt = uint64(block.timestamp);

        emit EpochClosed(epochId, amount0, amount1, uint64(block.timestamp));
    }

    /// @notice Publish the holder-set root for a closed epoch, and say where the tree that root
    /// commits to can be found. Claims open after the challenge delay.
    ///
    /// @dev The pointer is MANDATORY, not optional, and that is the only reason this signature
    /// takes it rather than leaving it to a follow-up call. A root with no published tree is a root
    /// only the poster can claim against: everybody else holds a 32-byte hash of leaves they have
    /// never seen. Requiring it here makes `root != 0` and a non-empty `uri` the same condition, so
    /// a claim UI that sees a root can rely on there being somewhere to go, and an epoch cannot
    /// reach `claimableAt` in a state where nobody but the owner can act on it.
    ///
    /// It is not validated beyond a length bound, and it is not evidence of anything. See
    /// `getRootSource`.
    ///
    /// @param rootURI_ Where the tree is published, e.g. an `ipfs://` CID. Must be non-empty and at
    /// most `MAX_ROOT_URI_BYTES` bytes.
    function postRoot(uint256 epochId, bytes32 root, string calldata rootURI_) external onlyOwner {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        if (root == bytes32(0)) revert InvalidRoot();
        _validateRootURI(rootURI_);

        Epoch storage epoch = _epochs[epochId];
        if (epoch.root != bytes32(0)) revert RootAlreadyPosted(epochId);
        if (epoch.rolledOver) revert AlreadyRolledOver(epochId);

        uint64 claimableAt = uint64(block.timestamp) + challengeDelay;
        uint64 expiresAt = claimableAt + claimWindow;

        epoch.root = root;
        epoch.claimableAt = claimableAt;
        epoch.expiresAt = expiresAt;

        emit RootPosted(epochId, root, claimableAt, expiresAt);
        // Revision zero: this root has never had its pointer moved. `cancelRoot` clears the record
        // outright, so a re-posted root starts from zero again rather than inheriting a count that
        // belonged to a root nobody can claim against any more.
        _writeRootURI(epochId, rootURI_, 0);
    }

    /// @notice Repoint an epoch at a different copy of the SAME tree. Does not touch the root.
    ///
    /// @dev Separate from `postRoot`, and deliberately available for as long as the root stands -
    /// including after the challenge window has closed. That is not an oversight, it is the case
    /// this function exists for:
    ///
    ///   * Inside the challenge window a wrong pointer can already be fixed by `cancelRoot` and a
    ///     fresh `postRoot`, at the cost of restarting the delay.
    ///   * AFTER it, `cancelRoot` is gone and the root is final. If a pin drops, a bucket moves or
    ///     a gateway dies at that point and the pointer were frozen too, the epoch would hold a
    ///     correct, immutable allocation that nobody can build a proof for. Every holder's share
    ///     would sit there until `rollover` swept it to the next epoch - funds not stolen, but
    ///     nobody paid, for a typo. A pointer that cannot be repaired is a live way to lose an
    ///     epoch, so the pointer is repairable and the ROOT is what is frozen.
    ///
    /// This grants the owner nothing: the root is unchanged, so a tree served from a new pointer
    /// still has to hash to it or every proof fails. The only new power is to break or redirect
    /// discovery, which the owner held anyway. It is made loud rather than forbidden - each call
    /// bumps `revisions` and emits `RootURIUpdated` with the value it replaced.
    ///
    /// Owner-only, and NOT extended to the guardian. The guardian's entire remit is to delay a
    /// payout during the challenge window; handing a faster key the ability to repoint any epoch's
    /// tree at any time would create exactly the phishing lever this contract otherwise does not
    /// have. A pointer repair can wait out a timelock inside a `claimWindow` measured in weeks.
    function setRootURI(uint256 epochId, string calldata rootURI_) external onlyOwner {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        // No root means no tree, so there is nothing for a pointer to point AT. Blocking it also
        // keeps the `root != 0` <=> non-empty `uri` equivalence that `getRootSource` promises.
        if (_epochs[epochId].root == bytes32(0)) revert RootNotPosted(epochId);
        _validateRootURI(rootURI_);

        // Checked arithmetic on a uint32 the owner would have to call 4 billion times to overflow.
        _writeRootURI(epochId, rootURI_, _rootSources[epochId].revisions + 1);
    }

    function _validateRootURI(string calldata rootURI_) private pure {
        uint256 length = bytes(rootURI_).length;
        if (length == 0) revert RootURIRequired();
        if (length > MAX_ROOT_URI_BYTES) revert RootURITooLong(length, MAX_ROOT_URI_BYTES);
    }

    /// @dev The single writer for the tree pointer, so publication, correction and clearing all
    /// land on one log topic in the order they happened.
    function _writeRootURI(uint256 epochId, string memory rootURI_, uint32 revisions) private {
        RootSource storage source = _rootSources[epochId];
        string memory previous = source.uri;
        source.uri = rootURI_;
        source.revisions = revisions;
        emit RootURIUpdated(epochId, previous, rootURI_, revisions);
    }

    /// @notice Clear a root during its challenge window so a corrected one can be posted.
    /// @dev Owner or guardian. Impossible once claims have opened - by then holders are relying on
    /// the published allocation, and letting an admin rewrite it would make the whole escrow
    /// meaningless.
    ///
    /// PUSHES THE ROLLOVER FLOOR OUT, and that is not housekeeping. Clearing `expiresAt` returns
    /// the epoch to the no-root fallback measured from `closedAt`. For a root posted LATE - which
    /// is the normal case for a root somebody had to notice was wrong - that deadline is already in
    /// the past, so the cancellation would make the epoch instantly sweepable and no corrected root
    /// could ever be posted. The function would defeat the one sentence of its own docstring that
    /// says why it exists. The floor guarantees `ROOT_GRACE_PERIOD` of room to actually post the
    /// replacement.
    function cancelRoot(uint256 epochId) external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardianOrOwner();
        if (epochId >= epochCount) revert UnknownEpoch(epochId);

        Epoch storage epoch = _epochs[epochId];
        bytes32 root = epoch.root;
        if (root == bytes32(0)) revert RootNotPosted(epochId);
        if (block.timestamp >= epoch.claimableAt) revert ChallengeWindowClosed(epochId, epoch.claimableAt);

        epoch.root = bytes32(0);
        epoch.claimableAt = 0;
        epoch.expiresAt = 0;

        uint64 notBefore = uint64(block.timestamp) + ROOT_GRACE_PERIOD;
        if (notBefore > _rolloverFloor[epochId]) {
            _rolloverFloor[epochId] = notBefore;
            emit RolloverDeferred(epochId, notBefore);
        }

        emit RootCancelled(epochId, root);
        // The pointer goes with the root. Leaving it would advertise a tree for an allocation that
        // has just been withdrawn, and a UI reading the pointer alone would show a claim set that
        // no longer has a root behind it.
        _writeRootURI(epochId, "", 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim one leaf of an epoch's tree. Pays `account`.
    /// @dev Payout is hard-wired to `account` (the address inside the proven leaf), so a third
    /// party may submit a claim on a holder's behalf - useful for a claim-bot or a gas sponsor -
    /// without being able to redirect it.
    ///
    /// EXCEPT for an account with code, which must submit its own claim. The root is off-chain
    /// work, and a generator that attributes balances naively will include contracts that hold the
    /// token but can never move a payout: the Vault, `RevShareHook`, this distributor, a router. A
    /// stranger claiming such a leaf would move holder money into a permanent dead end; left
    /// unclaimed it returns to real holders through `rollover`. See the longer note on
    /// `SnapshotEpochDistributor.claim`, where the same hole was found first.
    function claim(
        uint256 epochId,
        uint256 index,
        address account,
        uint256 amount0,
        uint256 amount1,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (msg.sender != account && account.code.length != 0) {
            revert ContractAccountMustClaimItself(account, msg.sender);
        }
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        Epoch storage epoch = _epochs[epochId];

        bytes32 root = epoch.root;
        if (root == bytes32(0)) revert RootNotPosted(epochId);
        if (block.timestamp < epoch.claimableAt) revert ClaimNotOpenYet(epochId, epoch.claimableAt);
        if (block.timestamp >= epoch.expiresAt) revert ClaimWindowClosed(epochId, epoch.expiresAt);
        if (isClaimed(epochId, index)) revert AlreadyClaimed(epochId, index);

        if (!MerkleProof.verifyCalldata(proof, root, leafHash(index, account, amount0, amount1))) {
            revert InvalidProof();
        }

        // ---- effects ----
        _setClaimed(epochId, index);

        uint256 claimed0 = epoch.claimed0 + amount0;
        uint256 claimed1 = epoch.claimed1 + amount1;
        // The escrow ceiling. An over-allocating root runs out here instead of reaching another
        // epoch's money; the epoch's own holders are the only ones who can be short-changed.
        if (claimed0 > epoch.amount0 || claimed1 > epoch.amount1) revert EpochOverAllocated(epochId);
        epoch.claimed0 = claimed0;
        epoch.claimed1 = claimed1;
        escrowed0 -= amount0;
        escrowed1 -= amount1;

        // ---- interactions ----
        if (amount0 != 0) _key.currency0.transfer(account, amount0);
        if (amount1 != 0) _key.currency1.transfer(account, amount1);

        emit EpochClaimed(epochId, index, account, amount0, amount1);
    }

    /// @notice Return an expired epoch's unclaimed remainder to the next epoch's holders.
    /// @dev Permissionless, and the only way value leaves an epoch other than a proven claim.
    /// Deliberately NOT a sweep to the owner: unclaimed holder money stays holder money.
    ///
    /// An epoch that never received a root becomes eligible once
    /// `minEpochDuration + claimWindow + ROOT_GRACE_PERIOD` has passed since it closed, so a root
    /// poster who abandons the job cannot strand funds forever. See `rolloverEligibleAt` for the
    /// exact deadline, which is the value to schedule against rather than one recomputed off chain.
    function rollover(uint256 epochId) external nonReentrant {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        Epoch storage epoch = _epochs[epochId];
        if (epoch.rolledOver) revert AlreadyRolledOver(epochId);

        uint64 expiresAt = _rolloverEligibleAt(epoch, epochId);
        if (block.timestamp < expiresAt) revert NotExpiredYet(epochId, expiresAt);

        uint256 remainder0 = epoch.amount0 - epoch.claimed0;
        uint256 remainder1 = epoch.amount1 - epoch.claimed1;

        epoch.rolledOver = true;
        // Zero the escrow so the remainder is accounted for in exactly one place afterwards.
        epoch.amount0 = epoch.claimed0;
        epoch.amount1 = epoch.claimed1;

        carryOver0 += remainder0;
        carryOver1 += remainder1;

        emit EpochRolledOver(epochId, remainder0, remainder1);
    }

    /// @notice Move anything this contract holds ABOVE its tracked escrow into the next epoch's
    /// carry-over, so a token sent here by mistake reaches holders instead of staying stuck.
    ///
    /// @dev Permissionless and admin-free like `closeEpoch` and `rollover`: there is no owner to pay
    /// and no recipient to choose, the surplus simply becomes holder money at the next close. It can
    /// never touch escrowed value - `escrowed0/1` is exactly what every live epoch and the carry-over
    /// are owed, and only the balance above it moves. Native can only exceed the escrow if it was
    /// forced in (`receive` refuses everyone but the hook). Acceptance finding L-1, 2026-09-18.
    function sweepSurplus() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 held0 = _key.currency0.balanceOfSelf();
        uint256 held1 = _key.currency1.balanceOfSelf();
        amount0 = held0 > escrowed0 ? held0 - escrowed0 : 0;
        amount1 = held1 > escrowed1 ? held1 - escrowed1 : 0;
        if (amount0 == 0 && amount1 == 0) revert NothingToSweep();

        carryOver0 += amount0;
        carryOver1 += amount1;
        escrowed0 += amount0;
        escrowed1 += amount1;

        emit SurplusSwept(amount0, amount1);
    }

    /**
     * The exact timestamp `rollover(epochId)` becomes callable.
     *
     * Two different clocks govern an epoch depending on whether a root ever
     * landed, and a keeper that recomputes either of them off chain will
     * eventually recompute the wrong one — `cancelRoot` moves the second, and
     * nothing in `getEpoch` records that it did. This is the single answer.
     *
     *   * A root stands (`expiresAt != 0`): its own claim window governs, exactly
     *     as before. Holders were told when claims close and that does not move.
     *   * No root (`expiresAt == 0`): the abandonment fallback,
     *     `closedAt + minEpochDuration + claimWindow + ROOT_GRACE_PERIOD`, or the
     *     floor left by a `cancelRoot`, whichever is later.
     *
     * Reverts for an epoch that does not exist. Returns a deadline for an epoch
     * that has already rolled over too — `rolledOver` is the flag to check for
     * that, and it is on `getEpoch`.
     */
    function rolloverEligibleAt(uint256 epochId) external view returns (uint64) {
        if (epochId >= epochCount) revert UnknownEpoch(epochId);
        return _rolloverEligibleAt(_epochs[epochId], epochId);
    }

    function _rolloverEligibleAt(Epoch storage epoch, uint256 epochId) private view returns (uint64) {
        uint64 expiresAt = epoch.expiresAt;
        if (expiresAt != 0) return expiresAt;

        uint64 fallbackAt = epoch.closedAt + minEpochDuration + claimWindow + ROOT_GRACE_PERIOD;
        uint64 floorAt = _rolloverFloor[epochId];
        return fallbackAt > floorAt ? fallbackAt : floorAt;
    }

    function _setClaimed(uint256 epochId, uint256 index) private {
        uint256 word = index >> 8;
        uint256 bit = index & 0xff;
        _claimedBitmap[epochId][word] |= (1 << bit);
    }
}
