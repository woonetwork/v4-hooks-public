// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {WOOFiAggregator} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiAggregator.sol";
import {WOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/WOOFiGateway.sol";
import {IWOOFiGateway} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWOOFiGateway.sol";
import {IWooPPV2} from "../../../src/aggregator-hooks/implementations/WOOFi/interfaces/IWooPPV2.sol";

/// @notice Deploys WOOFiGateway and WOOFiAggregator, configures the gateway, and initializes one pool per pair of
///         the launch tokens. Each chain's script supplies its PoolManager, its launch tokens and who the gateway
///         ownership goes to.
/// @dev Both contracts go through the deterministic CREATE2 deployer. WooPPV2 has the same address on every chain, so
///      the gateway's address only depends on the deployer (the same deployer gets the same gateway everywhere), and
///      the hook's init code hash is known up front and its salt can be mined offline:
///
///        HASH=$(FOUNDRY_PROFILE=aggregator_hooks forge script script/deploy/woofi/DeployWOOFi<Chain>.s.sol \
///          --sig "hookInitCodeHash(address)" $DEPLOYER)
///        cast create2 --starts-with 77 --ends-with 2888 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
///          --init-code-hash $HASH
///
///      (`77` is the WOOFi aggregator ID; `2888` the hook's permission bits; the hook's address depends on the
///      PoolManager, so each chain needs its own salt.) Then run with HOOK_SALT, MAX_PRICE_AGE, SPREAD_PER_SECOND,
///      MAX_NOTIONAL_PER_SWAP and optional PAUSERS. Deploy with the `aggregator_hooks` profile: the gateway's address
///      is the hash of its bytecode, so a different build gives a different gateway than on the other chains.
abstract contract WOOFiDeployScript is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IWooPPV2 constant WOOPP = IWooPPV2(0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4);

    bytes32 constant GATEWAY_SALT = keccak256("WOOFiGateway");
    uint8 constant HOOK_ID = 0x77;
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
    );
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    struct Config {
        bytes32 hookSalt;
        uint256 maxPriceAge;
        uint256 spreadPerSecond;
        uint256 maxNotionalPerSwap;
        address[] pausers;
    }

    /// @notice The chain's Uniswap v4 PoolManager
    function poolManager() public pure virtual returns (IPoolManager);

    /// @notice The launch tokens: every pair among them gets a pool
    function tokens() public pure virtual returns (address[] memory);

    /// @notice Who gateway ownership is offered to at the end (Ownable2Step: they must call `acceptOwnership`), or
    ///         zero to leave the deployer as owner
    function nextOwner() public pure virtual returns (address);

    function run() external returns (WOOFiGateway gateway, WOOFiAggregator hook) {
        Config memory config = Config({
            hookSalt: vm.envBytes32("HOOK_SALT"),
            maxPriceAge: vm.envUint("MAX_PRICE_AGE"),
            spreadPerSecond: vm.envUint("SPREAD_PER_SECOND"),
            maxNotionalPerSwap: vm.envUint("MAX_NOTIONAL_PER_SWAP"),
            pausers: vm.envOr("PAUSERS", ",", new address[](0))
        });
        (, address deployer,) = vm.readCallers();
        return deploy(config, deployer);
    }

    function gatewayAddress(address deployer) public pure returns (address) {
        return _create2Address(GATEWAY_SALT, keccak256(_gatewayInitCode(deployer)));
    }

    /// @notice What to mine the hook salt against
    function hookInitCodeHash(address deployer) public pure returns (bytes32) {
        return keccak256(_hookInitCode(gatewayAddress(deployer)));
    }

    function deploy(Config memory config, address deployer)
        public
        returns (WOOFiGateway gateway, WOOFiAggregator hook)
    {
        vm.startBroadcast(deployer);

        gateway = WOOFiGateway(_create2(GATEWAY_SALT, _gatewayInitCode(deployer)));
        hook = WOOFiAggregator(payable(_create2(config.hookSalt, _hookInitCode(address(gateway)))));
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "hook permission bits");
        require(uint8(uint160(address(hook)) >> 152) == HOOK_ID, "hook ID byte");

        gateway.setHook(address(hook));
        address[] memory list = tokens();
        for (uint256 i; i < list.length; ++i) {
            gateway.setTokenAllowed(list[i], true);
        }
        gateway.setPricing(config.maxPriceAge, config.spreadPerSecond);
        gateway.setMaxNotionalPerSwap(config.maxNotionalPerSwap);
        for (uint256 i; i < config.pausers.length; ++i) {
            gateway.setPauser(config.pausers[i], true);
        }

        IPoolManager manager = poolManager();
        for (uint256 i; i < list.length; ++i) {
            for (uint256 j = i + 1; j < list.length; ++j) {
                manager.initialize(_poolKey(hook, list[i], list[j]), SQRT_PRICE_1_1);
            }
        }

        if (nextOwner() != address(0)) gateway.transferOwnership(nextOwner());
        vm.stopBroadcast();

        console2.log("WOOFiGateway:", address(gateway));
        console2.log("WOOFiAggregator:", address(hook));
    }

    function _poolKey(WOOFiAggregator hook, address a, address b) internal pure returns (PoolKey memory) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: 0, // WOOFiAggregator.POOL_FEE
            tickSpacing: 1, // WOOFiAggregator.POOL_TICK_SPACING
            hooks: IHooks(address(hook))
        });
    }

    function _gatewayInitCode(address deployer) internal pure returns (bytes memory) {
        return abi.encodePacked(type(WOOFiGateway).creationCode, abi.encode(WOOPP, deployer));
    }

    function _hookInitCode(address gateway) internal pure returns (bytes memory) {
        return abi.encodePacked(type(WOOFiAggregator).creationCode, abi.encode(poolManager(), IWOOFiGateway(gateway)));
    }

    /// @dev Reuses the address when the contract is already there, e.g. when someone deploys the same init code first:
    ///      the result is identical, as the owner and constructor args are part of the address
    function _create2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = _create2Address(salt, keccak256(initCode));
        if (deployed.code.length > 0) return deployed;
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && deployed.code.length > 0, "CREATE2 deployment failed");
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
    }
}
