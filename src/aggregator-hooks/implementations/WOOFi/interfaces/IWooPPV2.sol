// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IWooPPV2
/// @notice Minimal interface for WOOFi's WooPPV2 (synthetic proactive market making pool)
/// @dev Subset of the WooPPV2 ABI used by WOOFiAggregator. See woonetwork/woofi-evm `contracts/spmm/WooPPV2.sol`.
///      `swap` uses a push model: the caller must transfer `fromAmount` of `fromToken` to the pool before calling.
///      Implemented by WooPPV2 itself and by WOOFiGateway, which wraps it with risk controls.
interface IWooPPV2 {
    /// @notice The quote token (e.g. USDC) every base token is priced against
    function quoteToken() external view returns (address);

    /// @notice The accounted reserve of `token` (swap liquidity)
    function poolSize(address token) external view returns (uint256);

    /// @notice Per-token configuration and accounting
    /// @return reserve Accounted balance reserve
    /// @return feeRate Fee rate in 1e5 units (10 = 1bp)
    /// @return maxGamma Max price impact (`amount * k`) per swap
    /// @return maxNotionalSwap Max notional (in quote token) per swap
    /// @return capBal Max balance of the token the pool will hold
    function tokenInfos(address token)
        external
        view
        returns (uint192 reserve, uint16 feeRate, uint128 maxGamma, uint128 maxNotionalSwap, uint192 capBal);

    /// @notice Quotes `fromAmount` of `fromToken` to `toToken`, checking cap and reserve
    function query(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount);

    /// @notice Swaps `fromAmount` of `fromToken` (already transferred to the pool) for `toToken`, sent to `to`
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount,
        address to,
        address rebateTo
    ) external returns (uint256 realToAmount);

    function paused() external view returns (bool);
}

/// @title IWooPPV2Pool
/// @notice The further WooPPV2 functions WOOFiGateway reads from the underlying pool
interface IWooPPV2Pool is IWooPPV2 {
    /// @notice Quotes `fromAmount` of `fromToken` to `toToken` without checking reserves
    function tryQuery(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount);

    /// @notice The Wooracle the pool prices with
    function wooracle() external view returns (address);
}

/// @title IWooracle
/// @notice Minimal interface for WOOFi's WooracleV2_2
interface IWooracle {
    /// @notice When the keeper last posted prices (shared by every base token)
    function timestamp() external view returns (uint256);
}
