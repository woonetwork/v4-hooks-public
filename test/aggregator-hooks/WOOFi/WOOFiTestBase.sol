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
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {IWOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWOOFiGateway.sol";
import {IWooPPV2} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";
import {MockWooracle} from "./mocks/MockWooracle.sol";

/// @notice Admin surface of WooPPV2 used to configure the pool in tests
interface IWooPPV2Admin is IWooPPV2 {
    function initialize(address owner, address quoteToken, address wooracle, address feeAddr) external;
    function setTokenInfo(address token, uint16 feeRate, uint128 maxGamma, uint128 maxNotionalSwap, uint192 capBal)
        external;
    function setFeeRate(address token, uint16 rate) external;
    function setMaxGasPrice(uint256 maxGasPrice) external;
    function setFeeRateMultiplier(address user, uint256 feeRateMultiplier) external;
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;
    function pause() external;
    function unpause() external;
}

/// @notice Shared setup: the real WooPPV2 bytecode (woonetwork/woofi-evm, solc 0.8.24, via-ir) behind an ERC1967
///         proxy with a mock Wooracle, a WOOFiGateway in front of it, and WOOFiAggregator with USDC/WETH,
///         USDC/WBTC and WETH/WBTC pools. The gateway starts permissive (no age spread, no notional cap); its own
///         tests tighten it.
abstract contract WOOFiTestBase is Test {
    using PoolIdLibrary for PoolKey;

    string constant WOOPP_BYTECODE_PATH = "test/aggregator-hooks/WOOFi/precompile/WooPPV2.bin";

    uint24 constant POOL_FEE = 0; // mirrors WOOFiAggregator.POOL_FEE (checked in test_poolParameters)
    int24 constant POOL_TICK_SPACING = 1; // mirrors WOOFiAggregator.POOL_TICK_SPACING
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint16 constant FEE_RATE = 25; // 2.5 bps
    uint128 constant MAX_GAMMA = 1e17; // 10%
    uint128 constant MAX_NOTIONAL = 10_000_000e6; // WooPP's cap: 10M USDC
    uint64 constant SPREAD = 1e15; // 0.1%
    uint64 constant COEFF = 1e9;
    uint128 constant WETH_PRICE = 3000e8;
    uint128 constant WBTC_PRICE = 60_000e8;

    uint256 constant USDC_RESERVE = 10_000_000e6;
    uint256 constant WETH_RESERVE = 3000e18;
    uint256 constant WBTC_RESERVE = 150e8;

    IPoolManager public manager;
    SafePoolSwapTest public swapRouter;
    MockV4FeeAdapter public feeAdapter;
    IWooPPV2Admin public wooPP;
    MockWooracle public wooracle;
    WOOFiGateway public gateway;
    WOOFiAggregator public hook;

    MockERC20 public usdc; // quote, 6 decimals
    MockERC20 public weth; // 18 decimals
    MockERC20 public wbtc; // 8 decimals

    address public alice = makeAddr("alice");
    address public tokenJar = makeAddr("tokenJar");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        wooracle = new MockWooracle(address(usdc));
        wooPP = _deployWooPP(address(usdc), address(wooracle));
        wooracle.setWooPP(address(wooPP));
        wooPP.setMaxGasPrice(1000 gwei);
        wooPP.setTokenInfo(address(usdc), 0, 0, 0, type(uint192).max);
        wooPP.setTokenInfo(address(weth), FEE_RATE, MAX_GAMMA, MAX_NOTIONAL, type(uint192).max);
        wooPP.setTokenInfo(address(wbtc), FEE_RATE, MAX_GAMMA, MAX_NOTIONAL, type(uint192).max);
        wooracle.setState(address(weth), WETH_PRICE, SPREAD, COEFF, true);
        wooracle.setState(address(wbtc), WBTC_PRICE, SPREAD, COEFF, true);
        _deposit(usdc, USDC_RESERVE);
        _deposit(weth, WETH_RESERVE);
        _deposit(wbtc, WBTC_RESERVE);

        gateway = new WOOFiGateway(wooPP, address(this));
        gateway.setPricing(1 days, 0);
        gateway.setMaxNotionalPerSwap(type(uint256).max);
        gateway.setTokenAllowed(address(usdc), true);
        gateway.setTokenAllowed(address(weth), true);
        gateway.setTokenAllowed(address(wbtc), true);

        manager = IPoolManager(deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        feeAdapter = new MockV4FeeAdapter(manager, tokenJar);
        manager.setProtocolFeeController(address(feeAdapter));
        // Seed PoolManager so `take` can front the swapper's input before the router settles it
        usdc.mint(address(manager), USDC_RESERVE);
        weth.mint(address(manager), WETH_RESERVE);
        wbtc.mint(address(manager), WBTC_RESERVE);
        swapRouter = new SafePoolSwapTest(manager);

        _deployHook();
        gateway.setHook(address(hook));

        manager.initialize(_key(address(usdc), address(weth), POOL_FEE), SQRT_PRICE_1_1);
        manager.initialize(_key(address(usdc), address(wbtc), POOL_FEE), SQRT_PRICE_1_1);
        manager.initialize(_key(address(weth), address(wbtc), POOL_FEE), SQRT_PRICE_1_1);

        usdc.mint(alice, USDC_RESERVE);
        weth.mint(alice, WETH_RESERVE);
        wbtc.mint(alice, WBTC_RESERVE);
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        wbtc.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

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
        hook = new WOOFiAggregator{salt: salt}(manager, IWOOFiGateway(address(gateway)));
        require(address(hook) == hookAddress, "Hook address mismatch");
    }

    function _key(address a, address b, uint24 fee) internal view returns (PoolKey memory) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: fee,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _poolId(MockERC20 a, MockERC20 b) internal view returns (PoolId) {
        return _key(address(a), address(b), POOL_FEE).toId();
    }

    function _quote(MockERC20 tokenIn, MockERC20 tokenOut, uint256 amountIn) internal returns (uint256) {
        return hook.quote(address(tokenIn) < address(tokenOut), -int256(amountIn), _poolId(tokenIn, tokenOut));
    }

    function _swap(MockERC20 tokenIn, MockERC20 tokenOut, int256 amountSpecified) internal {
        bool zeroForOne = address(tokenIn) < address(tokenOut);
        vm.prank(alice, alice);
        swapRouter.swap(
            _key(address(tokenIn), address(tokenOut), POOL_FEE),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(usdc.balanceOf(address(hook)), 0, "hook usdc");
        assertEq(weth.balanceOf(address(hook)), 0, "hook weth");
        assertEq(wbtc.balanceOf(address(hook)), 0, "hook wbtc");
    }
}
