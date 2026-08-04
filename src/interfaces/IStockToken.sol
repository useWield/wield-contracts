// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Robinhood tokenized stock: ERC-20 (18 dec) + ERC-8056 uiMultiplier.
/// @dev uiMultiplier scales for corporate actions; 1e18 == 1.0x (no adjustment).
interface IStockToken is IERC20 {
    function uiMultiplier() external view returns (uint256);
}
