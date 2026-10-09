// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/// @notice Well-behaved hook. Answers with whatever bitmap it was constructed with.
contract HonestHook {
    uint16 private immutable _bitmap;

    constructor(uint16 bitmap) {
        _bitmap = bitmap;
    }

    function getHooksRegistrationBitmap() external view returns (uint16) {
        return _bitmap;
    }
}

/// @notice Answers from storage and can be repointed. Stands in for a proxy whose implementation
/// is swapped, or a hook that decides its own permissions at runtime.
contract MutableHook {
    uint16 public bitmap;

    constructor(uint16 initial) {
        bitmap = initial;
    }

    function set(uint16 next) external {
        bitmap = next;
    }

    function getHooksRegistrationBitmap() external view returns (uint16) {
        return bitmap;
    }
}

/// @notice Reverts with a custom error.
contract RevertingHook {
    error Nope();

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        revert Nope();
    }
}

/// @notice Reverts with no data at all.
contract SilentRevertHook {
    function getHooksRegistrationBitmap() external pure returns (uint16) {
        assembly {
            revert(0, 0)
        }
    }
}

/// @notice Never returns. Consumes every unit of gas it is given.
/// @dev Reads storage inside the loop so the optimizer cannot fold it away.
contract GasBurnerHook {
    uint256 public seed = 1;

    function getHooksRegistrationBitmap() external view returns (uint16) {
        uint256 acc = seed;
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }
        return uint16(acc);
    }
}

/// @notice Burns gas and then reverts, so the failure looks ordinary while the cost is not.
contract GasBurnThenRevertHook {
    uint256 public seed = 1;

    function getHooksRegistrationBitmap() external view returns (uint16) {
        uint256 acc = seed;
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }
        revert();
    }
}

/// @notice Returns 32 bytes whose high bits are dirty. The low 16 bits look like a harmless
/// bitmap; solc's decoder would reject the word outright.
contract DirtyWordHook {
    uint256 public immutable word;

    constructor(uint256 word_) {
        word = word_;
    }

    fallback() external {
        uint256 w = word;
        assembly {
            mstore(0, w)
            return(0, 32)
        }
    }
}

/// @notice Returns fewer than 32 bytes.
contract ShortReturnHook {
    fallback() external {
        assembly {
            mstore(0, 0x0040)
            return(0, 4)
        }
    }
}

/// @notice Returns nothing.
contract EmptyReturnHook {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @notice Return bomb: hands back a very large buffer to make the caller pay for the copy.
contract ReturnBombHook {
    fallback() external {
        assembly {
            // Touch 32KB of memory, then hand all of it back. Cheap for the callee, expensive for
            // any caller that copies the whole return buffer instead of capping it.
            let size := 0x8000
            mstore(add(size, 0x20), 1)
            return(0, size)
        }
    }
}

/// @notice Returns exactly 32 bytes, but the value is a valid bitmap. Used to prove the probe
/// accepts a raw-assembly responder that behaves correctly.
contract RawButHonestHook {
    uint16 private immutable _bitmap;

    constructor(uint16 bitmap) {
        _bitmap = bitmap;
    }

    fallback() external {
        uint256 b = _bitmap;
        assembly {
            mstore(0, b)
            return(0, 32)
        }
    }
}

/// @notice Has code, but no matching function and no fallback: the call reverts.
contract NoBitmapHook {
    uint256 public unrelated = 7;
}

/// @notice Reenters the registry from inside the probe. Must fail, because the probe is a
/// staticcall and every registry entry point writes storage.
contract ReentrantHook {
    address public registry;
    bytes public payload;

    function arm(address registry_, bytes calldata payload_) external {
        registry = registry_;
        payload = payload_;
    }

    function getHooksRegistrationBitmap() external view returns (uint16) {
        (bool ok,) = registry.staticcall(payload);
        ok; // a state-changing call is impossible from a static frame; this is here to prove it
        return 0x0040;
    }
}

/*//////////////////////////////////////////////////////////////
              HOOKS THAT LIE TO THE REGISTRY SPECIFICALLY

    `getHooksRegistrationBitmap()` is `view`, and a `view`
    function can read `msg.sender` and `gasleft()`. Neither of
    these is exotic: both are four lines of Solidity, both pass
    every check `_probePermissions` makes, and both produce a
    listing that says "Passive, takes no cut" over a pool taking
    a delta on every swap.
//////////////////////////////////////////////////////////////*/

/// @notice Answers the registry with a tame bitmap and everybody else — core included, at pool
/// initialization — with the real one.
/// @dev The registry's probe is identifiable because `msg.sender` is always the same fixed address.
contract TwoFacedHook {
    address public immutable registry;
    uint16 public immutable tame;
    uint16 public immutable real;

    constructor(address registry_, uint16 tame_, uint16 real_) {
        registry = registry_;
        tame = tame_;
        real = real_;
    }

    function getHooksRegistrationBitmap() external view returns (uint16) {
        if (msg.sender == registry) return tame;
        return real;
    }
}

/// @notice Same spoof keyed on the gas budget instead of the caller.
/// @dev Exists to close off the "just probe from a fresh disposable address" idea. The registry
/// forwards `PROBE_GAS`; core forwards everything it has. Any budget the registry commits to is a
/// signal, so no amount of changing HOW the registry probes fixes this — only reading the bitmap
/// from somewhere the hook cannot reach does.
contract GasBranchHook {
    uint256 public immutable threshold;
    uint16 public immutable tame;
    uint16 public immutable real;

    constructor(uint256 threshold_, uint16 tame_, uint16 real_) {
        threshold = threshold_;
        tame = tame_;
        real = real_;
    }

    function getHooksRegistrationBitmap() external view returns (uint16) {
        return gasleft() < threshold ? tame : real;
    }
}

/// @notice Answers a different bitmap per caller, with a default for everyone unconfigured.
/// @dev Models the honest-but-plural case as well as the hostile one: a hook backing both a CL and
/// a Bin pool can legitimately carry two bitmaps, and the registry must handle that without
/// calling it fraud. Also the only way to build the "a LATER pool reveals more" scenario, since a
/// pool cannot be initialized with a bitmap its hook will not answer with.
contract PerCallerBitmapHook {
    uint16 public defaultBitmap;
    mapping(address caller => uint16) public forCaller;
    mapping(address caller => bool) public configured;

    constructor(uint16 defaultBitmap_) {
        defaultBitmap = defaultBitmap_;
    }

    function setFor(address caller, uint16 bitmap) external {
        forCaller[caller] = bitmap;
        configured[caller] = true;
    }

    function getHooksRegistrationBitmap() external view returns (uint16) {
        return configured[msg.sender] ? forCaller[msg.sender] : defaultBitmap;
    }
}
