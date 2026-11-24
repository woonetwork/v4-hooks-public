// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WOOFiDeployScript} from "./WOOFiDeployScript.sol";

/// @notice WOOFi on Base: pools for every pair of USDC, WETH and cbBTC, with gateway ownership offered to the WOOFi
///         Safe, as deployed on 2026-11-04. See `WOOFiDeployScript` for how to mine the hook salt and run it.
contract DeployWOOFiBaseScript is WOOFiDeployScript {
    /// @dev The 3/6 Safe that owns WooPPV2 and Wooracle
    address constant WOOFI_SAFE = 0x682F676389BDE27dB6C8a3d8bC6AF0B021E9FfF2;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    }

    function tokens() public pure override returns (address[] memory list) {
        list = new address[](3);
        list[0] = USDC;
        list[1] = WETH;
        list[2] = CBBTC;
    }

    function nextOwner() public pure override returns (address) {
        return WOOFI_SAFE;
    }
}
