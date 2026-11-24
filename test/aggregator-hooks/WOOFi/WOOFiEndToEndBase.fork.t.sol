// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {DeployWOOFiBaseScript} from "../../../script/deploy/woofi/DeployWOOFiBase.s.sol";
import {IUniversalRouter, IV4Quoter, WOOFiEndToEndTestBase} from "./WOOFiEndToEndTestBase.sol";

/// @notice End-to-end on a Base fork with `DeployWOOFiBase.s.sol`: the WOOFi Safe accepts gateway ownership.
/// @dev `FORK_RPC_URL_8453` and optional `FORK_BLOCK_NUMBER_8453`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndBaseForkTest is WOOFiEndToEndTestBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _newScript() internal override returns (WOOFiDeployScript) {
        return new DeployWOOFiBaseScript();
    }

    function _universalRouter() internal pure override returns (IUniversalRouter) {
        return IUniversalRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43);
    }

    function _v4Quoter() internal pure override returns (IV4Quoter) {
        return IV4Quoter(0x0d5e0F971ED27FBfF6c2837bf31316121532048D);
    }

    function _referenceTrade() internal pure override returns (address, address, uint256) {
        return (WETH, USDC, 1e18);
    }

    function test_e2e_safeOwnsGateway() public view {
        assertEq(owner, 0x682F676389BDE27dB6C8a3d8bC6AF0B021E9FfF2, "Safe accepted ownership");
    }

    function test_e2e_wethToUsdc() public {
        _assertEndToEnd(WETH, USDC, 1e18);
    }

    function test_e2e_usdcToWeth() public {
        _assertEndToEnd(USDC, WETH, 3000e6);
    }

    function test_e2e_usdcToCbbtc() public {
        _assertEndToEnd(USDC, CBBTC, 5000e6);
    }

    function test_e2e_wethToCbbtc() public {
        _assertEndToEnd(WETH, CBBTC, 1e18);
    }
}
