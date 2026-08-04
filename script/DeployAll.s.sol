// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDG} from "../src/MockUSDG.sol";
import {MockERC4626} from "../test/mocks/MockERC4626.sol";

/// @notice Combined deploy: MockERC4626 x2 - Vault.
/// All output addresses printed for copy-paste into .env and web config.
contract DeployAll is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address agentDid = vm.envAddress("AGENT_DID_ADDRESS");
        string memory usdgEnv = vm.envOr("USDG_ADDRESS", string(""));

        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // - STEP 1: Resolve USDG asset -
        address usdg;
        if (bytes(usdgEnv).length == 0) {
            MockUSDG mockUSDG = new MockUSDG();
            mockUSDG.mint(deployer, 1_000_000e6);
            usdg = address(mockUSDG);
        } else {
            usdg = vm.parseAddress(usdgEnv);
        }

        // - STEP 2: Deploy MockERC4626 vaults (underlyings) -
        MockERC4626 und1 = new MockERC4626(IERC20(usdg), "Mock RWA Treasury", "mTBILL");
        MockERC4626 und2 = new MockERC4626(IERC20(usdg), "Mock RWA Credit", "mCREDIT");

        // - STEP 3: Deploy Vault -
        Vault vault = new Vault(IERC20(usdg), deployer, agentDid);
        vault.addUnderlying(address(und1));
        vault.addUnderlying(address(und2));

        vm.stopBroadcast();

        // - OUTPUT -
        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("Chain ID:  ", block.chainid);
        console2.log("Deployer:  ", deployer);
        console2.log("USDG:      ", usdg);
        console2.log("MockERC4626 #1 (mTBILL):   ", address(und1));
        console2.log("MockERC4626 #2 (mCREDIT):  ", address(und2));
        console2.log("Vault (WIELD):          ", address(vault));
        console2.log("Agent DID:                 ", agentDid);
        console2.log("Copy to .env: UNDERLYING_1=", address(und1));
        console2.log("Copy to .env: UNDERLYING_2=", address(und2));
    }
}
