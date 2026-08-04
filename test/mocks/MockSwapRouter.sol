// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";
import {MockStockToken} from "./MockStockToken.sol";

/// @notice Test router: pulls amountIn of tokenIn, returns amountOut of tokenOut.
/// amountOut is set by the test via setRate (tokenOut per 1e18 tokenIn).
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    uint256 public rateOutPerIn = 1e18; // amountOut = amountIn * rate / 1e18

    function setRate(uint256 r) external {
        rateOutPerIn = r;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rateOutPerIn) / 1e18;
        require(amountOut >= p.amountOutMinimum, "MockRouter: slippage");
        // Mint tokenOut to recipient (mock tokens allow open mint).
        MockStockToken(p.tokenOut).mint(p.recipient, amountOut);
    }
}
