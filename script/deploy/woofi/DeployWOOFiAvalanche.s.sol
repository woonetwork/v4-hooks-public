// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WOOFiDeployScript} from "./WOOFiDeployScript.sol";

/// @notice WOOFi on Avalanche: pools for every pair of USDC, USDt, WETH.e, BTC.b and WAVAX (10 pools). Uniswap
///         charges no v4 protocol fee on Avalanche. The deployer stays gateway owner; it moves to the WOOFi Safe
///         later, on every chain at once. See `WOOFiDeployScript` for how to mine the hook salt and run it.
contract DeployWOOFiAvalancheScript is WOOFiDeployScript {
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address constant WETH_E = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;
    address constant BTC_B = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    }

    function tokens() public pure override returns (address[] memory list) {
        list = new address[](5);
        list[0] = USDC;
        list[1] = USDT;
        list[2] = WETH_E;
        list[3] = BTC_B;
        list[4] = WAVAX;
    }

    function nextOwner() public pure override returns (address) {
        return address(0);
    }
}
