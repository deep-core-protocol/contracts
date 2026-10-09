// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {IPriceBandOracle} from "../../src/interfaces/IPriceBandOracle.sol";

/// @dev Answers whatever the test told it to, including non-canonical encodings.
contract ConfigurablePriceOracle is IPriceBandOracle {
    uint160 public price;
    uint64 public stamp;

    bool public useRawReturn;
    bytes32 public rawPrice;
    bytes32 public rawStamp;

    function set(uint160 _price, uint64 _stamp) external {
        price = _price;
        stamp = _stamp;
        useRawReturn = false;
    }

    function setRaw(bytes32 _price, bytes32 _stamp) external {
        useRawReturn = true;
        rawPrice = _price;
        rawStamp = _stamp;
    }

    function referencePrice(PoolId) external view override returns (uint160, uint64) {
        if (useRawReturn) {
            bytes32 a = rawPrice;
            bytes32 b = rawStamp;
            assembly ("memory-safe") {
                let out := mload(0x40)
                mstore(out, a)
                mstore(add(out, 0x20), b)
                return(out, 0x40)
            }
        }
        return (price, stamp);
    }
}

/// @dev Always reverts. The band must fail CLOSED: no reference price means no trading.
contract RevertingPriceOracle is IPriceBandOracle {
    error NoPrice();

    function referencePrice(PoolId) external pure override returns (uint160, uint64) {
        revert NoPrice();
    }
}

/// @dev Burns every wei of gas it is given.
contract GasBombPriceOracle is IPriceBandOracle {
    function referencePrice(PoolId) external view override returns (uint160, uint64) {
        uint256 acc;
        for (uint256 i = 0; i < type(uint256).max; ++i) {
            acc = uint256(keccak256(abi.encode(acc, gasleft())));
        }
        return (uint160(acc), 0);
    }
}

/// @dev Returns 64 KiB. `returndatasize` must be checked before anything is copied.
contract ReturnBombPriceOracle is IPriceBandOracle {
    function referencePrice(PoolId) external pure override returns (uint160, uint64) {
        assembly ("memory-safe") {
            return(0, 0x10000)
        }
    }
}

/// @dev Returns one word where two are required.
contract ShortReturnPriceOracle is IPriceBandOracle {
    function referencePrice(PoolId) external pure override returns (uint160, uint64) {
        assembly ("memory-safe") {
            return(0, 0x20)
        }
    }
}
