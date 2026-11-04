// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {MockWooracle} from "./mocks/MockWooracle.sol";
import {WOOFiTestBase} from "./WOOFiTestBase.sol";

/// @notice WOOFiAggregator through a permissive WOOFiGateway, so these tests exercise the hook and WooPP itself
contract WOOFiAggregatorUnitTest is WOOFiTestBase {
    using PoolIdLibrary for PoolKey;

    bytes32 constant WOO_SWAP_TOPIC =
        keccak256("WooSwap(address,address,uint256,uint256,address,address,address,uint256,uint256)");

    /// @dev Quotes then swaps exact-in, asserting the swapper received exactly the quote
    function _assertQuoteMatchesSwap(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn)
        internal
        returns (uint256 quoted)
    {
        quoted = _quote(tokenIn, tokenOut, amountIn);
        assertGt(quoted, 0, "zero quote");

        uint256 inBefore = tokenIn.balanceOf(alice);
        uint256 outBefore = tokenOut.balanceOf(alice);
        uint256 wooPPInBefore = tokenIn.balanceOf(address(wooPP));
        _swap(tokenIn, tokenOut, -int256(amountIn));

        assertEq(inBefore - tokenIn.balanceOf(alice), amountIn, "input spent");
        assertEq(tokenOut.balanceOf(alice) - outBefore, quoted, "output matches quote");
        assertEq(tokenIn.balanceOf(address(wooPP)) - wooPPInBefore, amountIn, "input delivered to WooPP");
        _assertHookHoldsNothing();
    }

    // ── Construction / permissions ─────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(hook.gateway()), address(gateway));
        assertEq(hook.aggregatorHookVersion(), "WOOFiAggregator v1.0");
        assertEq(hook.tokenJar(), tokenJar);
    }

    function test_poolParameters() public view {
        assertEq(hook.POOL_FEE(), POOL_FEE);
        assertEq(hook.POOL_TICK_SPACING(), POOL_TICK_SPACING);
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeAddLiquidity);
        assertFalse(p.afterSwap);
    }

    function test_receive_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory data) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(data), WOOFiAggregator.NativeCurrencyNotSupported.selector);
    }

    // ── Initialization ─────────────────────────────────────────────────────────

    function test_initialize_registersPool() public view {
        PoolKey memory expected = _key(address(weth), address(wbtc), POOL_FEE);
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) = hook.poolKeys(expected.toId());
        assertEq(Currency.unwrap(c0), Currency.unwrap(expected.currency0));
        assertEq(Currency.unwrap(c1), Currency.unwrap(expected.currency1));
        assertEq(fee, POOL_FEE);
        assertEq(tickSpacing, POOL_TICK_SPACING);
        assertEq(address(hooks), address(hook));
    }

    function test_initialize_nativeCurrency_reverts() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(usdc)),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initialize_tokenNotAllowed_reverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        // Exercise both slots regardless of address ordering
        vm.expectRevert();
        manager.initialize(_key(address(other), address(usdc), POOL_FEE), SQRT_PRICE_1_1);
        vm.expectRevert();
        manager.initialize(_key(address(other), address(weth), POOL_FEE), SQRT_PRICE_1_1);
    }

    function test_initialize_allowedButUnpriced_succeeds() public {
        // Registration only needs the gateway's allowlist; an unpriced token simply fails to quote
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        gateway.setTokenAllowed(address(other), true);
        wooracle.setState(address(other), 1e8, 0, 0, false);
        PoolKey memory key = _key(address(other), address(usdc), POOL_FEE);
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.expectRevert();
        hook.quote(true, -1e18, key.toId());
    }

    function test_initialize_nonZeroFee_reverts() public {
        // A second pool for the same pair would need a different fee or tick spacing, both rejected
        vm.expectRevert();
        manager.initialize(_key(address(weth), address(usdc), 3000), SQRT_PRICE_1_1);
    }

    function test_initialize_tickSpacingNotOne_reverts() public {
        PoolKey memory key = _key(address(weth), address(usdc), POOL_FEE);
        key.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initialize_samePairTwice_reverts() public {
        vm.expectRevert();
        manager.initialize(_key(address(weth), address(usdc), POOL_FEE), SQRT_PRICE_1_1);
    }

    // ── Exact-in swaps ─────────────────────────────────────────────────────────

    function test_exactIn_sellQuote_usdcToWeth() public {
        _assertQuoteMatchesSwap(usdc, weth, 30_000e6);
    }

    function test_exactIn_sellBase_wethToUsdc() public {
        _assertQuoteMatchesSwap(weth, usdc, 10e18);
    }

    function test_exactIn_baseToBase_wethToWbtc() public {
        _assertQuoteMatchesSwap(weth, wbtc, 10e18);
    }

    function test_exactIn_baseToBase_wbtcToWeth() public {
        _assertQuoteMatchesSwap(wbtc, weth, 1e8);
    }

    function test_exactIn_emitsWooSwapFromGateway() public {
        vm.recordLogs();
        _swap(weth, usdc, -int256(1e18));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(wooPP) || logs[i].topics[0] != WOO_SWAP_TOPIC) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(weth), "fromToken");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdc), "toToken");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(gateway), "to");
            (uint256 fromAmount,, address from,,,) =
                abi.decode(logs[i].data, (uint256, uint256, address, address, uint256, uint256));
            assertEq(fromAmount, 1e18, "fromAmount");
            assertEq(from, address(gateway), "from");
        }
        assertTrue(found, "WooSwap not emitted");
    }

    function test_exactIn_movesOraclePrice() public {
        _swap(weth, usdc, -int256(100e18));
        MockWooracle.State memory s = wooracle.state(address(weth));
        assertLt(s.price, WETH_PRICE, "selling base lowers its price");
    }

    // ── Exact-out (unsupported) ────────────────────────────────────────────────

    function test_quote_exactOut_reverts() public {
        PoolId id = _poolId(weth, usdc);
        vm.expectRevert(WOOFiAggregator.ExactOutputNotSupported.selector);
        hook.quote(address(weth) < address(usdc), int256(1e6), id);
    }

    function test_swap_exactOut_reverts() public {
        vm.expectRevert();
        _swap(weth, usdc, int256(1000e6));
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function test_pseudoTotalValueLocked() public view {
        PoolKey memory key = _key(address(weth), address(usdc), POOL_FEE);
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(key.toId());
        assertEq(amount0, wooPP.poolSize(Currency.unwrap(key.currency0)));
        assertEq(amount1, wooPP.poolSize(Currency.unwrap(key.currency1)));
    }

    function test_quote_unregisteredPool_reverts() public {
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.quote(true, -1e6, PoolId.wrap(bytes32(uint256(1))));
    }

    function test_pseudoTVL_unregisteredPool_reverts() public {
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        hook.pseudoTotalValueLocked(PoolId.wrap(bytes32(uint256(1))));
    }

    // ── WooPP rejections pass through ──────────────────────────────────────────

    function test_oraclePaused_quoteAndSwapRevert() public {
        wooracle.setPaused(true);
        PoolId id = _poolId(weth, usdc);
        vm.expectRevert(MockWooracle.EnforcedPause.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_oracleInfeasible_quoteReverts() public {
        wooracle.setFeasible(address(weth), false);
        PoolId id = _poolId(weth, usdc);
        vm.expectRevert();
        hook.quote(address(weth) < address(usdc), -1e18, id);
    }

    function test_wooPPNotionalExceeded_quoteReverts() public {
        PoolId id = _poolId(weth, usdc);
        vm.expectRevert();
        hook.quote(address(weth) < address(usdc), -int256(uint256(MAX_NOTIONAL) / 3000 * 1e12 + 1e18), id);
    }

    // ── Fee rate multipliers ───────────────────────────────────────────────────

    function test_gatewayFeeMultiplier_appliesToQuoteAndSwap() public {
        uint256 baseline = _quote(weth, usdc, 10e18);
        wooPP.setFeeRateMultiplier(address(gateway), 4e5); // 4x fee for Uniswap flow
        uint256 quoted = _assertQuoteMatchesSwap(weth, usdc, 10e18);
        assertLt(quoted, baseline, "higher fee lowers output");
    }

    function test_originFeeMultiplier_appliesToQuoteAndSwap() public {
        uint256 baseline = _quote(weth, usdc, 10e18);
        wooPP.setFeeRateMultiplier(alice, 4e5);
        vm.prank(alice, alice);
        uint256 quoted = _quote(weth, usdc, 10e18);
        assertLt(quoted, baseline, "origin multiplier applies");

        uint256 outBefore = usdc.balanceOf(alice);
        _swap(weth, usdc, -10e18);
        assertEq(usdc.balanceOf(alice) - outBefore, quoted, "output matches origin quote");
    }

    // ── Protocol fee ───────────────────────────────────────────────────────────

    function test_protocolFee_exactIn() public {
        PoolKey memory key = _key(address(weth), address(usdc), POOL_FEE);
        uint24 fee = ProtocolFeeLibrary.MAX_PROTOCOL_FEE;
        vm.prank(address(feeAdapter));
        manager.setProtocolFee(key, (fee << 12) | fee);

        uint256 amountIn = 10e18;
        uint256 raw = wooPP.query(address(weth), address(usdc), amountIn);
        uint256 expectedFee = FullMath.mulDivRoundingUp(raw, fee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

        uint256 quoted = _assertQuoteMatchesSwap(weth, usdc, amountIn);
        assertEq(quoted, raw - expectedFee, "quote net of protocol fee");
        assertEq(usdc.balanceOf(tokenJar), expectedFee, "tokenJar fee");
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────

    /// @dev quote() succeeds ⇒ the same swap succeeds immediately after and pays out exactly the quote
    function testFuzz_quoteImpliesSwap_sellBase(uint256 amountIn, uint256 reserveLeft) public {
        amountIn = bound(amountIn, 1e9, 3000e18);
        reserveLeft = bound(reserveLeft, 0, USDC_RESERVE);
        // WooPP's production configuration: fees are charged through the oracle spread, not feeRate
        wooPP.setFeeRate(address(weth), 0);
        wooPP.withdraw(address(usdc), USDC_RESERVE - reserveLeft);
        _checkQuoteImpliesSwap(weth, usdc, amountIn);
    }

    function testFuzz_quoteImpliesSwap_sellQuote(uint256 amountIn, uint256 reserveLeft) public {
        amountIn = bound(amountIn, 1e3, MAX_NOTIONAL);
        reserveLeft = bound(reserveLeft, 0, WETH_RESERVE);
        wooPP.withdraw(address(weth), WETH_RESERVE - reserveLeft);
        _checkQuoteImpliesSwap(usdc, weth, amountIn);
    }

    function testFuzz_quoteImpliesSwap_baseToBase(uint256 amountIn, uint256 reserveLeft, uint256 quoteLeft) public {
        amountIn = bound(amountIn, 1e9, 3000e18);
        reserveLeft = bound(reserveLeft, 0, WBTC_RESERVE);
        quoteLeft = bound(quoteLeft, 0, USDC_RESERVE);
        wooPP.withdraw(address(wbtc), WBTC_RESERVE - reserveLeft);
        wooPP.withdraw(address(usdc), USDC_RESERVE - quoteLeft);
        _checkQuoteImpliesSwap(weth, wbtc, amountIn);
    }

    function _checkQuoteImpliesSwap(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn) internal {
        PoolId id = _poolId(tokenIn, tokenOut);
        try hook.quote(address(tokenIn) < address(tokenOut), -int256(amountIn), id) returns (uint256 quoted) {
            uint256 outBefore = tokenOut.balanceOf(alice);
            _swap(tokenIn, tokenOut, -int256(amountIn));
            assertEq(tokenOut.balanceOf(alice) - outBefore, quoted, "output matches quote");
            _assertHookHoldsNothing();
        } catch {}
    }
}
