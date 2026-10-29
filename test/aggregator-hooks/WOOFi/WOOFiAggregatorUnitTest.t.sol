// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {IAggregatorHook} from "../../../src/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {IWooPPV2} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";
import {MockWooracle} from "./mocks/MockWooracle.sol";

/// @notice Admin surface of WooPPV2 used to configure the pool in tests
interface IWooPPV2Admin is IWooPPV2 {
    function initialize(address owner, address quoteToken, address wooracle, address feeAddr) external;
    function setTokenInfo(address token, uint16 feeRate, uint128 maxGamma, uint128 maxNotionalSwap, uint192 capBal)
        external;
    function setFeeRate(address token, uint16 rate) external;
    function setMaxGasPrice(uint256 maxGasPrice) external;
    function setBlacklist(address user, bool flag) external;
    function setFeeRateMultiplier(address user, uint256 feeRateMultiplier) external;
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;
    function pause() external;
    function unpause() external;
}

/// @notice Unit tests run against the real WooPPV2 bytecode (woonetwork/woofi-evm, solc 0.8.24, via-ir) behind an
///         ERC1967 proxy, with a mock Wooracle supplying prices.
contract WOOFiAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    string constant WOOPP_BYTECODE_PATH = "test/aggregator-hooks/WOOFi/precompile/WooPPV2.bin";

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint256 constant MAX_GAS_PRICE = 1000 gwei;
    uint16 constant FEE_RATE = 25; // 2.5 bps
    uint128 constant MAX_GAMMA = 1e17; // 10%
    uint128 constant MAX_NOTIONAL = 10_000_000e6; // 10M USDC
    uint64 constant SPREAD = 1e15; // 0.1%
    uint64 constant COEFF = 1e9;
    uint128 constant WETH_PRICE = 3000e8;
    uint128 constant WBTC_PRICE = 60_000e8;

    uint256 constant USDC_RESERVE = 10_000_000e6;
    uint256 constant WETH_RESERVE = 3000e18;
    uint256 constant WBTC_RESERVE = 150e8;

    bytes32 constant WOO_SWAP_TOPIC =
        keccak256("WooSwap(address,address,uint256,uint256,address,address,address,uint256,uint256)");

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    MockV4FeeAdapter public feeAdapter;
    WOOFiAggregator public hook;
    IWooPPV2Admin public wooPP;
    MockWooracle public wooracle;

    MockERC20 public usdc; // quote, 6 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public wbtc; // 8 decimals

    address public alice = makeAddr("alice");
    address public rebateTo = makeAddr("rebateTo");
    address public tokenJar = makeAddr("tokenJar");
    address public feeAddr = makeAddr("feeAddr");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        wooracle = new MockWooracle(address(usdc));
        wooPP = _deployWooPP(address(usdc), address(wooracle));
        wooracle.setWooPP(address(wooPP));
        wooPP.setMaxGasPrice(MAX_GAS_PRICE);

        wooPP.setTokenInfo(address(usdc), 0, 0, 0, type(uint192).max);
        wooPP.setTokenInfo(address(weth), FEE_RATE, MAX_GAMMA, MAX_NOTIONAL, type(uint192).max);
        wooPP.setTokenInfo(address(wbtc), FEE_RATE, MAX_GAMMA, MAX_NOTIONAL, type(uint192).max);
        wooracle.setState(address(weth), WETH_PRICE, SPREAD, COEFF, true);
        wooracle.setState(address(wbtc), WBTC_PRICE, SPREAD, COEFF, true);

        _deposit(usdc, USDC_RESERVE);
        _deposit(weth, WETH_RESERVE);
        _deposit(wbtc, WBTC_RESERVE);

        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        feeAdapter = new MockV4FeeAdapter(manager, tokenJar);
        manager.setProtocolFeeController(address(feeAdapter));

        // Seed PoolManager so `take` can front the swapper's input before the router settles it
        usdc.mint(address(manager), USDC_RESERVE);
        weth.mint(address(manager), WETH_RESERVE);
        wbtc.mint(address(manager), WBTC_RESERVE);

        swapRouter = new SafePoolSwapTest(manager);
        _deployHook();

        _initPool(usdc, weth);
        _initPool(usdc, wbtc);
        _initPool(weth, wbtc);

        usdc.mint(alice, USDC_RESERVE);
        weth.mint(alice, WETH_RESERVE);
        wbtc.mint(alice, WBTC_RESERVE);
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        wbtc.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ── Setup helpers ──────────────────────────────────────────────────────────

    function _deployWooPP(address quote, address oracle) internal returns (IWooPPV2Admin) {
        bytes memory code = vm.parseBytes(vm.readFile(WOOPP_BYTECODE_PATH));
        address impl;
        assembly {
            impl := create(0, add(code, 0x20), mload(code))
        }
        require(impl != address(0), "WooPPV2 deploy failed");
        ERC1967Proxy proxy =
            new ERC1967Proxy(impl, abi.encodeCall(IWooPPV2Admin.initialize, (address(this), quote, oracle, feeAddr)));
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
        bytes memory constructorArgs = abi.encode(address(manager), address(wooPP), rebateTo);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WOOFiAggregator).creationCode, constructorArgs);
        hook = new WOOFiAggregator{salt: salt}(manager, IWooPPV2(address(wooPP)), rebateTo);
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function _key(address a, address b, uint24 fee) internal view returns (PoolKey memory) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: fee,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
    }

    function _initPool(MockERC20 a, MockERC20 b) internal {
        manager.initialize(_key(address(a), address(b), 0), SQRT_PRICE_1_1);
    }

    // ── Swap helpers ───────────────────────────────────────────────────────────

    function _quote(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn) internal returns (uint256) {
        PoolKey memory key = _key(address(tokenIn), address(tokenOut), 0);
        return hook.quote(address(tokenIn) < address(tokenOut), -int256(amountIn), key.toId());
    }

    function _swap(MockERC20 tokenIn, MockERC20 tokenOut, int256 amountSpecified) internal {
        PoolKey memory key = _key(address(tokenIn), address(tokenOut), 0);
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        vm.prank(alice, alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

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

    function _assertHookHoldsNothing() internal view {
        assertEq(usdc.balanceOf(address(hook)), 0, "hook usdc");
        assertEq(weth.balanceOf(address(hook)), 0, "hook weth");
        assertEq(wbtc.balanceOf(address(hook)), 0, "hook wbtc");
    }

    function _setProtocolFee(PoolKey memory key, uint24 fee) internal {
        vm.prank(address(feeAdapter));
        manager.setProtocolFee(key, (fee << 12) | fee);
    }

    // ── Construction / permissions ─────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(hook.wooPP()), address(wooPP));
        assertEq(hook.rebateTo(), rebateTo);
        assertEq(hook.aggregatorHookVersion(), "WOOFiAggregator v1.0");
        assertEq(hook.tokenJar(), tokenJar);
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
        PoolId id = _key(address(weth), address(wbtc), 0).toId();
        (address t0, address t1) = hook.poolIdToTokens(id);
        (address e0, address e1) =
            address(weth) < address(wbtc) ? (address(weth), address(wbtc)) : (address(wbtc), address(weth));
        assertEq(t0, e0);
        assertEq(t1, e1);
    }

    function test_initialize_nativeCurrency_reverts() public {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(usdc)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initialize_unconfiguredToken_reverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        wooracle.setState(address(other), 1e8, 0, 0, true);
        vm.expectRevert();
        manager.initialize(_key(address(other), address(usdc), 0), SQRT_PRICE_1_1);
    }

    function test_initialize_unconfiguredBaseInSecondSlot_reverts() public {
        // Exercise the second-token check regardless of address ordering
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectRevert();
        manager.initialize(_key(address(weth), address(other), 0), SQRT_PRICE_1_1);
    }

    function test_initialize_oracleInfeasible_reverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        wooPP.setTokenInfo(address(other), FEE_RATE, MAX_GAMMA, MAX_NOTIONAL, type(uint192).max);
        wooracle.setState(address(other), 1e8, 0, 0, false);
        vm.expectRevert();
        manager.initialize(_key(address(other), address(usdc), 0), SQRT_PRICE_1_1);
    }

    function test_initialize_duplicatePair_reverts() public {
        vm.expectRevert();
        manager.initialize(_key(address(weth), address(usdc), 3000), SQRT_PRICE_1_1);
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

    function test_exactIn_emitsWooSwapToPoolManagerWithRebate() public {
        vm.recordLogs();
        _swap(weth, usdc, -int256(1e18));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(wooPP) || logs[i].topics[0] != WOO_SWAP_TOPIC) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(weth), "fromToken");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdc), "toToken");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(manager), "to");
            (uint256 fromAmount,, address from, address rebate,,) =
                abi.decode(logs[i].data, (uint256, uint256, address, address, uint256, uint256));
            assertEq(fromAmount, 1e18, "fromAmount");
            assertEq(from, address(hook), "from");
            assertEq(rebate, rebateTo, "rebateTo");
        }
        assertTrue(found, "WooSwap not emitted");
    }

    function test_exactIn_movesOraclePrice() public {
        _swap(weth, usdc, -int256(100e18));
        (uint128 price,,,) = _oracleState(address(weth));
        assertLt(price, WETH_PRICE, "selling base lowers its price");
    }

    function _oracleState(address base) internal view returns (uint128, uint64, uint64, bool) {
        MockWooracle.State memory s = wooracle.state(base);
        return (s.price, s.spread, s.coeff, s.woFeasible);
    }

    // ── Exact-out (unsupported) ────────────────────────────────────────────────

    function test_quote_exactOut_reverts() public {
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(WOOFiAggregator.ExactOutputNotSupported.selector);
        hook.quote(address(weth) < address(usdc), int256(1e6), id);
    }

    function test_swap_exactOut_reverts() public {
        vm.expectRevert();
        _swap(weth, usdc, int256(1000e6));
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function test_pseudoTotalValueLocked() public view {
        PoolKey memory key = _key(address(weth), address(usdc), 0);
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

    // ── Quote executability: base → quote reserve boundary ─────────────────────

    /// @dev Price 100 USDC/WETH, 1% fee, no spread/slippage: selling 1 WETH gives Q = 100 USDC pre-fee,
    ///      fee = 1 USDC, output = 99 USDC. Leaves the quote reserve at `reserve`.
    function _setUpBoundary(uint256 reserve) internal {
        wooracle.setState(address(weth), 100e8, 0, 0, true);
        wooPP.setFeeRate(address(weth), 1000);
        wooPP.withdraw(address(usdc), USDC_RESERVE - reserve);
    }

    function test_boundary_queryPassesButSwapUnderflows_quoteReverts() public {
        _setUpBoundary(99e6);

        // WooPPV2.query checks output (99) and fee (1) against reserve (99) separately and passes
        assertEq(wooPP.query(address(weth), address(usdc), 1e18), 99e6, "raw query passes");

        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(WOOFiAggregator.InsufficientQuoteReserve.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);

        // ...while the swap subtracts output + fee (100) from the reserve (99) and underflows
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_boundary_exactReserve_quoteAndSwapSucceed() public {
        _setUpBoundary(100e6);
        uint256 quoted = _assertQuoteMatchesSwap(weth, usdc, 1e18);
        assertEq(quoted, 99e6);
        assertEq(wooPP.poolSize(address(usdc)), 0, "quote reserve fully used");
    }

    /// @dev The rebuilt pre-fee amount is sound (reserve Q - 1 is rejected) and tight (reserve Q + 1 is accepted)
    function testFuzz_boundary_reserveBoundIsTight(uint256 amountIn, uint16 feeRate, uint256 multiplier) public {
        amountIn = bound(amountIn, 1e12, 1000e18);
        feeRate = uint16(bound(feeRate, 1, 10_000));
        multiplier = bound(multiplier, 1e5, 4e5);
        wooPP.setFeeRateMultiplier(address(hook), multiplier);
        wooPP.setFeeRateMultiplier(address(this), multiplier); // so the raw queries below price like the hook

        wooPP.setFeeRate(address(weth), 0);
        uint256 gross = wooPP.query(address(weth), address(usdc), amountIn);
        wooPP.setFeeRate(address(weth), feeRate);
        uint256 out = wooPP.query(address(weth), address(usdc), amountIn);
        vm.assume(out < gross); // a fee was actually charged

        wooPP.withdraw(address(usdc), USDC_RESERVE - (gross - 1));
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(WOOFiAggregator.InsufficientQuoteReserve.selector);
        hook.quote(address(weth) < address(usdc), -int256(amountIn), id);

        _deposit(usdc, 2);
        assertEq(_assertQuoteMatchesSwap(weth, usdc, amountIn), out);
    }

    // ── Quote executability: swap-only conditions ──────────────────────────────

    function test_wooPPPaused_quoteAndSwapRevert() public {
        wooPP.pause();
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(WOOFiAggregator.WooPPPaused.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_hookBlacklisted_quoteAndSwapRevert() public {
        wooPP.setBlacklist(address(hook), true);
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(WOOFiAggregator.Blacklisted.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_originBlacklisted_quoteAndSwapRevert() public {
        wooPP.setBlacklist(alice, true);
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.prank(alice, alice);
        vm.expectRevert(WOOFiAggregator.Blacklisted.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_gasPriceTooHigh_quoteAndSwapRevert() public {
        vm.txGasPrice(MAX_GAS_PRICE + 1);
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(WOOFiAggregator.GasPriceTooHigh.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_oraclePaused_quoteAndSwapRevert() public {
        wooracle.setPaused(true);
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert(MockWooracle.EnforcedPause.selector);
        hook.quote(address(weth) < address(usdc), -1e18, id);
        vm.expectRevert();
        _swap(weth, usdc, -1e18);
    }

    function test_oracleInfeasible_quoteReverts() public {
        wooracle.setFeasible(address(weth), false);
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert();
        hook.quote(address(weth) < address(usdc), -1e18, id);
    }

    function test_notionalExceeded_quoteReverts() public {
        PoolId id = _key(address(weth), address(usdc), 0).toId();
        vm.expectRevert();
        hook.quote(address(weth) < address(usdc), -int256(uint256(MAX_NOTIONAL) / 3000 * 1e12 + 1e18), id);
    }

    // ── Fee rate multipliers ───────────────────────────────────────────────────

    function test_hookFeeMultiplier_appliesToQuoteAndSwap() public {
        uint256 baseline = _quote(weth, usdc, 10e18);
        wooPP.setFeeRateMultiplier(address(hook), 4e5); // 4x fee for Uniswap flow
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

    function test_fullFee_quoteIsZero() public {
        // feeRate 50% * multiplier 2x = 100% fee: output is 0 and the reserve bound is skipped
        wooPP.setFeeRate(address(weth), 50_000);
        wooPP.setFeeRateMultiplier(address(hook), 2e5);
        assertEq(_quote(weth, usdc, 1e18), 0);
    }

    // ── Protocol fee ───────────────────────────────────────────────────────────

    function test_protocolFee_exactIn() public {
        PoolKey memory key = _key(address(weth), address(usdc), 0);
        uint24 fee = ProtocolFeeLibrary.MAX_PROTOCOL_FEE;
        _setProtocolFee(key, fee);

        uint256 amountIn = 10e18;
        uint256 raw = wooPP.query(address(weth), address(usdc), amountIn);
        uint256 expectedFee = FullMath.mulDivRoundingUp(raw, fee * 25, ProtocolFeeLibrary.PIPS_DENOMINATOR);

        uint256 quoted = _assertQuoteMatchesSwap(weth, usdc, amountIn);
        assertEq(quoted, raw - expectedFee, "quote net of protocol fee");
        assertEq(usdc.balanceOf(tokenJar), expectedFee, "tokenJar fee");
    }

    // ── Fuzz ───────────────────────────────────────────────────────────────────

    /// @dev quote() succeeds ⇒ the same swap succeeds immediately after and pays out exactly the quote
    function testFuzz_quoteImpliesSwap_sellBase(uint256 amountIn, uint256 reserveLeft, uint16 feeRate) public {
        amountIn = bound(amountIn, 1e9, 3000e18);
        reserveLeft = bound(reserveLeft, 0, USDC_RESERVE);
        feeRate = uint16(bound(feeRate, 0, 1000));
        wooPP.setFeeRate(address(weth), feeRate);
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
        PoolId id = _key(address(tokenIn), address(tokenOut), 0).toId();
        try hook.quote(address(tokenIn) < address(tokenOut), -int256(amountIn), id) returns (uint256 quoted) {
            uint256 outBefore = tokenOut.balanceOf(alice);
            _swap(tokenIn, tokenOut, -int256(amountIn));
            assertEq(tokenOut.balanceOf(alice) - outBefore, quoted, "output matches quote");
            _assertHookHoldsNothing();
        } catch {}
    }
}
