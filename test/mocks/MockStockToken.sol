// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";

contract MockStockToken is ERC20, IStockToken {
    uint256 private _uiMultiplier = 1e18; // 1.0x

    constructor() ERC20("Mock Stock", "mSTOCK") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function uiMultiplier() external view returns (uint256) {
        return _uiMultiplier;
    }

    function setUiMultiplier(uint256 m) external {
        _uiMultiplier = m;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
