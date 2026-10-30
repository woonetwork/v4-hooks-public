// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {IWooPPV2, IWooPPV2Pool} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";
import {IWooPPV2Admin} from "./WOOFiAggregatorUnitTest.t.sol";
import {MockWooracle} from "./mocks/MockWooracle.sol";

/// @notice WOOFiGateway against the real WooPPV2 bytecode, with WOOFiAggregator routing Uniswap swaps through it
contract WOOFiGatewayUnitTest is Test {
    using PoolIdLibrary for PoolKey;

    string constant WOOPP_BYTECODE_PATH = "test/aggregator-hooks/WOOFi/precompile/WooPPV2.bin";

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint24 constant POOL_FEE = 0; // WOOFiAggregator.POOL_FEE
    int24 constant POOL_TICK_SPACING = 1; // WOOFiAggregator.POOL_TICK_SPACING

    uint256 constant MAX_PRICE_AGE = 6;
    uint256 constant SPREAD_PER_SECOND = 1e14; // 1 bp per second
    uint256 constant MAX_NOTIONAL_PER_SWAP = 1_000_000e6; // 1M USDC

    uint256 constant USDC_RESERVE = 10_000_000e6;
    uint256 constant WETH_RESERVE = 3000e18;
    uint256 constant WBTC_RESERVE = 150e8;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    IWooPPV2Admin public wooPP;
    MockWooracle public wooracle;
    WOOFiGateway public gateway;
    WOOFiAggregator public hook;

    MockERC20 public usdc; // quote, 6 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public wbtc; // 8 decimals

    address public alice = makeAddr("alice");
    address public pauser = makeAddr("pauser");
    address public treasury = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        wooracle = new MockWooracle(address(usdc));
        wooPP = _deployWooPP(address(usdc), address(wooracle));
        wooracle.setWooPP(address(wooPP));
        wooPP.setMaxGasPrice(1000 gwei);
        wooPP.setTokenInfo(address(usdc), 0, 0, 0, type(uint192).max);
        wooPP.setTokenInfo(address(weth), 0, 1e17, 10_000_000e6, type(uint192).max);
        wooPP.setTokenInfo(address(wbtc), 0, 1e17, 10_000_000e6, type(uint192).max);
        wooracle.setState(address(weth), 3000e8, 1e15, 1e9, true);
        wooracle.setState(address(wbtc), 60_000e8, 1e15, 1e9, true);
        _deposit(usdc, USDC_RESERVE);
        _deposit(weth, WETH_RESERVE);
        _deposit(wbtc, WBTC_RESERVE);

        gateway = new WOOFiGateway(
            IWooPPV2Pool(address(wooPP)), address(this), MAX_PRICE_AGE, SPREAD_PER_SECOND, MAX_NOTIONAL_PER_SWAP
        );
        gateway.setTokenAllowed(address(usdc), true);
        gateway.setTokenAllowed(address(weth), true);
        gateway.setTokenAllowed(address(wbtc), true);
        gateway.setPauser(pauser, true);

        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        usdc.mint(address(manager), USDC_RESERVE);
        weth.mint(address(manager), WETH_RESERVE);
        wbtc.mint(address(manager), WBTC_RESERVE);
        swapRouter = new SafePoolSwapTest(manager);

        _deployHook();
        gateway.setHook(address(hook));

        manager.initialize(_key(address(usdc), address(weth)), SQRT_PRICE_1_1);
        manager.initialize(_key(address(usdc), address(wbtc)), SQRT_PRICE_1_1);
        manager.initialize(_key(address(weth), address(wbtc)), SQRT_PRICE_1_1);

        usdc.mint(alice, USDC_RESERVE);
        weth.mint(alice, WETH_RESERVE);
        wbtc.mint(alice, WBTC_RESERVE);
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        wbtc.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _deployWooPP(address quote, address oracle) internal returns (IWooPPV2Admin) {
        bytes memory code = vm.parseBytes(vm.readFile(WOOPP_BYTECODE_PATH));
        address impl;
        assembly {
            impl := create(0, add(code, 0x20), mload(code))
        }
        require(impl != address(0), "WooPPV2 deploy failed");
        ERC1967Proxy proxy = new ERC1967Proxy(
            impl, abi.encodeCall(IWooPPV2Admin.initialize, (address(this), quote, oracle, makeAddr("feeAddr")))
        );
        return IWooPPV2Admin(address(proxy));
    }

    function _deposit(MockERC20 token, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(wooPP), amount);
        wooPP.deposit(address(token), amount);
    }

    function _deployHook() internal {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(gateway));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WOOFiAggregator).creationCode, args);
        hook = new WOOFiAggregator{salt: salt}(manager, IWooPPV2(address(gateway)));
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function _key(address a, address b) internal view returns (PoolKey memory) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _setPriceAge(uint256 age) internal {
        wooracle.setTimestamp(block.timestamp - age);
    }

    function _swap(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn) internal {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        vm.prank(alice, alice);
        swapRouter.swap(
            _key(address(tokenIn), address(tokenOut)),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
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

        PoolId id = _key(address(tokenIn), address(tokenOut)).toId();
        quoted = hook.quote(address(tokenIn) < address(tokenOut), -int256(amountIn), id);
        assertEq(quoted, expected, "quote = WooPP output less age spread");

        uint256 outBefore = tokenOut.balanceOf(alice);
        uint256 keptBefore = tokenOut.balanceOf(address(gateway));
        _swap(tokenIn, tokenOut, amountIn);
        assertEq(tokenOut.balanceOf(alice) - outBefore, quoted, "output matches quote");
        assertEq(tokenOut.balanceOf(address(gateway)) - keptBefore, raw - quoted, "gateway keeps the spread");
        assertEq(tokenIn.balanceOf(address(gateway)), 0, "no input left in gateway");
        assertEq(tokenIn.balanceOf(address(hook)) + tokenOut.balanceOf(address(hook)), 0, "hook holds nothing");
    }

    // ── Construction ───────────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(gateway.wooPP()), address(wooPP));
        assertEq(gateway.owner(), address(this));
        assertEq(gateway.hook(), address(hook));
        assertEq(gateway.maxPriceAge(), MAX_PRICE_AGE);
        assertEq(gateway.spreadPerSecond(), SPREAD_PER_SECOND);
        assertEq(gateway.maxNotionalPerSwap(), MAX_NOTIONAL_PER_SWAP);
        assertEq(address(hook.wooPP()), address(gateway));
    }

    function test_constructor_invalidPricing_reverts() public {
        vm.expectRevert(WOOFiGateway.InvalidPricing.selector);
        new WOOFiGateway(IWooPPV2Pool(address(wooPP)), address(this), 10, 1e17, 0);
    }

    function test_passthroughViews() public view {
        assertEq(gateway.quoteToken(), address(usdc));
        assertEq(gateway.poolSize(address(weth)), wooPP.poolSize(address(weth)));
        (uint192 reserve,,, uint128 maxNotionalSwap,) = gateway.tokenInfos(address(weth));
        assertEq(reserve, wooPP.poolSize(address(weth)));
        assertGt(maxNotionalSwap, 0);
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
        vm.expectRevert(abi.encodeWithSelector(WOOFiGateway.StalePrice.selector, MAX_PRICE_AGE + 1));
        gateway.query(address(weth), address(usdc), 1e18);

        PoolId id = _key(address(weth), address(usdc)).toId();
        vm.expectRevert(abi.encodeWithSelector(WOOFiGateway.StalePrice.selector, MAX_PRICE_AGE + 1));
        hook.quote(address(weth) < address(usdc), -1e18, id);

        vm.expectRevert();
        _swap(weth, usdc, 1e18);
    }

    // ── Token allowlist ────────────────────────────────────────────────────────

    function test_tokenNotAllowed_cannotRegisterPool() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        wooPP.setTokenInfo(address(other), 0, 1e17, 10_000_000e6, type(uint192).max);
        wooracle.setState(address(other), 1e8, 0, 0, true);

        (,,, uint128 maxNotionalSwap,) = gateway.tokenInfos(address(other));
        assertEq(maxNotionalSwap, 0, "reads as unconfigured");
        vm.expectRevert();
        manager.initialize(_key(address(other), address(usdc)), SQRT_PRICE_1_1);

        gateway.setTokenAllowed(address(other), true);
        manager.initialize(_key(address(other), address(usdc)), SQRT_PRICE_1_1);
    }

    function test_tokenDisallowed_quoteAndSwapRevert() public {
        gateway.setTokenAllowed(address(weth), false);
        vm.expectRevert(abi.encodeWithSelector(WOOFiGateway.TokenNotAllowed.selector, address(weth)));
        gateway.query(address(weth), address(usdc), 1e18);
        vm.expectRevert(abi.encodeWithSelector(WOOFiGateway.TokenNotAllowed.selector, address(weth)));
        gateway.query(address(usdc), address(weth), 1e6);
        vm.expectRevert();
        _swap(weth, usdc, 1e18);
    }

    // ── Notional cap ───────────────────────────────────────────────────────────

    function test_notional_sellQuote() public {
        gateway.query(address(usdc), address(weth), MAX_NOTIONAL_PER_SWAP);
        vm.expectRevert(abi.encodeWithSelector(WOOFiGateway.NotionalExceeded.selector, MAX_NOTIONAL_PER_SWAP + 1));
        gateway.query(address(usdc), address(weth), MAX_NOTIONAL_PER_SWAP + 1);
    }

    function test_notional_sellBase_usesOutput() public {
        // ~3000 USDC per WETH: 340 WETH is over 1M USDC after spread and slippage
        gateway.query(address(weth), address(usdc), 300e18);
        vm.expectRevert();
        gateway.query(address(weth), address(usdc), 340e18);
    }

    function test_notional_baseToBase_pricesInputInQuote() public {
        gateway.query(address(weth), address(wbtc), 300e18);
        uint256 notional = wooPP.tryQuery(address(weth), address(usdc), 340e18);
        vm.expectRevert(abi.encodeWithSelector(WOOFiGateway.NotionalExceeded.selector, notional));
        gateway.query(address(weth), address(wbtc), 340e18);
    }

    function test_notional_swapReverts() public {
        gateway.setMaxNotionalPerSwap(1000e6);
        vm.expectRevert();
        _swap(weth, usdc, 1e18);
    }

    // ── Pause ──────────────────────────────────────────────────────────────────

    function test_pause_byPauser_unpause_byOwnerOnly() public {
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        vm.expectRevert(WOOFiGateway.GatewayPaused.selector);
        gateway.query(address(weth), address(usdc), 1e18);
        // The hook checks `paused()` first
        PoolId id = _key(address(weth), address(usdc)).toId();
        vm.expectRevert(WOOFiAggregator.WooPPPaused.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, 1e18);

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

    function test_wooPPPaused_quoteReverts() public {
        wooPP.pause();
        assertFalse(gateway.paused(), "gateway's own state");
        vm.expectRevert(WOOFiGateway.GatewayPaused.selector);
        gateway.query(address(weth), address(usdc), 1e18);
        vm.expectRevert();
        _swap(weth, usdc, 1e18);

        // The gateway can still be paused while WooPP is
        gateway.pause();
        assertTrue(gateway.paused());
    }

    // ── Access control ─────────────────────────────────────────────────────────

    function test_swap_notHook_reverts() public {
        vm.prank(alice);
        vm.expectRevert(WOOFiGateway.NotHook.selector);
        gateway.swap(address(weth), address(usdc), 1e18, 0, alice, address(0));
    }

    function test_swap_minToAmount_reverts() public {
        weth.mint(address(gateway), 1e18);
        uint256 quoted = gateway.query(address(weth), address(usdc), 1e18);
        vm.prank(address(hook));
        vm.expectRevert(WOOFiGateway.InsufficientOutput.selector);
        gateway.swap(address(weth), address(usdc), 1e18, quoted + 1, alice, address(0));
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
        vm.expectRevert(WOOFiGateway.InvalidPricing.selector);
        gateway.setPricing(10, 1e17);
    }

    function test_withdraw_retainedSpread() public {
        uint256 quoted = _assertSpreadSwap(weth, usdc, 10e18, 5);
        uint256 kept = usdc.balanceOf(address(gateway));
        assertGt(kept, 0);
        assertGt(quoted, 0);
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
