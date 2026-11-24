// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WOOFiDeployScript} from "./WOOFiDeployScript.sol";

/// @notice WOOFi on Polygon: pools for every pair of USDC, USDC.e, USDT, WETH and WBTC (10 pools). USDC.e stays in,
///         unlike on Optimism: it is still a main dollar on Polygon. WPOL is left out for now: the hook takes a swap's
///         input from the PoolManager before the swapper pays, and Polygon's v4 trades native POL, so the
///         PoolManager holds too little WPOL to sell through the hook. Adding it later only needs the owner to allow
///         it and initialize its pools. The deployer stays gateway owner; it moves to the WOOFi Safe later, on every
///         chain at once. See `WOOFiDeployScript` for how to mine the hook salt and run it.
contract DeployWOOFiPolygonScript is WOOFiDeployScript {
    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant USDC_E = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(0x67366782805870060151383F4BbFF9daB53e5cD6);
    }

    function tokens() public pure override returns (address[] memory list) {
        list = new address[](5);
        list[0] = USDC;
        list[1] = USDC_E;
        list[2] = USDT;
        list[3] = WETH;
        list[4] = WBTC;
    }

    function nextOwner() public pure override returns (address) {
        return address(0);
    }
}
