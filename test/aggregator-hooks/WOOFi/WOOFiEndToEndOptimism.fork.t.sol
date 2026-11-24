// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {DeployWOOFiOptimismScript} from "../../../script/deploy/woofi/DeployWOOFiOptimism.s.sol";
import {IUniversalRouter, IV4Quoter, WOOFiEndToEndTestBase} from "./WOOFiEndToEndTestBase.sol";

/// @notice End-to-end on an Optimism fork with `DeployWOOFiOptimism.s.sol`: the deployer keeps gateway ownership.
///         Covers every launch token, base ↔ quote, base ↔ base and the USDT/USDC stable pair.
/// @dev `FORK_RPC_URL_10` and optional `FORK_BLOCK_NUMBER_10`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndOptimismForkTest is WOOFiEndToEndTestBase {
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    address constant OP = 0x4200000000000000000000000000000000000042;

    function _chainId() internal pure override returns (uint256) {
        return 10;
    }

    function _newScript() internal override returns (WOOFiDeployScript) {
        return new DeployWOOFiOptimismScript();
    }

    function _universalRouter() internal pure override returns (IUniversalRouter) {
        return IUniversalRouter(0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507);
    }

    function _v4Quoter() internal pure override returns (IV4Quoter) {
        return IV4Quoter(0x1f3131A13296FB91C90870043742C3CDBFF1A8d7);
    }

    function _referenceTrade() internal pure override returns (address, address, uint256) {
        return (WETH, USDC, 1e18);
    }

    function test_e2e_deployerOwnsGateway() public view {
        assertEq(owner, deployer, "no ownership handoff on Optimism");
    }

    function test_e2e_wethToUsdc() public {
        _assertEndToEnd(WETH, USDC, 1e18);
    }

    function test_e2e_usdcToWeth() public {
        _assertEndToEnd(USDC, WETH, 3000e6);
    }

    function test_e2e_usdcToWbtc() public {
        _assertEndToEnd(USDC, WBTC, 3000e6);
    }

    function test_e2e_wethToWbtc() public {
        _assertEndToEnd(WETH, WBTC, 1e18);
    }

    function test_e2e_usdtToUsdc() public {
        _assertEndToEnd(USDT, USDC, 1000e6);
    }

    function test_e2e_opToUsdt() public {
        _assertEndToEnd(OP, USDT, 10_000e18);
    }

    function test_e2e_wbtcToOp() public {
        _assertEndToEnd(WBTC, OP, 0.01e8);
    }
}
