// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IRevShareHook} from "../../src/interfaces/IRevShareHook.sol";

/// @dev An ERC20 that refuses to send to one address, standing in for a blacklisting token, a
/// contract with no `receive`, or a proxy mid-upgrade. Used to prove that a recipient which cannot
/// be paid strands only its own balance and never touches the swap path.
contract BlacklistERC20 is MockERC20 {
    address public blocked;

    constructor() MockERC20("Blacklist", "BL", 18) {}

    function setBlocked(address account) external {
        blocked = account;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blocked, "BLOCKED");
        return super.transfer(to, amount);
    }
}

/// @dev A distributor that reverts whenever it is paid. Proves a hostile route-3 integration can
/// only strand its own share.
contract RevertingDistributor {
    IRevShareHook public immutable hook;

    constructor(IRevShareHook hook_) {
        hook = hook_;
    }

    function pull(PoolKey calldata key, Currency currency) external returns (uint256) {
        return hook.pullDistributorShare(key, currency);
    }

    receive() external payable {
        revert("NOPE");
    }
}

/// @dev Minimal ERC20Votes token for the snapshot distributor tests.
contract VotesToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Votes", "VOTE") ERC20Permit("Votes") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

/// @dev An ERC20Votes token whose clock is timestamp-based, to exercise the ERC-6372 detection.
contract TimestampVotesToken is VotesToken {
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}

/// @dev A plain ERC20 with no `clock()` and no vote checkpoints at all.
contract PlainToken is MockERC20 {
    constructor() MockERC20("Plain", "PLAIN", 18) {}
}
