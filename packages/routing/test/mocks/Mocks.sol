// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepCoreFillRouter} from "../../src/DeepCoreFillRouter.sol";
import {DeepCoreFillExecutor} from "../../src/DeepCoreFillExecutor.sol";

/// @dev Minimal ERC-20. Written here rather than imported so the routing package depends on nothing
/// but OpenZeppelin, and so the fee-on-transfer variant below is a two-line change from it.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(balanceOf[from] >= amount, "BALANCE");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

/// @dev Burns `feeBps` of every transfer. Not supported for quoting; the point of the tests that use
/// it is that it cannot make the router mis-pay or hold a deficit.
contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) MockERC20(name_, symbol_, 18) {
        feeBps = feeBps_;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(balanceOf[from] >= amount, "BALANCE");
        uint256 cut = (amount * feeBps) / 10_000;
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount - cut;
            totalSupply -= cut;
        }
        emit Transfer(from, to, amount - cut);
    }
}

/// @dev Canonical wrapped-native behaviour: 1:1, `deposit` / `withdraw`.
contract MockWrappedNative is MockERC20 {
    constructor() MockERC20("Wrapped Native", "WNATIVE", 18) {}

    function deposit() external payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        unchecked {
            balanceOf[msg.sender] -= amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "SEND");
    }

    receive() external payable {}
}

/// @dev A venue that does exactly what the calldata tells it to: consume `amountIn` of `tokenIn`
/// (pulling on the allowance it was given, or from `msg.value`), pay `amountOut` of `tokenOut` to
/// `to`, and return any native it was over-sent. That lets a test express "consumed the whole
/// budget" (exact-input) and "consumed part and refunded the rest" (exact-output) with one mock.
contract MockVenue {
    error VenueRevert();

    /// @dev Whoever called the venue. Used to prove the arbitrary call comes from the executor and
    /// never from the contract that holds users' allowances.
    address public lastCaller;

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address to)
        external
        payable
    {
        lastCaller = msg.sender;
        if (tokenIn == address(0)) {
            require(msg.value >= amountIn, "VALUE");
            if (msg.value > amountIn) {
                (bool refunded,) = msg.sender.call{value: msg.value - amountIn}("");
                require(refunded, "REFUND");
            }
        } else {
            require(msg.value == 0, "UNEXPECTED_VALUE");
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }

        if (amountOut != 0) {
            if (tokenOut == address(0)) {
                (bool ok,) = to.call{value: amountOut}("");
                require(ok, "PAY");
            } else {
                IERC20(tokenOut).transfer(to, amountOut);
            }
        }
    }

    /// @dev Swaps, then pushes extra input currency straight at `pushTo` out of its own inventory -
    /// the griefing move that would make a naive "unspent = balance delta" underflow.
    function swapAndPush(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        address pushTo,
        uint256 pushAmount
    ) external payable {
        lastCaller = msg.sender;
        require(tokenIn != address(0) && msg.value == 0, "ERC20_ONLY");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (amountOut != 0) IERC20(tokenOut).transfer(to, amountOut);
        IERC20(tokenIn).transfer(pushTo, pushAmount);
    }

    /// @dev Takes the input and pays nothing at all.
    function steal(address tokenIn, uint256 amountIn) external payable {
        if (tokenIn != address(0)) IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    }

    /// @dev Reverts with its own error so the test can prove the router bubbles it.
    function boom() external payable {
        revert VenueRevert();
    }

    /// @dev Reverts with no reason data.
    function boomSilently() external payable {
        assembly {
            revert(0, 0)
        }
    }

    receive() external payable {}
}

/// @dev Calls back into the router or the executor while it holds the fill's funds.
contract ReentrantVenue {
    enum Mode {
        FillAgain,
        FlushFees,
        ExecuteDirectly,
        SweepStray
    }

    DeepCoreFillRouter public immutable ROUTER;
    Mode public mode;

    constructor(DeepCoreFillRouter router) {
        ROUTER = router;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function attack(address tokenIn, address tokenOut) external payable {
        if (mode == Mode.FillAgain) {
            DeepCoreFillRouter.FillParams memory p = DeepCoreFillRouter.FillParams({
                target: address(this),
                currencyIn: tokenIn,
                currencyOut: tokenOut,
                amountIn: 1,
                minAmountOut: 0,
                maxFeeBps: type(uint16).max,
                wrapInput: false,
                unwrapOutput: false,
                recipient: address(this),
                deadline: type(uint256).max,
                data: ""
            });
            ROUTER.fill(p);
        } else if (mode == Mode.FlushFees) {
            ROUTER.flushFees(tokenIn);
        } else if (mode == Mode.ExecuteDirectly) {
            ROUTER.EXECUTOR().execute(address(this), "", tokenIn, tokenOut);
        } else {
            ROUTER.EXECUTOR().sweepStray(tokenIn);
        }
    }

    receive() external payable {}
}

/// @dev Refuses every native transfer, so a test can prove a payout that cannot land reverts the
/// whole fill instead of stranding value.
contract NativeRejector {
    receive() external payable {
        revert("NOPE");
    }
}
