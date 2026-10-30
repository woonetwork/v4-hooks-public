// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {IWOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWOOFiGateway.sol";
import {IWooPPV2, IWooracle} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";

/// @notice Base (8453) fork tests: WOOFiAggregator → WOOFiGateway → live WooPPV2, for the launch set ETH, cbBTC, USDC.
/// @dev `FORK_RPC_URL_8453` and optional `FORK_BLOCK_NUMBER_8453` (0 = latest). Skips when the RPC is unset.
///      `POOL_MANAGER_8453` / `WOOPP_8453` default to the live deployments. The keeper posts Wooracle prices every
///      tens of seconds on Base, so the tests use a lenient `maxPriceAge` and derive the expected spread from the
///      age at the fork block.
contract WOOFiGatewayForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    address constant DEFAULT_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant DEFAULT_WOOPP = 0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // WooPP quote token
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint24 constant POOL_FEE = 0; // WOOFiAggregator.POOL_FEE
    int24 constant POOL_TICK_SPACING = 1; // WOOFiAggregator.POOL_TICK_SPACING
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint256 constant MAX_PRICE_AGE = 120;
    uint256 constant SPREAD_PER_SECOND = 1e13; // 0.1 bp per second
    uint256 constant MAX_NOTIONAL_PER_SWAP = 50_000e6;

    IPoolManager public manager;
    IWooPPV2 public wooPP;
    WOOFiGateway public gateway;
    WOOFiAggregator public hook;
    SafePoolSwapTest public swapRouter;

    address public alice = makeAddr("woofi_gateway_fork_alice");

    function setUp() public {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL_8453", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER_8453", uint256(0));
        if (forkBlock > 0) vm.createSelectFork(rpcUrl, forkBlock);
        else vm.createSelectFork(rpcUrl);

        manager = IPoolManager(vm.envOr("POOL_MANAGER_8453", DEFAULT_POOL_MANAGER));
        wooPP = IWooPPV2(vm.envOr("WOOPP_8453", DEFAULT_WOOPP));
        require(wooPP.quoteToken() == USDC, "unexpected WooPP quote token");

        gateway = new WOOFiGateway(wooPP, address(this));
        gateway.setPricing(MAX_PRICE_AGE, SPREAD_PER_SECOND);
        gateway.setMaxNotionalPerSwap(MAX_NOTIONAL_PER_SWAP);
        gateway.setTokenAllowed(USDC, true);
        gateway.setTokenAllowed(WETH, true);
        gateway.setTokenAllowed(CBBTC, true);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(gateway));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WOOFiAggregator).creationCode, args);
        hook = new WOOFiAggregator{salt: salt}(manager, IWOOFiGateway(address(gateway)));
        require(address(hook) == hookAddress, "Hook address mismatch");
        gateway.setHook(address(hook));

        manager.initialize(_key(USDC, WETH), SQRT_PRICE_1_1);
        manager.initialize(_key(USDC, CBBTC), SQRT_PRICE_1_1);
        manager.initialize(_key(WETH, CBBTC), SQRT_PRICE_1_1);

        swapRouter = new SafePoolSwapTest(manager);
        address[3] memory tokens = [USDC, WETH, CBBTC];
        for (uint256 i; i < tokens.length; ++i) {
            deal(tokens[i], alice, 1e30);
            vm.prank(alice);
            IERC20(tokens[i]).forceApprove(address(swapRouter), type(uint256).max);
        }
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

    function _priceAge() internal view returns (uint256) {
        uint256 postedAt = IWooracle(wooPP.wooracle()).timestamp();
        return block.timestamp > postedAt ? block.timestamp - postedAt : 0;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        bool zeroForOne = tokenIn < tokenOut;
        vm.prank(alice, alice);
        swapRouter.swap(
            _key(tokenIn, tokenOut),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _assertSpreadSwap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        uint256 age = _priceAge();
        if (age > MAX_PRICE_AGE) vm.skip(true); // the keeper was unusually late at this block
        uint256 raw = wooPP.query(tokenIn, tokenOut, amountIn);
        uint256 expected = raw * (1e18 - SPREAD_PER_SECOND * age) / 1e18;

        uint256 quoted = hook.quote(tokenIn < tokenOut, -int256(amountIn), _key(tokenIn, tokenOut).toId());
        assertEq(quoted, expected, "quote = WooPP output less age spread");

        uint256 outBefore = IERC20(tokenOut).balanceOf(alice);
        uint256 keptBefore = IERC20(tokenOut).balanceOf(address(gateway));
        _swap(tokenIn, tokenOut, amountIn);
        assertEq(IERC20(tokenOut).balanceOf(alice) - outBefore, quoted, "output matches quote");
        assertEq(IERC20(tokenOut).balanceOf(address(gateway)) - keptBefore, raw - quoted, "gateway keeps the spread");
    }

    function test_fork_sellBase_wethToUsdc() public {
        _assertSpreadSwap(WETH, USDC, 1e18);
    }

    function test_fork_sellQuote_usdcToCbbtc() public {
        _assertSpreadSwap(USDC, CBBTC, 5000e6);
    }

    function test_fork_baseToBase_wethToCbbtc() public {
        _assertSpreadSwap(WETH, CBBTC, 1e18);
    }

    function test_fork_baseToBase_cbbtcToWeth() public {
        _assertSpreadSwap(CBBTC, WETH, 0.01e8);
    }

    function test_fork_stalePrice_reverts() public {
        vm.warp(block.timestamp + MAX_PRICE_AGE + 1);
        vm.expectRevert(WOOFiGateway.StalePrice.selector);
        hook.quote(WETH < USDC, -1e18, _key(WETH, USDC).toId());
    }

    function test_fork_notionalCap_reverts() public {
        vm.expectRevert();
        hook.quote(USDC < WETH, -int256(MAX_NOTIONAL_PER_SWAP + 1), _key(USDC, WETH).toId());
    }

    function test_fork_tokenNotAllowed_cannotRegisterPool() public {
        // Any token the gateway has not allowed (here: Base USDT)
        address usdt = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
        vm.expectRevert();
        manager.initialize(_key(usdt, USDC), SQRT_PRICE_1_1);
    }
}
