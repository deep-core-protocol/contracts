// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {RevShareHook} from "../../src/RevShareHook.sol";
import {DeployRevShareHookMainnetScript} from "../../script/DeployRevShareHookMainnet.s.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";

/**
 * FORK REHEARSAL of the timestamp `RevShareHook` deploy on a chain where DeepCore core is live.
 *
 * Runs the REAL deploy script's `runWith` against the chain's `CLPoolManager` and the governance
 * Safe on a fork, then drives one pool through propose -> not due -> due -> applied,
 * and a second proposal past its TTL. Nothing is broadcast: a Foundry test cannot send a
 * transaction, and the deployer key below is a throwaway constant that holds nothing on any chain.
 *
 * Skipped unless `REHEARSAL_RPC_URL` is set. Every address comes from the same environment
 * variables the real deployment reads, so a green rehearsal is a statement about THOSE values:
 *
 *   REHEARSAL_RPC_URL=<chain RPC> CL_POOL_MANAGER=... REVSHARE_OWNER=<Safe> REVSHARE_GUARDIAN=<Ops> \
 *   REVSHARE_CONFIG_DELAY_SECONDS=43200 REVSHARE_MAX_BENEFICIARIES=... \
 *   forge test --match-path test/fork/TimestampRedeployRehearsal.t.sol --threads 2 -vvv
 */
contract TimestampRevShareRedeployRehearsal is Test {
    /// @dev A throwaway key for the forked simulation only. Never funded, never used to broadcast.
    uint256 internal constant REHEARSAL_PK = 0xBEEF_0001;
    address internal constant POOL_OWNER = address(0xB0B0);
    address internal constant STRANGER = address(0x5757);
    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant LP_FEE = 3000;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("REHEARSAL_RPC_URL", string(""));
        live = bytes(rpc).length != 0;
        if (live) vm.createSelectFork(rpc);
    }

    function _params(uint24 feePips, uint16 lpBps) internal pure returns (RevShareHook.ConfigParams memory) {
        return RevShareHook.ConfigParams({
            feePips: feePips,
            lpDonateBps: lpBps,
            beneficiaryBps: 0,
            distributorBps: 0,
            distributor: address(0),
            enabled: true
        });
    }

    function test_REHEARSE_deployThenProposeApplyExpire() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 999, "rehearsal must fork HyperEVM (999)");
        address poolManager = vm.envAddress("CL_POOL_MANAGER");

        DeployRevShareHookMainnetScript script = new DeployRevShareHookMainnetScript();
        RevShareHook hook = script.runWith(
            DeployRevShareHookMainnetScript.Params({
                pk: REHEARSAL_PK,
                poolManager: poolManager,
                owner: vm.envAddress("REVSHARE_OWNER"),
                guardian: vm.envAddress("REVSHARE_GUARDIAN"),
                configDelaySeconds: vm.envUint("REVSHARE_CONFIG_DELAY_SECONDS"),
                maxBeneficiaries: vm.envUint("REVSHARE_MAX_BENEFICIARIES"),
                target: CreateXTest.target(vm.addr(REHEARSAL_PK), "rehearsal")
            })
        );
        assertEq(hook.CLOCK_MODE(), "mode=timestamp");
        uint40 delay = hook.CONFIG_DELAY_SECONDS();

        // A pool of our own on the SHARED manager: native / a fresh token, so nothing live is touched.
        MockERC20 token = new MockERC20("Rehearsal", "RHR", 18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            hooks: IHooks(address(hook)),
            poolManager: ICLPoolManager(poolManager),
            fee: LP_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING)
        });
        PoolId poolId = key.toId();

        vm.startPrank(POOL_OWNER);
        hook.configure(key, _params(1_000, 10_000));
        vm.stopPrank();
        ICLPoolManager(poolManager).initialize(key, SQRT_1_1);

        // Propose an escalation. It must not be applicable before `effectiveAt`...
        vm.prank(POOL_OWNER);
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 10_000));
        RevShareHook.PendingConfig memory p = hook.getPendingConfig(poolId);
        assertEq(uint256(p.effectiveAt), block.timestamp + delay, "delay is seconds of block.timestamp");
        assertEq(uint256(p.expiresAt) - p.effectiveAt, 3 days, "TTL");

        vm.warp(uint256(p.effectiveAt) - 1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PendingConfigNotDue.selector, poolId, p.effectiveAt));
        hook.applyPendingConfig(key);

        // ...and permissionlessly applicable from it.
        uint256 snap = vm.snapshotState();
        vm.warp(p.effectiveAt);
        vm.prank(STRANGER);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, hook.MAX_FEE_PIPS(), "applied at effectiveAt");
        vm.revertToState(snap);

        // Past `expiresAt` it is dead.
        vm.warp(uint256(p.expiresAt) + 1);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PendingConfigExpired.selector, poolId, p.expiresAt));
        hook.applyPendingConfig(key);
    }
}
