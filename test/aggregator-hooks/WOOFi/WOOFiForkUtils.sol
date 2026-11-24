// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice The WooracleV2_2 admin surface the fork tests use
interface IWooracleAdmin {
    function owner() external view returns (address);
    function infos(address base) external view returns (uint128 price, uint64 coeff, uint64 spread);
    function postPrice(address base, uint128 price) external;
}

/// @notice Makes fork tests independent of when the keeper last posted at the fork block
abstract contract WOOFiForkUtils is Test {
    /// @dev Re-posts each base token's live price as the Wooracle owner, which sets the shared timestamp to now
    ///      (posting an unchanged price leaves its spread untouched), then advances time by `age` so the tests run
    ///      at a known price age instead of skipping when the keeper happens to be late.
    function _setWooracleAge(address wooracle, address[] memory bases, uint256 age) internal {
        IWooracleAdmin oracle = IWooracleAdmin(wooracle);
        vm.startPrank(oracle.owner());
        for (uint256 i; i < bases.length; ++i) {
            (uint128 price,,) = oracle.infos(bases[i]);
            oracle.postPrice(bases[i], price);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + age);
    }
}
