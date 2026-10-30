// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IWooPPV2} from "./interfaces/IWooPPV2.sol";

/// @title WOOFiAggregator
/// @notice Singleton Uniswap V4 hook that routes swaps through WOOFi's WooPPV2 (sPMM)
/// @dev One WooPPV2 per chain holds every supported token, so one hook serves every pair: base ↔ quote and
///      base ↔ base (WooPP performs base → quote → base internally in one call). All pools share the hook address,
///      which lets routers detect that they touch the same WooPP state.
///      WooPP only supports exact-input swaps of ERC20 tokens; exact-output and native currency revert.
///      WooPP uses a push model: input is taken from the PoolManager straight to WooPP and WooPP sends the output
///      straight to the PoolManager, so tokens never pass through the hook and no approvals are needed.
contract WOOFiAggregator is BaseAggregatorHook {
    /// @notice The only LP fee a pool using this hook may have. See `_beforeInitialize`.
    uint24 public constant POOL_FEE = 0;

    /// @notice The only tick spacing a pool using this hook may have. See `_beforeInitialize`.
    int24 public constant POOL_TICK_SPACING = 1;

    /// @notice The WooPPV2 pool
    IWooPPV2 public immutable wooPP;

    /// @notice PoolKey of each registered pool
    mapping(PoolId => PoolKey) public poolKeys;

    error ExactOutputNotSupported();
    error NativeCurrencyNotSupported();
    error TokensNotSupported(address token0, address token1);
    error InvalidPoolKey();
    error WooPPPaused();

    /// @param _manager The Uniswap V4 PoolManager contract
    /// @param _wooPP The WooPPV2 pool
    constructor(IPoolManager _manager, IWooPPV2 _wooPP) BaseAggregatorHook(_manager, "WOOFiAggregator v1.0") {
        wooPP = _wooPP;
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolKey storage key = poolKeys[poolId];
        if (key.currency0.isAddressZero()) revert PoolDoesNotExist();
        amount0 = wooPP.poolSize(Currency.unwrap(key.currency0));
        amount1 = wooPP.poolSize(Currency.unwrap(key.currency1));
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Quotes via `WooPPV2.query` after checking the pool pause, which `swap` enforces but `query` skips
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        if (amountSpecified >= 0) revert ExactOutputNotSupported();

        PoolKey storage key = poolKeys[poolId];
        if (key.currency0.isAddressZero()) revert PoolDoesNotExist();

        if (wooPP.paused()) revert WooPPPaused();

        (Currency tokenIn, Currency tokenOut) =
            zeroToOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        amountUnspecified = wooPP.query(Currency.unwrap(tokenIn), Currency.unwrap(tokenOut), uint256(-amountSpecified));
    }

    /// @notice Registers a pool; called once per pool when anyone runs `PoolManager.initialize` with this hook
    /// @dev `fee` and `tickSpacing` are the only free PoolKey fields for a given pair, and neither affects trading:
    ///      the hook fills the whole swap, so v4 never charges the LP fee or crosses a tick. Fixing them leaves one
    ///      PoolKey per pair, so the PoolManager (which initializes a PoolKey only once) enforces one pool per pair,
    ///      and nobody can claim a pair first with a misleading fee. Routers can derive the PoolKey directly.
    ///      Each token must be WooPP's quote token or an enabled base token, which also rules out native currency.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (key.fee != POOL_FEE || key.tickSpacing != POOL_TICK_SPACING) revert InvalidPoolKey();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        address quote = wooPP.quoteToken();
        if (!_isSupportedToken(token0, quote) || !_isSupportedToken(token1, quote)) {
            revert TokensNotSupported(token0, token1);
        }

        PoolId poolId = key.toId();
        poolKeys[poolId] = key;

        emit AggregatorPoolRegistered(poolId);
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();

        amountTake = uint256(-params.amountSpecified);

        // Push model: PoolManager → WooPP for input, WooPP → PoolManager for output.
        // Slippage is enforced by the V4 router on the output, so minToAmount is 0. `rebateTo` only feeds
        // WooPP's event; the hook is identifiable as the event's `from`, so it is left unset.
        poolManager.sync(settleCurrency);
        poolManager.take(takeCurrency, address(wooPP), amountTake);
        wooPP.swap(
            Currency.unwrap(takeCurrency),
            Currency.unwrap(settleCurrency),
            amountTake,
            0,
            address(poolManager),
            address(0)
        );
        // Credit what actually arrived at the PoolManager
        amountSettle = poolManager.settle();
        hasSettled = true;
    }

    /// @dev A token is supported if it is the quote token or a base token configured in WooPP
    function _isSupportedToken(address token, address quote) internal view returns (bool) {
        if (token == quote) return true;
        (,,, uint128 maxNotionalSwap,) = wooPP.tokenInfos(token);
        return maxNotionalSwap > 0;
    }

    receive() external payable override {
        revert NativeCurrencyNotSupported();
    }
}
