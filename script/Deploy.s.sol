// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy the Vault to the active network.
/// Required env: DEPLOYER_PRIVATE_KEY, AGENT_DID_ADDRESS, USDG_ADDRESS, UNDERLYING_1, UNDERLYING_2
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address agentDid = vm.envAddress("AGENT_DID_ADDRESS");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address und1 = vm.envAddress("UNDERLYING_1");
        address und2 = vm.envAddress("UNDERLYING_2");

        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        Vault v = new Vault(IERC20(usdg), deployer, agentDid);
        v.addUnderlying(und1);
        v.addUnderlying(und2);
        vm.stopBroadcast();

        console2.log("Vault deployed at:", address(v));
        console2.log("Owner:", deployer);
        console2.log("Agent DID:", agentDid);
        console2.log("USDG:", usdg);
        console2.log("Underlying 1:", und1);
        console2.log("Underlying 2:", und2);
    }
}
