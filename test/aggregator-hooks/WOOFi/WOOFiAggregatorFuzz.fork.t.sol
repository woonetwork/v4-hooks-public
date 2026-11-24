// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiForkBase} from "./WOOFiAggregatorForkTest.fork.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fuzz against the live Arbitrum WooPPV2: quote() succeeds ⇒ the swap succeeds and pays exactly the quote
/// forge-config: default.fuzz.runs = 64
contract WOOFiAggregatorFuzzForkTest is WOOFiForkBase {
    function testFuzz_fork_sellBase(uint256 amountIn) public {
        _checkQuoteImpliesSwap(WETH, USDC, bound(amountIn, 1e12, 100e18));
    }

    function testFuzz_fork_sellQuote(uint256 amountIn) public {
        _checkQuoteImpliesSwap(USDC, WETH, bound(amountIn, 1, 300_000e6));
    }

    function testFuzz_fork_baseToBase(uint256 amountIn) public {
        _checkQuoteImpliesSwap(WBTC, WETH, bound(amountIn, 100, 5e8));
    }

    function testFuzz_fork_usdt(uint256 amountIn) public {
        _checkQuoteImpliesSwap(USDT, USDC, bound(amountIn, 1, 300_000e6));
    }

    function _checkQuoteImpliesSwap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        try hook.quote(tokenIn < tokenOut, -int256(amountIn), _key(tokenIn, tokenOut).toId()) returns (uint256 quoted) {
            uint256 outBefore = IERC20(tokenOut).balanceOf(alice);
            _swap(tokenIn, tokenOut, amountIn);
            assertEq(IERC20(tokenOut).balanceOf(alice) - outBefore, quoted, "output matches quote");
        } catch {}
    }
}
