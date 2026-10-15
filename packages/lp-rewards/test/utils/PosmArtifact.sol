// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

// Compiles the REAL periphery CLPositionManager (at 9,000 runs, see foundry.toml) into this package's
// artifacts so the tests deploy it with `vm.deployCode`. Kept out of every test's own compilation unit:
// a via-IR build of the position manager costs minutes, and it then happens once per profile, not once
// per edited test file.
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";

contract PosmArtifact {}
