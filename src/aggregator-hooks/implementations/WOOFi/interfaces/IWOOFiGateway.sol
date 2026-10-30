// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IWOOFiGateway
/// @notice The WOOFiGateway surface WOOFiAggregator calls
interface IWOOFiGateway {
    /// @notice Whether Uniswap-routed flow may trade `token`
    function isTokenAllowed(address token) external view returns (bool);

    /// @notice WooPP's reserve of `token`
    function poolSize(address token) external view returns (uint256);

    /// @notice Output for swapping `fromAmount` of `fromToken` to `toToken`; reverts where `swap` would
    function query(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount);

    /// @notice Swaps `fromAmount` of `fromToken`, already transferred to the gateway, and sends the output to `to`
    function swap(address fromToken, address toToken, uint256 fromAmount, address to)
        external
        returns (uint256 toAmount);
}
