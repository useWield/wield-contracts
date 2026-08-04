// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../src/Vault.sol";
import {BlendManager} from "../src/BlendManager.sol";

/// Deploy 3 basket vaults + BlendManager. Jalankan HANYA via VPS (RPC geo-block).
/// @dev Deployment logic is split across small internal helpers (rather than one
///      flat `run()` body) purely to keep the EVM local-variable stack within
///      solc's non-viaIR limit; behavior is identical to a single flat script.
contract DeployBaskets is Script {
    struct Tokens {
        address aapl;
        address googl;
        address uso;
        address spcx;
        address aaplFeed;
        address googlFeed;
        address usoFeed;
        address spcxFeed;
    }

    function run() external {
        // Robinhood Chain Mainnet by default; override for local/dry-run sim only
        // (e.g. EXPECTED_CHAIN_ID=31337 against the default Anvil/forge-script chain id).
        uint256 expectedChainId = vm.envOr("EXPECTED_CHAIN_ID", uint256(4663));
        require(block.chainid == expectedChainId, "DeployBaskets: wrong chain");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        IERC20 usdg = IERC20(vm.envAddress("USDG_ADDRESS"));
        address router = vm.envAddress("DEX_ROUTER");
        uint256 seed = vm.envUint("SEED_USDG"); // anti first-depositor inflation

        require(keeper != address(0), "DeployBaskets: KEEPER_ADDRESS is zero");
        require(address(usdg) != address(0), "DeployBaskets: USDG_ADDRESS is zero");
        require(router != address(0), "DeployBaskets: DEX_ROUTER is zero");

        Tokens memory t = _loadTokens();
        _requireTokensNonZero(t);

        vm.startBroadcast(pk);

        Vault bigTech = _deployBigTech(usdg, deployer, keeper, router, t);
        Vault frontier = _deployFrontier(usdg, deployer, keeper, router, t);
        Vault core4 = _deployCore4(usdg, deployer, keeper, router, t);
        BlendManager blend = _deployBlend(usdg, bigTech, frontier, core4);

        _seedVaults(usdg, deployer, seed, bigTech, frontier, core4);

        vm.stopBroadcast();

        console2.log("=== DEPLOYMENT COMPLETE ===");
        console2.log("Chain ID:       ", block.chainid);
        console2.log("Deployer:       ", deployer);
        console2.log("BigTech vault:  ", address(bigTech));
        console2.log("Frontier vault: ", address(frontier));
        console2.log("Core4 vault:    ", address(core4));
        console2.log("BlendManager:   ", address(blend));
    }

    function _loadTokens() internal view returns (Tokens memory t) {
        t.aapl = vm.envAddress("AAPL");
        t.googl = vm.envAddress("GOOGL");
        t.uso = vm.envAddress("USO");
        t.spcx = vm.envAddress("SPCX");
        t.aaplFeed = vm.envAddress("AAPL_FEED");
        t.googlFeed = vm.envAddress("GOOGL_FEED");
        t.usoFeed = vm.envAddress("USO_FEED");
        t.spcxFeed = vm.envAddress("SPCX_FEED");
    }

    function _requireTokensNonZero(Tokens memory t) internal pure {
        require(t.aapl != address(0), "DeployBaskets: AAPL is zero");
        require(t.googl != address(0), "DeployBaskets: GOOGL is zero");
        require(t.uso != address(0), "DeployBaskets: USO is zero");
        require(t.spcx != address(0), "DeployBaskets: SPCX is zero");
        require(t.aaplFeed != address(0), "DeployBaskets: AAPL_FEED is zero");
        require(t.googlFeed != address(0), "DeployBaskets: GOOGL_FEED is zero");
        require(t.usoFeed != address(0), "DeployBaskets: USO_FEED is zero");
        require(t.spcxFeed != address(0), "DeployBaskets: SPCX_FEED is zero");
    }

    function _deployBigTech(IERC20 usdg, address deployer, address keeper, address router, Tokens memory t)
        internal
        returns (Vault bigTech)
    {
        bigTech = new Vault(usdg, deployer, keeper);
        bigTech.addStockUnderlying(t.aapl, t.aaplFeed, 8);
        bigTech.addStockUnderlying(t.googl, t.googlFeed, 8);
        _configure(bigTech, router);
    }

    function _deployFrontier(IERC20 usdg, address deployer, address keeper, address router, Tokens memory t)
        internal
        returns (Vault frontier)
    {
        frontier = new Vault(usdg, deployer, keeper);
        frontier.addStockUnderlying(t.spcx, t.spcxFeed, 8);
        frontier.addStockUnderlying(t.uso, t.usoFeed, 8);
        _configure(frontier, router);
    }

    function _deployCore4(IERC20 usdg, address deployer, address keeper, address router, Tokens memory t)
        internal
        returns (Vault core4)
    {
        core4 = new Vault(usdg, deployer, keeper);
        core4.addStockUnderlying(t.aapl, t.aaplFeed, 8);
        core4.addStockUnderlying(t.googl, t.googlFeed, 8);
        core4.addStockUnderlying(t.spcx, t.spcxFeed, 8);
        core4.addStockUnderlying(t.uso, t.usoFeed, 8);
        _configure(core4, router);
    }

    function _deployBlend(IERC20 usdg, Vault bigTech, Vault frontier, Vault core4)
        internal
        returns (BlendManager blend)
    {
        blend = new BlendManager(usdg);
        blend.addBasket(address(bigTech));
        blend.addBasket(address(frontier));
        blend.addBasket(address(core4));
    }

    /// @dev Seed deposit kecil per vault (share ke deployer, dibiarkan selamanya) - anti first-depositor inflation.
    function _seedVaults(IERC20 usdg, address deployer, uint256 seed, Vault bigTech, Vault frontier, Vault core4)
        internal
    {
        if (seed == 0) return;
        usdg.approve(address(bigTech), seed);
        bigTech.deposit(seed, deployer);
        usdg.approve(address(frontier), seed);
        frontier.deposit(seed, deployer);
        usdg.approve(address(core4), seed);
        core4.deposit(seed, deployer);
    }

    function _configure(Vault v, address router) internal {
        v.setDexRouter(router, 3000);
        v.setMaxSlippageBps(100);
        v.setOracleStaleAfter(172800);
    }
}
