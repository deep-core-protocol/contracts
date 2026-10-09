// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

/// @notice The custody-timelock operation that installs V4 on both pool-manager owner wrappers.
/// Pure encoding, shared by the script and its test. Same shape as V3's install
/// (docs/controller-v3.md section 6.3), under its own salt.
library InstallV4Calldata {
    /// `setProtocolFeeController(address)`
    bytes4 internal constant SET_PROTOCOL_FEE_CONTROLLER = 0x2d771389;
    /// `keccak256("deepcore.install.feeControllerV4")`, per the ops/safe salt convention.
    bytes32 internal constant SALT = keccak256("deepcore.install.feeControllerV4");
    bytes32 internal constant PREDECESSOR = bytes32(0);
    /// The custody tier. OZ rejects anything below `getMinDelay()`.
    uint256 internal constant CUSTODY_DELAY = 172_800;

    function batch(address clPoolManagerOwner, address binPoolManagerOwner, address v4)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        require(v4 != address(0), "V4 is the zero address: setProtocolFeeController(0) silently zeroes every new pool");
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = clPoolManagerOwner;
        targets[1] = binPoolManagerOwner;
        payloads[0] = abi.encodeWithSelector(SET_PROTOCOL_FEE_CONTROLLER, v4);
        payloads[1] = abi.encodeWithSelector(SET_PROTOCOL_FEE_CONTROLLER, v4);
    }

    function scheduleCalldata(address clOwner, address binOwner, address v4) internal pure returns (bytes memory) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = batch(clOwner, binOwner, v4);
        return abi.encodeWithSignature(
            "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", t, v, p, PREDECESSOR, SALT, CUSTODY_DELAY
        );
    }

    function executeCalldata(address clOwner, address binOwner, address v4) internal pure returns (bytes memory) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = batch(clOwner, binOwner, v4);
        return abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", t, v, p, PREDECESSOR, SALT);
    }

    /// @dev OZ `TimelockController.hashOperationBatch`.
    function operationId(address clOwner, address binOwner, address v4) internal pure returns (bytes32) {
        (address[] memory t, uint256[] memory v, bytes[] memory p) = batch(clOwner, binOwner, v4);
        return keccak256(abi.encode(t, v, p, PREDECESSOR, SALT));
    }
}

interface IOwnedV4 {
    function owner() external view returns (address);
}

interface IWrapperView {
    function owner() external view returns (address);
    function poolManager() external view returns (address);
}

interface IManagerView {
    function protocolFeeController() external view returns (address);
}

interface IV4View {
    function owner() external view returns (address);
    function policy() external view returns (address);
    function launchOracleCount() external view returns (uint256);
    function launchOracles() external view returns (address[] memory);
    function isLaunchOracle(address candidate) external view returns (bool);
    function treasury() external view returns (address);
}

interface ITimelockViewV4 {
    function getMinDelay() external view returns (uint256);
    function hashOperationBatch(address[] calldata, uint256[] calldata, bytes[] calldata, bytes32, bytes32)
        external
        pure
        returns (bytes32);
    function isOperation(bytes32 id) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/**
 * PRINTS calldata. SENDS NOTHING. There is no broadcast in this script and it reads no key.
 *
 *   FEE_CONTROLLER_V4=0x... FEE_POLICY_V2=0x... CUSTODY_TIMELOCK=0x... \
 *   CL_POOL_MANAGER_OWNER=0x... BIN_POOL_MANAGER_OWNER=0x... FEE_OWNER_SAFE=0x... CANCELLER=0x... \
 *   forge script script/BuildInstallFeeControllerV4.s.sol --rpc-url $RPC
 *
 * Refuses: the zero address, V2, a V3 (anything that answers `launchOracle()`), a V4 whose immutables
 * do not match, wrappers that the custody timelock does not own yet, and - the one that is specific
 * to V4 - a V4 that DROPS a kit the installed controller recognises. V4 exists so that a second kit
 * does not cost the first kit's pools their zero; installing a V4 that leaves the first kit out would
 * undo exactly that, silently, because every check on the new controller alone would still pass.
 *
 * Every address comes from the environment and none has a default (FEE_OWNER_SAFE and CANCELLER
 * included). On every production chain the Safe must be the governance Safe of record.
 */
contract BuildInstallFeeControllerV4Script is Script {
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    function run() external view {
        address v4 = vm.envAddress("FEE_CONTROLLER_V4");
        address safe = vm.envAddress("FEE_OWNER_SAFE");
        address v2 = vm.envAddress("FEE_POLICY_V2");
        address timelock = vm.envAddress("CUSTODY_TIMELOCK");
        address clOwner = vm.envAddress("CL_POOL_MANAGER_OWNER");
        address binOwner = vm.envAddress("BIN_POOL_MANAGER_OWNER");
        /// The dedicated cancel-only key (CLAUDE.md, "The canceller"). Its role is reported, never required.
        address canceller = vm.envAddress("CANCELLER");

        // No deployer here (nothing is sent); address(0) only skips the "is the deployer" comparison.
        DeepCoreGovernance.requireGovernanceSafe(safe, address(0), "FEE_OWNER_SAFE");
        require(canceller != address(0), "CANCELLER is unset");

        checkOperation(v4, safe, v2, timelock, clOwner, binOwner);
        checkNoKitIsDropped(v4, clOwner);
        checkNoKitIsDropped(v4, binOwner);

        bytes32 id = InstallV4Calldata.operationId(clOwner, binOwner, v4);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = InstallV4Calldata.batch(clOwner, binOwner, v4);
        require(
            ITimelockViewV4(timelock).hashOperationBatch(t, v, p, InstallV4Calldata.PREDECESSOR, InstallV4Calldata.SALT)
                == id,
            "local operation id disagrees with the timelock"
        );
        require(!ITimelockViewV4(timelock).isOperation(id), "this operation is already scheduled - do not schedule it again");

        console.log("=== INSTALL DeepCoreProtocolFeeControllerV4 (custody, 48h) ===");
        console.log("  V4                  ", v4);
        console.log("  custody timelock    ", timelock);
        console.log("  CLPoolManagerOwner  ", clOwner);
        console.log("  BinPoolManagerOwner ", binOwner);
        address[] memory kits = IV4View(v4).launchOracles();
        console.log("  kits whose locked launches pay zero, in the order they are asked:", kits.length);
        for (uint256 i; i < kits.length; ++i) {
            console.log("    ", i, kits[i]);
        }
        console.log("  salt  keccak256(\"deepcore.install.feeControllerV4\")");
        console.logBytes32(InstallV4Calldata.SALT);
        console.log("  operation id");
        console.logBytes32(id);
        console.log("");
        console.log("1) Safe transaction: to = custody timelock, value = 0, data =");
        console.logBytes(InstallV4Calldata.scheduleCalldata(clOwner, binOwner, v4));
        console.log("");
        console.log("2) After 172800 s, ANY address: to = custody timelock, value = 0, data =");
        console.logBytes(InstallV4Calldata.executeCalldata(clOwner, binOwner, v4));
        console.log("");
        console.log("3) Verify: protocolFeeController() on BOTH managers returns V4.");
        if (!ITimelockViewV4(timelock).hasRole(CANCELLER_ROLE, canceller)) {
            console.log("WARNING: the dedicated canceller does not hold CANCELLER_ROLE on this timelock.");
        }
    }

    /// @notice Every refusal about the new controller and the timelock, as one public view so the
    /// test suite runs the exact gate.
    function checkOperation(
        address v4,
        address safe,
        address v2,
        address timelock,
        address clOwner,
        address binOwner
    ) public view {
        require(v4 != address(0), "zero address");
        require(v4 != v2, "that is V2, not V4");
        require(v4.code.length > 0, "no code at V4");
        require(!_answersLaunchOracle(v4), "that is a V3 (it answers launchOracle()), not V4");

        /* Bounded reads first, so V1 or V2 passed by mistake is named rather than a bare revert. */
        (bool ok, bytes memory ret) = v4.staticcall(abi.encodeCall(IV4View.launchOracleCount, ()));
        require(ok && ret.length == 32, "no launchOracleCount(): not a DeepCoreProtocolFeeControllerV4");
        uint256 count = abi.decode(ret, (uint256));
        require(count > 0 && count <= 4, "V4.launchOracleCount is outside 1..4");

        IV4View c = IV4View(v4);
        require(c.owner() == safe, "V4 owner is not the Safe");
        require(c.policy() == v2, "V4.policy is not the installed V2");
        require(c.treasury() == safe, "V4 treasury is not the Safe");

        address[] memory kits = c.launchOracles();
        require(kits.length == count, "V4.launchOracles disagrees with launchOracleCount");
        for (uint256 i; i < kits.length; ++i) {
            require(kits[i].code.length > 0, "a V4 launch oracle has no code");
            require(c.isLaunchOracle(kits[i]), "V4.isLaunchOracle denies a listed oracle");
            (ok, ret) = kits[i].staticcall(abi.encodeCall(IOwnedV4.owner, ()));
            require(
                ok && ret.length == 32 && abi.decode(ret, (address)) == safe,
                "a V4 launch oracle is not owned by the Safe: not DeepCore's kit"
            );
        }

        /* Check for code BEFORE the first external call. A staticcall into an address with no code
           returns empty, which the decoder reports as a bare `EvmError: Revert` naming neither the
           address nor the reason. Found by the G-3 broadcast rehearsal on the V3 script. */
        require(timelock.code.length > 0, "CUSTODY_TIMELOCK has no code on this chain: check the address and the RPC");
        require(clOwner.code.length > 0 && binOwner.code.length > 0, "a pool manager owner wrapper has no code on this chain");

        require(ITimelockViewV4(timelock).getMinDelay() == InstallV4Calldata.CUSTODY_DELAY, "timelock is not the 48h tier");
        require(ITimelockViewV4(timelock).hasRole(PROPOSER_ROLE, safe), "Safe is not a proposer on this timelock");
        require(
            IWrapperView(clOwner).owner() == timelock && IWrapperView(binOwner).owner() == timelock,
            "wrappers are not owned by the custody timelock yet: execute and verify the queued acceptOwnership first"
        );
    }

    /// @notice Refuses a V4 that leaves out a kit the controller installed on `wrapper`'s manager
    /// recognises today. An installed V3 names one kit (`launchOracle()`); an installed V4 names a set.
    /// Anything else (no controller, V1, V2) recognises no kit, so there is nothing to keep.
    /// @dev Dropping a kit on purpose - the remedy for a kit that flags wrongly - is a decision this
    /// script does not take for anyone: set `ALLOW_DROPPING_A_KIT=true` and it prints a warning instead.
    function checkNoKitIsDropped(address v4, address wrapper) public view {
        address installed = IManagerView(IWrapperView(wrapper).poolManager()).protocolFeeController();
        if (installed == address(0) || installed == v4 || installed.code.length == 0) return;

        address[] memory recognised = recognisedKits(installed);
        bool allow = vm.envOr("ALLOW_DROPPING_A_KIT", false);
        for (uint256 i; i < recognised.length; ++i) {
            if (IV4View(v4).isLaunchOracle(recognised[i])) continue;
            require(
                allow,
                string.concat(
                    "V4 drops kit ",
                    vm.toString(recognised[i]),
                    ", which the installed controller recognises: its pools would lose the zero-fee refusal"
                )
            );
            console.log("WARNING: this install DROPS a kit the installed controller recognises:", recognised[i]);
        }
    }

    /// @notice The kits `controller` recognises: one for a V3, the set for a V4, none otherwise.
    function recognisedKits(address controller) public view returns (address[] memory kits) {
        (bool ok, bytes memory ret) = controller.staticcall(abi.encodeWithSignature("launchOracle()"));
        if (ok && ret.length == 32) {
            kits = new address[](1);
            kits[0] = abi.decode(ret, (address));
            return kits;
        }
        (ok, ret) = controller.staticcall(abi.encodeCall(IV4View.launchOracles, ()));
        if (ok && ret.length >= 64) return abi.decode(ret, (address[]));
        return new address[](0);
    }

    function _answersLaunchOracle(address controller) private view returns (bool) {
        (bool ok, bytes memory ret) = controller.staticcall(abi.encodeWithSignature("launchOracle()"));
        return ok && ret.length == 32;
    }
}
