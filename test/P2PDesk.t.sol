// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {P2PDesk} from "../src/P2PDesk.sol";
import {MockUSDG} from "../src/MockUSDG.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

contract P2PDeskTest is Test {
    MockUSDG usdg;
    MockStockToken aapl;
    MockStockToken googl;
    P2PDesk desk;

    uint256 makerPk = 0xA11CE;
    address maker;
    address taker = address(0xB0B);

    function setUp() public {
        usdg = new MockUSDG();
        aapl = new MockStockToken();
        googl = new MockStockToken();
        desk = new P2PDesk(IERC20(address(usdg)));
        desk.addStock(address(aapl));
        desk.addStock(address(googl));

        maker = vm.addr(makerPk);
        aapl.mint(maker, 1_000e18);
        usdg.mint(taker, 1_000_000e6);

        vm.prank(maker);
        aapl.approve(address(desk), type(uint256).max);
        vm.prank(taker);
        usdg.approve(address(desk), type(uint256).max);
    }

    /// maker menjual `sellAmt` AAPL (18d) untuk `buyAmt` USDG (6d)
    function _order(uint256 sellAmt, uint256 buyAmt) internal view returns (P2PDesk.Order memory o) {
        o = P2PDesk.Order({
            maker: maker,
            sellToken: address(aapl),
            buyToken: address(usdg),
            sellAmount: sellAmt,
            buyAmount: buyAmt,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1
        });
    }

    function _sign(P2PDesk.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, desk.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    function test_typehash_matches_canonical_string() public view {
        assertEq(
            desk.ORDER_TYPEHASH(),
            keccak256(
                "Order(address maker,address sellToken,address buyToken,uint256 sellAmount,uint256 buyAmount,uint64 expiry,uint64 nonce)"
            )
        );
    }

    function test_fill_full_moves_both_sides() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        vm.prank(taker);
        uint256 paid = desk.fillOrder(o, sig, 10e18);

        assertEq(paid, 2_000e6);
        assertEq(aapl.balanceOf(taker), 10e18);
        assertEq(usdg.balanceOf(maker), 2_000e6);
        assertEq(desk.remainingOf(o), 0);
        // kontrak tidak menahan apa pun
        assertEq(aapl.balanceOf(address(desk)), 0);
        assertEq(usdg.balanceOf(address(desk)), 0);
    }

    function test_fill_reverts_on_bad_signature() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, desk.hashOrder(o));
        bytes memory wrongSig = abi.encodePacked(r, s, v);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.BadSignature.selector);
        desk.fillOrder(o, wrongSig, 10e18);
    }

    function test_fill_reverts_when_expired() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + 2 days);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.OrderExpired.selector);
        desk.fillOrder(o, sig, 10e18);
    }

    function test_fill_reverts_on_zero_fill() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.ZeroFill.selector);
        desk.fillOrder(o, sig, 0);
    }

    function test_fill_reverts_on_bad_pair() public {
        // dua-duanya saham
        P2PDesk.Order memory both = _order(10e18, 5e18);
        both.buyToken = address(googl);
        bytes memory sigBoth = _sign(both);
        vm.prank(taker);
        vm.expectRevert(P2PDesk.BadPair.selector);
        desk.fillOrder(both, sigBoth, 1e18);

        // dua-duanya USDG
        P2PDesk.Order memory dual = _order(10e6, 10e6);
        dual.sellToken = address(usdg);
        bytes memory sigDual = _sign(dual);
        vm.prank(taker);
        vm.expectRevert(P2PDesk.BadPair.selector);
        desk.fillOrder(dual, sigDual, 1e6);

        // saham tidak terdaftar
        MockStockToken rogue = new MockStockToken();
        P2PDesk.Order memory bad = _order(10e18, 2_000e6);
        bad.sellToken = address(rogue);
        bytes memory sigBad = _sign(bad);
        vm.prank(taker);
        vm.expectRevert(P2PDesk.BadPair.selector);
        desk.fillOrder(bad, sigBad, 1e18);
    }

    function test_maker_can_also_be_the_buyer_side() public {
        // maker MEMBELI saham: sellToken = USDG, buyToken = AAPL
        usdg.mint(maker, 5_000e6);
        vm.prank(maker);
        usdg.approve(address(desk), type(uint256).max);
        aapl.mint(taker, 100e18);
        vm.prank(taker);
        aapl.approve(address(desk), type(uint256).max);

        P2PDesk.Order memory o = P2PDesk.Order({
            maker: maker,
            sellToken: address(usdg),
            buyToken: address(aapl),
            sellAmount: 2_000e6,
            buyAmount: 10e18,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 7
        });
        bytes memory sig = _sign(o);

        vm.prank(taker);
        uint256 paid = desk.fillOrder(o, sig, 2_000e6);

        assertEq(paid, 10e18);
        assertEq(usdg.balanceOf(taker), 1_000_000e6 + 2_000e6);
        assertEq(aapl.balanceOf(maker), 1_000e18 + 10e18);
    }

    // ---- Task 2: partial fill ----

    function test_partial_fill_tracks_remaining() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        vm.prank(taker);
        uint256 paid = desk.fillOrder(o, sig, 3e18);

        assertEq(paid, 600e6); // 3/10 dari 2000
        assertEq(desk.remainingOf(o), 7e18);
        assertEq(aapl.balanceOf(taker), 3e18);
        assertEq(usdg.balanceOf(maker), 600e6);
        assertEq(aapl.balanceOf(address(desk)), 0);
        assertEq(usdg.balanceOf(address(desk)), 0);
    }

    function test_multiple_partials_consume_exactly_the_order() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        vm.startPrank(taker);
        desk.fillOrder(o, sig, 4e18);
        desk.fillOrder(o, sig, 4e18);
        desk.fillOrder(o, sig, 2e18);
        vm.stopPrank();

        assertEq(desk.remainingOf(o), 0);
        assertEq(aapl.balanceOf(taker), 10e18);
    }

    function test_overfill_reverts() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        vm.prank(taker);
        desk.fillOrder(o, sig, 9e18);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.OrderUnfillable.selector);
        desk.fillOrder(o, sig, 2e18);
    }

    function test_fill_buy_amount_rounds_up_in_makers_favour() public {
        // 3 wei saham ditukar 10 USDG-unit: 1 wei seharusnya 3.33... -> dibulatkan ke 4
        P2PDesk.Order memory o = _order(3, 10);
        bytes memory sig = _sign(o);

        vm.prank(taker);
        uint256 paid = desk.fillOrder(o, sig, 1);
        assertEq(paid, 4); // ceil(1*10/3) = 4, bukan 3
    }

    /// SERANGAN: mengisi order dalam potongan sangat kecil tidak boleh lebih murah
    /// daripada mengisinya sekaligus. Pembulatan ke bawah akan membuat test ini gagal.
    function test_rounding_attack_small_fills_never_cheaper_than_one_full_fill() public {
        uint256 sellAmt = 1000;
        uint256 buyAmt = 7777; // sengaja tidak habis dibagi

        // referensi: satu fill penuh
        P2PDesk.Order memory ref = _order(sellAmt, buyAmt);
        ref.nonce = 100;
        bytes memory refSig = _sign(ref);
        uint256 makerBefore = usdg.balanceOf(maker);
        vm.prank(taker);
        desk.fillOrder(ref, refSig, sellAmt);
        uint256 costFull = usdg.balanceOf(maker) - makerBefore;

        // serangan: 1000 fill masing-masing 1 wei
        P2PDesk.Order memory atk = _order(sellAmt, buyAmt);
        atk.nonce = 101;
        bytes memory atkSig = _sign(atk);
        uint256 makerBefore2 = usdg.balanceOf(maker);
        vm.startPrank(taker);
        for (uint256 i; i < sellAmt; i++) {
            desk.fillOrder(atk, atkSig, 1);
        }
        vm.stopPrank();
        uint256 costSliced = usdg.balanceOf(maker) - makerBefore2;

        assertEq(costFull, buyAmt);
        assertGe(costSliced, costFull); // mencukur mustahil
    }

    // ---- Task 3: pembatalan, pause, reentrancy, invarian saldo ----

    function test_cancel_order_makes_it_unfillable() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        vm.prank(maker);
        desk.cancelOrder(o);
        assertEq(desk.remainingOf(o), 0);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.OrderUnfillable.selector);
        desk.fillOrder(o, sig, 1e18);
    }

    function test_cancel_reverts_for_non_maker() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        vm.prank(taker);
        vm.expectRevert(P2PDesk.NotMaker.selector);
        desk.cancelOrder(o);
    }

    function test_cancel_all_before_invalidates_old_orders() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6); // nonce 1
        bytes memory sig = _sign(o);

        vm.prank(maker);
        desk.cancelAllBefore(5);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.OrderNonceInvalidated.selector);
        desk.fillOrder(o, sig, 1e18);
    }

    function test_cancel_all_before_must_increase() public {
        vm.startPrank(maker);
        desk.cancelAllBefore(5);
        vm.expectRevert(P2PDesk.NonceNotIncreasing.selector);
        desk.cancelAllBefore(5); // sama -> ditolak
        vm.expectRevert(P2PDesk.NonceNotIncreasing.selector);
        desk.cancelAllBefore(4); // mundur -> ditolak
        vm.stopPrank();
    }

    function test_paused_blocks_fill_but_not_cancel() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);
        desk.setPaused(true);

        vm.prank(taker);
        vm.expectRevert(P2PDesk.FillsPaused.selector);
        desk.fillOrder(o, sig, 1e18);

        // pembatalan tetap jalan saat paused
        vm.prank(maker);
        desk.cancelOrder(o);
        assertEq(desk.remainingOf(o), 0);
    }

    function test_admin_functions_are_owner_gated() public {
        vm.startPrank(taker);
        vm.expectRevert();
        desk.addStock(address(0x1234));
        vm.expectRevert();
        desk.removeStock(address(aapl));
        vm.expectRevert();
        desk.setPaused(true);
        vm.stopPrank();
    }

    function test_fill_reverts_when_maker_lacks_allowance() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);
        vm.prank(maker);
        aapl.approve(address(desk), 0);

        vm.prank(taker);
        vm.expectRevert();
        desk.fillOrder(o, sig, 1e18);
    }

    /// INVARIAN INTI: kontrak tidak pernah memegang aset apa pun.
    function test_contract_never_holds_balance() public {
        P2PDesk.Order memory o = _order(10e18, 2_000e6);
        bytes memory sig = _sign(o);

        assertEq(aapl.balanceOf(address(desk)), 0);
        assertEq(usdg.balanceOf(address(desk)), 0);

        vm.prank(taker);
        desk.fillOrder(o, sig, 3e18);
        assertEq(aapl.balanceOf(address(desk)), 0);
        assertEq(usdg.balanceOf(address(desk)), 0);

        vm.prank(maker);
        desk.cancelOrder(o);
        assertEq(aapl.balanceOf(address(desk)), 0);
        assertEq(usdg.balanceOf(address(desk)), 0);
    }

    function test_reentrant_token_cannot_reenter_fill() public {
        ReentrantStockToken evil = new ReentrantStockToken();
        desk.addStock(address(evil));
        evil.mint(maker, 100e18);
        vm.prank(maker);
        evil.approve(address(desk), type(uint256).max);

        P2PDesk.Order memory o = P2PDesk.Order({
            maker: maker,
            sellToken: address(evil),
            buyToken: address(usdg),
            sellAmount: 10e18,
            buyAmount: 2_000e6,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 42
        });
        bytes memory sig = _sign(o);
        evil.arm(desk, o, sig);

        // Selector spesifik — bukan expectRevert telanjang, supaya test tidak
        // lolos karena revert lain yang kebetulan terjadi.
        vm.prank(taker);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        desk.fillOrder(o, sig, 5e18);
    }
}

/// Token yang mencoba masuk kembali ke fillOrder saat transferFrom dipanggil.
contract ReentrantStockToken is ERC20 {
    P2PDesk public desk;
    P2PDesk.Order public order;
    bytes public sig;
    bool public armed;

    constructor() ERC20("Reentrant", "RNT") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(P2PDesk desk_, P2PDesk.Order calldata order_, bytes calldata sig_) external {
        desk = desk_;
        order = order_;
        sig = sig_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            desk.fillOrder(order, sig, 1);
        }
        return super.transferFrom(from, to, value);
    }
}
