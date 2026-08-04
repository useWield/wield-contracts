// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {P2PDesk} from "../src/P2PDesk.sol";

/// Deploy P2PDesk + daftarkan 4 saham. Jalankan HANYA via VPS (RPC geo-block).
contract DeployP2P is Script {
    function run() external {
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(4663));
        require(block.chainid == expectedChainId, "DeployP2P: wrong chain");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address aapl = vm.envAddress("AAPL");
        address googl = vm.envAddress("GOOGL");
        address uso = vm.envAddress("USO");
        address spcx = vm.envAddress("SPCX");

        require(usdg != address(0), "DeployP2P: USDG_ADDRESS is zero");
        require(aapl != address(0), "DeployP2P: AAPL is zero");
        require(googl != address(0), "DeployP2P: GOOGL is zero");
        require(uso != address(0), "DeployP2P: USO is zero");
        require(spcx != address(0), "DeployP2P: SPCX is zero");

        vm.startBroadcast(pk);

        P2PDesk desk = new P2PDesk(IERC20(usdg));
        desk.addStock(aapl);
        desk.addStock(googl);
        desk.addStock(uso);
        desk.addStock(spcx);

        vm.stopBroadcast();

        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("Chain ID:  ", block.chainid);
        console2.log("Deployer:  ", vm.addr(pk));
        console2.log("P2PDesk:   ", address(desk));
    }
}
