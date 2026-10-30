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

/// @notice Deploys WOOFiGateway and WOOFiAggregator on Base, configures the gateway, initializes one pool per pair
///         of the launch tokens, and hands gateway ownership to the WOOFi Safe.
/// @dev Both contracts go through the deterministic CREATE2 deployer. The gateway's address only depends on the
///      deployer, so the hook's init code hash is known up front and its salt can be mined offline:
///
///        HASH=$(forge script script/deploy/woofi/DeployWOOFiBase.s.sol --sig "hookInitCodeHash(address)" $DEPLOYER)
///        cast create2 --starts-with 77 --ends-with 2888 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C \
///          --init-code-hash $HASH
///
///      (`77` is the WOOFi aggregator ID; `2888` the hook's permission bits.) Then run with HOOK_SALT,
///      MAX_PRICE_AGE, SPREAD_PER_SECOND, MAX_NOTIONAL_PER_SWAP and optional PAUSERS. The Safe must call
///      `acceptOwnership` on the gateway afterwards (Ownable2Step).
contract DeployWOOFiBaseScript is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IWooPPV2 constant WOOPP = IWooPPV2(0x5520385bFcf07Ec87C4c53A7d8d65595Dff69FA4);
    /// @dev The 3/6 Safe that owns WooPPV2 and Wooracle
    address constant WOOFI_SAFE = 0x682F676389BDE27dB6C8a3d8bC6AF0B021E9FfF2;

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

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

    /// @notice The launch tokens: every pair among them gets a pool
    function tokens() public pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = USDC;
        list[1] = WETH;
        list[2] = CBBTC;
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

        for (uint256 i; i < list.length; ++i) {
            for (uint256 j = i + 1; j < list.length; ++j) {
                POOL_MANAGER.initialize(_poolKey(hook, list[i], list[j]), SQRT_PRICE_1_1);
            }
        }

        gateway.transferOwnership(WOOFI_SAFE);
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
        return abi.encodePacked(type(WOOFiAggregator).creationCode, abi.encode(POOL_MANAGER, IWOOFiGateway(gateway)));
    }

    function _create2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = _create2Address(salt, keccak256(initCode));
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && deployed.code.length > 0, "CREATE2 deployment failed");
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
    }
}
