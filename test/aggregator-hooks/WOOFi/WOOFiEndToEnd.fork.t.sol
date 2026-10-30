// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {IWooracle} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";
import {DeployWOOFiBaseScript} from "../../../script/deploy/woofi/DeployWOOFiBase.s.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev V4Router.ExactInputSingleParams as deployed in the Base Universal Router
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

struct QuoteExactSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

interface IV4Quoter {
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice End-to-end on a Base fork: deploy with the production script (hook salt mined with `cast create2` for
///         the 0x77 ID), accept ownership as the Safe, then trade the way users do: Permit2 + Universal Router
///         (V4_SWAP), quoted through Uniswap's V4Quoter.
/// @dev `FORK_RPC_URL_8453` and optional `FORK_BLOCK_NUMBER_8453`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IUniversalRouter constant UNIVERSAL_ROUTER = IUniversalRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43);
    IV4Quoter constant V4_QUOTER = IV4Quoter(0x0d5e0F971ED27FBfF6c2837bf31316121532048D);
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant WOOFI_SAFE = 0x682F676389BDE27dB6C8a3d8bC6AF0B021E9FfF2;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    uint256 constant MAX_PRICE_AGE = 120;
    uint256 constant SPREAD_PER_SECOND = 1e13; // 0.1 bp per second
    uint256 constant MAX_NOTIONAL_PER_SWAP = 50_000e6;

    DeployWOOFiBaseScript script;
    WOOFiGateway gateway;
    WOOFiAggregator hook;

    address deployer = makeAddr("woofi_deployer");
    address pauser = makeAddr("woofi_pauser");
    address alice = makeAddr("woofi_e2e_alice");

    function setUp() public {
        string memory rpcUrl = vm.envOr("FORK_RPC_URL_8453", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER_8453", uint256(0));
        if (forkBlock > 0) vm.createSelectFork(rpcUrl, forkBlock);
        else vm.createSelectFork(rpcUrl);

        script = new DeployWOOFiBaseScript();
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        DeployWOOFiBaseScript.Config memory config = DeployWOOFiBaseScript.Config({
            hookSalt: _mineHookSalt(script.hookInitCodeHash(deployer)),
            maxPriceAge: MAX_PRICE_AGE,
            spreadPerSecond: SPREAD_PER_SECOND,
            maxNotionalPerSwap: MAX_NOTIONAL_PER_SWAP,
            pausers: pausers
        });
        (gateway, hook) = script.deploy(config, deployer);

        vm.prank(WOOFI_SAFE);
        gateway.acceptOwnership();

        address[] memory tokens = script.tokens();
        for (uint256 i; i < tokens.length; ++i) {
            deal(tokens[i], alice, 1e30);
            vm.startPrank(alice);
            IERC20(tokens[i]).forceApprove(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(tokens[i], address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    /// @dev Mines a salt with the 0x77 ID byte and the hook's permission bits (0x2888), as done before deployment
    function _mineHookSalt(bytes32 initCodeHash) internal returns (bytes32) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "PATH=$PATH:$HOME/.foundry/bin cast create2 --starts-with 77 --ends-with 2888 --deployer ",
            vm.toString(CREATE2_DEPLOYER),
            " --init-code-hash ",
            vm.toString(initCodeHash),
            " | awk '/^Salt:/{print $2}'"
        );
        return bytes32(vm.ffi(cmd));
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

    function _skipIfKeeperLate() internal {
        uint256 postedAt = IWooracle(gateway.wooPP().wooracle()).timestamp();
        if (block.timestamp > postedAt + MAX_PRICE_AGE) vm.skip(true);
    }

    function _quoterQuote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,) = V4_QUOTER.quoteExactInputSingle(
            QuoteExactSingleParams({
                poolKey: _key(tokenIn, tokenOut),
                zeroForOne: tokenIn < tokenOut,
                exactAmount: uint128(amountIn),
                hookData: ""
            })
        );
    }

    /// @dev Exact-in single swap through the Universal Router, as an interface or aggregator would send it
    function _routerSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 gasUsed)
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: _key(tokenIn, tokenOut),
                zeroForOne: tokenIn < tokenOut,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                hookData: ""
            })
        );
        params[1] = abi.encode(Currency.wrap(tokenIn), amountIn);
        params[2] = abi.encode(Currency.wrap(tokenOut), minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);

        vm.prank(alice, alice);
        uint256 gasBefore = gasleft();
        UNIVERSAL_ROUTER.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 60);
        gasUsed = gasBefore - gasleft();
    }

    /// @dev V4Quoter == hook.quote == what the user receives; the user pays exactly amountIn
    function _assertEndToEnd(address tokenIn, address tokenOut, uint256 amountIn) internal {
        _skipIfKeeperLate();
        uint256 quoterOut = _quoterQuote(tokenIn, tokenOut, amountIn);
        uint256 hookQuote = hook.quote(tokenIn < tokenOut, -int256(amountIn), _key(tokenIn, tokenOut).toId());
        assertEq(quoterOut, hookQuote, "V4Quoter matches hook.quote");

        uint256 inBefore = IERC20(tokenIn).balanceOf(alice);
        uint256 outBefore = IERC20(tokenOut).balanceOf(alice);
        uint256 gasUsed = _routerSwap(tokenIn, tokenOut, amountIn, quoterOut);
        assertEq(inBefore - IERC20(tokenIn).balanceOf(alice), amountIn, "paid exactly amountIn");
        assertEq(IERC20(tokenOut).balanceOf(alice) - outBefore, quoterOut, "received the quoted amount");
        console2.log("Universal Router swap gas:", gasUsed);
    }

    // ── Deployment ─────────────────────────────────────────────────────────────

    function test_e2e_deployment() public view {
        assertEq(uint8(uint160(address(hook)) >> 152), 0x77, "hook ID byte");
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, uint160(0x2888), "hook permission bits");
        assertEq(address(hook.gateway()), address(gateway));
        assertEq(gateway.hook(), address(hook));
        assertEq(gateway.owner(), WOOFI_SAFE, "Safe accepted ownership");
        assertEq(gateway.maxPriceAge(), MAX_PRICE_AGE);
        assertEq(gateway.spreadPerSecond(), SPREAD_PER_SECOND);
        assertEq(gateway.maxNotionalPerSwap(), MAX_NOTIONAL_PER_SWAP);
        assertTrue(gateway.isPauser(pauser));

        address[] memory tokens = script.tokens();
        for (uint256 i; i < tokens.length; ++i) {
            assertTrue(gateway.isTokenAllowed(tokens[i]));
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                (,,,, IHooks hooks) = hook.poolKeys(_key(tokens[i], tokens[j]).toId());
                assertEq(address(hooks), address(hook), "pool initialized");
            }
        }
    }

    // ── Trading through the Universal Router ───────────────────────────────────

    function test_e2e_wethToUsdc() public {
        _assertEndToEnd(WETH, USDC, 1e18);
    }

    function test_e2e_usdcToWeth() public {
        _assertEndToEnd(USDC, WETH, 3000e6);
    }

    function test_e2e_usdcToCbbtc() public {
        _assertEndToEnd(USDC, CBBTC, 5000e6);
    }

    function test_e2e_wethToCbbtc() public {
        _assertEndToEnd(WETH, CBBTC, 1e18);
    }

    function test_e2e_slippageProtection_reverts() public {
        _skipIfKeeperLate();
        uint256 quoted = _quoterQuote(WETH, USDC, 1e18);
        vm.expectRevert();
        _routerSwap(WETH, USDC, 1e18, quoted + 1);
    }

    function test_e2e_pausedGateway_quoterAndRouterRevert() public {
        _skipIfKeeperLate();
        vm.prank(pauser);
        gateway.pause();
        vm.expectRevert();
        _quoterQuote(WETH, USDC, 1e18);
        vm.expectRevert();
        _routerSwap(WETH, USDC, 1e18, 0);

        vm.prank(WOOFI_SAFE);
        gateway.unpause();
        _assertEndToEnd(WETH, USDC, 1e18);
    }
}
