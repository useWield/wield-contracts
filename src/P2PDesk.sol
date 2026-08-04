// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title P2PDesk - Wield P2P order settlement
/// @notice Maker menandatangani order EIP-712 off-chain (tanpa gas, tanpa mengunci aset);
///         taker mengisinya sebagian atau penuh lewat satu transaksi atomik.
///         INVARIAN: kontrak ini TIDAK PERNAH memegang aset siapa pun, bahkan sesaat.
///         Kontrak tidak membaca oracle dan tidak memanggil DEX.
contract P2PDesk is EIP712, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Order {
        address maker;
        address sellToken; // yang diserahkan maker
        address buyToken; // yang diminta maker
        uint256 sellAmount; // total ditawarkan
        uint256 buyAmount; // total diminta
        uint64 expiry; // unix seconds
        uint64 nonce; // untuk cancelAllBefore - BUKAN anti-replay
    }

    /// @dev Urutan field WAJIB identik dengan struct di atas dan dengan ORDER_TYPES di web.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address sellToken,address buyToken,uint256 sellAmount,uint256 buyAmount,uint64 expiry,uint64 nonce)"
    );

    IERC20 public immutable usdg;
    bool public paused; // hanya memblok fill baru; pembatalan selalu jalan

    mapping(bytes32 => uint256) public filled;
    mapping(address => uint64) public minNonce;
    mapping(address => bool) public allowedStock;

    error FillsPaused();
    error ZeroFill();
    error OrderExpired();
    error OrderNonceInvalidated();
    error BadPair();
    error BadSignature();
    error OrderUnfillable();
    error NotMaker();
    error NonceNotIncreasing();

    event StockAdded(address indexed token);
    event StockRemoved(address indexed token);
    event PausedSet(bool paused);
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        address sellToken,
        address buyToken,
        uint256 fillSellAmount,
        uint256 fillBuyAmount
    );
    event OrderCanceled(bytes32 indexed orderHash, address indexed maker);
    event NonceInvalidated(address indexed maker, uint64 minNonce);

    constructor(IERC20 usdg_) EIP712("Wield P2P", "1") Ownable(msg.sender) {
        usdg = usdg_;
    }

    // ---- admin (allowlist + pause saja; tidak pernah menyentuh aset user) ----

    function addStock(address token) external onlyOwner {
        allowedStock[token] = true;
        emit StockAdded(token);
    }

    /// @dev Hanya memblok fill BARU pada pasangan ini; order lama tetap bisa dibatalkan.
    function removeStock(address token) external onlyOwner {
        allowedStock[token] = false;
        emit StockRemoved(token);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    // ---- views ----

    function hashOrder(Order memory order) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.maker,
                    order.sellToken,
                    order.buyToken,
                    order.sellAmount,
                    order.buyAmount,
                    order.expiry,
                    order.nonce
                )
            )
        );
    }

    /// @notice Sisa `sellToken` yang masih bisa diisi dari order ini.
    function remainingOf(Order memory order) public view returns (uint256) {
        uint256 used = filled[hashOrder(order)];
        return used >= order.sellAmount ? 0 : order.sellAmount - used;
    }

    // ---- user ----

    function fillOrder(Order calldata order, bytes calldata signature, uint256 fillSellAmount)
        external
        nonReentrant
        returns (uint256 fillBuyAmount)
    {
        if (paused) revert FillsPaused();
        if (fillSellAmount == 0) revert ZeroFill();
        if (block.timestamp > order.expiry) revert OrderExpired();
        if (order.nonce < minNonce[order.maker]) revert OrderNonceInvalidated();
        _requireValidPair(order.sellToken, order.buyToken);

        bytes32 orderHash = hashOrder(order);
        if (ECDSA.recover(orderHash, signature) != order.maker) revert BadSignature();

        // EFFECTS sebelum INTERACTIONS
        uint256 newFilled = filled[orderHash] + fillSellAmount;
        if (newFilled > order.sellAmount) revert OrderUnfillable();
        filled[orderHash] = newFilled;

        // Pembulatan KE ATAS, memihak maker. Pembulatan ke bawah memungkinkan
        // penyerang mencukur sisa pembagian lewat banyak fill kecil.
        fillBuyAmount = (fillSellAmount * order.buyAmount + order.sellAmount - 1) / order.sellAmount;

        IERC20(order.sellToken).safeTransferFrom(order.maker, msg.sender, fillSellAmount);
        IERC20(order.buyToken).safeTransferFrom(msg.sender, order.maker, fillBuyAmount);

        emit OrderFilled(
            orderHash, order.maker, msg.sender, order.sellToken, order.buyToken, fillSellAmount, fillBuyAmount
        );
    }

    /// @notice Batalkan satu order. Tetap jalan saat paused.
    /// @dev Menyetel penghitung terisi ke penuh - "dibatalkan" dan "habis terisi"
    ///      berperilaku identik, jadi cukup satu state.
    function cancelOrder(Order calldata order) external {
        if (msg.sender != order.maker) revert NotMaker();
        bytes32 orderHash = hashOrder(order);
        filled[orderHash] = order.sellAmount;
        emit OrderCanceled(orderHash, msg.sender);
    }

    /// @notice Batalkan semua order dengan nonce di bawah `newMinNonce`. Tetap jalan saat paused.
    /// @dev WAJIB monoton naik - kalau tidak, maker bisa menghidupkan kembali order lama
    ///      yang harganya sudah usang.
    function cancelAllBefore(uint64 newMinNonce) external {
        if (newMinNonce <= minNonce[msg.sender]) revert NonceNotIncreasing();
        minNonce[msg.sender] = newMinNonce;
        emit NonceInvalidated(msg.sender, newMinNonce);
    }

    // ---- internal ----

    /// @dev Tepat satu sisi harus saham terdaftar, satunya USDG.
    ///      Menolak: dua-duanya saham, dua-duanya USDG, dan token tak terdaftar.
    function _requireValidPair(address a, address b) internal view {
        bool ok = (allowedStock[a] && b == address(usdg)) || (allowedStock[b] && a == address(usdg));
        if (!ok) revert BadPair();
    }
}
