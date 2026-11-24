// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WOOFiDeployScript} from "./WOOFiDeployScript.sol";

/// @notice WOOFi on Arbitrum: pools for every pair of USDC, USDT, WETH, WBTC and ARB (10 pools). USDC.e is left out,
///         as WooPP no longer takes it (zero `capBal` and `maxNotionalSwap`). The deployer stays gateway owner; it
///         moves to the WOOFi Safe later, on every chain at once. See `WOOFiDeployScript` for how to mine the hook
///         salt and run it.
contract DeployWOOFiArbitrumScript is WOOFiDeployScript {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);
    }

    function tokens() public pure override returns (address[] memory list) {
        list = new address[](5);
        list[0] = USDC;
        list[1] = USDT;
        list[2] = WETH;
        list[3] = WBTC;
        list[4] = ARB;
    }

    function nextOwner() public pure override returns (address) {
        return address(0);
    }
}
