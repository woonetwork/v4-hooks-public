// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWOOFiGateway} from "./interfaces/IWOOFiGateway.sol";
import {IWooPPV2, IWooracle} from "./interfaces/IWooPPV2.sol";

/// @title WOOFiGateway
/// @notice WOOFi-owned wrapper around WooPPV2 that WOOFiAggregator uses in place of the pool, so the hook stays
///         immutable and ownerless while WOOFi keeps adjustable risk controls over Uniswap-routed flow
/// @dev `query` and `swap` share every check and the same output formula, so a router's simulation matches
///      execution in the same state:
///      - pause: by any pauser or the owner; only the owner unpauses. A paused WooPP is rejected too
///      - token allowlist: the hook only registers pools of allowed tokens, and `query`/`swap` reject the rest
///      - price freshness: reverts when the Wooracle prices are older than `maxPriceAge`
///      - age spread: output = WooPP output * (1 - spreadPerSecond * age); the difference stays in the gateway
///      - per-swap notional cap (in quote token units), tighter than WooPP's own `maxNotionalSwap`
///      Only the hook can swap. Swaps move exact amounts, so the gateway's balance is the retained spread, which
///      the owner withdraws.
contract WOOFiGateway is IWOOFiGateway, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The WooPPV2 pool
    IWooPPV2 public immutable wooPP;

    /// @notice The only caller allowed to swap (the WOOFiAggregator hook)
    address public hook;

    /// @notice Max age, in seconds, of the Wooracle prices a quote or swap may use
    uint256 public maxPriceAge;

    /// @notice Extra spread per second of price age, 18 decimals (1e18 = 100%) like the Wooracle spread
    uint256 public spreadPerSecond;

    /// @notice Max notional per swap, in quote token units
    uint256 public maxNotionalPerSwap;

    mapping(address token => bool) public isTokenAllowed;
    mapping(address account => bool) public isPauser;

    event HookSet(address hook);
    event PauserSet(address account, bool flag);
    event Withdrawn(address token, address to, uint256 amount);

    error NotHook();
    error NotPauser();
    error GatewayPaused();
    error TokenNotAllowed();
    error StalePrice();
    error NotionalExceeded();
    error SpreadTooHigh();

    modifier onlyPauser() {
        if (!isPauser[msg.sender] && msg.sender != owner()) revert NotPauser();
        _;
    }

    /// @dev Pricing and the notional cap start at zero, so every quote reverts until the owner configures them
    constructor(IWooPPV2 _wooPP, address _owner) Ownable(_owner) {
        wooPP = _wooPP;
    }

    // ── IWOOFiGateway ─────────────────────────────────────────────────────────

    /// @inheritdoc IWOOFiGateway
    function poolSize(address token) external view returns (uint256) {
        return wooPP.poolSize(token);
    }

    /// @inheritdoc IWOOFiGateway
    function query(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount) {
        uint256 age = _checkSwappable(fromToken, toToken);
        uint256 out = wooPP.query(fromToken, toToken, fromAmount);
        _checkNotional(fromToken, toToken, fromAmount, out);
        toAmount = _applySpread(out, age);
    }

    /// @inheritdoc IWOOFiGateway
    function swap(address fromToken, address toToken, uint256 fromAmount, address to)
        external
        returns (uint256 toAmount)
    {
        if (msg.sender != hook) revert NotHook();
        uint256 age = _checkSwappable(fromToken, toToken);

        IERC20(fromToken).safeTransfer(address(wooPP), fromAmount);
        uint256 out = wooPP.swap(fromToken, toToken, fromAmount, 0, address(this), address(0));
        _checkNotional(fromToken, toToken, fromAmount, out);

        toAmount = _applySpread(out, age);
        IERC20(toToken).safeTransfer(to, toAmount);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }

    function pause() external onlyPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setPauser(address account, bool flag) external onlyOwner {
        isPauser[account] = flag;
        emit PauserSet(account, flag);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        isTokenAllowed[token] = allowed;
    }

    /// @dev The spread at the oldest allowed price must stay below 100%
    function setPricing(uint256 _maxPriceAge, uint256 _spreadPerSecond) external onlyOwner {
        if (_spreadPerSecond * _maxPriceAge >= 1e18) revert SpreadTooHigh();
        maxPriceAge = _maxPriceAge;
        spreadPerSecond = _spreadPerSecond;
    }

    function setMaxNotionalPerSwap(uint256 _maxNotionalPerSwap) external onlyOwner {
        maxNotionalPerSwap = _maxNotionalPerSwap;
    }

    /// @notice Withdraws retained spread
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @return age Seconds since the keeper last posted Wooracle prices
    function _checkSwappable(address fromToken, address toToken) internal view returns (uint256 age) {
        if (paused() || wooPP.paused()) revert GatewayPaused();
        if (!isTokenAllowed[fromToken] || !isTokenAllowed[toToken]) revert TokenNotAllowed();
        uint256 postedAt = IWooracle(wooPP.wooracle()).timestamp();
        age = block.timestamp > postedAt ? block.timestamp - postedAt : 0;
        if (age > maxPriceAge) revert StalePrice();
    }

    /// @dev Notional in quote token units: the quote leg when there is one, else the base input priced in quote
    function _checkNotional(address fromToken, address toToken, uint256 fromAmount, uint256 out) internal view {
        address quote = wooPP.quoteToken();
        uint256 notional =
            fromToken == quote ? fromAmount : toToken == quote ? out : wooPP.tryQuery(fromToken, quote, fromAmount);
        if (notional > maxNotionalPerSwap) revert NotionalExceeded();
    }

    /// @dev Rounds the output down, in WOOFi's favor
    function _applySpread(uint256 out, uint256 age) internal view returns (uint256) {
        return out * (1e18 - spreadPerSecond * age) / 1e18;
    }
}
