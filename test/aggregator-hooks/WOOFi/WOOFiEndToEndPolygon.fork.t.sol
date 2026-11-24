// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {DeployWOOFiPolygonScript} from "../../../script/deploy/woofi/DeployWOOFiPolygon.s.sol";
import {IUniversalRouter, IV4Quoter, WOOFiEndToEndTestBase} from "./WOOFiEndToEndTestBase.sol";

/// @notice End-to-end on a Polygon fork with `DeployWOOFiPolygon.s.sol`: the deployer keeps gateway ownership.
///         Covers every launch token, base ↔ quote, base ↔ base and stable pairs. Trades sell into USDC.e rather than
///         USDC, as WooPP's USDC reserve runs low at times.
/// @dev `FORK_RPC_URL_137` and optional `FORK_BLOCK_NUMBER_137`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndPolygonForkTest is WOOFiEndToEndTestBase {
    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant USDC_E = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    function _chainId() internal pure override returns (uint256) {
        return 137;
    }

    function _newScript() internal override returns (WOOFiDeployScript) {
        return new DeployWOOFiPolygonScript();
    }

    function _universalRouter() internal pure override returns (IUniversalRouter) {
        return IUniversalRouter(0x1095692A6237d83C6a72F3F5eFEdb9A670C49223);
    }

    function _v4Quoter() internal pure override returns (IV4Quoter) {
        return IV4Quoter(0xb3d5c3Dfc3a7aEbFF71895A7191796BFFc2c81b9);
    }

    function _referenceTrade() internal pure override returns (address, address, uint256) {
        return (WETH, USDC_E, 1e18);
    }

    function test_e2e_deployerOwnsGateway() public view {
        assertEq(owner, deployer, "no ownership handoff on Polygon");
    }

    function test_e2e_usdcToWeth() public {
        _assertEndToEnd(USDC, WETH, 3000e6);
    }

    function test_e2e_wethToUsdcE() public {
        _assertEndToEnd(WETH, USDC_E, 1e18);
    }

    function test_e2e_usdcEToWbtc() public {
        _assertEndToEnd(USDC_E, WBTC, 5000e6);
    }

    function test_e2e_wethToWbtc() public {
        _assertEndToEnd(WETH, WBTC, 1e18);
    }

    function test_e2e_usdcToUsdt() public {
        _assertEndToEnd(USDC, USDT, 1000e6);
    }

    function test_e2e_usdtToUsdcE() public {
        _assertEndToEnd(USDT, USDC_E, 1000e6);
    }

    function test_e2e_wbtcToUsdt() public {
        _assertEndToEnd(WBTC, USDT, 0.01e8);
    }
}
