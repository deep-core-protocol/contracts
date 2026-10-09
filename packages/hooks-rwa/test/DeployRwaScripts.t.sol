// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {DeployMarketHoursHookScript} from "../script/DeployMarketHoursHook.s.sol";
import {DeployStockPairHookScript} from "../script/DeployStockPairHook.s.sol";
import {DeployChainlinkPriceBandAdapterScript} from "../script/DeployChainlinkPriceBandAdapter.s.sol";
import {DeployAllowlistComplianceOracleScript} from "../script/DeployAllowlistComplianceOracle.s.sol";
import {RwaReleaseBase, RwaDeepCoreMetadata, RwaDeepCoreRecord} from "../script/RwaReleaseBase.sol";
import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {StockPairHook} from "../src/StockPairHook.sol";
import {ChainlinkPriceBandAdapter} from "../src/oracles/ChainlinkPriceBandAdapter.sol";
import {AllowlistComplianceOracle} from "../src/oracles/AllowlistComplianceOracle.sol";

/// @dev TEST ONLY. Stands in for `DeepCoreRegistry`'s listing surface: register reads the bitmap off the
/// hook like the real one, and steward rules are the real ones' (submitter, then transferable).
contract ListingRegistryStub {
    mapping(address => RwaDeepCoreRecord) internal _r;

    function register(address hook, RwaDeepCoreMetadata calldata m) external {
        require(_r[hook].submitter == address(0), "DeepCoreAlreadyRegistered");
        (bool ok, bytes memory ret) = hook.staticcall(abi.encodeWithSignature("getHooksRegistrationBitmap()"));
        require(ok, "PermissionsUnreadable");
        RwaDeepCoreRecord storage r = _r[hook];
        r.submitter = msg.sender;
        r.steward = msg.sender;
        r.permissions = abi.decode(ret, (uint16));
        r.metadata = m;
    }

    function transferSteward(address hook, address s) external {
        require(msg.sender == _r[hook].steward, "NotSteward");
        _r[hook].steward = s;
    }

    function isRegistered(address hook) external view returns (bool) {
        return _r[hook].submitter != address(0);
    }

    function getDeepCore(address hook) external view returns (RwaDeepCoreRecord memory) {
        return _r[hook];
    }
}

/// @dev A contract owner (the Safe must be a contract).
contract SafeStandIn {}

/// @dev Chainlink uptime feed shape, for the feed checks. Code-only (immutable + pure).
contract UptimeFeedStub {
    int256 internal immutable _answer;

    constructor(int256 a) {
        _answer = a;
    }

    function description() external pure returns (string memory) {
        return "L2 Sequencer Uptime Status Feed";
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function typeAndVersion() external pure returns (string memory) {
        return "OptimismSequencerUptimeFeed 1.0.0";
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, 1, block.timestamp, 1);
    }
}

/// @notice The four RWA release scripts' `runWith` entry points, driven in-EVM. The live proof is the
/// fork rehearsal (`ops/deploy/rwa-release-2026-09-28.md`); this pins the refusals under both profiles.
contract DeployRwaScriptsTest is Test, Deployers {
    uint256 internal constant PK = 0xA11CE;
    address internal deployer;
    address internal safe;
    address internal ops = makeAddr("ops");
    Vault internal vault;
    CLPoolManager internal manager;
    ListingRegistryStub internal registry;

    DeployMarketHoursHookScript internal mhScript;
    DeployStockPairHookScript internal spScript;
    DeployChainlinkPriceBandAdapterScript internal adScript;
    DeployAllowlistComplianceOracleScript internal orScript;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        (vault, manager) = createFreshManager();
        registry = new ListingRegistryStub();
        safe = address(new SafeStandIn());
        mhScript = new DeployMarketHoursHookScript();
        spScript = new DeployStockPairHookScript();
        adScript = new DeployChainlinkPriceBandAdapterScript();
        orScript = new DeployAllowlistComplianceOracleScript();
    }

    function _signer() internal view returns (RwaReleaseBase.Signer memory) {
        return RwaReleaseBase.Signer({pk: PK, deployer: deployer});
    }

    function _mh(address owner_, address steward) internal view returns (DeployMarketHoursHookScript.Params memory) {
        return DeployMarketHoursHookScript.Params({
            signer: _signer(),
            poolManager: address(manager),
            owner: owner_,
            registry: address(registry),
            steward: steward,
            target: CreateXTest.target(deployer, bytes11("mh"))
        });
    }

    function test_marketHoursHook_deploysOwnedBySafe_listed_stewardOps() public {
        MarketHoursHook hook = mhScript.runWith(_mh(safe, ops));
        assertEq(hook.owner(), safe);
        assertEq(hook.pendingOwner(), address(0));
        assertEq(hook.getHooksRegistrationBitmap(), 0x00C5);
        assertTrue(registry.isRegistered(address(hook)));
        assertEq(registry.getDeepCore(address(hook)).steward, ops);
        vm.expectRevert(MarketHoursHook.RenounceDisabled.selector);
        vm.prank(safe);
        hook.renounceOwnership();
    }

    function test_marketHoursHook_refusesAnEoaOwner() public {
        vm.expectRevert(bytes("RWA_OWNER has no code - the Safe, not an EOA"));
        mhScript.runWith(_mh(makeAddr("eoa"), ops));
    }

    function test_marketHoursHook_refusesTheDeployerAsOwner() public {
        vm.etch(deployer, hex"00");
        vm.expectRevert(bytes("RWA_OWNER is the deployer"));
        mhScript.runWith(_mh(deployer, ops));
    }

    function test_marketHoursHook_refusesNoSteward() public {
        vm.expectRevert(bytes("RWA_STEWARD unset - the Ownership table assigns listing stewardship to Ops"));
        mhScript.runWith(_mh(safe, address(0)));
    }

    function test_marketHoursHook_refusesAnUnregisteredManager() public {
        DeployMarketHoursHookScript.Params memory p = _mh(safe, ops);
        p.poolManager = address(new CLPoolManager(vault)); // never registerApp'd
        vm.expectRevert(bytes("the pool manager is not registered in its vault"));
        mhScript.runWith(p);
    }

    /// The governance Safe of record is set (`DeepCoreGovernance.SAFE`, 2026-10-07): on every production
    /// chain, HyperEVM included, a candidate owner that is not that Safe is refused — the test stub here.
    function test_marketHoursHook_onProduction_refusesAnOwnerThatIsNotTheSafeOfRecord() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        vm.chainId(999);
        vm.expectRevert(bytes("RWA_OWNER is not the governance Safe of record"));
        mhScript.runWith(_mh(safe, ops));
    }

    function test_stockPairHook_deploysOwnedBySafe_listed_noTrustedRouter() public {
        StockPairHook hook = spScript.runWith(
            DeployStockPairHookScript.Params({
                signer: _signer(),
                poolManager: address(manager),
                owner: safe,
                registry: address(registry),
                steward: ops,
                target: CreateXTest.target(deployer, bytes11("sp"))
            })
        );
        assertEq(hook.owner(), safe);
        assertEq(hook.getHooksRegistrationBitmap(), 0x00D5);
        assertFalse(hook.paused());
        assertFalse(hook.isTrustedRouter(deployer));
        assertEq(registry.getDeepCore(address(hook)).steward, ops);
    }

    function _ad(address feed, uint32 grace) internal view returns (DeployChainlinkPriceBandAdapterScript.Params memory) {
        return DeployChainlinkPriceBandAdapterScript.Params({
            signer: _signer(), owner: safe, uptimeFeed: feed, gracePeriod: grace, target: CreateXTest.target(deployer, bytes11("ad"))
        });
    }

    function test_adapter_localChain_noUptimeFeed() public {
        ChainlinkPriceBandAdapter a = adScript.runWith(_ad(address(0), 0));
        assertEq(a.owner(), safe);
        assertFalse(a.sequencerCheckEnabled());
    }

    function test_adapter_localChain_withUptimeFeed() public {
        UptimeFeedStub f = new UptimeFeedStub(0);
        ChainlinkPriceBandAdapter a = adScript.runWith(_ad(address(f), 3600));
        assertTrue(a.sequencerCheckEnabled());
        assertEq(a.sequencerGracePeriod(), 3600);
    }

    function test_adapter_refusesGraceWithoutFeed() public {
        vm.expectRevert(bytes("RWA_SEQUENCER_GRACE_SECONDS must be 0 when there is no uptime feed"));
        adScript.checkSequencerPolicy(address(0), 3600);
    }

    function test_adapter_refusesAGraceOutsideBounds() public {
        UptimeFeedStub f = new UptimeFeedStub(0);
        vm.expectRevert(bytes("RWA_SEQUENCER_GRACE_SECONDS outside [600, 86400]"));
        adScript.checkSequencerPolicy(address(f), 3_600_000);
    }

    function test_adapter_refusesASequencerThatIsDown() public {
        UptimeFeedStub f = new UptimeFeedStub(1);
        vm.expectRevert(bytes("the sequencer reads DOWN right now; do not deploy into an outage"));
        adScript.checkSequencerPolicy(address(f), 3600);
    }

    function test_adapter_productionChainWithoutARow_failsClosed() public {
        vm.chainId(999);
        vm.expectRevert(bytes("no sequencer-uptime policy is recorded for this production chain; add a row to this script"));
        adScript.checkSequencerPolicy(address(0), 0);
    }

    function test_oracle_deploysOwnedBySafe_emptyAtBirth() public {
        AllowlistComplianceOracle o = orScript.runWith(
            DeployAllowlistComplianceOracleScript.Params({
                signer: _signer(), owner: safe, target: CreateXTest.target(deployer, bytes11("or"))
            })
        );
        assertEq(o.owner(), safe);
        assertFalse(o.isPermitted(deployer));
    }

    function test_createX_refusesASecondDeployAtTheSameSalt() public {
        mhScript.runWith(_mh(safe, ops));
        vm.expectRevert(bytes("the predicted address already has code on this chain (MARKET_HOURS_HOOK)"));
        mhScript.runWith(_mh(safe, ops));
    }
}
