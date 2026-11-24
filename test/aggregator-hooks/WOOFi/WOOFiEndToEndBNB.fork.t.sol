// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WOOFiDeployScript} from "../../../script/deploy/woofi/WOOFiDeployScript.sol";
import {DeployWOOFiBNBScript} from "../../../script/deploy/woofi/DeployWOOFiBNB.s.sol";
import {IUniversalRouter, IV4Quoter, WOOFiEndToEndTestBase} from "./WOOFiEndToEndTestBase.sol";

/// @notice End-to-end on a BNB Chain fork with `DeployWOOFiBNB.s.sol`: the deployer keeps gateway ownership. Covers
///         every launch token, base ↔ quote, base ↔ base and the USDC/USDT stable pair. Every token here has 18
///         decimals, the USDT quote token included, so the notional cap is set in 18 decimals.
/// @dev `FORK_RPC_URL_56` and optional `FORK_BLOCK_NUMBER_56`; skips when the RPC is unset. Needs `cast` (ffi).
contract WOOFiEndToEndBNBForkTest is WOOFiEndToEndTestBase {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    function _chainId() internal pure override returns (uint256) {
        return 56;
    }

    function _newScript() internal override returns (WOOFiDeployScript) {
        return new DeployWOOFiBNBScript();
    }

    function _universalRouter() internal pure override returns (IUniversalRouter) {
        return IUniversalRouter(0x1906c1d672b88cD1B9aC7593301cA990F94Eae07);
    }

    function _v4Quoter() internal pure override returns (IV4Quoter) {
        return IV4Quoter(0x9F75dD27D6664c475B90e105573E550ff69437B0);
    }

    /// @dev 50,000 USDT: WooPP's quote token on BNB Chain has 18 decimals
    function _maxNotionalPerSwap() internal pure override returns (uint256) {
        return 50_000e18;
    }

    function _referenceTrade() internal pure override returns (address, address, uint256) {
        return (ETH, USDT, 1e18);
    }

    function test_e2e_deployerOwnsGateway() public view {
        assertEq(owner, deployer, "no ownership handoff on BNB Chain");
    }

    function test_e2e_ethToUsdt() public {
        _assertEndToEnd(ETH, USDT, 1e18);
    }

    function test_e2e_usdtToEth() public {
        _assertEndToEnd(USDT, ETH, 3000e18);
    }

    function test_e2e_usdtToBtcb() public {
        _assertEndToEnd(USDT, BTCB, 5000e18);
    }

    function test_e2e_ethToBtcb() public {
        _assertEndToEnd(ETH, BTCB, 1e18);
    }

    function test_e2e_usdcToUsdt() public {
        _assertEndToEnd(USDC, USDT, 1000e18);
    }

    function test_e2e_wbnbToUsdc() public {
        _assertEndToEnd(WBNB, USDC, 2e18);
    }

    function test_e2e_btcbToWbnb() public {
        _assertEndToEnd(BTCB, WBNB, 0.01e18);
    }
}
