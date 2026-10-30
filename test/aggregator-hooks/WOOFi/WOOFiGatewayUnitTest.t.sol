// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {WOOFiTestBase} from "./WOOFiTestBase.sol";

/// @notice WOOFiGateway's risk controls, with Uniswap swaps routed through WOOFiAggregator
contract WOOFiGatewayUnitTest is WOOFiTestBase {
    uint256 constant MAX_PRICE_AGE = 6;
    uint256 constant SPREAD_PER_SECOND = 1e14; // 1 bp per second
    uint256 constant MAX_NOTIONAL_PER_SWAP = 1_000_000e6; // 1M USDC

    address public pauser = makeAddr("pauser");
    address public treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        gateway.setPricing(MAX_PRICE_AGE, SPREAD_PER_SECOND);
        gateway.setMaxNotionalPerSwap(MAX_NOTIONAL_PER_SWAP);
        gateway.setPauser(pauser, true);
    }

    function _setPriceAge(uint256 age) internal {
        wooracle.setTimestamp(block.timestamp - age);
    }

    /// @dev Swaps through the hook and checks: output == hook quote == WooPP output less the age spread, and the
    ///      gateway keeps exactly the spread
    function _assertSpreadSwap(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn, uint256 age)
        internal
        returns (uint256 quoted)
    {
        _setPriceAge(age);
        uint256 raw = wooPP.query(address(tokenIn), address(tokenOut), amountIn);
        uint256 expected = raw * (1e18 - SPREAD_PER_SECOND * age) / 1e18;

        quoted = _quote(tokenIn, tokenOut, amountIn);
        assertEq(quoted, expected, "quote = WooPP output less age spread");

        uint256 outBefore = tokenOut.balanceOf(alice);
        uint256 keptBefore = tokenOut.balanceOf(address(gateway));
        _swap(tokenIn, tokenOut, -int256(amountIn));
        assertEq(tokenOut.balanceOf(alice) - outBefore, quoted, "output matches quote");
        assertEq(tokenOut.balanceOf(address(gateway)) - keptBefore, raw - quoted, "gateway keeps the spread");
        assertEq(tokenIn.balanceOf(address(gateway)), 0, "no input left in gateway");
        _assertHookHoldsNothing();
    }

    // ── Construction ───────────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(gateway.wooPP()), address(wooPP));
        assertEq(gateway.owner(), address(this));
        assertEq(gateway.hook(), address(hook));
        assertEq(gateway.maxPriceAge(), MAX_PRICE_AGE);
        assertEq(gateway.spreadPerSecond(), SPREAD_PER_SECOND);
        assertEq(gateway.maxNotionalPerSwap(), MAX_NOTIONAL_PER_SWAP);
    }

    function test_unconfigured_rejectsQuotes() public {
        WOOFiGateway fresh = new WOOFiGateway(wooPP, address(this));
        fresh.setTokenAllowed(address(weth), true);
        fresh.setTokenAllowed(address(usdc), true);
        assertEq(fresh.maxNotionalPerSwap(), 0);
        vm.expectRevert(WOOFiGateway.NotionalExceeded.selector);
        fresh.query(address(weth), address(usdc), 1e18);
    }

    function test_poolSize() public view {
        assertEq(gateway.poolSize(address(weth)), wooPP.poolSize(address(weth)));
    }

    // ── Swaps through the hook ─────────────────────────────────────────────────

    function test_swap_freshPrice_noSpread() public {
        _assertSpreadSwap(weth, usdc, 10e18, 0);
    }

    function test_swap_sellBase_ageSpread() public {
        _assertSpreadSwap(weth, usdc, 10e18, 4);
    }

    function test_swap_sellQuote_ageSpread() public {
        _assertSpreadSwap(usdc, weth, 30_000e6, 3);
    }

    function test_swap_baseToBase_ageSpread() public {
        _assertSpreadSwap(weth, wbtc, 10e18, MAX_PRICE_AGE);
    }

    function test_futurePriceTimestamp_treatedAsFresh() public {
        wooracle.setTimestamp(block.timestamp + 10);
        uint256 raw = wooPP.query(address(weth), address(usdc), 1e18);
        assertEq(gateway.query(address(weth), address(usdc), 1e18), raw);
    }

    // ── Price freshness ────────────────────────────────────────────────────────

    function test_stalePrice_quoteAndSwapRevert() public {
        _setPriceAge(MAX_PRICE_AGE + 1);
        vm.expectRevert(WOOFiGateway.StalePrice.selector);
        gateway.query(address(weth), address(usdc), 1e18);
        vm.expectRevert(WOOFiGateway.StalePrice.selector);
        _quote(weth, usdc, 1e18);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    // ── Token allowlist ────────────────────────────────────────────────────────

    function test_tokenNotAllowed_cannotRegisterPool() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        wooPP.setTokenInfo(address(other), 0, MAX_GAMMA, MAX_NOTIONAL, type(uint192).max);
        wooracle.setState(address(other), 1e8, 0, 0, true);

        vm.expectRevert();
        manager.initialize(_key(address(other), address(usdc), POOL_FEE), SQRT_PRICE_1_1);

        gateway.setTokenAllowed(address(other), true);
        manager.initialize(_key(address(other), address(usdc), POOL_FEE), SQRT_PRICE_1_1);
    }

    function test_tokenDisallowed_quoteAndSwapRevert() public {
        gateway.setTokenAllowed(address(weth), false);
        vm.expectRevert(WOOFiGateway.TokenNotAllowed.selector);
        gateway.query(address(weth), address(usdc), 1e18);
        vm.expectRevert(WOOFiGateway.TokenNotAllowed.selector);
        gateway.query(address(usdc), address(weth), 1e6);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    // ── Notional cap ───────────────────────────────────────────────────────────

    function test_notional_sellQuote() public {
        gateway.query(address(usdc), address(weth), MAX_NOTIONAL_PER_SWAP);
        vm.expectRevert(WOOFiGateway.NotionalExceeded.selector);
        gateway.query(address(usdc), address(weth), MAX_NOTIONAL_PER_SWAP + 1);
    }

    function test_notional_sellBase_usesOutput() public {
        // ~3000 USDC per WETH: 340 WETH is over 1M USDC after spread and slippage
        gateway.query(address(weth), address(usdc), 300e18);
        vm.expectRevert(WOOFiGateway.NotionalExceeded.selector);
        gateway.query(address(weth), address(usdc), 340e18);
    }

    function test_notional_baseToBase_pricesInputInQuote() public {
        gateway.query(address(weth), address(wbtc), 300e18);
        vm.expectRevert(WOOFiGateway.NotionalExceeded.selector);
        gateway.query(address(weth), address(wbtc), 340e18);
    }

    function test_notional_swapReverts() public {
        gateway.setMaxNotionalPerSwap(1000e6);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    // ── Pause ──────────────────────────────────────────────────────────────────

    function test_pause_byPauser_unpause_byOwnerOnly() public {
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        vm.expectRevert(WOOFiGateway.GatewayPaused.selector);
        _quote(weth, usdc, 1e18);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pauser));
        gateway.unpause();

        gateway.unpause();
        assertFalse(gateway.paused());
        _assertSpreadSwap(weth, usdc, 1e18, 0);
    }

    function test_pause_byOwner() public {
        vm.expectEmit(address(gateway));
        emit Pausable.Paused(address(this));
        gateway.pause();
        assertTrue(gateway.paused());
    }

    function test_pause_notPauser_reverts() public {
        vm.prank(alice);
        vm.expectRevert(WOOFiGateway.NotPauser.selector);
        gateway.pause();
    }

    function test_wooPPPaused_quoteAndSwapRevert() public {
        wooPP.pause();
        assertFalse(gateway.paused(), "gateway's own state");
        vm.expectRevert(WOOFiGateway.GatewayPaused.selector);
        _quote(weth, usdc, 1e18);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);

        // The gateway can still be paused while WooPP is
        gateway.pause();
        assertTrue(gateway.paused());
    }

    // ── Access control ─────────────────────────────────────────────────────────

    function test_swap_notHook_reverts() public {
        vm.prank(alice);
        vm.expectRevert(WOOFiGateway.NotHook.selector);
        gateway.swap(address(weth), address(usdc), 1e18, alice);
    }

    function test_admin_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        gateway.setHook(alice);
        vm.expectRevert(err);
        gateway.setPauser(alice, true);
        vm.expectRevert(err);
        gateway.setTokenAllowed(alice, true);
        vm.expectRevert(err);
        gateway.setPricing(1, 1);
        vm.expectRevert(err);
        gateway.setMaxNotionalPerSwap(1);
        vm.expectRevert(err);
        gateway.withdraw(address(usdc), alice, 1);
        vm.stopPrank();
    }

    function test_setPricing() public {
        gateway.setPricing(10, 2e14);
        assertEq(gateway.maxPriceAge(), 10);
        assertEq(gateway.spreadPerSecond(), 2e14);
        vm.expectRevert(WOOFiGateway.SpreadTooHigh.selector);
        gateway.setPricing(10, 1e17);
    }

    function test_withdraw_retainedSpread() public {
        _assertSpreadSwap(weth, usdc, 10e18, 5);
        uint256 kept = usdc.balanceOf(address(gateway));
        assertGt(kept, 0);
        gateway.withdraw(address(usdc), treasury, kept);
        assertEq(usdc.balanceOf(treasury), kept);
        assertEq(usdc.balanceOf(address(gateway)), 0);
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────

    function testFuzz_quoteMatchesSwap(uint256 amountIn, uint256 age, uint8 direction) public {
        age = bound(age, 0, MAX_PRICE_AGE);
        direction = uint8(bound(direction, 0, 2));
        if (direction == 0) _assertSpreadSwap(weth, usdc, bound(amountIn, 1e12, 300e18), age);
        else if (direction == 1) _assertSpreadSwap(usdc, weth, bound(amountIn, 1e3, MAX_NOTIONAL_PER_SWAP), age);
        else _assertSpreadSwap(weth, wbtc, bound(amountIn, 1e12, 300e18), age);
    }
}
