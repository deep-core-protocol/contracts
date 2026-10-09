// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeployManualPriceBandOracleScript} from "../script/DeployManualPriceBandOracle.s.sol";
import {DeployPythPriceBandAdapterScript} from "../script/DeployPythPriceBandAdapter.s.sol";
import {RwaReleaseBase} from "../script/RwaReleaseBase.sol";
import {ManualPriceBandOracle} from "../src/oracles/ManualPriceBandOracle.sol";
import {PythPriceBandAdapter} from "../src/oracles/PythPriceBandAdapter.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

/// @dev A `TimelockController` as far as the custody check reads it.
contract TimelockStub {
    uint256 public getMinDelay;
    mapping(bytes32 => mapping(address => bool)) public hasRole;

    constructor(uint256 delay, address proposer) {
        getMinDelay = delay;
        hasRole[keccak256("PROPOSER_ROLE")][proposer] = true;
    }
}

/// @dev Pyth as far as the preflight reads it.
contract PythStub {
    int64 public price = 2_600e8;
    int32 public expo = -8;
    uint256 public publishTime = 1;

    function set(int64 p, int32 e, uint256 t) external {
        price = p;
        expo = e;
        publishTime = t;
    }

    function getPriceUnsafe(bytes32) external view returns (IPyth.Price memory) {
        return IPyth.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }
}

contract SafeLike {}

contract DeployOracleScriptsTest is Test {
    uint256 internal constant PK = 0xA11CE;

    address internal deployer;
    address internal ops = makeAddr("ops");
    address internal custody;
    address internal safe;
    PythStub internal pyth;
    DeployManualPriceBandOracleScript internal mScript;
    DeployPythPriceBandAdapterScript internal pScript;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        safe = address(new SafeLike());
        custody = address(new TimelockStub(48 hours, safe));
        pyth = new PythStub();
        mScript = new DeployManualPriceBandOracleScript();
        pScript = new DeployPythPriceBandAdapterScript();
    }

    function _signer() internal view returns (RwaReleaseBase.Signer memory) {
        return RwaReleaseBase.Signer({pk: PK, deployer: deployer});
    }

    function _m(address owner_, address publisher, uint64 interval)
        internal
        view
        returns (DeployManualPriceBandOracleScript.Params memory)
    {
        return DeployManualPriceBandOracleScript.Params({
            signer: _signer(),
            owner: owner_,
            publisher: publisher,
            publisherInterval: interval,
            target: CreateXTest.target(deployer, bytes11("mo"))
        });
    }

    function _p(address owner_, address pyth_) internal view returns (DeployPythPriceBandAdapterScript.Params memory) {
        return DeployPythPriceBandAdapterScript.Params({
            signer: _signer(), owner: owner_, pyth: pyth_, target: CreateXTest.target(deployer, bytes11("py"))
        });
    }

    /* ------------------------------------------------------------ ManualPriceBandOracle */

    function test_manual_deploysOwnedByCustody_noPublisher_defaultBound() public {
        ManualPriceBandOracle o = mScript.runWith(_m(custody, ops, 3600));
        assertEq(o.owner(), custody);
        assertEq(o.pendingOwner(), address(0));
        assertFalse(o.isPublisher(ops));
        assertFalse(o.isPublisher(deployer));
        assertEq(o.maxPublisherDeviationBps(), 1000);
        // The printed batch is what custody executes; applied here, the interval lands first.
        vm.startPrank(custody);
        o.setPublisherBounds(1000, 3600);
        o.setPublisher(ops, true);
        vm.stopPrank();
        assertEq(o.minPublisherInterval(), 3600);
        assertTrue(o.isPublisher(ops));
    }

    function test_manual_refusesAZeroInterval() public {
        vm.expectRevert(bytes("RWA_PUBLISHER_INTERVAL_SECONDS must be non-zero on a live oracle"));
        mScript.runWith(_m(custody, ops, 0));
    }

    function test_manual_refusesAnEoaOwner() public {
        vm.expectRevert(bytes("RWA_CUSTODY_OWNER has no code - the custody timelock, not an EOA"));
        mScript.runWith(_m(makeAddr("eoa"), ops, 3600));
    }

    function test_manual_refusesThePublisherAsOwner() public {
        vm.expectRevert(bytes("RWA_PUBLISHER is the owner, who is exempt from every bound"));
        mScript.runWith(_m(custody, custody, 3600));
    }

    function test_manual_refusesNoPublisher() public {
        vm.expectRevert(bytes("RWA_PUBLISHER is unset"));
        mScript.runWith(_m(custody, address(0), 3600));
    }

    function test_manual_onProduction_refusesAShortDelay() public {
        vm.chainId(999);
        address shortOne = address(new TimelockStub(6 hours, safe));
        vm.expectRevert(bytes("RWA_CUSTODY_OWNER delay is under 48 h"));
        mScript.checkCustodyOwner(shortOne, deployer);
    }

    /// The governance Safe of record is set (`DeepCoreGovernance.SAFE`, 2026-10-07). The manual oracle is
    /// owned by the CUSTODY timelock, so on a production chain the script requires that Safe to be a
    /// proposer on it; the test's stub timelock names the test's stub Safe instead, and is refused.
    function test_manual_onProduction_refusesACustodyOwnerTheSafeOfRecordDoesNotPropose() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        vm.chainId(999);
        vm.expectRevert(bytes("the Safe of record is not a proposer on RWA_CUSTODY_OWNER"));
        mScript.checkCustodyOwner(custody, deployer);
    }

    function test_manual_refusesASecondDeployAtTheSameSalt() public {
        mScript.runWith(_m(custody, ops, 3600));
        vm.expectRevert(bytes("the predicted address already has code on this chain (MANUAL_PRICE_BAND_ORACLE)"));
        mScript.runWith(_m(custody, ops, 3600));
    }

    /* ------------------------------------------------------------ PythPriceBandAdapter */

    function test_pyth_deploysOwnedBySafe_boundToPyth() public {
        PythPriceBandAdapter a = pScript.runWith(_p(safe, address(pyth)));
        assertEq(a.owner(), safe);
        assertEq(address(a.pyth()), address(pyth));
        (bool ok,) = address(a).call(abi.encodeWithSignature("renounceOwnership()"));
        assertFalse(ok);
    }

    function test_pyth_refusesTheDeployerAsOwner() public {
        vm.expectRevert(bytes("RWA_OWNER has no code - the Safe, not an EOA"));
        pScript.runWith(_p(deployer, address(pyth)));
    }

    function test_pyth_refusesAPythWithNoPrice() public {
        pyth.set(0, -8, 1);
        vm.expectRevert(bytes("Pyth ETH/USD reads no positive price"));
        pScript.checkPyth(address(pyth));
    }

    function test_pyth_refusesAnExponentTheAdapterRejects() public {
        pyth.set(1, 13, 1);
        vm.expectRevert(bytes("Pyth ETH/USD exponent is outside what the adapter accepts"));
        pScript.checkPyth(address(pyth));
    }

    function test_pyth_refusesANeverPublishedFeed() public {
        pyth.set(1, -8, 0);
        vm.expectRevert(bytes("Pyth ETH/USD has never been published"));
        pScript.checkPyth(address(pyth));
    }

    function test_pyth_refusesNoCode() public {
        vm.expectRevert(bytes("RWA_PYTH has no code"));
        pScript.checkPyth(makeAddr("nothing"));
    }

    function test_pyth_productionChainWithoutARow_failsClosed() public {
        vm.chainId(999);
        vm.expectRevert(bytes("no Pyth address is recorded for this production chain; add a row to this script"));
        pScript.checkPyth(address(pyth));
    }
}
