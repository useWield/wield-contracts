// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";

/// @title Wield RWA Vault
/// @notice ERC-4626 USDG vault rebalanced by an off-chain agent via signed intents.
/// @dev See docs/superpowers/specs/2026-07-22-mixed-vault-design.md
contract Vault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Allocation {
        address asset;
        uint16 bps;
    }

    struct Intent {
        uint256 nonce;
        uint64 deadline;
        Allocation[] allocations;
    }

    /// @notice Address recovered from intent signatures must equal this.
    address public agentDid;

    /// @notice Monotonic nonce; prevents replay.
    uint256 public nextNonce;

    /// @notice Pause flag. When true, rebalance reverts.
    bool public paused;

    uint16 public constant MAX_BPS_PER_ASSET = 6000; // 60%
    uint16 public constant TOTAL_BPS = 10000;

    /// @notice Whitelist of underlying ERC-4626 vaults.
    mapping(address => bool) public isUnderlying;
    address[] public underlyings;

    enum Kind {
        YIELD,
        STOCK
    }

    struct UnderlyingInfo {
        Kind kind; // YIELD = ERC-4626 RWA; STOCK = ERC-20 Robinhood stock
        address priceFeed; // Chainlink feed (STOCK only; zero for YIELD)
        uint8 feedDecimals; // usually 8 (STOCK only)
        bool active;
    }

    /// @notice Per-underlying kind + oracle metadata.
    mapping(address => UnderlyingInfo) public underlyingInfo;

    /// @notice DEX router used for STOCK swaps (Uniswap-style on Robinhood Chain).
    ISwapRouter public dexRouter;

    /// @notice Uniswap pool fee tier used for stock swaps (e.g. 3000 = 0.30%).
    uint24 public dexPoolFee = 3000;

    /// @notice Max slippage for stock swaps, in bps. Default 100 = 1%.
    uint16 public maxSlippageBps = 100;

    /// @notice Reject Chainlink data older than this many seconds. Default 3600 = 1hr.
    uint256 public oracleStaleAfter = 3600;

    event AllocationExecuted(bytes32 indexed intentHash, Allocation[] allocations);
    event AgentRotated(address indexed oldDid, address indexed newDid);
    event Paused(bool paused);
    event UnderlyingAdded(address indexed asset);
    event StockUnderlyingAdded(address indexed token, address indexed priceFeed, uint8 feedDecimals);
    event DexRouterSet(address indexed router, uint24 poolFee);
    event MaxSlippageSet(uint16 bps);
    event OracleStaleAfterSet(uint256 secondsValue);

    error BadNonce();
    error Expired();
    error BadSig();
    error PausedErr();
    error CapExceeded();
    error NotWhitelisted();
    error BpsSumInvalid();
    error AlreadyUnderlying();
    error StaleOracle();
    error BadOraclePrice();
    error RouterNotSet();
    error NotAStock();

    constructor(IERC20 asset_, address owner_, address agentDid_)
        ERC20("Wield RWA Vault", "WIELD")
        ERC4626(asset_)
        Ownable(owner_)
    {
        agentDid = agentDid_;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedErr();
        _;
    }

    function setAgentDid(address newDid) external onlyOwner {
        emit AgentRotated(agentDid, newDid);
        agentDid = newDid;
    }

    function addUnderlying(address asset_) external onlyOwner {
        if (isUnderlying[asset_]) revert AlreadyUnderlying();
        isUnderlying[asset_] = true;
        underlyings.push(asset_);
        underlyingInfo[asset_] =
            UnderlyingInfo({kind: Kind.YIELD, priceFeed: address(0), feedDecimals: 0, active: true});
        emit UnderlyingAdded(asset_);
    }

    /// @notice Register a STOCK underlying (Robinhood tokenized stock, ERC-20 + Chainlink feed).
    function addStockUnderlying(address token, address priceFeed, uint8 feedDecimals) external onlyOwner {
        if (isUnderlying[token]) revert AlreadyUnderlying();
        isUnderlying[token] = true;
        underlyings.push(token);
        underlyingInfo[token] =
            UnderlyingInfo({kind: Kind.STOCK, priceFeed: priceFeed, feedDecimals: feedDecimals, active: true});
        emit StockUnderlyingAdded(token, priceFeed, feedDecimals);
    }

    function setDexRouter(address router, uint24 poolFee) external onlyOwner {
        dexRouter = ISwapRouter(router);
        dexPoolFee = poolFee;
        emit DexRouterSet(router, poolFee);
    }

    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        require(bps <= 1000, "slippage too high"); // hard ceiling 10%
        maxSlippageBps = bps;
        emit MaxSlippageSet(bps);
    }

    function setOracleStaleAfter(uint256 secondsValue) external onlyOwner {
        oracleStaleAfter = secondsValue;
        emit OracleStaleAfterSet(secondsValue);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit Paused(p);
    }

    /// @notice Compute the digest signed by the agent. Domain-separated by chainid + vault address.
    function hashIntent(Intent calldata intent) external view returns (bytes32) {
        return _hashIntent(intent);
    }

    function _hashIntent(Intent calldata intent) internal view returns (bytes32) {
        bytes memory packed;
        for (uint256 i = 0; i < intent.allocations.length; i++) {
            packed = abi.encodePacked(packed, intent.allocations[i].asset, intent.allocations[i].bps);
        }
        bytes32 allocsHash = keccak256(packed);
        return keccak256(abi.encode(block.chainid, address(this), intent.nonce, intent.deadline, allocsHash));
    }

    function _verify(bytes32 digest, bytes calldata sig) internal view returns (bool) {
        bytes32 ethSigned = MessageHashUtils.toEthSignedMessageHash(digest);
        address recovered = ECDSA.recover(ethSigned, sig);
        return recovered == agentDid;
    }

    /// @notice Submit a signed allocation intent. Pulls all funds back, then redeploys per `intent.allocations`.
    function rebalance(Intent calldata intent, bytes calldata sig) external whenNotPaused nonReentrant {
        if (intent.nonce != nextNonce) revert BadNonce();
        if (block.timestamp > intent.deadline) revert Expired();

        bytes32 digest = _hashIntent(intent);
        if (!_verify(digest, sig)) revert BadSig();

        uint256 sumBps;
        for (uint256 i = 0; i < intent.allocations.length; i++) {
            Allocation calldata a = intent.allocations[i];
            if (!isUnderlying[a.asset]) revert NotWhitelisted();
            if (a.bps > MAX_BPS_PER_ASSET) revert CapExceeded();
            sumBps += a.bps;
        }
        if (sumBps > TOTAL_BPS) revert BpsSumInvalid();

        nextNonce++;
        _execute(intent.allocations);

        emit AllocationExecuted(digest, intent.allocations);
    }

    /// @notice Sell the vault's entire balance of a STOCK back to USDG via the DEX.
    function _sellStockToUsdg(address token) internal {
        uint256 bal = IStockToken(token).balanceOf(address(this));
        if (bal == 0) return;
        if (address(dexRouter) == address(0)) revert RouterNotSet();

        // Oracle-derived expected USDG out, minus slippage, sets minOut.
        uint256 expectedOut = _stockValueUsdg(token);
        uint256 minOut = (expectedOut * (TOTAL_BPS - maxSlippageBps)) / TOTAL_BPS;

        IERC20(token).forceApprove(address(dexRouter), bal);
        dexRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: asset(),
                fee: dexPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: bal,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Buy `usdgAmount` worth of a STOCK from USDG via the DEX.
    function _buyStockWithUsdg(address token, uint256 usdgAmount) internal {
        if (usdgAmount == 0) return;
        if (address(dexRouter) == address(0)) revert RouterNotSet();

        // Expected stock out (18-dec) from oracle price, minus slippage.
        UnderlyingInfo memory info = underlyingInfo[token];
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(info.priceFeed).latestRoundData();
        if (answer <= 0) revert BadOraclePrice();
        if (block.timestamp - updatedAt > oracleStaleAfter) revert StaleOracle();

        // usdgAmount (6-dec) -> stock (18-dec): stock = usdg * 1e12 * 10**feedDec / price
        uint256 expectedStock = (usdgAmount * 1e12 * (10 ** info.feedDecimals)) / uint256(answer);
        uint256 minOut = (expectedStock * (TOTAL_BPS - maxSlippageBps)) / TOTAL_BPS;

        IERC20(asset()).forceApprove(address(dexRouter), usdgAmount);
        dexRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: asset(),
                tokenOut: token,
                fee: dexPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdgAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _execute(Allocation[] calldata allocations) internal {
        // 1. Pull all positions back to USDG (yield redeem + stock sell).
        uint256 len = underlyings.length;
        for (uint256 i = 0; i < len; i++) {
            address u = underlyings[i];
            if (underlyingInfo[u].kind == Kind.STOCK) {
                _sellStockToUsdg(u);
            } else {
                uint256 bal = IERC4626(u).balanceOf(address(this));
                if (bal > 0) IERC4626(u).redeem(bal, address(this), address(this));
            }
        }

        // 2. Re-allocate idle USDG by requested bps (yield deposit vs stock buy).
        IERC20 a = IERC20(asset());
        uint256 totalUsdg = a.balanceOf(address(this));
        for (uint256 i = 0; i < allocations.length; i++) {
            Allocation calldata alloc = allocations[i];
            uint256 amount = (totalUsdg * alloc.bps) / TOTAL_BPS;
            if (amount == 0) continue;
            if (underlyingInfo[alloc.asset].kind == Kind.STOCK) {
                _buyStockWithUsdg(alloc.asset, amount);
            } else {
                a.forceApprove(alloc.asset, amount);
                IERC4626(alloc.asset).deposit(amount, address(this));
            }
        }
    }

    /// @notice USDG-denominated (6-dec) value of a STOCK underlying's balance.
    /// @dev Reads Chainlink price, applies staleness + positivity checks, then
    ///      normalizes token 18-dec * feed-dec price down to USDG 6-dec. Assumes USDG ~= $1.
    /// @dev Deliberately does NOT apply ERC-8056 `uiMultiplier()`. Robinhood tokenized-equity
    ///      feeds already publish `Token Price = Underlying Equity Market Price x Multiplier`,
    ///      and Chainlink's docs state integrators must not apply the multiplier themselves.
    ///      Applying it here double-counted corporate actions: a 2:1 split reported 2x the
    ///      real value. Kept consistent with `_buyStockWithUsdg`, which also uses the raw
    ///      feed price. See https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood
    function _stockValueUsdg(address token) internal view returns (uint256) {
        UnderlyingInfo memory info = underlyingInfo[token];
        uint256 bal = IStockToken(token).balanceOf(address(this));
        if (bal == 0) return 0;

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(info.priceFeed).latestRoundData();
        if (answer <= 0) revert BadOraclePrice();
        if (block.timestamp - updatedAt > oracleStaleAfter) revert StaleOracle();

        uint256 price = uint256(answer); // feedDecimals (usually 8), already ui-adjusted

        // value = bal(1e18) * price(feedDec) / 10**feedDec / 10**(18-6)
        // Combine: token 18-dec -> USDG 6-dec means divide by 1e12; price divides by 10**feedDec.
        uint256 raw = (bal * price) / (10 ** info.feedDecimals); // still 18-dec scale
        return raw / 1e12; // 18-dec -> 6-dec
    }

    /// @notice Reports total USDG under management (idle + deployed), branching by underlying kind.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 deployed;
        uint256 len = underlyings.length;
        for (uint256 i = 0; i < len; i++) {
            address u = underlyings[i];
            if (underlyingInfo[u].kind == Kind.STOCK) {
                deployed += _stockValueUsdg(u);
            } else {
                uint256 sh = IERC4626(u).balanceOf(address(this));
                if (sh > 0) deployed += IERC4626(u).previewRedeem(sh);
            }
        }
        return idle + deployed;
    }

    /// @notice Number of whitelisted underlying vaults.
    function underlyingsCount() external view returns (uint256) {
        return underlyings.length;
    }

    /// @notice Full list of whitelisted underlying vaults (registry view).
    function getUnderlyings() external view returns (address[] memory) {
        return underlyings;
    }

    /// @notice Owner-only: unwind every underlying back into the vault as USDG.
    /// @dev Use with `setPaused(true)` for full emergency stop.
    /// @dev Branches by kind. STOCK underlyings are plain ERC-20s with no `redeem()`,
    ///      so treating them as ERC-4626 reverted the whole call and bricked the
    ///      emergency exit whenever the vault held any stock — including for the
    ///      YIELD positions that could otherwise have been unwound.
    function emergencyWithdrawAll() external onlyOwner {
        uint256 len = underlyings.length;
        for (uint256 i = 0; i < len; i++) {
            address u = underlyings[i];
            if (underlyingInfo[u].kind == Kind.STOCK) {
                _sellStockToUsdg(u);
            } else {
                uint256 bal = IERC4626(u).balanceOf(address(this));
                if (bal > 0) IERC4626(u).redeem(bal, address(this), address(this));
            }
        }
    }
}
