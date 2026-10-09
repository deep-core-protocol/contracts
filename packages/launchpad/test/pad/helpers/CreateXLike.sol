// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

/// @notice Moved to `packages/hooks/test/helpers/CreateXLike.sol` on 2026-09-20, when the registry, fees
/// and hooks-revshare deploy scripts also began deploying through CreateX and needed the same stand-in.
/// Re-exported here so the path already written into the pad tests keeps working.
import {CreateXLike} from "deepcore-hooks/test/helpers/CreateXLike.sol";
