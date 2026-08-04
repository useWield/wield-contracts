// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BlendManager} from "../src/BlendManager.sol";
import {MockUSDG} from "../src/MockUSDG.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

contract BlendManagerTest is Test {
    MockUSDG usdg;
    MockERC4626 basketA; // "Big Tech"
    MockERC4626 basketB; // "Frontier"
    BlendManager blend;
    address user = address(0xBEEF);

    function setUp() public {
        usdg = new MockUSDG();
        basketA = new MockERC4626(IERC20(address(usdg)), "Wield Big Tech", "wBTECH");
        basketB = new MockERC4626(IERC20(address(usdg)), "Wield Frontier", "wFRONT");
        blend = new BlendManager(IERC20(address(usdg)));
        blend.addBasket(address(basketA));
        blend.addBasket(address(basketB));
        usdg.mint(user, 1_000e6);
        vm.prank(user);
        usdg.approve(address(blend), type(uint256).max);
    }

    function _two(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2); arr[0] = a; arr[1] = b;
    }

    function _w(uint16 a, uint16 b) internal pure returns (uint16[] memory w) {
        w = new uint16[](2); w[0] = a; w[1] = b;
    }

    function test_deposit_splits_and_mints_nft() public {
        vm.prank(user);
        uint256 tokenId = blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(6000, 4000));
        assertEq(blend.ownerOf(tokenId), user);
        (address[] memory vaults, uint256[] memory shares) = blend.positionOf(tokenId);
        assertEq(vaults.length, 2);
        assertEq(basketA.balanceOf(address(blend)), shares[0]);
        assertEq(basketB.balanceOf(address(blend)), shares[1]);
        // 60/40 split of 100 USDG; empty mock vault → shares 1:1 with assets
        assertEq(basketA.previewRedeem(shares[0]), 60e6);
        assertEq(basketB.previewRedeem(shares[1]), 40e6);
        assertEq(blend.positionValue(tokenId), 100e6);
        assertEq(usdg.balanceOf(address(blend)), 0); // no idle USDG left
    }

    function test_deposit_rounding_remainder_goes_to_last_basket() public {
        vm.prank(user);
        uint256 tokenId = blend.deposit(101, _two(address(basketA), address(basketB)), _w(3333, 6667));
        // 101*3333/10000 = 33 → last leg gets 101-33 = 68; total preserved
        assertEq(blend.positionValue(tokenId), 101);
        (, uint256[] memory shares) = blend.positionOf(tokenId);
        assertEq(basketA.previewRedeem(shares[0]), 33);
        assertEq(basketB.previewRedeem(shares[1]), 68);
        assertEq(usdg.balanceOf(address(blend)), 0);
    }

    function test_deposit_reverts_on_bad_input() public {
        address[] memory one = new address[](1); one[0] = address(basketA);
        uint16[] memory w1 = new uint16[](1); w1[0] = 9999;
        vm.prank(user);
        vm.expectRevert(BlendManager.BadWeights.selector);
        blend.deposit(100e6, one, w1); // sum != 10000

        vm.prank(user);
        vm.expectRevert(BlendManager.ZeroAmount.selector);
        blend.deposit(0, _two(address(basketA), address(basketB)), _w(5000, 5000));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlendManager.DuplicateBasket.selector, address(basketA)));
        blend.deposit(100e6, _two(address(basketA), address(basketA)), _w(5000, 5000));

        MockERC4626 rogue = new MockERC4626(IERC20(address(usdg)), "X", "X");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlendManager.NotAllowed.selector, address(rogue)));
        blend.deposit(100e6, _two(address(basketA), address(rogue)), _w(5000, 5000));
    }

    function test_deposit_blocked_when_paused() public {
        blend.setPaused(true);
        vm.prank(user);
        vm.expectRevert(BlendManager.DepositsPaused.selector);
        blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(5000, 5000));
    }

    function test_deposit_reverts_on_bad_legs() public {
        // zero baskets
        address[] memory zero = new address[](0);
        uint16[] memory zeroW = new uint16[](0);
        vm.prank(user);
        vm.expectRevert(BlendManager.BadLegs.selector);
        blend.deposit(100e6, zero, zeroW);

        // more than MAX_LEGS (4) baskets
        address[] memory five = new address[](5);
        uint16[] memory fiveW = new uint16[](5);
        for (uint256 i; i < 5; i++) {
            five[i] = address(basketA);
            fiveW[i] = 2000;
        }
        vm.prank(user);
        vm.expectRevert(BlendManager.BadLegs.selector);
        blend.deposit(100e6, five, fiveW);

        // mismatched lengths
        address[] memory twoAddrs = _two(address(basketA), address(basketB));
        uint16[] memory oneWeight = new uint16[](1);
        oneWeight[0] = 10000;
        vm.prank(user);
        vm.expectRevert(BlendManager.BadLegs.selector);
        blend.deposit(100e6, twoAddrs, oneWeight);
    }

    function test_admin_functions_are_owner_gated() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        blend.addBasket(address(basketA));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        blend.removeBasket(address(basketA));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        blend.setPaused(true);
    }

    function test_exit_redeems_all_to_owner_and_burns() public {
        vm.prank(user);
        uint256 tokenId = blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(6000, 4000));
        uint256 balBefore = usdg.balanceOf(user);
        vm.prank(user);
        uint256 out = blend.exit(tokenId);
        assertEq(out, 100e6);
        assertEq(usdg.balanceOf(user), balBefore + 100e6);
        assertEq(basketA.balanceOf(address(blend)), 0);
        assertEq(basketB.balanceOf(address(blend)), 0);
        vm.expectRevert(); // ERC721NonexistentToken
        blend.ownerOf(tokenId);
    }

    function test_exit_reverts_for_non_owner() public {
        vm.prank(user);
        uint256 tokenId = blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(5000, 5000));
        vm.prank(address(0xBAD));
        vm.expectRevert(BlendManager.NotPositionOwner.selector);
        blend.exit(tokenId);
    }

    function test_exit_works_while_paused() public {
        vm.prank(user);
        uint256 tokenId = blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(5000, 5000));
        blend.setPaused(true);
        vm.prank(user);
        assertEq(blend.exit(tokenId), 100e6);
    }

    function test_positions_are_independent_and_track_value() public {
        vm.startPrank(user);
        uint256 t1 = blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(5000, 5000));
        uint256 t2 = blend.deposit(200e6, _two(address(basketA), address(basketB)), _w(2500, 7500));
        vm.stopPrank();
        // simulasi kenaikan nilai basketA (+10 USDG donasi)
        usdg.mint(address(this), 10e6);
        usdg.approve(address(basketA), 10e6);
        basketA.simulateYield(10e6);
        // t1 dan t2 naik proporsional terhadap share basketA masing-masing; exit t1 tidak mengganggu t2
        uint256 v2Before = blend.positionValue(t2);
        vm.prank(user);
        blend.exit(t1);
        // NOTE: t2's underlying share balance is untouched by t1's exit; previewRedeem's
        // OZ ERC4626 virtual-share rounding (floor of shares*(totalAssets+1)/(totalSupply+1))
        // can shift the *quoted* value by up to 1 wei once t1's shares leave the shared vault's
        // totalSupply/totalAssets. This is expected ERC4626 rounding, not a BlendManager bug.
        assertApproxEqAbs(blend.positionValue(t2), v2Before, 1);
        assertEq(blend.ownerOf(t2), user);
    }

    function test_transferred_nft_new_owner_can_exit() public {
        vm.prank(user);
        uint256 tokenId = blend.deposit(100e6, _two(address(basketA), address(basketB)), _w(5000, 5000));
        address buyer = address(0xCAFE);
        vm.prank(user);
        blend.transferFrom(user, buyer, tokenId);
        vm.prank(buyer);
        uint256 out = blend.exit(tokenId);
        assertEq(usdg.balanceOf(buyer), out);
    }
}
