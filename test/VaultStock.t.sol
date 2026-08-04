// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDG} from "../src/MockUSDG.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultStockTest is Test {
    Vault vault;
    MockUSDG usdg;
    MockStockToken stock;
    MockAggregatorV3 feed;
    MockSwapRouter router;

    address owner = address(0xA11CE);
    // Agent signer: derive address from a known private key so tests can vm.sign intents.
    uint256 constant AGENT_PK =
        0xA11CE0000000000000000000000000000000000000000000000000000000BEEF;
    address agent;

    function setUp() public {
        agent = vm.addr(AGENT_PK);
        usdg = new MockUSDG();
        vault = new Vault(IERC20(address(usdg)), owner, agent);
        stock = new MockStockToken();
        // Chainlink feed: 8 decimals, price = $150.00 => 150e8
        feed = new MockAggregatorV3(8, 150e8);
        router = new MockSwapRouter();
    }

    function _signIntent(Vault.Allocation[] memory allocs)
        internal
        view
        returns (Vault.Intent memory intent, bytes memory sig)
    {
        intent = Vault.Intent({
            nonce: vault.nextNonce(),
            deadline: uint64(block.timestamp + 3600),
            allocations: allocs
        });
        bytes32 digest = vault.hashIntent(intent);
        bytes32 ethSigned = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, ethSigned);
        sig = abi.encodePacked(r, s, v);
    }

    function test_addStockUnderlying_setsMetadata() public {
        vm.prank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);

        (Vault.Kind kind, address pf, uint8 fd, bool active) =
            vault.underlyingInfo(address(stock));
        assertEq(uint256(kind), uint256(Vault.Kind.STOCK));
        assertEq(pf, address(feed));
        assertEq(fd, 8);
        assertTrue(active);
        assertTrue(vault.isUnderlying(address(stock)));
    }

    function test_addUnderlying_defaultsYieldKind() public {
        MockUSDG yieldMock = new MockUSDG();
        vm.prank(owner);
        vault.addUnderlying(address(yieldMock));
        (Vault.Kind kind,,,) = vault.underlyingInfo(address(yieldMock));
        assertEq(uint256(kind), uint256(Vault.Kind.YIELD));
    }

    function test_setDexRouter_onlyOwner() public {
        vm.prank(owner);
        vault.setDexRouter(address(router), 3000);
        assertEq(address(vault.dexRouter()), address(router));
        assertEq(vault.dexPoolFee(), 3000);
    }

    function test_totalAssets_valuesStockViaOracle() public {
        vm.prank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);

        // Give the vault 2 whole stock tokens (2e18). Price $150 (150e8), USDG 6-dec.
        stock.mint(address(vault), 2e18);
        // Expected USDG value: 2 * 150 = 300 USDG = 300e6
        assertEq(vault.totalAssets(), 300e6);
    }

    function test_totalAssets_revertsOnStaleOracle() public {
        vm.prank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);
        stock.mint(address(vault), 1e18);

        // Warp forward past staleness window (default 3600s) without updating feed.
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(Vault.StaleOracle.selector);
        vault.totalAssets();
    }

    function test_totalAssets_revertsOnZeroPrice() public {
        vm.prank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);
        stock.mint(address(vault), 1e18);
        feed.setAnswer(0);
        vm.expectRevert(Vault.BadOraclePrice.selector);
        vault.totalAssets();
    }

    function test_rebalance_buysStockWithUsdg() public {
        // Configure router + register stock.
        vm.startPrank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);
        vault.setDexRouter(address(router), 3000);
        vm.stopPrank();

        // Seed the vault with 300 USDG idle (a user deposit).
        usdg.mint(address(this), 300e6);
        usdg.approve(address(vault), 300e6);
        vault.deposit(300e6, address(this));

        // MockSwapRouter rate: USDG(6-dec) in -> stock(18-dec) out.
        // For 300e6 USDG at $150 -> 2e18 stock. amountOut = amountIn * rate / 1e18
        // => rate = 2e18 * 1e18 / 300e6. Use uint math to avoid rational literal error.
        uint256 rate = (uint256(2e18) * uint256(1e18)) / uint256(300e6);
        router.setRate(rate);

        // Build intent: 60% (6000 bps max-per-asset cap) into the stock.
        Vault.Allocation[] memory allocs = new Vault.Allocation[](1);
        allocs[0] = Vault.Allocation({asset: address(stock), bps: 6000});

        (Vault.Intent memory intent, bytes memory sig) = _signIntent(allocs);
        vault.rebalance(intent, sig);

        // 60% of 300 USDG = 180 USDG -> at $150 => 1.2 stock (1.2e18).
        assertApproxEqAbs(stock.balanceOf(address(vault)), 1.2e18, 1e15);
    }

    // ---- Regresi: uiMultiplier TIDAK boleh diterapkan ulang ----
    //
    // Feed tokenized-equity Chainlink Robinhood sudah melaporkan
    //   Token Price = Underlying Equity Market Price x Multiplier
    // dan dokumentasinya eksplisit bahwa integrator TIDAK menerapkan
    // uiMultiplier() sendiri. Menerapkannya lagi = double-count setelah
    // corporate action.
    // Sumber: https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood

    function _seedStockPosition() internal {
        vm.startPrank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);
        vm.stopPrank();
        // 2 token saham di vault; feed $150 => nilai 300 USDG apa pun multiplier-nya.
        stock.mint(address(vault), 2e18);
    }

    function test_stockValue_ignores_uiMultiplier() public {
        _seedStockPosition();
        assertEq(vault.totalAssets(), 300e6, "baseline 1.0x");

        // Simulasi stock split 2:1 -> multiplier jadi 2.0x.
        // Harga feed sudah ikut menyesuaikan, jadi NILAI VAULT TIDAK BERUBAH.
        stock.setUiMultiplier(2e18);
        assertEq(vault.totalAssets(), 300e6, "nilai tidak boleh berlipat setelah split");
    }

    function test_stockValue_unaffected_by_fractional_multiplier() public {
        _seedStockPosition();
        stock.setUiMultiplier(0.5e18); // reverse split 1:2
        assertEq(vault.totalAssets(), 300e6, "nilai tidak boleh menyusut setelah reverse split");
    }

    // ---- Regresi: emergencyWithdrawAll harus jalan walau ada posisi saham ----

    function test_emergencyWithdrawAll_works_with_stock_position() public {
        vm.startPrank(owner);
        vault.addStockUnderlying(address(stock), address(feed), 8);
        vault.setDexRouter(address(router), 3000);
        vm.stopPrank();

        stock.mint(address(vault), 2e18);
        // Router mengembalikan USDG 6-dec: 2e18 saham -> 300e6 USDG.
        router.setRate(150e6);

        vm.prank(owner);
        vault.emergencyWithdrawAll();

        assertEq(stock.balanceOf(address(vault)), 0, "posisi saham harus terjual habis");
        assertEq(usdg.balanceOf(address(vault)), 300e6, "hasil jual masuk sebagai USDG");
    }
}
