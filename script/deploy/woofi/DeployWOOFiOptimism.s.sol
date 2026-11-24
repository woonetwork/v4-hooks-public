// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WOOFiDeployScript} from "./WOOFiDeployScript.sol";

/// @notice WOOFi on Optimism: pools for every pair of USDC, USDT, WETH, WBTC and OP (10 pools). USDC.e is left out
///         although WooPP still takes it: its WooPP inventory is small, and its pairs with USDC and USDT are stable
///         pairs where Uniswap's own pools are hard to beat. The deployer stays gateway owner; it moves to the WOOFi
///         Safe later, on every chain at once. See `WOOFiDeployScript` for how to mine the hook salt and run it.
contract DeployWOOFiOptimismScript is WOOFiDeployScript {
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    address constant OP = 0x4200000000000000000000000000000000000042;

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3);
    }

    function tokens() public pure override returns (address[] memory list) {
        list = new address[](5);
        list[0] = USDC;
        list[1] = USDT;
        list[2] = WETH;
        list[3] = WBTC;
        list[4] = OP;
    }

    function nextOwner() public pure override returns (address) {
        return address(0);
    }
}
