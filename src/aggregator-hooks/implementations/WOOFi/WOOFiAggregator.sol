// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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
    /// @dev WooPP fee rate denominator (1e5) times fee rate multiplier denominator (1e5)
    uint256 internal constant FEE_DENOMINATOR = 1e10;
    /// @dev WooPP's default fee rate multiplier, applied when none is configured
    uint256 internal constant BASE_MULTIPLIER = 1e5;

    /// @notice The WooPPV2 pool
    IWooPPV2 public immutable wooPP;

    /// @notice Address passed to WooPP as `rebateTo` for volume attribution
    address public immutable rebateTo;

    /// @notice Token pair info for each registered pool
    struct PoolTokens {
        address token0;
        address token1;
    }

    /// @notice Maps Uniswap V4 pool IDs to their token addresses
    mapping(PoolId => PoolTokens) public poolIdToTokens;

    /// @notice Canonical pool per token pair (key = keccak256(abi.encode(ordered token0, ordered token1)))
    /// @dev Enforces one pool per pair
    mapping(bytes32 => PoolId) private _canonicalPoolByPair;

    error ExactOutputNotSupported();
    error NativeCurrencyNotSupported();
    error TokensNotSupported(address token0, address token1);
    error PairAlreadyHasCanonicalPool(PoolId existingPoolId, address token0, address token1);
    error WooPPPaused();
    error Blacklisted();
    error GasPriceTooHigh();
    error InsufficientQuoteReserve();

    /// @param _manager The Uniswap V4 PoolManager contract
    /// @param _wooPP The WooPPV2 pool
    /// @param _rebateTo Address passed to WooPP as `rebateTo` on every swap
    constructor(IPoolManager _manager, IWooPPV2 _wooPP, address _rebateTo)
        BaseAggregatorHook(_manager, "WOOFiAggregator v1.0")
    {
        wooPP = _wooPP;
        rebateTo = _rebateTo;
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0)) revert PoolDoesNotExist();
        amount0 = wooPP.poolSize(tokens.token0);
        amount1 = wooPP.poolSize(tokens.token1);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Quotes via `WooPPV2.query` (called from the hook, so the hook's fee rate multiplier applies exactly as in
    ///      the swap), then checks the swap-only conditions `query` skips. See `_assertSwappable`.
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        if (amountSpecified >= 0) revert ExactOutputNotSupported();

        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0)) revert PoolDoesNotExist();

        (address tokenIn, address tokenOut) =
            zeroToOne ? (tokens.token0, tokens.token1) : (tokens.token1, tokens.token0);

        amountUnspecified = wooPP.query(tokenIn, tokenOut, uint256(-amountSpecified));
        _assertSwappable(tokenIn, tokenOut, amountUnspecified);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Native currency always sorts as currency0
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Every non-quote token must be configured as a base token in WooPP
        address quote = wooPP.quoteToken();
        if (!_isSupportedToken(token0, quote) || !_isSupportedToken(token1, quote)) {
            revert TokensNotSupported(token0, token1);
        }

        // Confirm WooPP can actually price the pair (oracle knows every base token)
        try wooPP.tryQuery(token0, token1, 1) {}
        catch {
            revert TokensNotSupported(token0, token1);
        }

        // Enforce one canonical pool per token pair
        bytes32 pairKey = _canonicalPairKey(token0, token1);
        PoolId existing = _canonicalPoolByPair[pairKey];
        if (PoolId.unwrap(existing) != bytes32(0)) revert PairAlreadyHasCanonicalPool(existing, token0, token1);
        _canonicalPoolByPair[pairKey] = key.toId();

        poolIdToTokens[key.toId()] = PoolTokens({token0: token0, token1: token1});

        emit AggregatorPoolRegistered(key.toId());
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
        // Slippage is enforced by the V4 router on the output, so minToAmount is 0.
        poolManager.sync(settleCurrency);
        poolManager.take(takeCurrency, address(wooPP), amountTake);
        wooPP.swap(
            Currency.unwrap(takeCurrency),
            Currency.unwrap(settleCurrency),
            amountTake,
            0,
            address(poolManager),
            rebateTo
        );
        // Credit what actually arrived at the PoolManager
        amountSettle = poolManager.settle();
        hasSettled = true;
    }

    /// @notice Reverts if WooPP would reject a swap that `query` accepted
    /// @dev `WooPPV2.query` skips checks that `swap` enforces:
    ///      - pool pause (`whenNotPaused`), blacklist of `tx.origin`/`msg.sender`, and `tx.gasprice <= maxGasPrice`
    ///      - base → quote: `query` checks the output and the swap fee against the quote reserve separately, while
    ///        `swap` subtracts their sum, so e.g. output 99 + fee 1 against reserve 99 quotes but underflows on swap.
    ///      For base → quote the pre-fee amount `Q = output + fee` is rebuilt from the output by inverting
    ///      `output = f(Q) = Q - floor(Q * r / 1e10)`. Since `f(Q) >= Q * (1 - r / 1e10)`, every `Q` with
    ///      `f(Q) = output` is at most `ceil(output * 1e10 / (1e10 - r))`; stepping that bound down while
    ///      `f(gross) > output` (at most twice) yields the largest such `Q`. When two `Q` map to the same output the
    ///      larger is checked, so the bound may reject a fillable swap by 1 wei but never accepts an unfillable one.
    ///      quote → base and base → base reserve checks in `query` already match `swap`.
    ///      Wooracle pause and staleness already make `query` revert.
    function _assertSwappable(address tokenIn, address tokenOut, uint256 amountOut) internal view {
        if (wooPP.paused()) revert WooPPPaused();
        if (wooPP.blacklist(address(this)) || wooPP.blacklist(tx.origin)) revert Blacklisted();
        if (tx.gasprice > wooPP.maxGasPrice()) revert GasPriceTooHigh();

        address quote = wooPP.quoteToken();
        if (tokenOut != quote) return;

        (, uint16 feeRate,,,) = wooPP.tokenInfos(tokenIn);
        uint256 rate = uint256(feeRate) * _feeRateMultiplier();
        // rate >= 1e10 means fee >= pre-fee amount; `query` then either underflows or yields output 0 with
        // fee == pre-fee amount, which its own fee-vs-reserve check already covers.
        if (rate >= FEE_DENOMINATOR) return;

        uint256 gross = FullMath.mulDivRoundingUp(amountOut, FEE_DENOMINATOR, FEE_DENOMINATOR - rate);
        while (gross - gross * rate / FEE_DENOMINATOR > amountOut) {
            --gross;
        }
        (uint192 quoteReserve,,,,) = wooPP.tokenInfos(quote);
        if (gross > quoteReserve) revert InsufficientQuoteReserve();
    }

    /// @dev Mirrors `WooPPV2._getFeeRateMultiplier` for a swap sent by this hook
    function _feeRateMultiplier() internal view returns (uint256 multiplier) {
        uint256 originMultiplier = wooPP.feeRateMultipliers(tx.origin);
        uint256 hookMultiplier = wooPP.feeRateMultipliers(address(this));
        multiplier = originMultiplier > hookMultiplier ? originMultiplier : hookMultiplier;
        if (multiplier == 0) multiplier = BASE_MULTIPLIER;
    }

    /// @dev A token is supported if it is the quote token or a base token configured in WooPP
    function _isSupportedToken(address token, address quote) internal view returns (bool) {
        if (token == quote) return true;
        (,,, uint128 maxNotionalSwap,) = wooPP.tokenInfos(token);
        return maxNotionalSwap > 0;
    }

    /// @notice Returns the canonical storage key for a token pair (ordered by address)
    function _canonicalPairKey(address token0, address token1) private pure returns (bytes32) {
        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(t0, t1));
    }

    receive() external payable override {
        revert NativeCurrencyNotSupported();
    }
}
