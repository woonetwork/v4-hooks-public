// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {WOOFiTestBase} from "./WOOFiTestBase.sol";
import {MultiSwapRouter} from "./mocks/MultiSwapRouter.sol";

/// @notice Route shapes and keeper behavior the single-swap tests do not reach: several WOOFi swaps in one
///         transaction (multi-hop and split routes), keeper posts that cover only some tokens, and WooPP checks that
///         `query` skips. Tests named `*_currentBehavior` pin down what the gateway does today, so a fix flips them;
///         the others pin down intended behavior.
contract WOOFiRouteScenariosTest is WOOFiTestBase {
    uint256 constant MAX_PRICE_AGE = 6;
    uint256 constant SPREAD_PER_SECOND = 1e14; // 1 bp per second
    uint256 constant MAX_NOTIONAL_PER_SWAP = 1_000_000e6; // 1M USDC

    MultiSwapRouter public router;

    function setUp() public override {
        super.setUp();
        gateway.setPricing(MAX_PRICE_AGE, SPREAD_PER_SECOND);
        gateway.setMaxNotionalPerSwap(MAX_NOTIONAL_PER_SWAP);

        router = new MultiSwapRouter(manager);
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        wbtc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _hop(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn)
        internal
        view
        returns (MultiSwapRouter.Hop memory)
    {
        return MultiSwapRouter.Hop({
            key: _key(address(tokenIn), address(tokenOut), POOL_FEE),
            zeroForOne: address(tokenIn) < address(tokenOut),
            amountIn: amountIn
        });
    }

    function _route(MultiSwapRouter.Hop[] memory hops) internal returns (uint256 out) {
        Currency[] memory currencies = new Currency[](3);
        currencies[0] = Currency.wrap(address(usdc));
        currencies[1] = Currency.wrap(address(weth));
        currencies[2] = Currency.wrap(address(wbtc));
        vm.prank(alice, alice);
        out = router.swap(hops, currencies);
    }

    // ── Multi-hop ──────────────────────────────────────────────────────────────

    /// @dev Every pool shares one WooPP, and each swap moves the Wooracle price. The second hop of a route therefore
    ///      prices against the state the first hop left: a router must simulate the route as a whole (V4Quoter
    ///      `quoteExactInput`) rather than quote each hop on the pre-trade state.
    function test_multiHop_secondHopPricesAfterFirstHop() public {
        uint256 amountIn = 300_000e6;

        uint256 snapshot = vm.snapshotState();
        uint256 mid = _quote(usdc, weth, amountIn);
        _swap(usdc, weth, -int256(amountIn));
        uint256 sequential = _quote(weth, wbtc, mid);
        vm.revertToState(snapshot);

        uint256 independent = _quote(weth, wbtc, mid);

        MultiSwapRouter.Hop[] memory hops = new MultiSwapRouter.Hop[](2);
        hops[0] = _hop(usdc, weth, amountIn);
        hops[1] = _hop(weth, wbtc, 0);
        uint256 wbtcBefore = wbtc.balanceOf(alice);
        uint256 out = _route(hops);

        assertEq(out, sequential, "route output = hops simulated in order");
        assertEq(wbtc.balanceOf(alice) - wbtcBefore, out, "alice receives the route output");
        assertTrue(out != independent, "per-hop quotes on pre-trade state are wrong");
        emit log_named_uint("sequential quote (WBTC)", sequential);
        emit log_named_uint("independent quote (WBTC)", independent);
        _assertHookHoldsNothing();
        assertEq(weth.balanceOf(address(gateway)), 0, "no WETH left in gateway");
    }

    // ── Notional cap ───────────────────────────────────────────────────────────

    /// @dev `maxNotionalPerSwap` caps each swap, not each transaction (by design): two swaps on the same pool in one
    ///      route trade 1.5M USDC against a 1M cap, and fill at least as well as one uncapped 1.5M swap, since WooPP
    ///      re-prices after every swap.
    function test_capIsPerSwap_splitRouteFillsBoth() public {
        uint256 total = 1_500_000e6;

        vm.expectRevert();
        _swap(usdc, weth, -int256(total));

        uint256 snapshot = vm.snapshotState();
        gateway.setMaxNotionalPerSwap(type(uint256).max);
        uint256 uncapped = _quote(usdc, weth, total);
        vm.revertToState(snapshot);

        MultiSwapRouter.Hop[] memory hops = new MultiSwapRouter.Hop[](2);
        hops[0] = _hop(usdc, weth, total / 2);
        hops[1] = _hop(usdc, weth, total / 2);
        uint256 wethBefore = weth.balanceOf(alice);
        _route(hops);
        uint256 received = weth.balanceOf(alice) - wethBefore;

        assertGe(received, uncapped, "split fills at least as well as one uncapped swap");
        emit log_named_uint("split received (WETH)", received);
        emit log_named_uint("uncapped single quote (WETH)", uncapped);
    }

    // ── Price freshness ────────────────────────────────────────────────────────

    /// @dev WooracleV2_2 keeps one `timestamp` for every base token. A keeper post that only covers WETH makes an
    ///      hour-old WBTC price pass the freshness check, with no age spread.
    function test_partialKeeperPost_refreshesEveryToken_currentBehavior() public {
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(WOOFiGateway.StalePrice.selector);
        gateway.query(address(wbtc), address(usdc), 1e8);

        wooracle.setState(address(weth), WETH_PRICE, SPREAD, COEFF, true); // WETH only

        uint256 raw = wooPP.query(address(wbtc), address(usdc), 1e8);
        assertEq(gateway.query(address(wbtc), address(usdc), 1e8), raw, "stale WBTC quoted as fresh, no spread");

        uint256 usdcBefore = usdc.balanceOf(alice);
        _swap(wbtc, usdc, -1e8);
        assertEq(usdc.balanceOf(alice) - usdcBefore, raw, "and it trades");
    }

    // ── Quote / swap parity ────────────────────────────────────────────────────

    /// @dev WooPP's `swap` rejects `tx.gasprice > maxGasPrice` but its `query` does not check it, and the gateway does
    ///      not mirror it (by design: a quote is simulated off-chain), so the quote succeeds for a swap that reverts.
    ///      (Live WooPP sets maxGasPrice to 1e18 on Base and Arbitrum today.)
    function test_gasPriceAboveWooPPMax_quotesButSwapReverts() public {
        wooPP.setMaxGasPrice(1 gwei);
        vm.txGasPrice(2 gwei);

        assertGt(_quote(weth, usdc, 1e18), 0, "quote succeeds");
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }
}
