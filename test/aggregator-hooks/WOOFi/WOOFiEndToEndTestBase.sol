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
import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {WOOFiForkUtils} from "./WOOFiForkUtils.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev V4Router.ExactInputSingleParams as deployed in Universal Router V2.0
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @dev V4Router.ExactInputSingleParams as deployed in Universal Router V2.1.x, which adds a per-hop price limit
struct ExactInputSingleParamsV2_1 {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
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

/// @notice End-to-end on a chain fork: deploy with the chain's production script (hook salt mined with
///         `cast create2` for the 0x77 ID), take gateway ownership the way the script leaves it, then trade the way
///         users do: Permit2 + Universal Router (V4_SWAP), quoted through Uniswap's V4Quoter. Chain tests supply the
///         script, the live Uniswap contracts (Universal Router V2.0, or V2.1.x where the chain has no V2.0) and the
///         trades.
/// @dev `FORK_RPC_URL_<chain id>` and optional `FORK_BLOCK_NUMBER_<chain id>`; skips when the RPC is unset. Needs
///      `cast` (ffi).
abstract contract WOOFiEndToEndTestBase is WOOFiForkUtils {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint8 constant V4_SWAP = 0x10;
    uint8 constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant SETTLE_ALL = 0x0c;
    uint8 constant TAKE_ALL = 0x0f;

    uint256 constant MAX_PRICE_AGE = 120;
    uint256 constant SPREAD_PER_SECOND = 1e13; // 0.1 bp per second
    uint256 constant MAX_NOTIONAL_PER_SWAP = 50_000e6;

    WOOFiDeployScript script;
    WOOFiGateway gateway;
    WOOFiAggregator hook;
    /// @dev The gateway owner once deployed: whoever the script offers ownership to (accepted here), else the deployer
    address owner;

    address deployer = makeAddr("woofi_deployer");
    address pauser = makeAddr("woofi_pauser");
    address alice = makeAddr("woofi_e2e_alice");

    function _chainId() internal pure virtual returns (uint256);

    function _newScript() internal virtual returns (WOOFiDeployScript);

    function _universalRouter() internal pure virtual returns (IUniversalRouter);

    /// @dev Whether `_universalRouter` is V2.1.x, whose exact-in params carry `minHopPriceX36`
    function _routerIsV2_1() internal pure virtual returns (bool) {
        return false;
    }

    function _v4Quoter() internal pure virtual returns (IV4Quoter);

    /// @dev A liquid trade for the slippage and pause tests
    function _referenceTrade() internal pure virtual returns (address tokenIn, address tokenOut, uint256 amountIn);

    function setUp() public {
        string memory chainId = vm.toString(_chainId());
        string memory rpcUrl = vm.envOr(string.concat("FORK_RPC_URL_", chainId), string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr(string.concat("FORK_BLOCK_NUMBER_", chainId), uint256(0));
        if (forkBlock > 0) vm.createSelectFork(rpcUrl, forkBlock);
        else vm.createSelectFork(rpcUrl);

        script = _newScript();
        address[] memory pausers = new address[](1);
        pausers[0] = pauser;
        WOOFiDeployScript.Config memory config = WOOFiDeployScript.Config({
            hookSalt: _mineHookSalt(script.hookInitCodeHash(deployer)),
            maxPriceAge: MAX_PRICE_AGE,
            spreadPerSecond: SPREAD_PER_SECOND,
            maxNotionalPerSwap: MAX_NOTIONAL_PER_SWAP,
            pausers: pausers
        });
        (gateway, hook) = script.deploy(config, deployer);

        owner = script.nextOwner();
        if (owner == address(0)) {
            owner = deployer;
        } else {
            vm.prank(owner);
            gateway.acceptOwnership();
        }

        address[] memory tokens = script.tokens();
        address quoteToken = gateway.wooPP().quoteToken();
        address[] memory bases = new address[](tokens.length - 1);
        uint256 n;
        for (uint256 i; i < tokens.length; ++i) {
            deal(tokens[i], alice, 1e30);
            vm.startPrank(alice);
            IERC20(tokens[i]).forceApprove(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(tokens[i], address(_universalRouter()), type(uint160).max, type(uint48).max);
            vm.stopPrank();
            if (tokens[i] != quoteToken) bases[n++] = tokens[i];
        }

        // Trade at a known price age regardless of when the keeper last posted at the fork block
        _setWooracleAge(gateway.wooPP().wooracle(), bases, 10);
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
            " 2>&1 | grep -oE '0x[0-9a-fA-F]{64}' | tail -1"
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

    function _quoterQuote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,) = _v4Quoter()
            .quoteExactInputSingle(
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
        params[0] = _routerIsV2_1()
            ? abi.encode(
                ExactInputSingleParamsV2_1({
                    poolKey: _key(tokenIn, tokenOut),
                    zeroForOne: tokenIn < tokenOut,
                    amountIn: uint128(amountIn),
                    amountOutMinimum: uint128(minOut),
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
            : abi.encode(
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

        IUniversalRouter router = _universalRouter();
        vm.prank(alice, alice);
        uint256 gasBefore = gasleft();
        router.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 60);
        gasUsed = gasBefore - gasleft();
    }

    /// @dev V4Quoter == hook.quote == what the user receives; the user pays exactly amountIn
    function _assertEndToEnd(address tokenIn, address tokenOut, uint256 amountIn) internal {
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
        assertEq(address(hook.poolManager()), address(script.poolManager()));
        assertEq(gateway.hook(), address(hook));
        assertEq(gateway.owner(), owner, "gateway owner");
        assertEq(gateway.pendingOwner(), address(0), "no ownership handoff left pending");
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

    /// @dev Anyone can deploy the gateway's init code through the public CREATE2 deployer first; the script reuses
    ///      that (identical, deployer-owned) contract instead of failing
    function test_e2e_deployAfterGatewayFrontRun() public {
        address otherDeployer = makeAddr("woofi_other_deployer");
        address predicted = script.gatewayAddress(otherDeployer);
        (bool ok,) = CREATE2_DEPLOYER.call(
            abi.encodePacked(
                keccak256("WOOFiGateway"), type(WOOFiGateway).creationCode, abi.encode(gateway.wooPP(), otherDeployer)
            )
        );
        assertTrue(ok && predicted.code.length > 0, "front-run deployment");

        WOOFiDeployScript.Config memory config = WOOFiDeployScript.Config({
            hookSalt: _mineHookSalt(script.hookInitCodeHash(otherDeployer)),
            maxPriceAge: MAX_PRICE_AGE,
            spreadPerSecond: SPREAD_PER_SECOND,
            maxNotionalPerSwap: MAX_NOTIONAL_PER_SWAP,
            pausers: new address[](0)
        });
        (WOOFiGateway reused, WOOFiAggregator otherHook) = script.deploy(config, otherDeployer);
        assertEq(address(reused), predicted, "reused the front-run gateway");
        assertEq(reused.hook(), address(otherHook));
        assertEq(reused.owner(), otherDeployer);
        assertEq(reused.pendingOwner(), script.nextOwner());
    }

    // ── Trading through the Universal Router ───────────────────────────────────

    function test_e2e_slippageProtection_reverts() public {
        (address tokenIn, address tokenOut, uint256 amountIn) = _referenceTrade();
        uint256 quoted = _quoterQuote(tokenIn, tokenOut, amountIn);
        vm.expectRevert();
        _routerSwap(tokenIn, tokenOut, amountIn, quoted + 1);
    }

    function test_e2e_pausedGateway_quoterAndRouterRevert() public {
        (address tokenIn, address tokenOut, uint256 amountIn) = _referenceTrade();
        vm.prank(pauser);
        gateway.pause();
        vm.expectRevert();
        _quoterQuote(tokenIn, tokenOut, amountIn);
        vm.expectRevert();
        _routerSwap(tokenIn, tokenOut, amountIn, 0);

        vm.prank(owner);
        gateway.unpause();
        _assertEndToEnd(tokenIn, tokenOut, amountIn);
    }
}
