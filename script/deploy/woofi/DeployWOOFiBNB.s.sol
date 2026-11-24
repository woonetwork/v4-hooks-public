// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {WOOFiDeployScript} from "./WOOFiDeployScript.sol";

/// @notice WOOFi on BNB Chain: pools for every pair of USDT, USDC, WBNB, ETH and BTCB (10 pools). WooPP's tokenized
///         stocks are left out. WooPP's quote token here is USDT with 18 decimals, so MAX_NOTIONAL_PER_SWAP takes 18
///         decimals (10,000 USDT = 10000e18). The deployer stays gateway owner; it moves to the WOOFi Safe later, on
///         every chain at once. See `WOOFiDeployScript` for how to mine the hook salt and run it.
contract DeployWOOFiBNBScript is WOOFiDeployScript {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
    }

    function tokens() public pure override returns (address[] memory list) {
        list = new address[](5);
        list[0] = USDT;
        list[1] = USDC;
        list[2] = WBNB;
        list[3] = ETH;
        list[4] = BTCB;
    }

    function nextOwner() public pure override returns (address) {
        return address(0);
    }
}
