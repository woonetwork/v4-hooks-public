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
import {IWooPPV2} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";

interface IWooPPV2Owner is IWooPPV2 {
    function owner() external view returns (address);
    function setFeeRate(address token, uint16 rate) external;
    function withdraw(address token, uint256 amount) external;
}

/// @notice Shared Arbitrum (42161) fork setup against the live WooPPV2.
/// @dev `FORK_RPC_URL_42161` and optional `FORK_BLOCK_NUMBER_42161` (0 = latest). Skips when the RPC is unset.
///      `POOL_MANAGER_42161` / `WOOPP_42161` default to the live deployments. The fork must not be warped:
///      Wooracle prices go stale after `staleDuration` (300s by default) and every quote/swap then reverts.
abstract contract WOOFiForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    address constant DEFAULT_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant DEFAULT_WOOPP = 0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // WooPP quote token
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager public manager;
    IWooPPV2Owner public wooPP;
    SafePoolSwapTest public swapRouter;
    WOOFiAggregator public hook;

    address public alice = makeAddr("woofi_fork_alice");
    address public rebateTo = makeAddr("woofi_fork_rebateTo");

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL_42161", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER_42161", uint256(0));
        if (forkBlock > 0) vm.createSelectFork(rpcUrl, forkBlock);
        else vm.createSelectFork(rpcUrl);

        manager = IPoolManager(vm.envOr("POOL_MANAGER_42161", DEFAULT_POOL_MANAGER));
        wooPP = IWooPPV2Owner(vm.envOr("WOOPP_42161", DEFAULT_WOOPP));
        require(wooPP.quoteToken() == USDC, "unexpected WooPP quote token");

        swapRouter = new SafePoolSwapTest(manager);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(address(manager), address(wooPP), rebateTo);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WOOFiAggregator).creationCode, args);
        hook = new WOOFiAggregator{salt: salt}(manager, IWooPPV2(address(wooPP)), rebateTo);
        require(address(hook) == hookAddress, "Hook address mismatch");

        manager.initialize(_key(USDC, WETH), SQRT_PRICE_1_1);
        manager.initialize(_key(WETH, WBTC), SQRT_PRICE_1_1);
        manager.initialize(_key(USDT, USDC), SQRT_PRICE_1_1);

        address[4] memory tokens = [USDC, USDT, WETH, WBTC];
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
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        return hook.quote(tokenIn < tokenOut, -int256(amountIn), _key(tokenIn, tokenOut).toId());
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

    function _assertQuoteMatchesSwap(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 quoted)
    {
        quoted = _quote(tokenIn, tokenOut, amountIn);
        assertGt(quoted, 0, "zero quote");
        uint256 inBefore = IERC20(tokenIn).balanceOf(alice);
        uint256 outBefore = IERC20(tokenOut).balanceOf(alice);
        _swap(tokenIn, tokenOut, amountIn);
        assertEq(inBefore - IERC20(tokenIn).balanceOf(alice), amountIn, "input spent");
        assertEq(IERC20(tokenOut).balanceOf(alice) - outBefore, quoted, "output matches quote");
        assertEq(IERC20(tokenIn).balanceOf(address(hook)), 0, "hook holds no input");
        assertEq(IERC20(tokenOut).balanceOf(address(hook)), 0, "hook holds no output");
    }
}

/// @notice Fork tests against the live Arbitrum WooPPV2
contract WOOFiAggregatorForkTest is WOOFiForkBase {
    using PoolIdLibrary for PoolKey;

    function test_fork_sellQuote_usdcToWeth() public {
        _assertQuoteMatchesSwap(USDC, WETH, 1000e6);
    }

    function test_fork_sellBase_wethToUsdc() public {
        _assertQuoteMatchesSwap(WETH, USDC, 0.5e18);
    }

    function test_fork_baseToBase_wethToWbtc() public {
        _assertQuoteMatchesSwap(WETH, WBTC, 0.5e18);
    }

    function test_fork_baseToBase_wbtcToWeth() public {
        _assertQuoteMatchesSwap(WBTC, WETH, 0.01e8);
    }

    function test_fork_usdt_sellBase() public {
        _assertQuoteMatchesSwap(USDT, USDC, 1000e6);
    }

    function test_fork_usdt_sellQuote() public {
        _assertQuoteMatchesSwap(USDC, USDT, 1000e6);
    }

    function test_fork_pseudoTotalValueLocked() public view {
        PoolKey memory key = _key(USDC, WETH);
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(key.toId());
        assertEq(amount0, wooPP.poolSize(Currency.unwrap(key.currency0)));
        assertEq(amount1, wooPP.poolSize(Currency.unwrap(key.currency1)));
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    /// @dev Confirms the deployed WooPPV2 has the base → quote reserve mismatch the hook guards against:
    ///      `query` checks output and fee against the quote reserve separately, `swap` subtracts their sum.
    function test_fork_baseToQuoteReserveBoundary() public {
        uint256 amountIn = 0.1e18;
        address owner = wooPP.owner();

        // Pre-fee quote amount Q: with feeRate 0 the output is exactly Q
        vm.prank(owner);
        wooPP.setFeeRate(WETH, 0);
        uint256 gross = wooPP.query(WETH, USDC, amountIn);

        vm.prank(owner);
        wooPP.setFeeRate(WETH, 1000); // 1%
        uint256 out = wooPP.query(WETH, USDC, amountIn);
        assertLt(out, gross, "fee charged");

        // Leave the quote reserve one unit below output + fee
        uint256 reserve = wooPP.poolSize(USDC);
        vm.prank(owner);
        wooPP.withdraw(USDC, reserve - (gross - 1));
        assertEq(wooPP.poolSize(USDC), gross - 1);

        assertEq(wooPP.query(WETH, USDC, amountIn), out, "raw query still passes");
        PoolId id = _key(WETH, USDC).toId();
        vm.expectRevert(WOOFiAggregator.InsufficientQuoteReserve.selector);
        hook.quote(WETH < USDC, -int256(amountIn), id);
        vm.expectRevert();
        _swap(WETH, USDC, amountIn);

        // output + fee (+1 for the case where two pre-fee amounts round to the same output): quote and swap go through
        deal(USDC, owner, 2);
        vm.startPrank(owner);
        IERC20(USDC).approve(address(wooPP), 2);
        (bool ok,) = address(wooPP).call(abi.encodeWithSignature("deposit(address,uint256)", USDC, 2));
        vm.stopPrank();
        assertTrue(ok, "deposit");
        assertEq(wooPP.poolSize(USDC), gross + 1);
        assertEq(_assertQuoteMatchesSwap(WETH, USDC, amountIn), out);
    }
}
