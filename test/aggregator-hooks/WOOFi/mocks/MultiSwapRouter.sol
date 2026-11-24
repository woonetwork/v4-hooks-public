// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MultiSwapRouter
/// @notice Runs several exact-input swaps inside one PoolManager unlock, like a multi-hop or split route through the
///         Universal Router, then settles the net currency deltas with the caller
contract MultiSwapRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    struct Hop {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn; // 0 = the previous hop's output
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @param currencies Every currency the hops touch, settled or taken at the end
    /// @return out The last hop's output
    function swap(Hop[] calldata hops, Currency[] calldata currencies) external returns (uint256 out) {
        out = abi.decode(manager.unlock(abi.encode(msg.sender, hops, currencies)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (address payer, Hop[] memory hops, Currency[] memory currencies) =
            abi.decode(data, (address, Hop[], Currency[]));

        uint256 out;
        for (uint256 i; i < hops.length; ++i) {
            Hop memory hop = hops[i];
            uint256 amountIn = hop.amountIn == 0 ? out : hop.amountIn;
            BalanceDelta delta = manager.swap(
                hop.key,
                SwapParams({
                    zeroForOne: hop.zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: hop.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            out = uint256(int256(hop.zeroForOne ? delta.amount1() : delta.amount0()));
        }

        for (uint256 i; i < currencies.length; ++i) {
            int256 owed = manager.currencyDelta(address(this), currencies[i]);
            if (owed < 0) {
                manager.sync(currencies[i]);
                IERC20(Currency.unwrap(currencies[i])).transferFrom(payer, address(manager), uint256(-owed));
                manager.settle();
            } else if (owed > 0) {
                manager.take(currencies[i], payer, uint256(owed));
            }
        }
        return abi.encode(out);
    }
}
