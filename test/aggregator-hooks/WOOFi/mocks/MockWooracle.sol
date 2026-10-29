// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockWooracle
/// @notice Minimal stand-in for WOOFi's WooracleV2_2, exposing the subset WooPPV2 reads and writes
/// @dev Prices use 8 decimals (quote per base), spread and coeff use 18 decimals, as in WooracleV2_2.
///      `postPrice` is restricted to the configured WooPP, which moves the price after each swap.
contract MockWooracle {
    struct State {
        uint128 price;
        uint64 spread;
        uint64 coeff;
        bool woFeasible;
    }

    address public quoteToken;
    address public wooPP;
    bool public paused;

    mapping(address => State) internal _states;

    error NotWooPP();
    error EnforcedPause();

    constructor(address _quoteToken) {
        quoteToken = _quoteToken;
    }

    function setWooPP(address _wooPP) external {
        wooPP = _wooPP;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function setState(address base, uint128 _price, uint64 _spread, uint64 _coeff, bool _feasible) external {
        _states[base] = State({price: _price, spread: _spread, coeff: _coeff, woFeasible: _feasible});
    }

    function setFeasible(address base, bool _feasible) external {
        _states[base].woFeasible = _feasible;
    }

    /// @dev Mirrors WooracleV2_2: reading the state of a paused oracle reverts
    function state(address base) external view returns (State memory) {
        if (paused) revert EnforcedPause();
        return _states[base];
    }

    function postPrice(address base, uint128 _price) external {
        if (msg.sender != wooPP) revert NotWooPP();
        _states[base].price = _price;
    }

    function decimals(address) external pure returns (uint8) {
        return 8;
    }
}
