// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWooPPV2, IWooPPV2Pool, IWooracle} from "./interfaces/IWooPPV2.sol";

/// @title WOOFiGateway
/// @notice WOOFi-owned wrapper around WooPPV2 that WOOFiAggregator uses in place of the pool, so the hook stays
///         immutable and ownerless while WOOFi keeps adjustable risk controls over Uniswap-routed flow
/// @dev Implements the IWooPPV2 surface the hook calls. `query` and `swap` share every check and the same output
///      formula, so a router's simulation matches execution in the same state:
///      - pause: by any pauser or the owner; only the owner unpauses. A paused WooPP is rejected too
///      - token allowlist: `tokenInfos` reports non-allowed tokens as unconfigured, so the hook refuses to
///        register their pools, and `query`/`swap` reject them
///      - price freshness: reverts when the Wooracle prices are older than `maxPriceAge`
///      - age spread: output = WooPP output * (1 - spreadPerSecond * age); the difference stays in the gateway
///      - per-swap notional cap (in quote token units), tighter than WooPP's own `maxNotionalSwap`
///      Only the hook can swap. Swaps move exact amounts, so the gateway's balance is the retained spread, which
///      the owner withdraws.
contract WOOFiGateway is IWooPPV2, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    /// @notice The WooPPV2 pool
    IWooPPV2Pool public immutable wooPP;

    /// @notice The only caller allowed to swap (the WOOFiAggregator hook)
    address public hook;

    /// @notice Max age, in seconds, of the Wooracle prices a quote or swap may use
    uint256 public maxPriceAge;

    /// @notice Extra spread per second of price age, in WAD (1e18 = 100%)
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
    error TokenNotAllowed(address token);
    error StalePrice(uint256 age);
    error NotionalExceeded(uint256 notional);
    error InsufficientOutput();
    error InvalidPricing();

    modifier onlyPauser() {
        if (!isPauser[msg.sender] && msg.sender != owner()) revert NotPauser();
        _;
    }

    constructor(
        IWooPPV2Pool _wooPP,
        address _owner,
        uint256 _maxPriceAge,
        uint256 _spreadPerSecond,
        uint256 _maxNotionalPerSwap
    ) Ownable(_owner) {
        wooPP = _wooPP;
        _setPricing(_maxPriceAge, _spreadPerSecond);
        maxNotionalPerSwap = _maxNotionalPerSwap;
    }

    // ── IWooPPV2 ──────────────────────────────────────────────────────────────

    /// @inheritdoc IWooPPV2
    function quoteToken() external view returns (address) {
        return wooPP.quoteToken();
    }

    /// @inheritdoc IWooPPV2
    function poolSize(address token) external view returns (uint256) {
        return wooPP.poolSize(token);
    }

    /// @inheritdoc IWooPPV2
    /// @dev Non-allowed tokens read as unconfigured (all zero), so WOOFiAggregator refuses to register them
    function tokenInfos(address token)
        external
        view
        returns (uint192 reserve, uint16 feeRate, uint128 maxGamma, uint128 maxNotionalSwap, uint192 capBal)
    {
        if (isTokenAllowed[token]) return wooPP.tokenInfos(token);
    }

    /// @inheritdoc IWooPPV2
    /// @dev The gateway's own pause state; a paused WooPP is rejected in `_checkSwappable`
    function paused() public view override(IWooPPV2, Pausable) returns (bool) {
        return super.paused();
    }

    /// @inheritdoc IWooPPV2
    function query(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount) {
        uint256 age = _checkSwappable(fromToken, toToken);
        uint256 out = wooPP.query(fromToken, toToken, fromAmount);
        _checkNotional(fromToken, toToken, fromAmount, out);
        toAmount = _applySpread(out, age);
    }

    /// @inheritdoc IWooPPV2
    /// @dev `fromAmount` must already be in the gateway (push model, sent by the hook)
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount,
        address to,
        address rebateTo
    ) external returns (uint256 realToAmount) {
        if (msg.sender != hook) revert NotHook();
        uint256 age = _checkSwappable(fromToken, toToken);

        IERC20(fromToken).safeTransfer(address(wooPP), fromAmount);
        uint256 out = wooPP.swap(fromToken, toToken, fromAmount, 0, address(this), rebateTo);
        _checkNotional(fromToken, toToken, fromAmount, out);

        realToAmount = _applySpread(out, age);
        if (realToAmount < minToAmount) revert InsufficientOutput();
        IERC20(toToken).safeTransfer(to, realToAmount);
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

    function setPricing(uint256 _maxPriceAge, uint256 _spreadPerSecond) external onlyOwner {
        _setPricing(_maxPriceAge, _spreadPerSecond);
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

    /// @dev The spread at the oldest allowed price must stay below 100%
    function _setPricing(uint256 _maxPriceAge, uint256 _spreadPerSecond) internal {
        if (_spreadPerSecond * _maxPriceAge >= WAD) revert InvalidPricing();
        maxPriceAge = _maxPriceAge;
        spreadPerSecond = _spreadPerSecond;
    }

    /// @return age Seconds since the keeper last posted Wooracle prices
    function _checkSwappable(address fromToken, address toToken) internal view returns (uint256 age) {
        if (paused() || wooPP.paused()) revert GatewayPaused();
        if (!isTokenAllowed[fromToken]) revert TokenNotAllowed(fromToken);
        if (!isTokenAllowed[toToken]) revert TokenNotAllowed(toToken);
        uint256 postedAt = IWooracle(wooPP.wooracle()).timestamp();
        age = block.timestamp > postedAt ? block.timestamp - postedAt : 0;
        if (age > maxPriceAge) revert StalePrice(age);
    }

    /// @dev Notional in quote token units: the quote leg when there is one, else the base input priced in quote
    function _checkNotional(address fromToken, address toToken, uint256 fromAmount, uint256 out) internal view {
        address quote = wooPP.quoteToken();
        uint256 notional =
            fromToken == quote ? fromAmount : toToken == quote ? out : wooPP.tryQuery(fromToken, quote, fromAmount);
        if (notional > maxNotionalPerSwap) revert NotionalExceeded(notional);
    }

    /// @dev Rounds the output down, in WOOFi's favor
    function _applySpread(uint256 out, uint256 age) internal view returns (uint256) {
        return out * (WAD - spreadPerSecond * age) / WAD;
    }
}
