# WOOFiAggregator: plugging WOOFi WooPPV2 into Uniswap v4 as an Aggregator Hook

> **Status (2026-10-29): implemented.** Where the implementation differs from the original plan:
> - Unit tests don't use a hand-written MockWooPPV2. They run the **real WooPPV2 bytecode** (`test/aggregator-hooks/WOOFi/precompile/WooPPV2.bin`,
>   from woofi-evm `out_forge`, whose source keccak matches the current `contracts/spmm/WooPPV2.sol`) behind an ERC1967 proxy, paired with `mocks/MockWooracle.sol`.
> - The base→quote pre-fee reconstruction is tightened from "`ceil` upper bound" to "upper bound, then step down to invert `f(Q)` exactly" (at most 2 iterations), leaving at most 1 wei of ambiguity at the boundary.
> - The Arbitrum WooPPV2 in use is **`0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4`** (proxy, implementation `0x7b5fdb8c89a616d319202704b0ea18b168654281`).
>   `0xEd9e3f98…9642` is an old, paused pool. The PoolManager is `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32`.
> - `.env.example` was not changed (reading it was denied). The fork variables are documented in `test/aggregator-hooks/README.md`.

## Context
WOOFi wants WooPPV2 (sPMM, an oracle-priced single pool holding many tokens) to show up as liquidity in Uniswap v4,
so Uniswap routing (Routing API / Universal Router) can send orders straight to WooPP. This repo already has a
complete Aggregator Hook framework (`src/aggregator-hooks/`). Every external protocol gets one `BaseAggregatorHook`
subclass that uses `beforeSwap` + `beforeSwapReturnDelta` to fully replace v4's own AMM math, and swaps entirely
against the external liquidity. The goal is to add a `WOOFiAggregator` following the same pattern, with tests,
the mining script, and documentation.

Decisions confirmed with the user:
- **Exact-in only**: exact-out reverts with `ExactOutputNotSupported` (precedent: `StableSwapAggregator`)
- **All pairs WooPP supports**: base↔quote and base↔base
- **ERC20 only**: native ETH reverts with `NativeCurrencyNotSupported` (precedent: UniswapV2/V3 Aggregator)
- **Arbitrum** first, for fork tests and deployment

## How WooPP is shaped (from reading woofi-evm)
- `WooPPV2.swap(from, to, fromAmount, minToAmount, to, rebateTo)` uses a **push model**: the caller transfers
  `fromToken` to WooPP first, and WooPP checks `balance - reserve >= fromAmount`. There is no callback and no approve.
- It routes internally by token: quote→base / base→quote / base→base (one call does the two legs).
- `query()` is a view that includes the cap, reserve and swapFee checks; `tryQuery()` skips the reserve check.
- Swap preconditions: Wooracle `woFeasible` (price not stale, within the CL oracle bound, oracle not paused),
  `maxNotionalSwap`, `maxGamma`, `capBal`, WooPP not paused, `tx.gasprice <= maxGasPrice`, and neither
  tx.origin nor msg.sender blacklisted.
- `feeRateMultiplier = max(multiplier[tx.origin], multiplier[msg.sender])`. msg.sender is the hook, so WOOFi can
  give Uniswap flow its own fee tier with `setFeeRateMultiplier(hook, x)` (an ops lever, no code change).
- Pool depth: `tokenInfos[token].reserve` / `poolSize(token)`.

## Design

### New files
```
src/aggregator-hooks/implementations/WOOFi/
├── WOOFiAggregator.sol
└── interfaces/IWooPPV2.sol      # minimal interface: swap/query/tryQuery/quoteToken/poolSize/tokenInfos/paused
```
Following the README rule ("strict 1-1 mapping → singleton, no factory"): WooPP is a single contract on each
chain, so there is **one hook per chain and no Factory**. Every pair shares one hook address, which lets routers
spot that a route touches WooPP state more than once.

### `WOOFiAggregator is BaseAggregatorHook` (pragma 0.8.29, same as the other implementations)
- immutables: `IWooPPV2 wooPP`, `address rebateTo` (WOOFi's attribution address, a constructor argument)
- storage: `mapping(PoolId => PoolTokens) poolIdToTokens` and `mapping(bytes32 => PoolId) _canonicalPoolByPair`
  (copy TempoExchangeAggregator's `_canonicalPairKey` approach directly)
- `aggregatorHookVersion = "WOOFiAggregator v1.0"`

**`_beforeInitialize`**
1. Revert `NativeCurrencyNotSupported` if either currency is address(0)
2. Validate the pair: at least one side is a base token (`tokenInfos[t].maxNotionalSwap > 0`, or
   `t == quoteToken`). Then do a `tryQuery(token0, token1, 1-unit)` probe inside try/catch, and revert
   `TokensNotSupported` if it fails (same as Tempo, so fake tokens can't get registered)
3. One canonical pool per pair → revert `PairAlreadyHasCanonicalPool` on a second one
4. Store `poolIdToTokens`, emit `AggregatorPoolRegistered`, call `pollTokenJar()`
- No approve needed (push model)

**`_rawQuote`**
- `amountSpecified >= 0` → revert `ExactOutputNotSupported`
- exact-in: `wooPP.query(tokenIn, tokenOut, amountIn)`. It is called from the hook, so msg.sender = hook and the
  fee multiplier matches the real swap. `BaseAggregatorHook.quote()` then applies the Uniswap protocol fee on top.
- **Executability checks** (WooPPV2 `query()` is missing these relative to `swap()`; add them in a hook helper
  `_assertSwappable`, so a quote that passes can also be filled):
  1. `wooPP.paused()` → revert `WooPPPaused` (swap has `whenNotPaused`, query does not.
     Wooracle being paused already makes query revert, so no extra check is needed for that)
  2. `wooPP.blacklist(address(this)) || wooPP.blacklist(tx.origin)` → revert `Blacklisted`
  3. `tx.gasprice > wooPP.maxGasPrice()` → revert `GasPriceTooHigh` (parity with swap. The gas price at
     simulation time is the simulating caller's, so this only ensures what the caller saw)
  4. **base→quote reserve boundary**: swap does `reserve[quote] -= quoteAmountAfterFee + swapFee`, but query only
     checks the two terms against reserve **separately**. The hook rebuilds the pre-fee amount and checks the sum:
     `r = feeRate(base) * max(mult[tx.origin], mult[hook])` (a multiplier of 0 is treated as 1e5);
     `grossUpper = ceil(toAmount * 1e10 / (1e10 - r))`;
     `grossUpper > tokenInfos(quoteToken).reserve` → revert `InsufficientQuoteReserve`.
     Since `toAmount = Q - floor(Q·r/1e10) ≥ Q·(1 - r/1e10)`, `grossUpper ≥` the real `Q = quoteAmountAfterFee + swapFee`.
     It's a conservative upper bound that misjudges by at most a few wei at the boundary, so it never lets an unfillable quote through.
     quote→base (`reserve[base] -= baseAmount`) and base→base (`reserve[quote] -= swapFee`, `reserve[base2] -= base2Amount`)
     already match query's checks and don't need this.
- `_conductSwap` does not repeat these checks (if swap itself reverts, the whole thing reverts, and no funds are lost)
- **Long-term root fix (optional, on the WOOFi side)**: upgrade the WooPPV2 implementation so `query()` adds
  `whenNotPaused`/blacklist/gasprice checks and changes the base→quote check to `toAmount + swapFee > reserve`.
  Once that ships, the hook helper becomes a redundant safety net and can stay.

**`_conductSwap`** (exact-in, zero extra transfers):
```
poolManager.sync(settleCurrency);
poolManager.take(takeCurrency, address(wooPP), amountIn);           // PM → WooPP directly
amountSettle = wooPP.swap(tokenIn, tokenOut, amountIn, 0, address(poolManager), rebateTo); // WooPP → PM directly
poolManager.settle();                                                // credits the amount that actually arrived
hasSettled = true;
```
- `minToAmount = 0`: slippage protection is enforced by the v4 router on the output, same as the other aggregators
- For `amountSettle`, use the PM balance difference rather than the return value, which guards against tokens
  with a transfer tax (same as UniswapV2Aggregator)

**`pseudoTotalValueLocked`**: `(wooPP.poolSize(token0), wooPP.poolSize(token1))`

**`receive()`**: revert `NativeCurrencyNotSupported`

`protocolFeeFlags()` keeps the default `1 << 11`. Whether a dedicated classification is needed is up to the Uniswap side.

### Address ID
`W` isn't a hex character, so we propose **`0x77`** (ASCII `'w'`). Confirm with the Uniswap maintainers when the PR goes up.

### Changes to existing files
- `script/MineAggregatorHook.s.sol`: add `ID_WOOFI = 0x77` and a branch for it
- `src/aggregator-hooks/README.md`: add `77 | WOOFi (WooPPV2)` to the ID table, plus a "WOOFi" section (singleton, exact-in
  only, ERC20 only, oracle-priced, conditions that cause a revert)
- `test/aggregator-hooks/README.md` + `.env.example`: Arbitrum fork variables `FORK_RPC_URL_42161`,
  `FORK_BLOCK_NUMBER_42161`, `POOL_MANAGER_42161`, `WOOPP_42161`
- Root `README.md` Hooks table / Deployments (after deployment)

## Tests (meeting test/aggregator-hooks/README.md: 100% unit coverage + fork + fuzz, with USDT covered at least once)
```
test/aggregator-hooks/WOOFi/
├── mocks/MockWooPPV2.sol                  # replicates WooPPV2 query/swap reserve bookkeeping 1:1 (including line 441's subtraction of the sum);
│                                          #   can be set to pause/blacklist/maxGasPrice/cap
├── WOOFiAggregatorUnitTest.t.sol          # init validation, duplicate pool, native rejection, exact-out revert,
│                                          #   quote == swap, protocol fee, TVL, WooPP revert passing through
├── WOOFiAggregatorForkTest.fork.t.sol     # Arbitrum real WooPP: USDC↔WETH, WETH↔WBTC (base↔base), USDT pair
└── WOOFiAggregatorFuzz.fork.t.sol         # fuzz on fork: amountIn ∈ [min, maxNotional], quote == actual output
```
- Unit tests reuse `test/aggregator-hooks/mocks/MockV4FeeAdapter.sol` and `shared/SafePoolSwapTest.sol`, and
  follow the structure of `LitePSM/LitePSMAggregatorUnitTest.t.sol`
- **Quote executability regression tests** (unit + fork):
  - base→quote, output 99 + fee 1, quote reserve 99: raw `query()` passes, but `hook.quote()` must revert
    `InsufficientQuoteReserve`; reserve = 100 passes and the swap succeeds (boundary is just enough)
  - WooPP paused / hook blacklisted / tx.origin blacklisted / `vm.txGasPrice` > maxGasPrice:
    `quote()` reverts with the matching error, and so does the real swap
  - fuzz invariant: **`quote()` succeeds ⇒ the v4 swap with the same parameters succeeds right after, and the output equals the quote**
- **Confirm the target deployment**: on the Arbitrum fork, read the WooPP proxy's implementation (EIP-1967 slot),
  and check against the verified source that `query`/`_sellBase` reserve logic matches local woofi-evm
  (`WooPPV2.sol:150-174`, `:441`). On the fork, use admin `withdraw` to drain the quote reserve right up to the
  boundary and reproduce the case above.
- Fork tests: Wooracle prices go stale after 300s. Don't `vm.warp` after pinning the block, or the test should
  first prank the Wooracle admin and `postState` a fresh price
- WooPPV2 itself isn't compiled locally (it depends on OZ-upgradeable + v3-periphery). The fork tests run
  against the real contract.

## Verification
```bash
FOUNDRY_PROFILE=aggregator_hooks forge build
FOUNDRY_PROFILE=aggregator_hooks forge test --match-path "test/aggregator-hooks/WOOFi/*"
FOUNDRY_PROFILE=aggregator_hooks forge coverage --match-path "test/aggregator-hooks/WOOFi/*"   # 100% for WOOFiAggregator
PROTOCOL_ID=0x77 CONSTRUCTOR_ARGS=$(cast abi-encode "f(address,address,address)" $PM $WOOPP $REBATE) \
  forge script script/MineAggregatorHook.s.sol
```
The fork tests check that the output of `quote()` (via `query`) exactly equals the actual v4 swap output, and
that the WooSwap event's `to == PoolManager` and `rebateTo` are correct.

## Risks / ops notes (not blocking)
- Quotes come from oracle prices. If the oracle is stale or out of bound, both quote and swap revert, and the router skips the pool automatically.
- Large orders hit `maxNotionalSwap`/`maxGamma` and revert, so the router has to split them.
- WooPP is a proxy. A `migrateToNewPool` to a new contract would need a new hook deployment.
- `maxGasPrice` gas-price ceiling: if gas spikes on-chain, a swap through the hook reverts too.
