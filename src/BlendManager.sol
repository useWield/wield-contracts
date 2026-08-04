// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BlendManager - Wield Baskets position router
/// @notice Menerima USDG + bobot pilihan user, deposit ke basket vaults (ERC-4626),
///         menyimpan share basket, dan mint satu Position NFT per deposit.
///         Custodial-of-shares: TIDAK ADA jalur admin ke dana/posisi user.
///         Blend buy-and-hold - tidak ada rebalance antar-basket.
contract BlendManager is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant TOTAL_BPS = 10000;
    uint256 public constant MAX_LEGS = 4;

    IERC20 public immutable usdg;
    bool public paused; // hanya memblok deposit baru; exit selalu jalan
    uint256 public nextTokenId;

    struct Position {
        address[] vaults;
        uint256[] shares;
    }

    mapping(uint256 => Position) private _positions;
    mapping(address => bool) public allowedBasket;

    error DepositsPaused();
    error ZeroAmount();
    error BadLegs();
    error BadWeights();
    error NotAllowed(address vault);
    error DuplicateBasket(address vault);
    error NotPositionOwner();

    event BasketAdded(address indexed vault);
    event BasketRemoved(address indexed vault);
    event PausedSet(bool paused);
    event Deposited(
        uint256 indexed tokenId, address indexed owner, uint256 usdgIn, address[] baskets, uint16[] weightsBps
    );
    event Exited(uint256 indexed tokenId, address indexed owner, uint256 usdgOut);

    constructor(IERC20 usdg_) ERC721("Wield Basket Position", "wPOS") Ownable(msg.sender) {
        usdg = usdg_;
    }

    // ---- admin (allowlist + pause saja; tidak pernah menyentuh posisi user) ----

    function addBasket(address vault) external onlyOwner {
        allowedBasket[vault] = true;
        emit BasketAdded(vault);
    }

    /// @dev Hanya memblok deposit BARU ke vault ini; posisi existing tetap bisa exit.
    function removeBasket(address vault) external onlyOwner {
        allowedBasket[vault] = false;
        emit BasketRemoved(vault);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    // ---- user ----

    function deposit(uint256 usdgAmount, address[] calldata baskets, uint16[] calldata weightsBps)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (paused) revert DepositsPaused();
        if (usdgAmount == 0) revert ZeroAmount();
        uint256 n = baskets.length;
        if (n == 0 || n > MAX_LEGS || n != weightsBps.length) revert BadLegs();

        uint256 sum;
        for (uint256 i; i < n; i++) {
            if (!allowedBasket[baskets[i]]) revert NotAllowed(baskets[i]);
            for (uint256 j; j < i; j++) {
                if (baskets[j] == baskets[i]) revert DuplicateBasket(baskets[i]);
            }
            sum += weightsBps[i];
        }
        if (sum != TOTAL_BPS) revert BadWeights();

        usdg.safeTransferFrom(msg.sender, address(this), usdgAmount);

        uint256[] memory shares = new uint256[](n);
        uint256 spent;
        for (uint256 i; i < n; i++) {
            // sisa pembulatan masuk ke leg terakhir agar total USDG habis terpakai
            uint256 part = i == n - 1 ? usdgAmount - spent : (usdgAmount * weightsBps[i]) / TOTAL_BPS;
            spent += part;
            usdg.forceApprove(baskets[i], part);
            shares[i] = IERC4626(baskets[i]).deposit(part, address(this));
        }

        tokenId = nextTokenId++;
        Position storage p = _positions[tokenId];
        p.vaults = baskets;
        p.shares = shares;
        _safeMint(msg.sender, tokenId);
        emit Deposited(tokenId, msg.sender, usdgAmount, baskets, weightsBps);
    }

    /// @notice Redeem seluruh leg posisi ke USDG untuk pemilik NFT. Tetap jalan saat paused.
    function exit(uint256 tokenId) external nonReentrant returns (uint256 usdgOut) {
        if (ownerOf(tokenId) != msg.sender) revert NotPositionOwner();
        Position storage p = _positions[tokenId];
        address[] memory vaults = p.vaults;
        uint256[] memory shares = p.shares;

        // effects before interactions: burn + clear storage first (defense-in-depth)
        _burn(tokenId);
        delete _positions[tokenId];

        uint256 n = vaults.length;
        for (uint256 i; i < n; i++) {
            usdgOut += IERC4626(vaults[i]).redeem(shares[i], address(this), address(this));
        }
        usdg.safeTransfer(msg.sender, usdgOut);
        emit Exited(tokenId, msg.sender, usdgOut);
    }

    // ---- views ----

    function positionValue(uint256 tokenId) external view returns (uint256 value) {
        Position storage p = _positions[tokenId];
        for (uint256 i; i < p.vaults.length; i++) {
            value += IERC4626(p.vaults[i]).previewRedeem(p.shares[i]);
        }
    }

    function positionOf(uint256 tokenId) external view returns (address[] memory vaults, uint256[] memory shares) {
        Position storage p = _positions[tokenId];
        return (p.vaults, p.shares);
    }
}
