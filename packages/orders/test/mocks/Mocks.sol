// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BaseCLTestHook} from "infinity-core/test/pool-cl/helpers/BaseCLTestHook.sol";

/// @dev Takes 1% of every transfer.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Taxed", "TAX", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100;
        super.transferFrom(from, address(0xdead), fee);
        return super.transferFrom(from, to, amount - fee);
    }
}

/// @dev Calls an arbitrary target from afterSwap (a hostile hook attempting re-entry).
contract ReentrantSwapHook is BaseCLTestHook {
    address public target;
    bytes public payload;
    bool public armed;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return uint16(1 << 7); // afterSwap
    }

    function afterSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return (this.afterSwap.selector, 0);
    }
}

/// @dev A recipient that re-enters a target when it receives native.
contract ReentrantReceiver {
    address public target;
    bytes public payload;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function call(address to, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
