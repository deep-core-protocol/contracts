// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {RevShareHook} from "../src/RevShareHook.sol";
import {IRevShareHook} from "../src/interfaces/IRevShareHook.sol";
import {MerkleEpochDistributor} from "../src/distributors/MerkleEpochDistributor.sol";
import {SnapshotEpochDistributor} from "../src/distributors/SnapshotEpochDistributor.sol";
import {IEpochDistributor, EpochDistributorKind} from "../src/interfaces/IEpochDistributor.sol";
import {VotesToken, TimestampVotesToken, PlainToken} from "./mocks/Mocks.sol";

/// @dev Shared plumbing: a live pool whose whole revenue share is routed to route 3.
abstract contract DistributorFixture is Test, Deployers {
    Vault vault;
    CLPoolManager poolManager;
    RevShareHook hook;
    CLPoolManagerRouter router;

    PoolKey key;
    PoolId poolId;
    Currency currency0;
    Currency currency1;

    address constant GOVERNANCE = address(0x600E);
    address constant GUARDIAN = address(0x6A47);
    address constant HOLDER_A = address(0xA);
    address constant HOLDER_B = address(0xB);
    address constant HOLDER_C = address(0xC);

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE_PIPS = 50_000; // 5%, so an epoch pot is comfortably above dust
    int256 constant SWAP_AMOUNT = -10 ether;


    /// @dev The hook's floor, in seconds of `block.timestamp`.
    uint40 constant CONFIG_DELAY = 12 hours;

    /// @dev `rootGracePeriod` for every distributor built here. Equal to
    /// `ROOT_GRACE_PERIOD_FLOOR`, which is also what the old `constant` was.
    uint64 constant GRACE = 3 days;

    function _deployPool(address tokenA, address tokenB) internal {
        (vault, poolManager) = createFreshManager();
        hook = new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, CONFIG_DELAY, 8);
        router = new CLPoolManagerRouter(vault, poolManager);

        (currency0, currency1) =
            tokenA < tokenB ? (Currency.wrap(tokenA), Currency.wrap(tokenB)) : (Currency.wrap(tokenB), Currency.wrap(tokenA));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: LP_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });
        poolId = key.toId();
    }

    function _configureAndSeed(address distributor) internal {
        hook.configure(
            key,
            RevShareHook.ConfigParams({
                feePips: FEE_PIPS,
                lpDonateBps: 0,
                beneficiaryBps: 0,
                distributorBps: 10_000,
                distributor: distributor,
                enabled: true
            })
        );
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 100_000 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _swap(int256 amount, bool zeroForOne) internal returns (BalanceDelta) {
        return router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }
}

/// @dev Stands in for wherever an operator actually publishes an epoch's tree - IPFS, a bucket, a
/// git tag. Everything is keyed by URI, so a test can only obtain a proof by RESOLVING A POINTER.
/// That is the whole point: before `getRootSource` there was no on-chain pointer to resolve, and a
/// test that reached for a proof it had built itself two lines earlier would prove nothing about
/// whether a real claim UI could find one.
contract TreePublisher {
    struct Leaf {
        uint256 index;
        address account;
        uint256 amount0;
        uint256 amount1;
    }

    mapping(bytes32 uriKey => Leaf[]) private _leaves;
    mapping(bytes32 uriKey => mapping(uint256 index => bytes32[])) private _proofs;

    function publish(string calldata uri, Leaf calldata leaf, bytes32[] calldata proof) external {
        bytes32 uriKey = keccak256(bytes(uri));
        _leaves[uriKey].push(leaf);
        _proofs[uriKey][leaf.index] = proof;
    }

    function tree(string calldata uri) external view returns (Leaf[] memory) {
        return _leaves[keccak256(bytes(uri))];
    }

    function proofFor(string calldata uri, uint256 index) external view returns (bytes32[] memory) {
        return _proofs[keccak256(bytes(uri))][index];
    }
}

/*//////////////////////////////////////////////////////////////
                     MERKLE EPOCH DISTRIBUTOR
//////////////////////////////////////////////////////////////*/

contract MerkleEpochDistributorTest is DistributorFixture {
    MerkleEpochDistributor distributor;

    uint64 constant MIN_EPOCH = 1 days;
    uint64 constant CHALLENGE = 2 hours;
    uint64 constant CLAIM_WINDOW = 30 days;

    /// @dev Every `postRoot` needs a tree pointer, so the tests that are not about the pointer use
    /// this one and say nothing more about it.
    string constant TREE_URI = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";

    function setUp() public {
        vm.warp(1_000_000);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        a.mint(address(this), 1_000_000 ether);
        b.mint(address(this), 1_000_000 ether);
        _deployPool(address(a), address(b));

        // The distributor address must be known before `configure`, and `configure` must happen
        // before `initialize`, so the distributor is deployed against the key first.
        distributor = new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, GRACE
        );
        _configureAndSeed(address(distributor));

        // `lastCloseAt` is seeded at construction, so the FIRST close waits `minEpochDuration`
        // like every other one - there is no epoch-0 exemption any more. Stepped past once here
        // rather than in every test below that closes an epoch.
        vm.warp(block.timestamp + MIN_EPOCH);
    }

    /*//////////////////////// merkle helpers ////////////////////////*/

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _leaf(uint256 index, address account, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount0, amount1))));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    /*//////////////////////// tests ////////////////////////*/

    function test_closeEpoch_pullsTheAccruedPot() public {
        _swap(SWAP_AMOUNT, true);
        uint256 pot = hook.pendingDistributorShare(poolId, currency1);
        assertGt(pot, 0);

        vm.prank(HOLDER_A); // permissionless
        uint256 epochId = distributor.closeEpoch();

        assertEq(epochId, 0);
        assertEq(distributor.getEpoch(0).amount1, pot);
        assertEq(distributor.getEpoch(0).amount0, 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(distributor)), pot);
        assertEq(hook.pendingDistributorShare(poolId, currency1), 0);
    }

    /*//////////// L-1 (2026-09-18): a stray token becomes holder money, escrow is never touched ////////////*/

    function test_FIX_sweepSurplus_tracksEscrowExactly_andMovesOnlyTheSurplus() public {
        vm.expectRevert(MerkleEpochDistributor.NothingToSweep.selector);
        distributor.sweepSurplus();

        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;
        assertEq(distributor.escrowed1(), pot, "escrow = what closeEpoch pulled");
        assertEq(distributor.escrowed0(), 0);
        vm.expectRevert(MerkleEpochDistributor.NothingToSweep.selector);
        distributor.sweepSurplus();

        // A stray send of both currencies, by anyone.
        uint256 stray0 = 5 ether;
        uint256 stray1 = 2 ether;
        IERC20(Currency.unwrap(currency0)).transfer(address(distributor), stray0);
        IERC20(Currency.unwrap(currency1)).transfer(address(distributor), stray1);

        vm.prank(HOLDER_C); // permissionless
        vm.expectEmit(false, false, false, true, address(distributor));
        emit MerkleEpochDistributor.SurplusSwept(stray0, stray1);
        (uint256 s0, uint256 s1) = distributor.sweepSurplus();
        assertEq(s0, stray0);
        assertEq(s1, stray1);
        assertEq(distributor.carryOver0(), stray0, "surplus is the next epoch's carry-over");
        assertEq(distributor.carryOver1(), stray1);
        assertEq(distributor.escrowed0(), stray0);
        assertEq(distributor.escrowed1(), pot + stray1, "epoch 0's pot is still escrowed");
        vm.expectRevert(MerkleEpochDistributor.NothingToSweep.selector);
        distributor.sweepSurplus();

        // Epoch 0 pays in full afterwards, and the claim releases exactly its amount from escrow.
        bytes32 leafA = _leaf(0, HOLDER_A, 0, pot);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, leafA, TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);
        distributor.claim(0, 0, HOLDER_A, 0, pot, new bytes32[](0));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A), pot);
        assertEq(distributor.escrowed1(), stray1);

        // The next close distributes the swept surplus with the new pot.
        _swap(SWAP_AMOUNT, true);
        vm.warp(block.timestamp + MIN_EPOCH);
        distributor.closeEpoch();
        assertEq(distributor.getEpoch(1).amount0, stray0);
        assertGt(distributor.getEpoch(1).amount1, stray1);
        assertEq(distributor.carryOver0(), 0);
    }

    function test_closeEpoch_revertsWithNothingToDistribute() public {
        vm.expectRevert(MerkleEpochDistributor.NothingToDistribute.selector);
        distributor.closeEpoch();
    }

    function test_closeEpoch_respectsMinimumDuration() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        _swap(SWAP_AMOUNT, true);
        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.EpochTooSoon.selector, uint64(block.timestamp) + MIN_EPOCH)
        );
        distributor.closeEpoch();

        vm.warp(block.timestamp + MIN_EPOCH);
        distributor.closeEpoch();
        assertEq(distributor.epochCount(), 2);
    }

    function test_fullLifecycle_twoHoldersClaim() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        uint256 shareA = pot / 2;
        uint256 shareB = pot - shareA;
        bytes32 leafA = _leaf(0, HOLDER_A, 0, shareA);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, shareB);
        bytes32 root = _hashPair(leafA, leafB);

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, root, TREE_URI);

        // Claims are shut during the challenge window.
        vm.expectRevert(
            abi.encodeWithSelector(
                MerkleEpochDistributor.ClaimNotOpenYet.selector, uint256(0), distributor.getEpoch(0).claimableAt
            )
        );
        distributor.claim(0, 0, HOLDER_A, 0, shareA, _proof(leafB));

        vm.warp(block.timestamp + CHALLENGE);

        // Anyone may submit; the funds go to the address inside the proven leaf.
        vm.prank(HOLDER_C);
        distributor.claim(0, 0, HOLDER_A, 0, shareA, _proof(leafB));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A), shareA);
        assertTrue(distributor.isClaimed(0, 0));

        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.AlreadyClaimed.selector, uint256(0), uint256(0)));
        distributor.claim(0, 0, HOLDER_A, 0, shareA, _proof(leafB));

        distributor.claim(0, 1, HOLDER_B, 0, shareB, _proof(leafA));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_B), shareB);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(distributor)), 0, "epoch fully drained");
    }

    /// @dev MEDIUM, fixed (same pattern as the snapshot distributor): a root that allots a leaf to a
    /// contract cannot be claimed into that contract by a stranger. The contract may claim itself.
    function test_FIX_strangerCannotClaimAContractLeaf_contractMayClaimItself() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        DelegatingSink sink = new DelegatingSink();
        SelfClaimingHolder holder = new SelfClaimingHolder();
        uint256 share = pot / 2;
        bytes32 leafSink = _leaf(0, address(sink), 0, share);
        bytes32 leafHolder = _leaf(1, address(holder), 0, share);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafSink, leafHolder), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);

        vm.prank(HOLDER_C);
        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.ContractAccountMustClaimItself.selector, address(sink), HOLDER_C)
        );
        distributor.claim(0, 0, address(sink), 0, share, _proof(leafHolder));
        assertFalse(distributor.isClaimed(0, 0));

        holder.claimMerkle(distributor, 0, 1, 0, share, _proof(leafSink));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(holder)), share);
    }

    function test_claim_rejectsForgedProofsAndAmounts() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        uint256 shareA = pot / 2;
        uint256 shareB = pot - shareA;
        bytes32 leafA = _leaf(0, HOLDER_A, 0, shareA);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, shareB);

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafA, leafB), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);

        // Right proof, inflated amount.
        vm.expectRevert(MerkleEpochDistributor.InvalidProof.selector);
        distributor.claim(0, 0, HOLDER_A, 0, shareA + 1, _proof(leafB));

        // Right amount, wrong claimant.
        vm.expectRevert(MerkleEpochDistributor.InvalidProof.selector);
        distributor.claim(0, 0, HOLDER_C, 0, shareA, _proof(leafB));

        // Right leaf, wrong index (which is what the double-claim bitmap keys on).
        vm.expectRevert(MerkleEpochDistributor.InvalidProof.selector);
        distributor.claim(0, 5, HOLDER_A, 0, shareA, _proof(leafB));
    }

    /// @dev The bound on a dishonest root. An over-allocating tree runs out at its own epoch's
    /// escrow instead of reaching the next epoch's money.
    function test_overAllocatingRoot_cannotReachAnotherEpoch() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot0 = distributor.getEpoch(0).amount1;

        vm.warp(block.timestamp + MIN_EPOCH);
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot1 = distributor.getEpoch(1).amount1;
        assertGt(pot1, 0);

        // A root for epoch 0 that allocates the whole balance of BOTH epochs.
        uint256 greedy = pot0 + pot1;
        bytes32 leafA = _leaf(0, HOLDER_A, 0, greedy);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, 1);

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafA, leafB), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);

        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.EpochOverAllocated.selector, uint256(0)));
        distributor.claim(0, 0, HOLDER_A, 0, greedy, _proof(leafB));

        // Epoch 1 is untouched.
        assertEq(distributor.getEpoch(1).amount1, pot1);
        assertEq(distributor.getEpoch(1).claimed1, 0);
    }

    function test_postRoot_isOwnerOnlyAndSingleUse() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        vm.prank(HOLDER_A);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, HOLDER_A));
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);

        vm.prank(GOVERNANCE);
        vm.expectRevert(MerkleEpochDistributor.InvalidRoot.selector);
        distributor.postRoot(0, bytes32(0), TREE_URI);

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);

        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.RootAlreadyPosted.selector, uint256(0)));
        distributor.postRoot(0, bytes32(uint256(2)), TREE_URI);
    }

    function test_cancelRoot_onlyInsideTheChallengeWindow() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);

        vm.prank(HOLDER_A);
        vm.expectRevert(MerkleEpochDistributor.NotGuardianOrOwner.selector);
        distributor.cancelRoot(0);

        // The guardian exists so a wrong root can be pulled without waiting for a timelock.
        vm.prank(GUARDIAN);
        distributor.cancelRoot(0);
        assertEq(distributor.getEpoch(0).root, bytes32(0));

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(2)), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);

        // Once claims open the allocation is final, even for the owner. Read `claimableAt` BEFORE
        // the prank: `vm.prank` applies to the next call, and an argument that is itself an
        // external call would consume it, leaving `cancelRoot` to run as this test contract and
        // revert on access control instead of on the window.
        uint64 claimableAt = distributor.getEpoch(0).claimableAt;
        vm.prank(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.ChallengeWindowClosed.selector, uint256(0), claimableAt)
        );
        distributor.cancelRoot(0);
    }

    function test_rollover_returnsUnclaimedValueToTheNextEpoch() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot0 = distributor.getEpoch(0).amount1;

        bytes32 leafA = _leaf(0, HOLDER_A, 0, pot0 / 2);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, pot0 - pot0 / 2);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafA, leafB), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);
        distributor.claim(0, 0, HOLDER_A, 0, pot0 / 2, _proof(leafB));

        uint256 unclaimed = pot0 - pot0 / 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                MerkleEpochDistributor.NotExpiredYet.selector, uint256(0), distributor.getEpoch(0).expiresAt
            )
        );
        distributor.rollover(0);

        vm.warp(distributor.getEpoch(0).expiresAt);
        vm.expectRevert(
            abi.encodeWithSelector(
                MerkleEpochDistributor.ClaimWindowClosed.selector, uint256(0), distributor.getEpoch(0).expiresAt
            )
        );
        distributor.claim(0, 1, HOLDER_B, 0, unclaimed, _proof(leafA));

        distributor.rollover(0);
        assertEq(distributor.carryOver1(), unclaimed);

        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.AlreadyRolledOver.selector, uint256(0)));
        distributor.rollover(0);

        // The carry-over is folded into the next epoch rather than being stranded or swept.
        _swap(SWAP_AMOUNT, true);
        uint256 fresh = hook.pendingDistributorShare(poolId, currency1);
        distributor.closeEpoch();
        assertEq(distributor.getEpoch(1).amount1, fresh + unclaimed);
        assertEq(distributor.carryOver1(), 0);
    }

    /// @dev A root poster who abandons the job cannot strand an epoch forever.
    function test_rollover_worksOnAnEpochThatNeverGotARoot() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        // The fallback deadline is the close plus `minEpochDuration + claimWindow`, and then
        // `ROOT_GRACE_PERIOD` on top - see `test_rollover_cannotFrontRunALatePostRoot` for why
        // that last term is there rather than being a rounding-up of the other two.
        uint64 eligibleAt = distributor.rolloverEligibleAt(0);
        assertEq(
            eligibleAt,
            distributor.getEpoch(0).closedAt + MIN_EPOCH + CLAIM_WINDOW + distributor.ROOT_GRACE_PERIOD()
        );

        vm.warp(eligibleAt);
        distributor.rollover(0);
        assertEq(distributor.carryOver1(), pot);
    }

    /*//////////////////////// the tree pointer ////////////////////////*/

    /// @dev The gap, end to end. A claim UI that begins with NOTHING BUT THE DISTRIBUTOR ADDRESS -
    /// which is all `RevShareHook.distributorOf` gives it - reaches a working proof and pays out.
    /// Every input to `claim` below travels address -> `kind()` -> `getRootSource` -> the tree.
    /// Nothing is passed to the consumer half of this test out of band.
    function test_rootSource_aClaimUiReachesTheProofFromChainAlone() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        // ---- the operator's off-chain job: compute the holder set, publish it, post the root ----
        uint256 shareA = pot / 2;
        uint256 shareB = pot - shareA;
        bytes32 leafA = _leaf(0, HOLDER_A, 0, shareA);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, shareB);
        bytes32 root = _hashPair(leafA, leafB);

        TreePublisher publisher = new TreePublisher();
        string memory published = "ipfs://bafkreiepochzeroholderset";
        publisher.publish(published, TreePublisher.Leaf(0, HOLDER_A, 0, shareA), _proof(leafB));
        publisher.publish(published, TreePublisher.Leaf(1, HOLDER_B, 0, shareB), _proof(leafA));

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, root, published);
        vm.warp(block.timestamp + CHALLENGE);

        // ---- the consumer: hands itself the address and nothing else ----
        address discovered = address(distributor);

        // Step 1. What is this? One call, no probing, no guessing at `getEpoch`'s layout.
        assertEq(IEpochDistributor(discovered).kind(), EpochDistributorKind.MERKLE);

        MerkleEpochDistributor d = MerkleEpochDistributor(payable(discovered));

        // Step 2. Where is the tree? This is the answer that did not exist before.
        MerkleEpochDistributor.RootSource memory source = d.getRootSource(0);
        assertGt(bytes(source.uri).length, 0, "a posted root always names somewhere to go");
        assertEq(source.revisions, 0, "this pointer has not been moved since the root was posted");

        // Step 3. Resolve it and claim. `source.uri` is the only path to a proof here - the local
        // `published` and the leaves above are never referenced again.
        TreePublisher.Leaf[] memory leaves = publisher.tree(source.uri);
        assertEq(leaves.length, 2, "the pointer resolved to the epoch's tree");
        for (uint256 i = 0; i < leaves.length; ++i) {
            TreePublisher.Leaf memory entry = leaves[i];
            // Cross-check the leaf against the contract's own encoding before spending gas, which
            // is what a UI should do and what `leafHash` is exposed for.
            assertTrue(
                d.leafHash(entry.index, entry.account, entry.amount0, entry.amount1) != bytes32(0)
            );
            d.claim(0, entry.index, entry.account, entry.amount0, entry.amount1, publisher.proofFor(source.uri, entry.index));
        }

        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A), shareA);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_B), shareB);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(distributor)), 0, "epoch fully drained");
    }

    /// @dev `root != 0` and a non-empty pointer must be the same condition. A root with no pointer
    /// is a root only its poster can claim against.
    function test_postRoot_requiresATreePointer() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        vm.prank(GOVERNANCE);
        vm.expectRevert(MerkleEpochDistributor.RootURIRequired.selector);
        distributor.postRoot(0, bytes32(uint256(1)), "");

        vm.prank(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.RootURITooLong.selector, uint256(513), uint256(512))
        );
        distributor.postRoot(0, bytes32(uint256(1)), new string(513));

        // The bound is inclusive, so exactly `MAX_ROOT_URI_BYTES` is not an off-by-one rejection.
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), new string(512));
        assertEq(bytes(distributor.getRootSource(0).uri).length, distributor.MAX_ROOT_URI_BYTES());

        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.UnknownEpoch.selector, uint256(9)));
        distributor.getRootSource(9);
    }

    /// @dev The case the separate setter exists for. Past the challenge window the root is final
    /// and `cancelRoot` is gone, so if the pointer were frozen too a dead link would leave a
    /// correct allocation that nobody can build a proof for - every share stranded until rollover,
    /// for a typo. The root stays immutable; the pointer does not.
    function test_setRootURI_repairsAPointerAfterTheRootIsFinal() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        uint256 shareA = pot / 2;
        uint256 shareB = pot - shareA;
        bytes32 leafA = _leaf(0, HOLDER_A, 0, shareA);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, shareB);
        bytes32 root = _hashPair(leafA, leafB);

        TreePublisher publisher = new TreePublisher();
        string memory movedTo = "ipfs://bafkreithecopythatisstillup";
        publisher.publish(movedTo, TreePublisher.Leaf(0, HOLDER_A, 0, shareA), _proof(leafB));

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, root, "ipfs://bafkreithepinthatdropped");

        vm.warp(block.timestamp + CHALLENGE);

        // Read before the prank: an external call in an argument list consumes it.
        uint64 claimableAt = distributor.getEpoch(0).claimableAt;
        vm.prank(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.ChallengeWindowClosed.selector, uint256(0), claimableAt)
        );
        distributor.cancelRoot(0);

        // Every move is announced, with the value it replaced, so a UI can show that the pointer
        // is not the one the root was posted with.
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MerkleEpochDistributor.RootURIUpdated(0, "ipfs://bafkreithepinthatdropped", movedTo, 1);
        vm.prank(GOVERNANCE);
        distributor.setRootURI(0, movedTo);

        MerkleEpochDistributor.RootSource memory source = distributor.getRootSource(0);
        assertEq(source.uri, movedTo);
        assertEq(source.revisions, 1, "a moved pointer is a fact on chain, not a log to be summed");
        assertEq(distributor.getEpoch(0).root, root, "the root is what is frozen, not the pointer");

        // And the repaired pointer leads to a tree that still satisfies the ORIGINAL root - which
        // is why letting the owner move it grants no new power over the money.
        distributor.claim(0, 0, HOLDER_A, 0, shareA, publisher.proofFor(source.uri, 0));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A), shareA);
    }

    function test_setRootURI_isOwnerOnlyAndNeedsARootToPointAt() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.RootNotPosted.selector, uint256(0)));
        distributor.setRootURI(0, TREE_URI);

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);

        vm.prank(HOLDER_A);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, HOLDER_A));
        distributor.setRootURI(0, "ipfs://hijacked");

        // Not the guardian either. Its entire remit is to DELAY a payout inside the challenge
        // window; a faster key that could repoint any epoch's tree at any time would be a phishing
        // lever this contract otherwise does not hand anybody.
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        distributor.setRootURI(0, "ipfs://hijacked");

        vm.prank(GOVERNANCE);
        vm.expectRevert(MerkleEpochDistributor.RootURIRequired.selector);
        distributor.setRootURI(0, "");

        assertEq(distributor.getRootSource(0).uri, TREE_URI, "nothing above moved the pointer");
    }

    function test_cancelRoot_clearsTheTreePointerWithTheRoot() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        _assertRootAndPointerAgree(0);

        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);
        _assertRootAndPointerAgree(0);

        vm.prank(GOVERNANCE);
        distributor.setRootURI(0, "ipfs://second");
        assertEq(distributor.getRootSource(0).revisions, 1);

        vm.prank(GUARDIAN);
        distributor.cancelRoot(0);
        // A pointer that outlived its root would advertise an allocation that has been withdrawn.
        _assertRootAndPointerAgree(0);
        assertEq(distributor.getRootSource(0).uri, "");

        // The corrected root starts its own revision count rather than inheriting one that
        // belonged to a root nobody can claim against any more.
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(2)), "ipfs://corrected");
        MerkleEpochDistributor.RootSource memory source = distributor.getRootSource(0);
        assertEq(source.uri, "ipfs://corrected");
        assertEq(source.revisions, 0);
        _assertRootAndPointerAgree(0);
    }

    /// @dev The invariant `getRootSource` promises: a consumer that sees a root can rely on there
    /// being somewhere to go, and one that sees a pointer can rely on a root standing behind it.
    function _assertRootAndPointerAgree(uint256 epochId) internal view {
        bool hasRoot = distributor.getEpoch(epochId).root != bytes32(0);
        bool hasPointer = bytes(distributor.getRootSource(epochId).uri).length != 0;
        assertEq(hasRoot, hasPointer, "root and tree pointer must be set and cleared together");
    }

    function test_constructor_rejectsAMismatchedKeyOrZeroWindows() public {
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(0x1234));

        vm.expectRevert(MerkleEpochDistributor.InvalidWindows.selector);
        new MerkleEpochDistributor(IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, 0, CLAIM_WINDOW, GRACE);

        vm.expectRevert(MerkleEpochDistributor.InvalidWindows.selector);
        new MerkleEpochDistributor(IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, 0, GRACE);

        vm.expectRevert(MerkleEpochDistributor.InvalidPoolKey.selector);
        new MerkleEpochDistributor(
            IRevShareHook(address(hook)), wrong, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, GRACE
        );
    }

    /*//////////////////////////////////////////////////////////////
                   A1 - RENOUNCING OWNERSHIP IS DISABLED
    //////////////////////////////////////////////////////////////*/

    /// @dev The asymmetry that makes stock `Ownable` wrong here. The owner is not a party that
    /// might abuse a power; it is the ONLY party that can release escrowed money, because
    /// `postRoot` is `onlyOwner` and `claim` reverts `RootNotPosted` without a root. Renouncing
    /// would therefore not reduce risk, it would make every epoch - closed and future -
    /// permanently unpayable, churning through `rollover` forever with no holder ever paid.
    ///
    /// FAILS AGAINST STOCK OZ: without the override this call succeeds, `owner()` becomes zero,
    /// and the `postRoot` at the end reverts `OwnableUnauthorizedAccount`.
    function test_renounceOwnership_isDisabledAndTheEscrowStaysPayable() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        vm.prank(GOVERNANCE);
        vm.expectRevert(MerkleEpochDistributor.RenounceDisabled.selector);
        distributor.renounceOwnership();

        // Not merely gated on the owner - there is no caller for whom it works.
        vm.prank(HOLDER_A);
        vm.expectRevert(MerkleEpochDistributor.RenounceDisabled.selector);
        distributor.renounceOwnership();

        // And there is no side door to a zero owner. `Ownable2Step.transferOwnership` accepts the
        // zero address, but only as the documented CANCEL of a pending handover - it writes
        // `_pendingOwner` and never touches `owner`, and nobody can call `acceptOwnership` as
        // `address(0)` to complete it.
        vm.prank(GOVERNANCE);
        distributor.transferOwnership(address(0));
        assertEq(distributor.pendingOwner(), address(0));

        assertEq(distributor.owner(), GOVERNANCE, "ownership survived every attempt to drop it");

        // The point of keeping it: holders can still be paid.
        uint256 pot = distributor.getEpoch(0).amount1;
        bytes32 leafA = _leaf(0, HOLDER_A, 0, pot / 2);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, pot - pot / 2);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafA, leafB), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);
        distributor.claim(0, 0, HOLDER_A, 0, pot / 2, _proof(leafB));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A), pot / 2);
    }

    /// @dev The bounded version of the same intent still works: an owner who wants out hands the
    /// job to somebody, and `Ownable2Step` means it cannot land at an address that cannot accept.
    function test_ownershipCanStillBeHandedOnRatherThanDropped() public {
        vm.prank(GOVERNANCE);
        distributor.transferOwnership(HOLDER_C);
        assertEq(distributor.owner(), GOVERNANCE, "step 1 alone must not move it");

        vm.prank(HOLDER_C);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), HOLDER_C);

        vm.prank(HOLDER_C);
        vm.expectRevert(MerkleEpochDistributor.RenounceDisabled.selector);
        distributor.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                A3 - ROLLOVER MUST NOT FRONT-RUN A LATE ROOT
    //////////////////////////////////////////////////////////////*/

    /// @dev THE GRIEF. An epoch with no root is sweepable at
    /// `closedAt + minEpochDuration + claimWindow`, and `postRoot` refuses a rolled-over epoch. Put
    /// back to back, those two let anybody watch for the owner's `postRoot` near the deadline, land
    /// `rollover(id)` in front of it and void an allocation that took an off-chain job to compute.
    /// Nothing is stolen; the work is destroyed for the price of gas.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: `rollover(0)` below succeeds at the old deadline, and the
    /// `postRoot` after it reverts `AlreadyRolledOver`.
    function test_rollover_cannotFrontRunALatePostRoot() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        uint64 oldDeadline = distributor.getEpoch(0).closedAt + MIN_EPOCH + CLAIM_WINDOW;
        vm.warp(oldDeadline);

        // The griefer's window is shut.
        vm.prank(HOLDER_C);
        vm.expectRevert(
            abi.encodeWithSelector(
                MerkleEpochDistributor.NotExpiredYet.selector, uint256(0), distributor.rolloverEligibleAt(0)
            )
        );
        distributor.rollover(0);

        // A root arriving right on the published deadline still lands, and still pays.
        bytes32 leafA = _leaf(0, HOLDER_A, 0, pot / 2);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, pot - pot / 2);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafA, leafB), TREE_URI);

        vm.warp(block.timestamp + CHALLENGE);
        distributor.claim(0, 0, HOLDER_A, 0, pot / 2, _proof(leafB));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A), pot / 2);
    }

    /// @dev The grace must DEFER the sweep, never remove it. An abandoned epoch still returns its
    /// value to the next one; the only change is when.
    function test_rollover_theGraceDefersTheSweepItDoesNotCancelIt() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        uint64 eligibleAt = distributor.rolloverEligibleAt(0);
        assertEq(eligibleAt, distributor.getEpoch(0).closedAt + MIN_EPOCH + CLAIM_WINDOW + distributor.ROOT_GRACE_PERIOD());

        vm.warp(eligibleAt - 1);
        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.NotExpiredYet.selector, uint256(0), eligibleAt));
        distributor.rollover(0);

        vm.warp(eligibleAt);
        vm.prank(HOLDER_C); // permissionless, as before
        distributor.rollover(0);
        assertEq(distributor.carryOver1(), pot);
    }

    /*//////////////////////////////////////////////////////////////
              A4 - CANCELROOT MUST LEAVE ROOM FOR THE FIX
    //////////////////////////////////////////////////////////////*/

    /// @dev `cancelRoot` exists, in its own words, "so a corrected one can be posted". Clearing
    /// `expiresAt` drops the epoch back onto the `closedAt` fallback - and for the case the
    /// function is FOR, a root somebody had to notice was wrong, that fallback is usually already
    /// in the past. Cancelling would then make the epoch instantly sweepable and no corrected root
    /// could ever be posted: the rescue strands the thing it was rescuing.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: after `cancelRoot` the epoch is immediately rolloverable,
    /// so `rollover(0)` succeeds where this asserts a revert and the corrected `postRoot` dies with
    /// `AlreadyRolledOver`.
    function test_cancelRoot_leavesRoomToPostTheCorrectedRoot() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;
        uint64 closedAt = distributor.getEpoch(0).closedAt;

        // A LATE root: posted after even the graced fallback would already have fired, which is
        // the normal shape of the case rather than a contrived one - a root somebody had to notice
        // was wrong is a root that was noticed slowly. Without the floor `cancelRoot` writes, this
        // cancellation drops the epoch back onto a deadline that is already in the past.
        vm.warp(closedAt + MIN_EPOCH + CLAIM_WINDOW + distributor.ROOT_GRACE_PERIOD() + 1 days);
        bytes32 wrongRoot = _hashPair(_leaf(0, HOLDER_C, 0, pot), _leaf(1, HOLDER_C, 0, 0));
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, wrongRoot, TREE_URI);

        // Somebody spots it inside the challenge window and the guardian pulls it.
        vm.prank(GUARDIAN);
        distributor.cancelRoot(0);
        assertEq(distributor.getEpoch(0).root, bytes32(0));
        assertEq(distributor.getEpoch(0).expiresAt, 0);

        // The epoch must NOT be sweepable now, or the correction is impossible. Asserted as
        // BEHAVIOUR first and as an exact deadline second, so removing the floor trips the thing
        // that actually matters rather than only an arithmetic check.
        uint64 eligibleAt = distributor.rolloverEligibleAt(0);
        vm.prank(HOLDER_C);
        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.NotExpiredYet.selector, uint256(0), eligibleAt));
        distributor.rollover(0);
        assertEq(eligibleAt, uint64(block.timestamp) + distributor.ROOT_GRACE_PERIOD(), "floor set by the cancel");

        // The corrected root lands and pays the real holders.
        bytes32 leafA = _leaf(0, HOLDER_A, 0, pot / 2);
        bytes32 leafB = _leaf(1, HOLDER_B, 0, pot - pot / 2);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, _hashPair(leafA, leafB), TREE_URI);
        vm.warp(block.timestamp + CHALLENGE);
        distributor.claim(0, 1, HOLDER_B, 0, pot - pot / 2, _proof(leafA));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_B), pot - pot / 2);
    }

    /// @dev A cancelled epoch that is then abandoned must still be sweepable. The floor is a delay,
    /// not a lock.
    function test_cancelRoot_stillLeavesTheEpochSweepableIfNobodyRepostsIt() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        vm.warp(distributor.getEpoch(0).closedAt + MIN_EPOCH + CLAIM_WINDOW + distributor.ROOT_GRACE_PERIOD() + 1 days);
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);
        vm.prank(GOVERNANCE);
        distributor.cancelRoot(0);

        vm.warp(distributor.rolloverEligibleAt(0));
        distributor.rollover(0);
        assertEq(distributor.carryOver1(), pot);
    }

    /// @dev Which clock governs is not something a keeper should be recomputing off chain, because
    /// `cancelRoot` moves one of them and nothing in `getEpoch` records that it did.
    function test_rolloverEligibleAt_reportsWhicheverClockGoverns() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint64 closedAt = distributor.getEpoch(0).closedAt;

        // 1. No root: the abandonment fallback, grace included.
        assertEq(distributor.rolloverEligibleAt(0), closedAt + MIN_EPOCH + CLAIM_WINDOW + distributor.ROOT_GRACE_PERIOD());

        // 2. A root stands: its own claim window governs, and holders were told when that closes.
        vm.prank(GOVERNANCE);
        distributor.postRoot(0, bytes32(uint256(1)), TREE_URI);
        assertEq(distributor.rolloverEligibleAt(0), distributor.getEpoch(0).expiresAt);

        // 3. Cancelled: back to no root, but never sooner than the grace from the cancellation.
        vm.prank(GUARDIAN);
        distributor.cancelRoot(0);
        uint64 afterCancel = distributor.rolloverEligibleAt(0);
        assertGe(afterCancel, uint64(block.timestamp) + distributor.ROOT_GRACE_PERIOD());

        vm.expectRevert(abi.encodeWithSelector(MerkleEpochDistributor.UnknownEpoch.selector, uint256(7)));
        distributor.rolloverEligibleAt(7);
    }

    /*//////////////////////////////////////////////////////////////
              A2 - THE EPOCH COOLDOWN IS ENFORCED, NOT ADVISED
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
       ROOT_GRACE_PERIOD IS A TENANT'S PARAMETER, NOT DEEPCORE'S
    //////////////////////////////////////////////////////////////*/

    /// @dev It was `uint64 public constant ROOT_GRACE_PERIOD = 3 days`, sized against
    /// `DeepCoreTimelock.CUSTODY_MIN_DELAY` - which quietly made ONE protocol's governance schedule a
    /// property of every tenant's distributor. A tenant running a 7-day timelock gets exactly the
    /// race the grace exists to close: the root is queued and maturing, `rollover` becomes
    /// available first, and a griefer voids an allocation that took an off-chain job to compute.
    ///
    /// The floor stays at 3 days because a grace shorter than DeepCore's own delay was never
    /// defensible for anybody. The ceiling exists because the grace DELAYS the permissionless path
    /// that returns unclaimed value to the next epoch.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: there was no argument to reject.
    function test_constructor_boundsTheRootGracePeriod() public {
        uint64 floor_ = distributor.ROOT_GRACE_PERIOD_FLOOR();
        uint64 ceil_ = distributor.ROOT_GRACE_PERIOD_CEILING();

        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.InvalidRootGracePeriod.selector, uint64(0), floor_, ceil_)
        );
        new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, 0
        );

        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.InvalidRootGracePeriod.selector, floor_ - 1, floor_, ceil_)
        );
        new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, floor_ - 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.InvalidRootGracePeriod.selector, ceil_ + 1, floor_, ceil_)
        );
        new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, ceil_ + 1
        );
    }

    /// @dev The case the constant could not express: a tenant behind a 7-day timelock buys itself
    /// room that actually covers it, and the no-root sweep moves back by exactly that much.
    function test_aTenantWithALongerTimelockCanBuyItselfTheRoom() public {
        MerkleEpochDistributor patient = new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, 7 days
        );
        assertEq(patient.ROOT_GRACE_PERIOD(), 7 days);
        assertEq(distributor.ROOT_GRACE_PERIOD(), GRACE, "DeepCore's own sits at the floor");
        assertEq(uint256(patient.ROOT_GRACE_PERIOD()) - distributor.ROOT_GRACE_PERIOD(), 4 days);
    }

    /// @dev `minEpochDuration` was validated by nothing, so `0` was accepted - and a zero cooldown
    /// lets anybody shred the pot into one epoch per block, each needing its own root, its own
    /// challenge window and its own claim transaction. Exactly the griefing the parameter exists to
    /// stop, guaranteed by a comment.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: both constructions below succeed.
    function test_constructor_refusesADegenerateEpochCooldown() public {
        uint64 floor_ = distributor.MIN_EPOCH_DURATION_FLOOR();

        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.MinEpochDurationTooShort.selector, uint64(0), floor_)
        );
        new MerkleEpochDistributor(IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, 0, CHALLENGE, CLAIM_WINDOW, GRACE);

        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.MinEpochDurationTooShort.selector, floor_ - 1, floor_)
        );
        new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, floor_ - 1, CHALLENGE, CLAIM_WINDOW, GRACE
        );

        // The floor itself is accepted: this is a floor, not a policy.
        new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, floor_, CHALLENGE, CLAIM_WINDOW, GRACE
        );
    }

    /// @dev The first close used to be exempt from the cooldown outright (`epochCount != 0 && ...`,
    /// which never bit because `lastCloseAt` was zero). Seeding `lastCloseAt` at construction
    /// deletes the carve-out.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: the first `closeEpoch` succeeds immediately.
    function test_closeEpoch_theFirstEpochIsNotExemptFromTheCooldown() public {
        MerkleEpochDistributor fresh = new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, GRACE
        );
        assertEq(fresh.lastCloseAt(), uint64(block.timestamp), "the cooldown clock starts at deployment");

        _swap(SWAP_AMOUNT, true);
        assertGt(hook.pendingDistributorShare(poolId, currency1), 0, "there is a pot; only the clock is stopping it");

        vm.expectRevert(
            abi.encodeWithSelector(MerkleEpochDistributor.EpochTooSoon.selector, uint64(block.timestamp) + MIN_EPOCH)
        );
        fresh.closeEpoch();
    }
}

/*//////////////////////////////////////////////////////////////
                    SNAPSHOT EPOCH DISTRIBUTOR
//////////////////////////////////////////////////////////////*/

/// @dev A contract holder that can accept a delegation and nothing else: no function moves a token.
/// Stands in for the Vault, the hook after `redeem`, a router - anything `DeepCoreVotes` auto-delegates.
contract DelegatingSink {
    function delegateSelf(VotesToken votes) external {
        votes.delegate(address(this));
    }
}

/// @dev A contract holder that CAN claim for itself (a Safe, a treasury contract).
contract SelfClaimingHolder {
    function delegateSelf(VotesToken votes) external {
        votes.delegate(address(this));
    }

    function claimSnapshot(SnapshotEpochDistributor d, uint256 epochId) external returns (uint256, uint256) {
        return d.claim(epochId, address(this));
    }

    function claimMerkle(MerkleEpochDistributor d, uint256 epochId, uint256 index, uint256 a0, uint256 a1, bytes32[] calldata proof)
        external
    {
        d.claim(epochId, index, address(this), a0, a1, proof);
    }
}

contract SnapshotEpochDistributorTest is DistributorFixture {
    SnapshotEpochDistributor distributor;
    VotesToken votes;

    uint64 constant MIN_EPOCH = 1 days;
    uint64 constant CLAIM_WINDOW = 30 days;

    function setUp() public {
        // Separate the two clock domains so the ERC-6372 probe has something to distinguish.
        vm.roll(1000);
        vm.warp(1_000_000);

        votes = new VotesToken();
        votes.mint(address(this), 1_000_000 ether);
        MockERC20 pair = new MockERC20("PAIR", "PAIR", 18);
        pair.mint(address(this), 1_000_000 ether);

        _deployPool(address(votes), address(pair));

        distributor = new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(votes)), MIN_EPOCH, CLAIM_WINDOW
        );
        _configureAndSeed(address(distributor));

        // Holders must delegate for their balances to be counted. This is the whole catch.
        votes.transfer(HOLDER_A, 600 ether);
        votes.transfer(HOLDER_B, 400 ether);
        vm.prank(HOLDER_A);
        votes.delegate(HOLDER_A);
        vm.prank(HOLDER_B);
        votes.delegate(HOLDER_B);
        vm.roll(block.number + 1);

        // See the merkle fixture: the first close is gated too, now that `lastCloseAt` starts at
        // construction rather than at zero.
        vm.warp(block.timestamp + MIN_EPOCH);
    }

    /// @dev The mirror of `EpochDistributorKindTest`'s merkle case, and the worse direction. A
    /// snapshot epoch decoded through the merkle layout comes back with a NON-ZERO `root` - which
    /// is exactly how a UI decides an epoch has been posted and is claimable - so this epoch would
    /// present as a merkle epoch with a tree to go and fetch that has never existed.
    function test_kind_isWhatStopsASnapshotEpochBeingReadAsAMerkleEpoch() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        SnapshotEpochDistributor.Epoch memory truth = distributor.getEpoch(0);

        (bool ok, bytes memory raw) =
            address(distributor).staticcall(abi.encodeWithSignature("getEpoch(uint256)", uint256(0)));
        assertTrue(ok);
        MerkleEpochDistributor.Epoch memory misread = abi.decode(raw, (MerkleEpochDistributor.Epoch));

        assertEq(misread.root, bytes32(truth.totalVotingSupply), "index 4: a voting supply read as a root");
        assertEq(misread.closedAt, uint64(truth.timepoint), "index 5: a timepoint read as closedAt");
        assertEq(misread.claimableAt, truth.closedAt, "index 6: closedAt read as claimableAt");
        assertTrue(misread.root != bytes32(0), "a supply of zero is impossible, so the fake root is never zero");

        assertEq(distributor.kind(), EpochDistributorKind.SNAPSHOT);
    }

    function test_clockDetection_blockNumberToken() public view {
        assertTrue(distributor.clockIsBlockNumber());
        assertEq(distributor.clock(), uint48(block.number));
    }

    function test_clockDetection_timestampToken() public {
        TimestampVotesToken ts = new TimestampVotesToken();
        ts.mint(address(this), 1 ether);
        SnapshotEpochDistributor d = new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(ts)), MIN_EPOCH, CLAIM_WINDOW
        );
        assertFalse(d.clockIsBlockNumber(), "a timestamp clock must not be read as a block clock");
        assertEq(d.clock(), uint48(block.timestamp));
    }

    /// @dev Detect, do not assume. A token with no checkpoints fails at construction rather than
    /// silently paying everybody zero after the pot has already been pulled out of the hook.
    function test_clockDetection_rejectsANonSnapshotToken() public {
        PlainToken plain = new PlainToken();
        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.TokenNotSnapshotCapable.selector, address(plain))
        );
        new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(plain)), MIN_EPOCH, CLAIM_WINDOW
        );
    }

    function test_fullLifecycle_proRataByDelegatedVotes() public {
        _swap(SWAP_AMOUNT, true);
        _swap(SWAP_AMOUNT, false);

        uint256 pot0 = hook.pendingDistributorShare(poolId, currency0);
        uint256 pot1 = hook.pendingDistributorShare(poolId, currency1);
        assertGt(pot0, 0);
        assertGt(pot1, 0);

        vm.prank(HOLDER_C); // permissionless, admin-free
        distributor.closeEpoch();

        SnapshotEpochDistributor.Epoch memory epoch = distributor.getEpoch(0);
        // The numerator is DELEGATED votes; the denominator is ERC-5805's total supply of voting
        // units, which is the token's whole supply - including the 999_000 this contract minted to
        // itself and never delegated. The two do not measure the same thing, and the denominator
        // being the larger is exactly what keeps the epoch solvent. See the contract's NatSpec.
        assertEq(epoch.totalVotingSupply, votes.getPastTotalSupply(epoch.timepoint));
        assertEq(epoch.totalVotingSupply, 1_000_000 ether, "the denominator is total supply");
        assertEq(votes.getPastVotes(HOLDER_A, epoch.timepoint), 600 ether, "the numerator is delegated votes");

        uint256 supply = epoch.totalVotingSupply;
        (uint256 expect0, uint256 expect1) = distributor.claimableAmounts(0, HOLDER_A);
        assertEq(expect0, (pot0 * 600 ether) / supply);
        assertEq(expect1, (pot1 * 600 ether) / supply);
        assertGt(expect0, 0, "the fixture must not round A's share away to nothing");

        // currency0 IS the votes token here, so A necessarily already holds the 600 ether that
        // gives them voting power at all. Measure what the claim moved, not A's whole balance.
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(HOLDER_A);
        uint256 before1 = IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A);

        vm.prank(HOLDER_C);
        (uint256 got0, uint256 got1) = distributor.claim(0, HOLDER_A);
        assertEq(got0, expect0);
        assertEq(got1, expect1);
        // The payout lands on the account named in the call, not on the permissionless caller.
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(HOLDER_A) - before0, expect0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(HOLDER_A) - before1, expect1);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(HOLDER_C), 0, "the caller is paid nothing");

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.AlreadyClaimed.selector, uint256(0), HOLDER_A)
        );
        distributor.claim(0, HOLDER_A);

        distributor.claim(0, HOLDER_B);
        // Both claims together can never exceed the escrow.
        assertLe(distributor.getEpoch(0).claimed0, pot0);
        assertLe(distributor.getEpoch(0).claimed1, pot1);
    }

    /*//////////////////////////////////////////////////////////////
       MEDIUM, fixed: A STRANGER CANNOT CLAIM A CONTRACT HOLDER'S SHARE INTO A DEAD END
    //////////////////////////////////////////////////////////////*/

    /// @dev FAILS AGAINST THE PRE-FIX DISTRIBUTOR: there, HOLDER_C's call succeeded and paid the
    /// sink, which can never move a token - that share was gone for good instead of rolling over.
    function test_FIX_strangerCannotClaimForAContractHolder() public {
        DelegatingSink sink = new DelegatingSink();
        votes.transfer(address(sink), 300 ether);
        sink.delegateSelf(votes);
        vm.roll(block.number + 1);
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        (uint256 c0, uint256 c1) = distributor.claimableAmounts(0, address(sink));
        assertGt(c0 + c1, 0, "the sink does have a share");

        vm.prank(HOLDER_C);
        vm.expectRevert(
            abi.encodeWithSelector(
                SnapshotEpochDistributor.ContractAccountMustClaimItself.selector, address(sink), HOLDER_C
            )
        );
        distributor.claim(0, address(sink));
        assertFalse(distributor.claimed(0, address(sink)));
    }

    /// @dev The sink's unclaimed share returns to real holders through `rollover`.
    /*//////////// L-1 (2026-09-18): a stray token becomes holder money, escrow is never touched ////////////*/

    function test_FIX_sweepSurplus_tracksEscrowExactly_andMovesOnlyTheSurplus() public {
        vm.expectRevert(SnapshotEpochDistributor.NothingToSweep.selector);
        distributor.sweepSurplus();

        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;
        assertEq(distributor.escrowed1(), pot);
        assertEq(distributor.escrowed0(), 0);

        // Claims release exactly what they pay (floored shares); the rounding dust stays escrowed.
        vm.prank(HOLDER_A);
        (, uint256 a1) = distributor.claim(0, HOLDER_A);
        assertEq(distributor.escrowed1(), pot - a1);
        vm.expectRevert(SnapshotEpochDistributor.NothingToSweep.selector);
        distributor.sweepSurplus();

        uint256 stray0 = 4 ether;
        uint256 stray1 = 1 ether;
        IERC20(Currency.unwrap(currency0)).transfer(address(distributor), stray0);
        IERC20(Currency.unwrap(currency1)).transfer(address(distributor), stray1);
        vm.prank(HOLDER_C);
        (uint256 s0, uint256 s1) = distributor.sweepSurplus();
        assertEq(s0, stray0);
        assertEq(s1, stray1);
        assertEq(distributor.carryOver0(), stray0);
        assertEq(distributor.carryOver1(), stray1);
        assertEq(distributor.escrowed1(), pot - a1 + stray1);

        // HOLDER_B's share of epoch 0 is untouched by the sweep.
        (, uint256 expectedB) = distributor.claimableAmounts(0, HOLDER_B);
        vm.prank(HOLDER_B);
        (, uint256 b1) = distributor.claim(0, HOLDER_B);
        assertEq(b1, expectedB);

        // Rollover moves the dust into carry-over without changing the escrow total.
        uint256 escrowBefore = distributor.escrowed1();
        vm.warp(distributor.getEpoch(0).expiresAt);
        distributor.rollover(0);
        assertEq(distributor.escrowed1(), escrowBefore);
        assertEq(distributor.carryOver1(), stray1 + (pot - a1 - b1));

        // And the next epoch distributes all of it.
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        assertEq(distributor.getEpoch(1).amount0, stray0);
        assertEq(distributor.escrowed1(), distributor.getEpoch(1).amount1);
    }

    function test_FIX_aContractHoldersUnclaimedShareRollsOver() public {
        DelegatingSink sink = new DelegatingSink();
        votes.transfer(address(sink), 300 ether);
        sink.delegateSelf(votes);
        vm.roll(block.number + 1);
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        (uint256 c0,) = distributor.claimableAmounts(0, address(sink));

        vm.warp(distributor.getEpoch(0).expiresAt);
        distributor.rollover(0);
        assertGe(distributor.carryOver0(), c0, "the sink's share is carried to the next epoch");
    }

    /// @dev A contract that can claim for itself still can: the rule is "claim your own", not "no contracts".
    function test_FIX_aContractHolderMayClaimForItself() public {
        SelfClaimingHolder holder = new SelfClaimingHolder();
        votes.transfer(address(holder), 300 ether);
        holder.delegateSelf(votes);
        vm.roll(block.number + 1);
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        (uint256 e0, uint256 e1) = distributor.claimableAmounts(0, address(holder));
        (uint256 g0, uint256 g1) = holder.claimSnapshot(distributor, 0);
        assertEq(g0, e0);
        assertEq(g1, e1);
        assertTrue(distributor.claimed(0, address(holder)));
    }

    /// @dev The finding's own sinks, not a stand-in: the real Vault (which holds the pool's votes
    /// token as liquidity), the hook and the distributor itself, each self-delegated the way
    /// `DeepCoreVotes` auto-delegates a first receiver. A stranger can claim none of them, and all three
    /// shares roll over to the next epoch intact.
    function test_FIX_theVaultHookAndDistributorSharesCannotBeClaimedByAStranger() public {
        votes.transfer(address(hook), 100 ether);
        votes.transfer(address(distributor), 100 ether);
        address[3] memory sinks = [address(vault), address(hook), address(distributor)];
        for (uint256 i; i < sinks.length; ++i) {
            vm.prank(sinks[i]);
            votes.delegate(sinks[i]);
        }
        vm.roll(block.number + 1);
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        uint256 sinkShare0;
        uint256 sinkShare1;
        for (uint256 i; i < sinks.length; ++i) {
            (uint256 c0, uint256 c1) = distributor.claimableAmounts(0, sinks[i]);
            assertGt(c0 + c1, 0, "each sink holds a real share");
            sinkShare0 += c0;
            sinkShare1 += c1;
            vm.prank(HOLDER_C);
            vm.expectRevert(
                abi.encodeWithSelector(SnapshotEpochDistributor.ContractAccountMustClaimItself.selector, sinks[i], HOLDER_C)
            );
            distributor.claim(0, sinks[i]);
        }

        vm.warp(distributor.getEpoch(0).expiresAt);
        distributor.rollover(0);
        assertGe(distributor.carryOver0(), sinkShare0, "all three shares return to the next epoch");
        assertGe(distributor.carryOver1(), sinkShare1, "in both currencies");
    }

    /// @dev The documented catch, asserted rather than hand-waved: an undelegated holder gets
    /// nothing, and - because their balance is still in the denominator - nobody else gets more.
    /// Their share simply goes unclaimed and `rollover` hands it to the next epoch.
    function test_undelegatedHolderReceivesNothing() public {
        votes.transfer(HOLDER_C, 500 ether); // never delegates
        vm.roll(block.number + 1);

        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        SnapshotEpochDistributor.Epoch memory epoch = distributor.getEpoch(0);
        assertEq(votes.getPastVotes(HOLDER_C, epoch.timepoint), 0, "C delegated to nobody");
        // A transfer moves votes between delegates; it never touches `_totalCheckpoints`. So C's
        // balance stays in the denominator, and C being unpaid does not enlarge A's or B's share.
        assertEq(epoch.totalVotingSupply, votes.totalSupply(), "undelegated supply stays in the denominator");

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.NothingToClaim.selector, uint256(0), HOLDER_C)
        );
        distributor.claim(0, HOLDER_C);

        // Nothing is destroyed by that: whatever nobody can claim returns to the next epoch.
        uint256 pot1 = epoch.amount1;
        assertGt(pot1, 0);
        vm.warp(block.timestamp + CLAIM_WINDOW);
        distributor.rollover(0);
        assertEq(distributor.carryOver1(), pot1, "the unclaimable share is escrowed, not burned");
    }

    /*//////////////////////////////////////////////////////////////
             A2 - WHO CHOOSES THE SNAPSHOT MOMENT, AND AT WHAT COST
    //////////////////////////////////////////////////////////////*/

    /// @dev THE RESIDUAL RISK, ASSERTED RATHER THAN HAND-WAVED. `closeEpoch` is permissionless and
    /// it is what fixes the timepoint, so an attacker picks the moment: buy in block N, close in
    /// N+1, `timepoint == N` captures the position, claim, sell. This test PASSES on purpose - the
    /// behaviour is accepted, and the alternative (recording the next epoch's timepoint at the
    /// previous close) is rejected on the reasoning in the `closeEpoch` docstring. What is asserted
    /// here is the shape and the bound, so that a future change which makes it cheaper is loud.
    ///
    /// Note the delegation happens in the same block as the transfer, which is exactly what
    /// `DeepCoreVotes` does automatically on first receipt: the attacker has no delegation lag to sit
    /// through, and this is the honest, cheapest version of the attack.
    function test_snapshotTiming_anAttackerCanPickTheMomentButNotTheFrequency() public {
        address attacker = address(0xA77ACC);

        _swap(SWAP_AMOUNT, true);
        uint256 pot = hook.pendingDistributorShare(poolId, currency1);
        assertGt(pot, 0, "the prize is a public number before the attacker commits any capital");

        // Block N: buy in, and be delegated in the same block.
        votes.transfer(attacker, 1000 ether);
        vm.prank(attacker);
        votes.delegate(attacker);

        // Not in the SAME block: closing at N snapshots N-1, before the buy.
        vm.roll(block.number + 1);
        distributor.closeEpoch();

        (, uint256 owed) = distributor.claimableAmounts(0, attacker);
        assertGt(owed, 0, "one block of exposure is the entire cost, and it is not zero");

        // The bound. The position may be dumped immediately - the snapshot is already taken - but
        // the trick cannot be repeated until the cooldown elapses, and that is the ONLY lever.
        distributor.claim(0, attacker);
        vm.prank(attacker);
        votes.transfer(address(this), 1000 ether);

        _swap(SWAP_AMOUNT, true);
        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.EpochTooSoon.selector, uint64(block.timestamp) + MIN_EPOCH)
        );
        distributor.closeEpoch();
    }

    /// @dev The cooldown carries a security property and used to be enforced by nothing: `0` was a
    /// valid `minEpochDuration`, which makes the timepoint attacker-choosable in every block. Same
    /// shape as `ManualPriceBandOracle.minPublisherInterval` defaulting to zero.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: both constructions below succeed.
    function test_constructor_refusesADegenerateEpochCooldown() public {
        uint64 floor_ = distributor.MIN_EPOCH_DURATION_FLOOR();

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.MinEpochDurationTooShort.selector, uint64(0), floor_)
        );
        new SnapshotEpochDistributor(IRevShareHook(address(hook)), key, IVotes(address(votes)), 0, CLAIM_WINDOW);

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.MinEpochDurationTooShort.selector, floor_ - 1, floor_)
        );
        new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(votes)), floor_ - 1, CLAIM_WINDOW
        );

        new SnapshotEpochDistributor(IRevShareHook(address(hook)), key, IVotes(address(votes)), floor_, CLAIM_WINDOW);
    }

    /// @dev The first snapshot used to be free: `epochCount != 0 && ...` exempted epoch 0, so a
    /// fresh distributor could be sniped the moment it had a pot, with no cooldown at all - the one
    /// close nobody is watching for yet.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: the first `closeEpoch` succeeds immediately.
    function test_closeEpoch_theFirstSnapshotIsNotFree() public {
        SnapshotEpochDistributor fresh = new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(votes)), MIN_EPOCH, CLAIM_WINDOW
        );
        assertEq(fresh.lastCloseAt(), uint64(block.timestamp), "the cooldown clock starts at deployment");

        _swap(SWAP_AMOUNT, true);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.EpochTooSoon.selector, uint64(block.timestamp) + MIN_EPOCH)
        );
        fresh.closeEpoch();
    }

    function test_closeEpoch_revertsWhenNobodyHasDelegated() public {
        VotesToken lonely = new VotesToken();
        lonely.mint(address(this), 1 ether);
        SnapshotEpochDistributor d = new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(lonely)), MIN_EPOCH, CLAIM_WINDOW
        );
        vm.warp(block.timestamp + MIN_EPOCH); // `d` was just built; its own cooldown starts now

        _swap(SWAP_AMOUNT, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                SnapshotEpochDistributor.NoVotingSupplyAtSnapshot.selector, uint48(block.number - 1)
            )
        );
        d.closeEpoch();

        // Nothing was pulled, so the value is still in the hook for a later epoch.
        assertGt(hook.pendingDistributorShare(poolId, currency1), 0);
    }

    function test_closeEpoch_respectsMinimumDuration() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();

        _swap(SWAP_AMOUNT, true);
        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SnapshotEpochDistributor.EpochTooSoon.selector, uint64(block.timestamp) + MIN_EPOCH)
        );
        distributor.closeEpoch();

        vm.warp(block.timestamp + MIN_EPOCH);
        distributor.closeEpoch();
        assertEq(distributor.epochCount(), 2);
    }

    function test_rollover_returnsTheFloorRemainderAndUnclaimedShares() public {
        _swap(SWAP_AMOUNT, true);
        distributor.closeEpoch();
        uint256 pot = distributor.getEpoch(0).amount1;

        distributor.claim(0, HOLDER_A);
        uint256 unclaimed = pot - distributor.getEpoch(0).claimed1;
        assertGt(unclaimed, 0, "HOLDER_B has not claimed yet");

        vm.warp(block.timestamp + CLAIM_WINDOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                SnapshotEpochDistributor.ClaimWindowClosed.selector, uint256(0), distributor.getEpoch(0).expiresAt
            )
        );
        distributor.claim(0, HOLDER_B);

        distributor.rollover(0);
        assertEq(distributor.carryOver1(), unclaimed);

        _swap(SWAP_AMOUNT, true);
        vm.roll(block.number + 1);
        uint256 fresh = hook.pendingDistributorShare(poolId, currency1);
        distributor.closeEpoch();
        assertEq(distributor.getEpoch(1).amount1, fresh + unclaimed);
    }

    /// @dev The distributor holds exactly what its epochs say it holds, at every point.
    function test_escrowAccountingIsExact() public {
        _swap(SWAP_AMOUNT, true);
        _swap(SWAP_AMOUNT, false);
        distributor.closeEpoch();

        distributor.claim(0, HOLDER_A);
        distributor.claim(0, HOLDER_B);

        SnapshotEpochDistributor.Epoch memory epoch = distributor.getEpoch(0);
        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(distributor)),
            epoch.amount1 - epoch.claimed1,
            "distributor balance must equal unclaimed escrow"
        );
        assertEq(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(distributor)),
            epoch.amount0 - epoch.claimed0,
            "distributor balance must equal unclaimed escrow"
        );
    }
}

/*//////////////////////////////////////////////////////////////
                     DISTRIBUTOR TYPE DISCOVERY
//////////////////////////////////////////////////////////////*/

/// @dev `RevShareHook.distributorOf` returns a bare address. Until `kind()` the only way to learn
/// which of the two distributors was behind it was to PROBE - call `token()` (answers only on the
/// snapshot one) and `challengeDelay()` (only on the merkle one) and require exactly one to
/// succeed. Three separate consumers had reimplemented that.
///
/// These tests do two things: show that one call now answers the question outright, and show what
/// the probe was actually protecting against, so that removing it is a deliberate decision rather
/// than a tidy-up.
contract EpochDistributorKindTest is DistributorFixture {
    MerkleEpochDistributor merkle;
    SnapshotEpochDistributor snapshot;

    uint64 constant MIN_EPOCH = 1 days;
    uint64 constant CHALLENGE = 2 hours;
    uint64 constant CLAIM_WINDOW = 30 days;

    function setUp() public {
        // Two clock domains apart, so the snapshot distributor's ERC-6372 probe has something to
        // tell apart when it is constructed.
        vm.roll(1000);
        vm.warp(1_000_000);

        VotesToken votes = new VotesToken();
        votes.mint(address(this), 1_000_000 ether);
        MockERC20 pair = new MockERC20("PAIR", "PAIR", 18);
        pair.mint(address(this), 1_000_000 ether);
        _deployPool(address(votes), address(pair));

        // Both are built against the same key, but only the merkle one is the pool's configured
        // distributor. `kind()` is `pure`, so being wired to a pool is not a precondition for
        // answering - which matters, because a consumer inspecting an address it was handed has no
        // way to know in advance whether it is wired to anything.
        merkle = new MerkleEpochDistributor(
            IRevShareHook(address(hook)), key, GOVERNANCE, GUARDIAN, MIN_EPOCH, CHALLENGE, CLAIM_WINDOW, GRACE
        );
        snapshot = new SnapshotEpochDistributor(
            IRevShareHook(address(hook)), key, IVotes(address(votes)), MIN_EPOCH, CLAIM_WINDOW
        );
        _configureAndSeed(address(merkle));

        vm.warp(block.timestamp + MIN_EPOCH);
    }

    function test_kind_answersDirectlyForBothDistributors() public view {
        assertEq(merkle.kind(), EpochDistributorKind.MERKLE);
        assertEq(snapshot.kind(), EpochDistributorKind.SNAPSHOT);

        // Distinct, and neither is the value a catch-all fallback, an empty proxy or a zero-filled
        // decode produces. That last property is the reason these are keccak constants and not an
        // enum: with an enum, "I could not tell" and "it is a snapshot distributor" are both 0.
        assertTrue(EpochDistributorKind.MERKLE != EpochDistributorKind.SNAPSHOT);
        assertTrue(EpochDistributorKind.MERKLE != bytes32(0));
        assertTrue(EpochDistributorKind.SNAPSHOT != bytes32(0));
    }

    /// @dev Consumers reach this over `eth_call` and will never send a transaction for it, so it
    /// has to work through a `staticcall` and cost effectively nothing.
    function test_kind_isStaticcallableOnBoth() public view {
        (bool okMerkle, bytes memory merkleRet) = address(merkle).staticcall(abi.encodeWithSignature("kind()"));
        (bool okSnapshot, bytes memory snapshotRet) = address(snapshot).staticcall(abi.encodeWithSignature("kind()"));

        assertTrue(okMerkle);
        assertTrue(okSnapshot);
        assertEq(abi.decode(merkleRet, (bytes32)), EpochDistributorKind.MERKLE);
        assertEq(abi.decode(snapshotRet, (bytes32)), EpochDistributorKind.SNAPSHOT);
    }

    /// @dev WHY THE PROBE WAS LOAD-BEARING, NOT COSMETIC. Both `Epoch` structs are nine all-static
    /// fields, so a consumer holding the wrong ABI does not get an exception - it gets numbers.
    /// This decodes a REAL merkle epoch through the snapshot layout to show the misread is silent,
    /// then shows the single call that means a consumer is never in that position.
    function test_kind_isWhatStopsAMerkleEpochBeingReadAsASnapshotEpoch() public {
        _swap(SWAP_AMOUNT, true);
        merkle.closeEpoch();

        bytes32 root = keccak256("epoch 0 holder set");
        vm.prank(GOVERNANCE);
        merkle.postRoot(0, root, "ipfs://bafkreiepochzero");

        MerkleEpochDistributor.Epoch memory truth = merkle.getEpoch(0);

        (bool ok, bytes memory raw) =
            address(merkle).staticcall(abi.encodeWithSignature("getEpoch(uint256)", uint256(0)));
        assertTrue(ok);

        // Nine words in, nine words out. Nothing reverts, nothing is left over, there is no error
        // for a caller to catch and no length mismatch to notice.
        SnapshotEpochDistributor.Epoch memory misread = abi.decode(raw, (SnapshotEpochDistributor.Epoch));

        assertEq(misread.totalVotingSupply, uint256(truth.root), "index 4: a root read as a voting supply");
        assertEq(misread.timepoint, uint48(truth.closedAt), "index 5: closedAt read as a timepoint");
        assertEq(misread.closedAt, truth.claimableAt, "index 6: claimableAt read as closedAt");
        // The first four words agree, which is exactly what makes the misread survive a sanity
        // check: the amounts a reader is most likely to eyeball are correct.
        assertEq(misread.amount1, truth.amount1);
        assertEq(misread.claimed1, truth.claimed1);

        // And the damage is not a visibly broken number. `payout = pot * votes / supply` against a
        // 256-bit root floors to zero for every holder, so the consumer reports "nobody is owed
        // anything" about an epoch that is fully funded.
        assertGt(misread.totalVotingSupply, type(uint128).max, "the bogus denominator is astronomically large");

        // One call, made first, and none of the above can happen.
        assertEq(merkle.kind(), EpochDistributorKind.MERKLE);
    }
}
