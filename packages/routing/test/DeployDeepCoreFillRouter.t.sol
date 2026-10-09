// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {DeployDeepCoreFillRouterScript} from "../script/DeployDeepCoreFillRouter.s.sol";
import {DeepCoreFillRouter} from "../src/DeepCoreFillRouter.sol";
import {MockWrappedNative, MockVenue} from "./mocks/Mocks.sol";

/// @dev Stands in for the governance Safe: the script refuses an EOA owner, so the rehearsal needs a
/// contract. Receives native so a later flush has somewhere to land.
contract FakeSafe {
    receive() external payable {}
}

/// @notice The deploy script end to end as a contract: CREATE3 through CreateX at a salt permissioned
/// to the deployer, the Safe from birth, every number read back, and each pre-flight guard tripped.
/// Driven through `runWith`, never the environment - a script whose only proof is a mainnet run is a
/// script nobody has tested.
contract DeployDeepCoreFillRouterTest is Test {
    uint256 internal constant PK = 0xBEEF_0020;

    DeployDeepCoreFillRouterScript internal script;
    address internal safe;
    MockWrappedNative internal wnative;
    /// Stands in for DeepCore's own UniversalRouter: the venue that must be fee-exempt from birth.
    address internal deepcoreOwnRouter;

    function setUp() public {
        CreateXTest.etch();
        script = new DeployDeepCoreFillRouterScript();
        safe = address(new FakeSafe());
        wnative = new MockWrappedNative();
        deepcoreOwnRouter = address(new MockVenue());
    }

    function _wiring() internal view returns (DeployDeepCoreFillRouterScript.Wiring memory w) {
        w = DeployDeepCoreFillRouterScript.Wiring({
            pk: PK,
            safe: safe,
            wrappedNative: address(wnative),
            feeBps: 15,
            capBps: 50,
            noticeSeconds: 7 days,
            deepcoreVenue: address(deepcoreOwnRouter),
            target: CreateXTest.target(vm.addr(PK), bytes11("dcore.fill"))
        });
    }

    function test_SCRIPT_deploysOwnedByTheSafeAndReadsEveryNumberBack() public {
        DeployDeepCoreFillRouterScript.Wiring memory w = _wiring();
        address predicted = DeepCoreDeploy.predict(w.target);

        DeepCoreFillRouter router = script.runWith(w);

        assertEq(address(router), predicted, "CREATE3 prediction");
        assertEq(router.owner(), safe);
        assertEq(router.protocolFeeRecipient(), safe);
        assertEq(router.WNATIVE(), address(wnative));
        assertEq(router.feeBps(), 15, "the owner's decision: 15 bps on a routed fill (2026-09-26)");
        assertEq(router.maxFeeBps(), 50);
        assertEq(router.feeNoticeSeconds(), 7 days);
        // The executor is the router's own first CREATE, so it is identical wherever the router is.
        assertEq(address(router.EXECUTOR()), vm.computeCreateAddress(address(router), 1));
        assertEq(router.EXECUTOR().ROUTER(), address(router));
        assertEq(router.EXECUTOR().protocolFeeRecipient(), safe);
        // "0 on a DeepCore pool" must not depend on a follow-up transaction somebody remembers to send.
        assertTrue(router.isFeeExempt(deepcoreOwnRouter), "DeepCore's own router is exempt from birth");
        (uint16 bps,, uint256 maxFee) = router.quoteFill(deepcoreOwnRouter, 1 ether);
        assertEq(bps, 0);
        assertEq(maxFee, 0);
    }

    function test_SCRIPT_refusesAnExemptVenueWithNoCode() public {
        DeployDeepCoreFillRouterScript.Wiring memory w = _wiring();
        w.deepcoreVenue = makeAddr("notAContractEither");
        vm.expectRevert(bytes("ROUTING_DEEPCORE_VENUE has no code on this chain"));
        script.runWith(w);
    }

    /// Two "chains": the same deployer and salt, a different Safe and a different wrapped native
    /// (which is what actually differs per chain). One address, both times.
    function test_SCRIPT_theSameDeployerAndSaltGiveTheSameAddressOnEveryChain() public {
        /* Both legs run NON-production chain ids (HyperEVM testnet 998, Sepolia): DeepCore has no
           governance Safe of record yet, so every production chain refuses before deploying (see
           `test_SCRIPT_onProductionrefusesAnOwnerThatIsNotTheSafeOfRecord`).

           What is being asserted is the whole point: the CREATE3 address is a function of (CreateX,
           deployer, salt) ALONE, so differing constructor arguments — a different Safe, a different
           wrapped native, a different fee, a different chain — must not move it. */
        uint256 clean = vm.snapshotState();
        vm.chainId(998);
        DeployDeepCoreFillRouterScript.Wiring memory wa = _wiring();
        address a = address(script.runWith(wa));
        vm.revertToState(clean);

        vm.chainId(11155111);
        DeployDeepCoreFillRouterScript.Wiring memory w = _wiring();
        w.safe = address(new FakeSafe());
        w.wrappedNative = address(0); // a chain where DeepCore does not want the router to wrap
        w.feeBps = 0;
        address b = address(script.runWith(w));

        assertEq(a, b, "the constructor arguments must not move the address");
    }

    function test_SCRIPT_refusesAnEoaOwnerAndTheDeployerAsOwner() public {
        DeployDeepCoreFillRouterScript.Wiring memory w = _wiring();
        w.safe = makeAddr("someEoa");
        vm.expectRevert(bytes("the owner must be a contract (the governance Safe), not an EOA"));
        script.runWith(w);

        w.safe = vm.addr(PK);
        vm.expectRevert(bytes("the owner must never be the deployer"));
        script.runWith(w);
    }

    function test_SCRIPT_refusesABadFeeCapOrNotice() public {
        DeployDeepCoreFillRouterScript.Wiring memory w = _wiring();
        w.capBps = 0;
        vm.expectRevert(bytes("a zero cap would make the fee unraisable forever"));
        script.runWith(w);

        w = _wiring();
        w.capBps = 101;
        vm.expectRevert(bytes("the cap is above the contract ceiling ABSOLUTE_MAX_FEE_BPS"));
        script.runWith(w);

        w = _wiring();
        w.feeBps = 51;
        vm.expectRevert(bytes("the initial fee is above the cap"));
        script.runWith(w);

        w = _wiring();
        w.noticeSeconds = 1 hours;
        vm.expectRevert(bytes("the notice is outside the contract's bounds"));
        script.runWith(w);
    }

    function test_SCRIPT_refusesAWrappedNativeWithNoCode() public {
        DeployDeepCoreFillRouterScript.Wiring memory w = _wiring();
        w.wrappedNative = makeAddr("notAContract");
        vm.expectRevert(bytes("ROUTING_WRAPPED_NATIVE has no code on this chain"));
        script.runWith(w);
    }

    /// The governance Safe of record is set (`DeepCoreGovernance.SAFE`, 2026-10-07): on every production
    /// chain, HyperEVM 999 included, a candidate owner that is not that Safe is refused — the test stub here.
    function test_SCRIPT_onProductionrefusesAnOwnerThatIsNotTheSafeOfRecord() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        vm.chainId(999);
        vm.expectRevert(bytes("ROUTER_OWNER_SAFE is not the governance Safe of record"));
        script.runWith(_wiring());
    }

    function test_SCRIPT_refusesToRedeployOverAnExistingAddress() public {
        script.runWith(_wiring());
        vm.expectRevert(
            bytes("the predicted address already has code on this chain (DEEPCORE_FILL_ROUTER)")
        );
        script.runWith(_wiring());
    }
}
