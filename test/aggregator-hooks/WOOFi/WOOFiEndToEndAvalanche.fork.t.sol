// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {DeployWOOFiAvalancheScript} from "../../../script/deploy/woofi/DeployWOOFiAvalanche.s.sol";
import {IUniversalRouter, IV4Quoter, WOOFiEndToEndTestBase} from "./WOOFiEndToEndTestBase.sol";

/// @notice End-to-end on an Avalanche fork with `DeployWOOFiAvalanche.s.sol`: the deployer keeps gateway ownership.
///         Covers every launch token, base ↔ quote, base ↔ base and the USDt/USDC stable pair. Avalanche has no
///         Universal Router V2.0, so trades go through V2.1.2.
/// @dev `FORK_RPC_URL_43114` and optional `FORK_BLOCK_NUMBER_43114`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndAvalancheForkTest is WOOFiEndToEndTestBase {
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address constant WETH_E = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;
    address constant BTC_B = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    function _chainId() internal pure override returns (uint256) {
        return 43114;
    }

    function _newScript() internal override returns (WOOFiDeployScript) {
        return new DeployWOOFiAvalancheScript();
    }

    function _universalRouter() internal pure override returns (IUniversalRouter) {
        return IUniversalRouter(0x661E93cca42AfacB172121EF892830cA3b70F08d);
    }

    function _routerIsV2_1() internal pure override returns (bool) {
        return true;
    }

    function _v4Quoter() internal pure override returns (IV4Quoter) {
        return IV4Quoter(0xbE40675BB704506a3c2Ccfb762DCFd1e979845C2);
    }

    function _referenceTrade() internal pure override returns (address, address, uint256) {
        return (WETH_E, USDC, 1e18);
    }

    function test_e2e_deployerOwnsGateway() public view {
        assertEq(owner, deployer, "no ownership handoff on Avalanche");
    }

    function test_e2e_wethToUsdc() public {
        _assertEndToEnd(WETH_E, USDC, 1e18);
    }

    function test_e2e_usdcToWeth() public {
        _assertEndToEnd(USDC, WETH_E, 3000e6);
    }

    function test_e2e_usdcToBtcb() public {
        _assertEndToEnd(USDC, BTC_B, 5000e6);
    }

    function test_e2e_wethToBtcb() public {
        _assertEndToEnd(WETH_E, BTC_B, 1e18);
    }

    function test_e2e_usdtToUsdc() public {
        _assertEndToEnd(USDT, USDC, 1000e6);
    }

    function test_e2e_wavaxToUsdt() public {
        _assertEndToEnd(WAVAX, USDT, 200e18);
    }

    function test_e2e_btcbToWavax() public {
        _assertEndToEnd(BTC_B, WAVAX, 0.01e8);
    }
}
