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
/// @dev `query` and `swap` share the gateway's checks and output formula, and `query` also applies the swap-time
///      checks WooPP's own `query` skips (gas price cap, blacklist), so a quote reverts wherever the swap would and
///      a router's simulation matches execution in the same state. The gateway's checks:
///      - pause: by any pauser or the owner; only the owner unpauses. A paused WooPP is rejected too
///      - token allowlist: the hook only registers pools of allowed tokens, and `query`/`swap` reject the rest
///      - price freshness: reverts when the Wooracle prices are older than `maxPriceAge` or posted in the future
///      - age spread: output = WooPP output * (1 - spreadPerSecond * age); the difference stays in the gateway
///      - per-swap notional cap (in quote token units), tighter than WooPP's own `maxNotionalSwap`. It bounds each
///        swap, not a transaction or block: a route may split an order into several swaps, each priced after the last
///      Only the hook can swap. Swaps move exact amounts, so the gateway's balance is the retained spread, which
///      the owner withdraws.
contract WOOFiGateway is IWOOFiGateway, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Ceiling on the age spread, reached at the oldest allowed price: 10%, in 18 decimals
    uint256 public constant MAX_SPREAD = 1e17;

    /// @notice The WooPPV2 pool
    IWooPPV2 public immutable wooPP;

    /// @notice The only caller allowed to swap (the WOOFiAggregator hook)
    address public hook;

    /// @notice Max age, in seconds, of the Wooracle prices a quote or swap may use
    uint256 public maxPriceAge;

    /// @notice Extra spread per second of price age, 18 decimals (1e18 = 100%) like the Wooracle spread
    uint256 public spreadPerSecond;

    /// @notice Max notional per swap (not per transaction or block), in quote token units
    uint256 public maxNotionalPerSwap;

    mapping(address token => bool) public isTokenAllowed;
    mapping(address account => bool) public isPauser;

    event HookSet(address hook);
    event PauserSet(address account, bool flag);
    event TokenAllowedSet(address token, bool allowed);
    event PricingSet(uint256 maxPriceAge, uint256 spreadPerSecond);
    event MaxNotionalPerSwapSet(uint256 maxNotionalPerSwap);
    event Withdrawn(address token, address to, uint256 amount);

    error NotHook();
    error HookAlreadySet();
    error NotPauser();
    error GatewayPaused();
    error TokenNotAllowed();
    error StalePrice();
    error NotionalExceeded();
    error SpreadTooHigh();
    error GasPriceTooHigh();
    error Blacklisted();
    error MaxPriceAgeTooLong();

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
    /// @dev Also checks what WooPP's `swap` enforces but its `query` skips. `swap` needs no copy, as WooPP itself
    ///      rejects there; WooPP sees the gateway as its caller.
    function query(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount) {
        uint256 age = _checkSwappable(fromToken, toToken, fromAmount);
        if (tx.gasprice > wooPP.maxGasPrice()) revert GasPriceTooHigh();
        if (wooPP.blacklist(tx.origin) || wooPP.blacklist(address(this))) revert Blacklisted();
        toAmount = _applySpread(wooPP.query(fromToken, toToken, fromAmount), age);
    }

    /// @inheritdoc IWOOFiGateway
    function swap(address fromToken, address toToken, uint256 fromAmount, address to)
        external
        returns (uint256 toAmount)
    {
        if (msg.sender != hook) revert NotHook();
        uint256 age = _checkSwappable(fromToken, toToken, fromAmount);

        IERC20(fromToken).safeTransfer(address(wooPP), fromAmount);
        uint256 out = wooPP.swap(fromToken, toToken, fromAmount, 0, address(this), address(0));
        toAmount = _applySpread(out, age);
        IERC20(toToken).safeTransfer(to, toAmount);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @dev Set once: `swap` pays WooPP out of the gateway's balance (the retained spread), so only the immutable
    ///      hook may ever call it
    function setHook(address _hook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
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
        emit TokenAllowedSet(token, allowed);
    }

    /// @dev The spread at the oldest allowed price may not exceed `MAX_SPREAD`, and the max age must stay within the
    ///      Wooracle's own `staleDuration`, past which WooPP stops pricing with these prices
    function setPricing(uint256 _maxPriceAge, uint256 _spreadPerSecond) external onlyOwner {
        if (_spreadPerSecond * _maxPriceAge > MAX_SPREAD) revert SpreadTooHigh();
        if (_maxPriceAge > IWooracle(wooPP.wooracle()).staleDuration()) revert MaxPriceAgeTooLong();
        maxPriceAge = _maxPriceAge;
        spreadPerSecond = _spreadPerSecond;
        emit PricingSet(_maxPriceAge, _spreadPerSecond);
    }

    function setMaxNotionalPerSwap(uint256 _maxNotionalPerSwap) external onlyOwner {
        maxNotionalPerSwap = _maxNotionalPerSwap;
        emit MaxNotionalPerSwapSet(_maxNotionalPerSwap);
    }

    /// @notice Withdraws retained spread
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @dev Runs before WooPP is touched, so `query` and `swap` check the same pre-trade state. The notional is the
    ///      input in quote token units: the input itself when it is the quote token, else priced through WooPP.
    /// @return age Seconds since the keeper last posted Wooracle prices
    function _checkSwappable(address fromToken, address toToken, uint256 fromAmount)
        internal
        view
        returns (uint256 age)
    {
        if (paused() || wooPP.paused()) revert GatewayPaused();
        if (!isTokenAllowed[fromToken] || !isTokenAllowed[toToken]) revert TokenNotAllowed();

        uint256 postedAt = IWooracle(wooPP.wooracle()).timestamp();
        if (postedAt > block.timestamp) revert StalePrice();
        age = block.timestamp - postedAt;
        if (age > maxPriceAge) revert StalePrice();

        address quote = wooPP.quoteToken();
        uint256 notional = fromToken == quote ? fromAmount : wooPP.tryQuery(fromToken, quote, fromAmount);
        if (notional > maxNotionalPerSwap) revert NotionalExceeded();
    }

    /// @dev Rounds the output down, in WOOFi's favor
    function _applySpread(uint256 out, uint256 age) internal view returns (uint256) {
        return out * (1e18 - spreadPerSecond * age) / 1e18;
    }
}
