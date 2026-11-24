// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {DeployWOOFiArbitrumScript} from "../../../script/deploy/woofi/DeployWOOFiArbitrum.s.sol";
import {IUniversalRouter, IV4Quoter, WOOFiEndToEndTestBase} from "./WOOFiEndToEndTestBase.sol";

/// @notice End-to-end on an Arbitrum fork with `DeployWOOFiArbitrum.s.sol`: the deployer keeps gateway ownership.
///         Covers every launch token, base ↔ quote, base ↔ base and the USDT/USDC stable pair.
/// @dev `FORK_RPC_URL_42161` and optional `FORK_BLOCK_NUMBER_42161`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndArbitrumForkTest is WOOFiEndToEndTestBase {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;

    function _chainId() internal pure override returns (uint256) {
        return 42161;
    }

    function _newScript() internal override returns (WOOFiDeployScript) {
        return new DeployWOOFiArbitrumScript();
    }

    function _universalRouter() internal pure override returns (IUniversalRouter) {
        return IUniversalRouter(0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3);
    }

    function _v4Quoter() internal pure override returns (IV4Quoter) {
        return IV4Quoter(0x3972C00f7ed4885e145823eb7C655375d275A1C5);
    }

    function _referenceTrade() internal pure override returns (address, address, uint256) {
        return (WETH, USDC, 1e18);
    }

    function test_e2e_deployerOwnsGateway() public view {
        assertEq(owner, deployer, "no ownership handoff on Arbitrum");
    }

    function test_e2e_wethToUsdc() public {
        _assertEndToEnd(WETH, USDC, 1e18);
    }

    function test_e2e_usdcToWeth() public {
        _assertEndToEnd(USDC, WETH, 3000e6);
    }

    function test_e2e_usdcToWbtc() public {
        _assertEndToEnd(USDC, WBTC, 5000e6);
    }

    function test_e2e_wethToWbtc() public {
        _assertEndToEnd(WETH, WBTC, 1e18);
    }

    function test_e2e_usdtToUsdc() public {
        _assertEndToEnd(USDT, USDC, 1000e6);
    }

    function test_e2e_arbToUsdt() public {
        _assertEndToEnd(ARB, USDT, 10_000e18);
    }

    function test_e2e_wbtcToArb() public {
        _assertEndToEnd(WBTC, ARB, 0.01e8);
    }
}
