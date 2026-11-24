## Uniswap V4 Hooks

This repository contains the official Uniswap v4 hook contracts developed and maintained by Uniswap Labs. New hooks will be added to this repository as they are built and audited.

## Table of Contents

- [Overview](#overview)
- [Hooks](#hooks)
- [Installation](#installation)
- [Deployments](#deployments)
- [Audits](#audits)
- [Docs](#docs)
- [Contributing](#contributing)
- [License](#license)

## Overview

[Hooks](https://docs.uniswap.org/contracts/v4/concepts/hooks) are external contracts that can be attached to Uniswap V4 pools to customize their behavior at key points in the pool lifecycle. This repository houses all Uniswap hook implementations built on top of v4-core.

## Hooks

| Hook                                                  | Description                                                                                                                                            |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [StablePairHook](src/stable/StablePairHook.sol)       | Dynamic fee hook for pools of two assets expected to hold the same price, with optimal range pricing and time-decaying fees                            |
| [VolatilePairHook](src/volatile/VolatilePairHook.sol) | Dynamic fee hook for volatile pairs such as ETH/USDC, with separate ask and bid fees that lean toward the last price move and an extra fee on backruns |
| [WETHHook](src/WETHHook.sol)                          | Wraps ETH to WETH and unwraps WETH to ETH through a Uniswap v4 pool at a 1:1 rate with zero fees                                                       |
| [WstETHHook](src/WstETHHook.sol)                      | Wraps stETH to wstETH and back through a Uniswap v4 pool, handling the dynamic exchange rate and rebasing rounding errors                              |
| [WstETHRoutingHook](src/WstETHRoutingHook.sol)        | Companion to `WstETHHook` that enables swap simulation via the V4 Quoter, computing wrapping output without executing token transfers                  |

## Installation

```bash
forge install
forge build
forge test --isolate
```

## Deployments

### WETHHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0x57991106cb7aa27e2771beda0d6522f68524a888 | c797b9e     |
| Unichain | 0x730b109bad65152c67ecc94eb8b0968603dba888 | c797b9e     |
| Optimism | 0x480dafdb4d6092ef3217595b75784ec54b52e888 | c797b9e     |
| Base     | 0xb08211d57032dd10b1974d4b876851a7f7596888 | c797b9e     |
| Arbitrum | 0x2a4adf825bd96598487dbb6b2d8d882a4eb86888 | c797b9e     |
| Monad    | 0x3fad8a7205f943528915e67cf94fc792c8fce888 | efab318     |

### WstETHHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0xcdde8f9c3414a00f804e5c565eed9949ad17e888 | 320811c     |

### WstETHRoutingHook

| Network  | Address                                    | Commit Hash |
| -------- | ------------------------------------------ | ----------- |
| Ethereum | 0x3ac6e14a142251eb3fe739399e0a8da81ed06888 | 320811c     |

### StablePairHook

The registered v4 hook is the ERC1967 proxy — its address is permanent and carries the hook flags.
The implementation behind it changes on UUPS upgrades, so the implementation column reflects the
current implementation as of the listed commit.

| Network  | Proxy (hook)                               | Implementation                             | Commit Hash | Date       |
| -------- | ------------------------------------------ | ------------------------------------------ | ----------- | ---------- |
| Ethereum | 0x0000113dCf4ADd69999Fad8F20F2b63F979bfcC0 | 0x5f216d21b1C81346938EDDc1Df7e0111A0F64000 | ecb8c96     | 2026-07-27 |
| Arbitrum | 0x630e9CaC0ffF557Bd3A01DAa111ed253c771Bcc0 | 0x424e2f8D89eeaB51AF10669D149Fbd4BEB090000 | ecb8c96     | 2026-10-05 |
| X Layer  | 0x630e9CaC0ffF557Bd3A01DAa111ed253c771Bcc0 | 0x424e2f8D89eeaB51AF10669D149Fbd4BEB090000 | ecb8c96     | 2026-10-20 |
| Sepolia  | 0x2F45A94782d3e187BaB5F72448bb85d6d1d67CC0 | 0xDBc81fFadaB5ee9c9fB1c2D43Bef547EB9c64000 | 7abd34b     | 2026-07-22 |

`owner` and `configManager` are the [Uniswap Governance Timelock](https://etherscan.io/address/0x1a9C8182C09F50C8318d769245beA52c32BE35BC),
so fee-config changes and implementation upgrades go through a governance proposal.
On Arbitrum and X Layer they are the Timelock's L1-to-L2 alias `0x2BAD8182C09F50c8318d769245beA52C32Be46CD`
([Arbiscan](https://arbiscan.io/address/0x2BAD8182C09F50c8318d769245beA52C32Be46CD), [OKLink](https://www.oklink.com/x-layer/address/0x2BAD8182C09F50c8318d769245beA52C32Be46CD)),
so the same governance proposals reach them through each chain's bridge.
On Sepolia, `owner`, `poolInitializer` and `configManager` are all the test deployer
`0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95`.

On Robinhood Chain only the implementation is deployed, at `0xaF7895228C7E5ea4FA60d6CB7E42eedC99e94000`
(commit ecb8c96)

#### Pools

Pools initialized on the StablePairHook, on each network's hook from the table above. Every pool uses the
dynamic-fee flag (`0x800000`) and a `tickSpacing` of 1, so the pool ID is `keccak256(abi.encode(PoolKey))`
over the values below.

| Network  | Pool       | Currency0                                          | Currency1                                          | Pool ID                                                            | Date       |
| -------- | ---------- | -------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------ | ---------- |
| Ethereum | USDC/USDT  | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`  | USDT `0xdAC17F958D2ee523a2206206994597C13D831ec7`  | 0x2b21c65d9a7dc6926ee330a1c6e5a8037fd81774f3dc066536f800128e39f634 | 2026-09-10 |
| Ethereum | USDC/USDG  | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`  | USDG `0xe343167631d89B6Ffc58B88d6b7fB0228795491D`  | 0xeda62d2906d0edf26d40c793d581609552a44a87f618a98ff76ebe8dde4b7edb | 2026-09-10 |
| Arbitrum | USDG/USDC  | USDG `0x004B506865409877C9fA29bfb1ebA929984B9bbC`  | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`  | 0x52b42d5f1e4a0d4bce86667bb069cf257e512d98ce617f549f6e4fbb0bee41e6 | 2026-10-05 |
| X Layer  | USDG/USDT0 | USDG `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8`  | USDT0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | 0x472a136cc430cb6fc27870fe8e973a2891abc619752fabbdc4d78cf887cd0851 | 2026-10-21 |
| X Layer  | USDT0/USDC | USDT0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | USDC `0xB6CEceAB302E2E4948951eE7843FC24E92933061`  | 0xc3157901d6cdc7ddc8e0e99d03494aab58126bac3e09bad5d107f59fc81a6456 | 2026-10-22 |
| X Layer  | USDG/USDC  | USDG `0x4ae46a509F6b1D9056937BA4500cb143933D2dc8`  | USDC `0xB6CEceAB302E2E4948951eE7843FC24E92933061`  | 0x97b14788c981b4c79f3fe4d8a3725a2364e03ae56cab6cae4b3ac31c86d73fea | 2026-10-22 |

### VolatilePairHook

Same proxy layout as `StablePairHook`: the ERC1967 proxy is the registered v4 hook and the
implementation column reflects the current implementation as of the listed commit.

| Network  | Proxy (hook)                               | Implementation                             | Commit Hash | Date       |
| -------- | ------------------------------------------ | ------------------------------------------ | ----------- | ---------- |
| Ethereum | 0x000022Ec4eBD6b12294396E852E4C3876b253Cc0 | 0x1DDbf7215be4F8A7623B9B1B0255C6e1E3F6c000 | a053a88     | 2026-10-13 |
| Sepolia  | 0x6B1DF823F9492000cC6Bc8dB2c1714E767DaFCc0 | 0x01C274A3Ea7CdA08c90140395349004cEf28C000 | ba9a531     | 2026-10-13 |

On Ethereum, `owner` and `configManager` are the [Uniswap Governance Timelock](https://etherscan.io/address/0x1a9C8182C09F50C8318d769245beA52c32BE35BC),
so fee-config changes and implementation upgrades go through a governance proposal. `poolInitializer`
is the Labs Safe `0xFc43582532E90Fa8726FE9cdb5FAd48f4e487d27`.

On Sepolia, `owner`, `poolInitializer` and `configManager` are all the test deployer
`0xE49ACc3B16c097ec88Dc9352CE4Cd57aB7e35B95`.

#### Pools

Pools initialized on the Ethereum hook. Every pool uses the dynamic-fee flag (`0x800000`) and a
`tickSpacing` of 4, so the pool ID is `keccak256(abi.encode(PoolKey))` over the values below.

| Pool     | Currency0                                        | Currency1                                         | Pool ID                                                            | Date       |
| -------- | ------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------ | ---------- |
| ETH/USDC | ETH `0x0000000000000000000000000000000000000000` | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 0x98316e8405502774a5d0a0761276b5d26505a8195c1905169864008d5e7a3eea | 2026-10-13 |

### WOOFiAggregator

The hook calls WooPPV2 (`0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4` on every chain) through a WOOFi-owned
WOOFiGateway. The gateway has the same address on every chain (same deployer, CREATE2 salt and bytecode); the hook's
address commits to the chain's PoolManager, so it differs per chain. On every chain the gateway runs with a 90s max
price age, no age spread and a 10,000 USDC per-swap cap, and the deployer
`0xc031C368b51c28266396273b0C6ce2489b00969d` is a pauser.

- **Base**: the gateway was deployed closed (max price age, spread and per-swap notional cap all 0) and opened on
  2026-11-04. Ownership is pending to the WOOFi 3/6 Safe `0x682F676389BDE27dB6C8a3d8bC6AF0B021E9FfF2`, which must
  call `acceptOwnership`.
- **Arbitrum, Optimism, Polygon**: deployed open on 2026-11-24. The deployer stays owner until ownership moves to the
  WOOFi Safe on every chain at once.

| Network  | Hook                                       | Gateway                                    | Commit Hash | Date       |
| -------- | ------------------------------------------ | ------------------------------------------ | ----------- | ---------- |
| Base     | 0x77132a6b5760651447DA262B1180430Ae84e2888 | 0xB2781074F5da0b30f9004ed7eCf1c3933477AE42 | 41adf20     | 2026-11-04 |
| Arbitrum | 0x772d41Ff3325b5457be90cD79f0dD5C56Be12888 | 0xB2781074F5da0b30f9004ed7eCf1c3933477AE42 | 7e9d478     | 2026-11-24 |
| Optimism | 0x77181D2d7B3b116Bb4bdF8c897416A28b9412888 | 0xB2781074F5da0b30f9004ed7eCf1c3933477AE42 | 45b4138     | 2026-11-24 |
| Polygon  | 0x77D1BdAaa32572D5Ea301dabE6AEe8C03e162888 | 0xB2781074F5da0b30f9004ed7eCf1c3933477AE42 | 4954c12     | 2026-11-24 |

#### Pools

Every pool uses fee 0 and `tickSpacing` 1.

**Base**

| Pool       | Currency0                                         | Currency1                                          | Pool ID                                                            |
| ---------- | ------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------ |
| WETH/USDC  | WETH `0x4200000000000000000000000000000000000006` | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`  | 0xe73820f374359d2e767612877d21d5e41bf1f198453379b8458a57f869cb6f2b |
| USDC/cbBTC | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | cbBTC `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 0xd1370c843c9f6e4a6c252151d2571dacc0adaa99bbb24742df8b0178c0126122 |
| WETH/cbBTC | WETH `0x4200000000000000000000000000000000000006` | cbBTC `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 0x4e44800646ea42d88f50899515c39743af0f1472c3c6b532182cc80be9090323 |

**Arbitrum**

| Pool      | Currency0                                         | Currency1                                        | Pool ID                                                            |
| --------- | ------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------ |
| USDC/USDT | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | USDT `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 0xffc2d2e224d13001c7c80a56a4919be8c89258280aa8ddf52a12a1342f155008 |
| WETH/USDC | WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 0x8e3e7a765f7b09a4a3df9d0261f985a9f3b01006fbf890dd4e72b4348bbdc106 |
| WBTC/USDC | WBTC `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 0xd9891bcf814f3321c4bb31225e81a7ee7073d35cc1238c14fe8207f00d0154dc |
| ARB/USDC  | ARB `0x912CE59144191C1204E64559FE8253a0e49E6548`  | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 0xa724bb202455b421871a3fdcb794330a2cc6f12daf661d51f39cbb6a95e22dd3 |
| WETH/USDT | WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | USDT `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 0x32fde2cd8bd1b28ab6a6958d50b350b83f27d0ca68814231daec645ec0f55261 |
| WBTC/USDT | WBTC `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` | USDT `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 0x384d708ec222dbdc440b8f38839fd5471fb0eb9825b3cea2aab20ffe7965b8d2 |
| ARB/USDT  | ARB `0x912CE59144191C1204E64559FE8253a0e49E6548`  | USDT `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 0x93c8dfbfb82a17a6054a1ac900f4ac8a5a827629a7155b59cf9a87d4d7d04731 |
| WBTC/WETH | WBTC `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` | WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | 0xa407e1738ff08f456e91e5836935df5ba914a55e72aa69b250cba609ff8967ff |
| WETH/ARB  | WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | ARB `0x912CE59144191C1204E64559FE8253a0e49E6548`  | 0x7fc8d571446f261f4b590376cb00e5b785c5fbd157f9eb33d52ff616cb5eef2f |
| WBTC/ARB  | WBTC `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` | ARB `0x912CE59144191C1204E64559FE8253a0e49E6548`  | 0xfd35b830c170c913f736909a2f8e5d5d7bf6ab8857f5408c69735e58effd8a26 |

**Optimism**

| Pool      | Currency0                                         | Currency1                                         | Pool ID                                                            |
| --------- | ------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------ |
| USDC/USDT | USDC `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | USDT `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` | 0x7907e1dacf8274f3d3d0ed27257aa6a2ae9549b58cc0d5ff2d419cda74f47000 |
| USDC/WETH | USDC `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | WETH `0x4200000000000000000000000000000000000006` | 0x50ffd38427d1de5874c446c176f19c41d6057fcd26e2e49db7e680394afaad26 |
| USDC/WBTC | USDC `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | WBTC `0x68f180fcCe6836688e9084f035309E29Bf0A2095` | 0x87a8409d31c614e90e7d7180053b61e7e124155420add7a58828678895039c03 |
| USDC/OP   | USDC `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | OP `0x4200000000000000000000000000000000000042`   | 0x78cfb2c20fc5489647d4dffeffd5911109e9f9cf77567baa6fe554500304c044 |
| WETH/USDT | WETH `0x4200000000000000000000000000000000000006` | USDT `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` | 0xe07f5fb86c90ef0e0f3e2310806de7ef116db24c8214525b0ba665abe0672469 |
| WBTC/USDT | WBTC `0x68f180fcCe6836688e9084f035309E29Bf0A2095` | USDT `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` | 0xa30dae83942eb3dd5496e742573d6e716cc3f8f661d3230206756228a6adb05a |
| OP/USDT   | OP `0x4200000000000000000000000000000000000042`   | USDT `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` | 0x62df15c809c773c7c262ef12d8910723199bc98cb6e9f264ebd88e9145e88167 |
| WETH/WBTC | WETH `0x4200000000000000000000000000000000000006` | WBTC `0x68f180fcCe6836688e9084f035309E29Bf0A2095` | 0x99050e550600033e56a387b05ec3f7353fbc07f6ed3015a2c91d69bad3748ee2 |
| WETH/OP   | WETH `0x4200000000000000000000000000000000000006` | OP `0x4200000000000000000000000000000000000042`   | 0x697e2250c4f0306f7c56a89ea1b227be32a8b960c2b4d4aa57a8caa8dd6b3b70 |
| OP/WBTC   | OP `0x4200000000000000000000000000000000000042`   | WBTC `0x68f180fcCe6836688e9084f035309E29Bf0A2095` | 0xe1e207c3dccab617a8dc09017dfbf33821aa27cd9539ec2e9a84cee10952af9e |

**Polygon**

| Pool        | Currency0                                           | Currency1                                           | Pool ID                                                            |
| ----------- | --------------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------ |
| USDC.e/USDC | USDC.e `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | USDC `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`   | 0xb6f9d83e33b84cf4af06cc47c2f06d8a412ea2e2281a7788f1b6411e16297734 |
| USDC/USDT   | USDC `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`   | USDT `0xc2132D05D31c914a87C6611C10748AEb04B58e8F`   | 0xf031c9151e7633c5c2494c4eed36862ea520cf56e27a146551596a1f7fa85062 |
| USDC/WETH   | USDC `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`   | WETH `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619`   | 0xf349fc3f8f762f692d2aa57ce3638b69a284b480010978123fe9e45e08640b40 |
| WBTC/USDC   | WBTC `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`   | USDC `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`   | 0x9b3e1126057236211a06e4cf7dbe83c4fba6d73d665d6c4ec3d677029e75bbe1 |
| USDC.e/USDT | USDC.e `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | USDT `0xc2132D05D31c914a87C6611C10748AEb04B58e8F`   | 0x1877f8902f93cc18f606c37647f5e1665e3b0b4be319959d4f5907086a1f0277 |
| USDC.e/WETH | USDC.e `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | WETH `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619`   | 0x4bcc49770690b3df9cc4bdbaa91b59596528079dbd2d86227c733e748c7805ab |
| WBTC/USDC.e | WBTC `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`   | USDC.e `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | 0xe8d2efee980067b30515d8e2099a47eabdbad25a9cbf02ce0102ed5a28ca4593 |
| WETH/USDT   | WETH `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619`   | USDT `0xc2132D05D31c914a87C6611C10748AEb04B58e8F`   | 0xf5b6a154596b85ee8c2645cd6ce4ba18480cab32f28cd24c84582d64c40f52c9 |
| WBTC/USDT   | WBTC `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`   | USDT `0xc2132D05D31c914a87C6611C10748AEb04B58e8F`   | 0x5c0f9249447542cf2e168b24eb78b2b20298f3a9cc2f6fe7866b592b1ddef5d8 |
| WBTC/WETH   | WBTC `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6`   | WETH `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619`   | 0x3f9c4ce080e92b15eccf1436dfa55cb3c8bd7ae14c7ff2d289db9a0afa5557b7 |

## Audits

| Name             | Date       | Report                                                     |
| ---------------- | ---------- | ---------------------------------------------------------- |
| WETHHook         | 04/24/2025 | [OpenZeppelin](./docs/audits/openzeppelin-weth-wsteth.pdf) |
| WstETHHook       | 04/24/2025 | [OpenZeppelin](./docs/audits/openzeppelin-weth-wsteth.pdf) |
| StablePairHook   | 03/02/2026 | [OpenZeppelin](./docs/audits/openzeppelin-stablepair.pdf)  |
| VolatilePairHook | 10/14/2026 | [OpenZeppelin](./docs/audits/openzeppelin-volatile.pdf)    |

### Security Contact

[security@uniswap.org](mailto:security@uniswap.org)

## Docs

The documentation and architecture diagrams for the contracts within this repo can be found [here](docs/).
Detailed documentation generated from the NatSpec documentation of the contracts can be found [here](docs/autogen/src/pages/src/).
When exploring the contracts within this repository, it is recommended to start with the interfaces first and then move on to the implementation as outlined [here](CONTRIBUTING.md#natspec--comments).

## Repository Structure

All contracts are located in the `src/` directory. `test/` contains unit and fork tests for the hook contracts.

```
src/
----base/
|   BaseHook.sol
|   BaseTokenWrapperHook.sol
----interfaces/
|   IWstETH.sol
----utils/
|   HookMiner.sol
----WETHHook.sol
----WstETHHook.sol
----WstETHRoutingHook.sol
test/
----mocks/
----shared/
----WETHHook.t.sol
----WstETHHook.t.sol
----WstETHHook.fork.t.sol
```

## Contributing

If you want to contribute to this project, please check [CONTRIBUTING.md](CONTRIBUTING.md) first.

## License

The contracts are covered under the MIT License (`MIT`), see [LICENSE](LICENSE).
