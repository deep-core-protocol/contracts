// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreDynamicFeeHook} from "deepcore-hooks/src/dex/DeepCoreDynamicFeeHook.sol";
import {ManualPriceBandOracle} from "deepcore-hooks-rwa/src/oracles/ManualPriceBandOracle.sol";

import {DeepCoreTunerGate} from "../src/DeepCoreTunerGate.sol";

contract DeepCoreTunerGateTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    address internal constant SAFE = address(0x5AFE); // the hook's Safe and the gate's recipient
    address internal constant GOV = address(0x6007); // the gate's owner
    address internal constant OPS = address(0x0B5); // the gate's guardian
    address internal constant AGENT = address(0xA6E7);
    address internal constant POOL_OWNER = address(0xC0FFEE);
    address internal constant ORACLE_OWNER = address(0x0C0C);
    address internal constant STRANGER = address(0xBAD);

    uint32 internal constant NOTICE = 1 days;
    uint256 internal constant T0 = 1_800_000_000;
    uint160 internal constant P1 = 79_228_162_514_264_337_593_543_950_336; // 1.0 (2^96)

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;
    DeepCoreDynamicFeeHook internal hook;
    ManualPriceBandOracle internal oracle;
    DeepCoreTunerGate internal gate;
    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal id;
    PoolId internal refPool = PoolId.wrap(bytes32(uint256(0xBEEF)));

    function setUp() public {
        vm.warp(T0);
        (vault, manager) = createFreshManager();
        router = new CLPoolManagerRouter(vault, manager);
        (c0, c1) = deployCurrencies(2 ** 250);
        IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
        hook = new DeepCoreDynamicFeeHook(manager, IVault(address(vault)), SAFE, SAFE, 50_000, 1_500, 3_000, 7 days, 1 days, 500);
        gate = new DeepCoreTunerGate(GOV, OPS, SAFE, NOTICE, NOTICE, 1_000);

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: manager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), 60)
        });
        id = key.toId();
        vm.prank(POOL_OWNER);
        hook.configure(key, _hookCfg(), 3_000);
        manager.initialize(key, SQRT_RATIO_1_1);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: 1_000 ether, salt: 0}),
            ZERO_BYTES
        );

        // The pool owner appoints the gate as tuner; the gate's owner accepts after the hook's notice.
        vm.prank(POOL_OWNER);
        hook.proposeTuner(id, address(gate));
        vm.warp(T0 + 1 days);
        vm.prank(GOV);
        gate.acceptTuner(address(hook), id);

        // The oracle: its owner (Custody) publishes the first reference and makes the gate a publisher.
        // Its interval is left at the DEFAULT of 0: the gate must not rely on it.
        oracle = new ManualPriceBandOracle(ORACLE_OWNER);
        vm.startPrank(ORACLE_OWNER);
        oracle.setReferencePrice(refPool, P1);
        oracle.setPublisher(address(gate), true);
        vm.stopPrank();

        // Agent and policies, each behind the gate's notice.
        vm.startPrank(GOV);
        bytes32 a = gate.proposeAgent(AGENT);
        bytes32 f = gate.proposeFeePolicy(address(hook), id, _feePolicy());
        bytes32 r = gate.proposeRefPolicy(address(oracle), refPool, _refPolicy());
        vm.stopPrank();
        vm.warp(T0 + 2 days);
        gate.applyProposal(a);
        gate.applyProposal(f);
        gate.applyProposal(r);
    }

    function _hookCfg() internal pure returns (DeepCoreDynamicFeeHook.FeeConfig memory c) {
        c.baseFee = 3_000;
        c.volSlope = 10;
        c.sameSecondSlope = 50;
        c.minBaseFee = 500;
        c.maxBaseFee = 10_000;
        c.maxVolSlope = 40;
        c.maxSameSecondSlope = 100;
        c.maxFee = 30_000;
        c.volCap = 2_000;
        c.decaySeconds = 1_800;
        c.deadband = 5;
        c.maxBaseFeeStep = 500;
        c.maxSlopeStep = 5;
        c.minTuneInterval = 3_600;
    }

    function _feePolicy() internal pure returns (DeepCoreTunerGate.FeePolicy memory) {
        return DeepCoreTunerGate.FeePolicy({
            enabled: true, minBaseFee: 1_000, maxBaseFee: 6_000, maxVolSlope: 20, maxSameSecondSlope: 80, minInterval: 7_200
        });
    }

    function _refPolicy() internal pure returns (DeepCoreTunerGate.RefPolicy memory) {
        return DeepCoreTunerGate.RefPolicy({enabled: true, maxDeviationBps: 500, minInterval: 3_600});
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// @dev A price `bps` above `p` (sqrt scaled by sqrt(1 + bps/1e4), close enough for bounds tests).
    function _up(uint160 p, uint256 sqrtBpsTimes10) internal pure returns (uint160) {
        return uint160(uint256(p) * (100_000 + sqrtBpsTimes10) / 100_000);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev An EXTERNAL constructor call, so `vm.expectRevert` applies to this call. With
    /// `allow_internal_expect_revert`, an expected revert on a bare `new` inside the test makes the TEST
    /// itself revert-and-pass, and every line after the first refusal silently never runs (found by a
    /// surviving mutant, 2026-10-14).
    function newGate(address o, address g, address r, uint32 an, uint32 pn, uint16 dev) external returns (address) {
        return address(new DeepCoreTunerGate(o, g, r, an, pn, dev));
    }

    function test_deploy_refusesBadImmutables_andRenounce() public {
        vm.expectRevert(DeepCoreTunerGate.ZeroAddress.selector);
        this.newGate(GOV, OPS, address(0), NOTICE, NOTICE, 1_000);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidDeployment.selector, 1));
        this.newGate(GOV, OPS, SAFE, NOTICE - 1, NOTICE, 1_000);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidDeployment.selector, 1));
        this.newGate(GOV, OPS, SAFE, NOTICE, NOTICE - 1, 1_000);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidDeployment.selector, 2));
        this.newGate(GOV, OPS, SAFE, NOTICE, NOTICE, 1_001);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidDeployment.selector, 2));
        this.newGate(GOV, OPS, SAFE, NOTICE, NOTICE, 0);
        vm.prank(GOV);
        vm.expectRevert(DeepCoreTunerGate.RenounceDisabled.selector);
        gate.renounceOwnership();
        assertEq(gate.owner(), GOV);
        assertEq(gate.guardian(), OPS);
        assertEq(gate.agent(), AGENT);
    }

    function test_ownership_isTwoStep() public {
        vm.prank(GOV);
        gate.transferOwnership(STRANGER);
        assertEq(gate.owner(), GOV);
        vm.prank(STRANGER);
        gate.acceptOwnership();
        assertEq(gate.owner(), STRANGER);
    }

    /*//////////////////////////////////////////////////////////////
                              THE FEE PATH
    //////////////////////////////////////////////////////////////*/

    function test_tuneFee_writesThroughTheHook_insidePolicy() public {
        vm.expectEmit(address(gate));
        emit DeepCoreTunerGate.FeeTuned(address(hook), id, 3_400, 12, 55);
        vm.prank(AGENT);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);
        DeepCoreDynamicFeeHook.FeeConfig memory c = hook.getConfig(id);
        assertEq(c.baseFee, 3_400);
        assertEq(c.volSlope, 12);
        assertEq(c.sameSecondSlope, 55);
        assertEq(gate.nextFeeTuneAt(address(hook), id), _now() + 7_200);
    }

    function test_tuneFee_refusesStrangerPauseUnknownTargetAndKeyMismatch() public {
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreTunerGate.NotAgent.selector);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);

        PoolKey memory other = key;
        other.parameters = CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), 10);
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.TargetNotEnabled.selector, address(hook), other.toId()));
        gate.tuneFee(address(hook), other, 3_400, 12, 55);

        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.KeyMismatch.selector);
        gate.tuneFee(address(0x1234), key, 3_400, 12, 55);

        vm.prank(OPS);
        gate.pause();
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.GatePaused.selector);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);
    }

    function test_tuneFee_refusesOutsideThePolicyInEachField() public {
        vm.startPrank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.OutOfPolicy.selector, 1, 999));
        gate.tuneFee(address(hook), key, 999, 10, 50); // inside the HOOK's bounds (500), outside the policy's
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.OutOfPolicy.selector, 1, 6_001));
        gate.tuneFee(address(hook), key, 6_001, 10, 50);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.OutOfPolicy.selector, 2, 21));
        gate.tuneFee(address(hook), key, 3_000, 21, 50);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.OutOfPolicy.selector, 3, 81));
        gate.tuneFee(address(hook), key, 3_000, 10, 81);
        vm.stopPrank();
    }

    function test_tuneFee_theGateIntervalHoldsWhereTheHooksWouldAllow_andTheHookStillRefusesItsStep() public {
        vm.prank(AGENT);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);
        vm.warp(_now() + 3_600); // the hook's own interval has passed, the gate's (7,200) has not
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.TooSoon.selector, uint40(_now() + 3_600)));
        gate.tuneFee(address(hook), key, 3_500, 12, 55);
        vm.warp(_now() + 3_600);
        // Inside the gate's policy, but a step the hook refuses (max 500 against its anchor 3,400):
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.StepTooLarge.selector, 1, 3_400, 4_000, 500));
        gate.tuneFee(address(hook), key, 4_000, 12, 55);
        assertEq(gate.nextFeeTuneAt(address(hook), id), _now(), "a refused call writes nothing");
        vm.prank(AGENT);
        gate.tuneFee(address(hook), key, 3_900, 12, 55);
    }

    /*//////////////////////////////////////////////////////////////
                           THE REFERENCE PATH
    //////////////////////////////////////////////////////////////*/

    function test_publish_seedsFromTheOracleAnchor_andHoldsItsOwnIntervalAgainstTheOraclesZeroDefault() public {
        assertEq(oracle.minPublisherInterval(), 0, "the oracle's own interval is the default 0");
        uint160 p2 = _up(P1, 2_000); // sqrt +2% = price ~+4.04%
        vm.prank(AGENT);
        gate.publishReference(address(oracle), refPool, p2);
        (uint160 ref,) = oracle.referencePrice(refPool);
        assertEq(ref, p2);
        assertEq(gate.refPolicyOf(address(oracle), refPool).anchor, p2);
        // a second update at once would pass the ORACLE (interval 0); the gate refuses it
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.TooSoon.selector, uint40(_now() + 3_600)));
        gate.publishReference(address(oracle), refPool, _up(p2, 1_000));
        vm.warp(_now() + 3_600);
        vm.prank(AGENT);
        gate.publishReference(address(oracle), refPool, _up(p2, 1_000));
    }

    function test_publish_refusesADeviationAboveThePolicy_evenWhereTheOracleAllowsIt() public {
        uint160 p = _up(P1, 3_000); // sqrt +3% = price ~+6.09%: under the oracle's 10%, over the policy's 5%
        uint256 dev = gate.priceDeviationBps(p, P1);
        assertGt(dev, 500);
        assertLt(dev, 1_000);
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.DeviationTooLarge.selector, dev, 500));
        gate.publishReference(address(oracle), refPool, p);
    }

    function test_publish_clearAndRepublishDoesNotResetTheGatesAnchor() public {
        uint160 p2 = _up(P1, 2_000);
        vm.prank(AGENT);
        gate.publishReference(address(oracle), refPool, p2);
        // Somebody clears the oracle's price; the gate's anchor survives.
        vm.prank(ORACLE_OWNER);
        oracle.clearReference(refPool);
        vm.warp(_now() + 3_600);
        uint160 far = _up(p2, 5_000);
        bytes memory tooFar1 = abi.encodeWithSelector(DeepCoreTunerGate.DeviationTooLarge.selector, gate.priceDeviationBps(far, p2), 500);
        vm.prank(AGENT); // after the arguments: a call in the argument list would consume the prank
        vm.expectRevert(tooFar1);
        gate.publishReference(address(oracle), refPool, far);
    }

    /// @dev The oracle's owner re-anchors (a split): the agent can neither undo it (oracle anchor) nor
    /// jump to it (its own anchor) until the gate's owner re-proposes the policy.
    function test_publish_anOwnerReAnchorStopsTheAgentUntilThePolicyIsReProposed() public {
        uint160 p2 = _up(P1, 1_000);
        vm.prank(AGENT);
        gate.publishReference(address(oracle), refPool, p2);
        uint160 split = uint160(uint256(P1) * 2);
        vm.prank(ORACLE_OWNER);
        oracle.setReferencePrice(refPool, split); // the owner is exempt from the oracle's bound
        vm.warp(_now() + 3_600);
        bytes memory tooFar2 = abi.encodeWithSelector(DeepCoreTunerGate.DeviationTooLarge.selector, gate.priceDeviationBps(p2, split), 500);
        vm.prank(AGENT); // after the arguments: a call in the argument list would consume the prank
        vm.expectRevert(tooFar2);
        gate.publishReference(address(oracle), refPool, p2); // cannot undo the re-anchor
        uint160 nearSplit = _up(split, 500);
        bytes memory tooFar3 = abi.encodeWithSelector(DeepCoreTunerGate.DeviationTooLarge.selector, gate.priceDeviationBps(nearSplit, p2), 500);
        vm.prank(AGENT); // after the arguments: a call in the argument list would consume the prank
        vm.expectRevert(tooFar3);
        gate.publishReference(address(oracle), refPool, nearSplit); // cannot jump to it either
        vm.prank(GOV);
        bytes32 r = gate.proposeRefPolicy(address(oracle), refPool, _refPolicy());
        vm.warp(_now() + NOTICE);
        gate.applyProposal(r);
        assertEq(gate.refPolicyOf(address(oracle), refPool).anchor, 0, "re-seeded");
        vm.prank(AGENT);
        gate.publishReference(address(oracle), refPool, nearSplit);
    }

    /// @dev Another bounded publisher walks the oracle; the agent cannot ride that walk past its own anchor.
    function test_publish_theAgentCannotRideAnotherPublishersWalk() public {
        address other = address(0x07E7);
        vm.prank(ORACLE_OWNER);
        oracle.setPublisher(other, true);
        vm.prank(AGENT);
        gate.publishReference(address(oracle), refPool, P1 + 1); // the gate's anchor ~P1
        uint160 w1 = _up(P1, 4_000); // +8% price
        uint160 w2 = _up(w1, 4_000);
        vm.startPrank(other);
        oracle.setReferencePrice(refPool, w1);
        oracle.setReferencePrice(refPool, w2);
        vm.stopPrank();
        vm.warp(_now() + 3_600);
        uint160 ride = _up(w2, 1_000); // within 5% of the oracle's anchor, ~+19% from the gate's
        bytes memory tooFar4 = abi.encodeWithSelector(DeepCoreTunerGate.DeviationTooLarge.selector, gate.priceDeviationBps(ride, P1 + 1), 500);
        vm.prank(AGENT); // after the arguments: a call in the argument list would consume the prank
        vm.expectRevert(tooFar4);
        gate.publishReference(address(oracle), refPool, ride);
    }

    function test_publish_refusesWithNoAnchorAnywhere_andAPriceOutOfRange() public {
        PoolId fresh = PoolId.wrap(bytes32(uint256(0xF00D)));
        vm.prank(GOV);
        bytes32 r = gate.proposeRefPolicy(address(oracle), fresh, _refPolicy());
        vm.warp(_now() + NOTICE);
        gate.applyProposal(r);
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.NoAnchor.selector);
        gate.publishReference(address(oracle), fresh, P1);
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.PriceOutOfRange.selector, uint160(0)));
        gate.publishReference(address(oracle), refPool, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         STOPPING THE AGENT
    //////////////////////////////////////////////////////////////*/

    function test_stop_guardianRevokes_ownerRevokes_agentResigns_eachAtOnce() public {
        vm.prank(OPS);
        gate.revokeAgent();
        assertEq(gate.agent(), address(0));
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.NotAgent.selector);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);

        _reappoint();
        vm.prank(GOV);
        gate.revokeAgent();
        assertEq(gate.agent(), address(0));

        _reappoint();
        vm.prank(AGENT);
        gate.resign();
        assertEq(gate.agent(), address(0));
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.NotAgent.selector);
        gate.resign();
    }

    function test_stop_thePoolOwnerRemovesTheGateOnTheHook_orFreezes() public {
        vm.prank(POOL_OWNER);
        hook.revokeTuner(id);
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreDynamicFeeHook.NotTuner.selector);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);
    }

    function test_stop_guardianDropsTheTunerRole() public {
        vm.prank(OPS);
        gate.dropTuner(address(hook), id);
        assertEq(hook.getAdmin(id).tuner, address(0));
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreTunerGate.NotGuardianOrOwner.selector);
        gate.dropTuner(address(hook), id);
    }

    function test_stop_revokeAndAgentCallInOneBlock_bothOrders() public {
        // agent first, then revoke: the call landed, nothing further can
        vm.prank(AGENT);
        gate.tuneFee(address(hook), key, 3_400, 12, 55);
        vm.prank(OPS);
        gate.revokeAgent();
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.NotAgent.selector);
        gate.publishReference(address(oracle), refPool, _up(P1, 100));
        // revoke first, then the agent: refused in the same block
        _reappoint();
        vm.prank(OPS);
        gate.revokeAgent();
        vm.prank(AGENT);
        vm.expectRevert(DeepCoreTunerGate.NotAgent.selector);
        gate.publishReference(address(oracle), refPool, _up(P1, 100));
    }

    function _reappoint() internal {
        vm.prank(GOV);
        bytes32 a = gate.proposeAgent(AGENT);
        vm.warp(_now() + NOTICE);
        gate.applyProposal(a);
        assertEq(gate.agent(), AGENT);
    }

    /*//////////////////////////////////////////////////////////////
                    THE GUARDIAN CAN ONLY REDUCE
    //////////////////////////////////////////////////////////////*/

    function test_guardian_cannotEscalateAnything() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OPS);
        vm.startPrank(OPS);
        vm.expectRevert(notOwner);
        gate.proposeAgent(STRANGER);
        vm.expectRevert(notOwner);
        gate.proposeFeePolicy(address(hook), id, _feePolicy());
        vm.expectRevert(notOwner);
        gate.proposeRefPolicy(address(oracle), refPool, _refPolicy());
        gate.pause();
        vm.expectRevert(notOwner);
        gate.proposeUnpause();
        vm.expectRevert(notOwner);
        gate.tightenFeePolicy(address(hook), id, _feePolicy());
        vm.expectRevert(notOwner);
        gate.setGuardian(STRANGER);
        vm.expectRevert(notOwner);
        gate.acceptTuner(address(hook), id);
        vm.expectRevert(notOwner);
        gate.cancelProposal(bytes32(0));
        vm.expectRevert(notOwner);
        gate.transferOwnership(OPS);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              PROPOSALS
    //////////////////////////////////////////////////////////////*/

    function test_proposal_notDue_expired_cancelled_unknown_appliedOnce() public {
        vm.startPrank(GOV);
        bytes32 a = gate.proposeAgent(address(0xA2));
        bytes32 b = gate.proposeAgent(address(0xA3));
        bytes32 c = gate.proposeAgent(address(0xA4));
        vm.stopPrank();
        uint40 due = uint40(_now() + NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.ProposalNotDue.selector, due));
        gate.applyProposal(a);
        vm.prank(GOV);
        gate.cancelProposal(b);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NoSuchProposal.selector, b));
        gate.applyProposal(b);
        vm.warp(due);
        vm.prank(STRANGER);
        gate.applyProposal(a);
        assertEq(gate.agent(), address(0xA2));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NoSuchProposal.selector, a));
        gate.applyProposal(a);
        vm.warp(uint256(due) + 3 days + 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.ProposalExpired.selector, due + 3 days));
        gate.applyProposal(c);
    }

    function test_proposal_anAgentAppointmentQueuedBeforeARevocationIsVoid() public {
        vm.prank(GOV);
        bytes32 a = gate.proposeAgent(address(0xA2));
        vm.prank(OPS);
        gate.revokeAgent();
        vm.warp(_now() + NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.ProposalVoided.selector, a));
        gate.applyProposal(a);
        assertEq(gate.agent(), address(0));
    }

    function test_proposal_anUnpauseQueuedBeforeAPauseIsVoid_andUnpauseWaitsTheNotice() public {
        vm.prank(GOV);
        vm.expectRevert(DeepCoreTunerGate.NotPaused.selector);
        gate.proposeUnpause();
        vm.prank(OPS);
        gate.pause();
        vm.prank(GOV);
        bytes32 u1 = gate.proposeUnpause();
        vm.prank(OPS);
        gate.pause(); // a second incident
        vm.prank(GOV);
        bytes32 u2 = gate.proposeUnpause();
        vm.warp(_now() + NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.ProposalVoided.selector, u1));
        gate.applyProposal(u1);
        assertTrue(gate.paused());
        gate.applyProposal(u2);
        assertFalse(gate.paused());
    }

    function test_policy_tightenAtOnce_looseningSentAsATighteningRefused_andItVoidsQueuedLoosenings() public {
        DeepCoreTunerGate.FeePolicy memory loose = _feePolicy();
        loose.maxBaseFee = 9_000;
        vm.prank(GOV);
        bytes32 l = gate.proposeFeePolicy(address(hook), id, loose);

        DeepCoreTunerGate.FeePolicy memory p = _feePolicy();
        p.maxBaseFee = 6_001;
        vm.prank(GOV);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NotATightening.selector, 2));
        gate.tightenFeePolicy(address(hook), id, p);
        p = _feePolicy();
        p.minBaseFee = 999;
        vm.prank(GOV);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NotATightening.selector, 1));
        gate.tightenFeePolicy(address(hook), id, p);
        p = _feePolicy();
        p.minInterval = 7_199;
        vm.prank(GOV);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NotATightening.selector, 5));
        gate.tightenFeePolicy(address(hook), id, p);

        p = _feePolicy();
        p.maxBaseFee = 4_000;
        vm.prank(GOV);
        gate.tightenFeePolicy(address(hook), id, p);
        assertEq(gate.feePolicyOf(address(hook), id).policy.maxBaseFee, 4_000);
        vm.warp(_now() + NOTICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.ProposalVoided.selector, l));
        gate.applyProposal(l);

        // disabling is a tightening
        p.enabled = false;
        vm.prank(GOV);
        gate.tightenFeePolicy(address(hook), id, p);
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.TargetNotEnabled.selector, address(hook), id));
        gate.tuneFee(address(hook), key, 3_400, 12, 55);
        // and re-enabling one is not
        p = _feePolicy();
        vm.prank(GOV);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NotATightening.selector, 0));
        gate.tightenFeePolicy(address(hook), id, p);
    }

    function test_policy_refPolicyTightening_andInvalidPolicies() public {
        DeepCoreTunerGate.RefPolicy memory r = _refPolicy();
        r.maxDeviationBps = 501;
        vm.prank(GOV);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NotATightening.selector, 1));
        gate.tightenRefPolicy(address(oracle), refPool, r);
        r.maxDeviationBps = 200;
        vm.prank(GOV);
        gate.tightenRefPolicy(address(oracle), refPool, r);

        vm.startPrank(GOV);
        DeepCoreTunerGate.FeePolicy memory f = _feePolicy();
        f.minInterval = 3_599;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidPolicy.selector, 2));
        gate.proposeFeePolicy(address(hook), id, f);
        f = _feePolicy();
        f.minBaseFee = 7_000;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidPolicy.selector, 1));
        gate.proposeFeePolicy(address(hook), id, f);
        f = _feePolicy();
        f.enabled = false;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidPolicy.selector, 0));
        gate.proposeFeePolicy(address(hook), id, f);
        r = _refPolicy();
        r.maxDeviationBps = 1_001;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidPolicy.selector, 3));
        gate.proposeRefPolicy(address(oracle), refPool, r);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidAgent.selector, OPS));
        gate.proposeAgent(OPS);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.InvalidAgent.selector, GOV));
        gate.proposeAgent(GOV);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         A STOLEN AGENT KEY
    //////////////////////////////////////////////////////////////*/

    /// @dev The attacker holds the agent key and tries every privileged selector on gate, hook and
    /// oracle. Every one reverts, and every balance (tokens and vault claims) is equal to the wei.
    function test_stolenKey_everyPrivilegedSelectorRevertsAndNoBalanceMoves() public {
        // some revenue sits in the hook as claims, so there is something to steal
        for (uint256 i; i < 3; ++i) {
            vm.warp(_now() + 1);
            router.swap(
                key,
                ICLPoolManager.SwapParams({zeroForOne: i % 2 == 0, amountSpecified: -1 ether, sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1}),
                CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                ZERO_BYTES
            );
        }
        IERC20(Currency.unwrap(c0)).transfer(address(gate), 5);
        uint256[] memory before = _balances();

        bytes[] memory gateCalls = new bytes[](11);
        gateCalls[0] = abi.encodeCall(gate.proposeAgent, (AGENT));
        gateCalls[1] = abi.encodeCall(gate.proposeFeePolicy, (address(hook), id, _feePolicy()));
        gateCalls[2] = abi.encodeCall(gate.proposeRefPolicy, (address(oracle), refPool, _refPolicy()));
        gateCalls[3] = abi.encodeCall(gate.tightenFeePolicy, (address(hook), id, _feePolicy()));
        gateCalls[4] = abi.encodeCall(gate.setGuardian, (AGENT));
        gateCalls[5] = abi.encodeCall(gate.acceptTuner, (address(hook), id));
        gateCalls[6] = abi.encodeCall(gate.transferOwnership, (AGENT));
        gateCalls[7] = abi.encodeCall(gate.revokeAgent, ());
        gateCalls[8] = abi.encodeCall(gate.pause, ());
        gateCalls[9] = abi.encodeCall(gate.dropTuner, (address(hook), id));
        gateCalls[10] = abi.encodeCall(gate.renounceOwnership, ());
        bytes[] memory hookCalls = new bytes[](7);
        hookCalls[0] = abi.encodeCall(hook.tune, (key, 3_400, 12, 55));
        hookCalls[1] = abi.encodeCall(hook.proposeTuner, (id, AGENT));
        hookCalls[2] = abi.encodeCall(hook.freeze, (id));
        hookCalls[3] = abi.encodeCall(hook.transferPoolOwnership, (id, AGENT));
        hookCalls[4] = abi.encodeCall(hook.setProtocolShare, (0));
        hookCalls[5] = abi.encodeCall(hook.transferOwnership, (AGENT));
        hookCalls[6] = abi.encodeWithSignature("lockAcquired(bytes)", abi.encode(c0, uint256(1)));
        bytes[] memory oracleCalls = new bytes[](5);
        oracleCalls[0] = abi.encodeCall(oracle.setReferencePrice, (refPool, _up(P1, 100)));
        oracleCalls[1] = abi.encodeCall(oracle.clearReference, (refPool));
        oracleCalls[2] = abi.encodeCall(oracle.setPublisher, (AGENT, true));
        oracleCalls[3] = abi.encodeCall(oracle.setPublisherBounds, (10_000, 0));
        oracleCalls[4] = abi.encodeCall(oracle.rescueERC20, (Currency.unwrap(c0), AGENT));

        _allRevert(address(gate), gateCalls, "gate call ");
        _allRevert(address(hook), hookCalls, "hook call ");
        _allRevert(address(oracle), oracleCalls, "oracle call ");

        uint256[] memory afterAll = _balances();
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterAll[i], before[i], "a balance moved");
        }
        assertEq(gate.agent(), AGENT, "nothing about the gate changed either");
        assertEq(gate.owner(), GOV);
        assertEq(gate.guardian(), OPS);
    }

    function _allRevert(address target, bytes[] memory calls, string memory what) internal {
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(AGENT);
            (bool ok,) = target.call(calls[i]);
            assertFalse(ok, string.concat(what, vm.toString(i)));
        }
    }

    /// @dev token0, token1 and both vault-claim balances of every account that could gain or lose.
    function _balances() internal view returns (uint256[] memory b) {
        address[6] memory who = [address(gate), address(hook), AGENT, SAFE, address(vault), address(oracle)];
        b = new uint256[](24);
        for (uint256 i; i < 6; ++i) {
            b[4 * i] = c0.balanceOf(who[i]);
            b[4 * i + 1] = c1.balanceOf(who[i]);
            b[4 * i + 2] = vault.balanceOf(who[i], c0);
            b[4 * i + 3] = vault.balanceOf(who[i], c1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNDS
    //////////////////////////////////////////////////////////////*/

    function test_sweep_paysStraysToTheRecipient_permissionless() public {
        IERC20(Currency.unwrap(c0)).transfer(address(gate), 9);
        uint256 before = c0.balanceOf(SAFE);
        vm.prank(STRANGER);
        assertEq(gate.sweep(c0), 9);
        assertEq(c0.balanceOf(SAFE), before + 9);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTunerGate.NothingToSweep.selector, c0));
        gate.sweep(c0);
        vm.deal(address(gate), 3); // forced in
        uint256 nb = SAFE.balance;
        gate.sweep(Currency.wrap(address(0)));
        assertEq(SAFE.balance, nb + 3);
        (bool ok,) = address(gate).call{value: 1}("");
        assertFalse(ok, "no receive");
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Random agent calls and time steps: every value the hook holds stays inside BOTH the
    /// policy and the hook's own bounds, and no tune lands sooner than the policy interval.
    function testFuzz_everyWrittenValueIsInsidePolicyAndHookBounds(uint256 seed) public {
        uint256 lastTune;
        for (uint256 i; i < 30; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(_now() + (seed % 5_000));
            uint24 base = uint24((seed >> 8) % 12_000);
            uint24 vol = uint24((seed >> 40) % 50);
            uint24 ss = uint24((seed >> 72) % 120);
            vm.prank(AGENT);
            try gate.tuneFee(address(hook), key, base, vol, ss) {
                assertTrue(lastTune == 0 || _now() >= lastTune + 7_200, "interval");
                lastTune = _now();
            } catch {}
            DeepCoreDynamicFeeHook.FeeConfig memory c = hook.getConfig(id);
            assertTrue(c.baseFee == 3_000 || (c.baseFee >= 1_000 && c.baseFee <= 6_000), "base in policy");
            assertTrue(c.baseFee >= 500 && c.baseFee <= 10_000, "base in hook bounds");
            assertTrue(c.volSlope == 10 || c.volSlope <= 20, "vol in policy");
            assertTrue(c.sameSecondSlope == 50 || c.sameSecondSlope <= 80, "ss in policy");
        }
    }
}
