// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {
    ConfidentialRebalancingHook
} from "../src/ConfidentialRebalancingHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title GetHookAddress
 * @dev Script to calculate the hook address without deploying
 */
contract GetHookAddress is Script {
    // Sepolia Pool Manager address (from PoolManagerAddresses.sol)
    IPoolManager constant POOLMANAGER =
        IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    address constant CREATE2_DEPLOYER =
        address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() public view {
        // Get deployer address
        address deployer;
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            deployer = vm.addr(pk);
        } catch {
            deployer = msg.sender;
        }
        // Use deployer as governance for address calculation
        address governanceAddress = deployer;

        // Hook permissions
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Calculate hook address
        bytes memory constructorArgs = abi.encode(
            POOLMANAGER,
            governanceAddress
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(ConfidentialRebalancingHook).creationCode,
            constructorArgs
        );

        console.log("========================================");
        console.log("Hook Address Calculation:");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Governance:", governanceAddress);
        console.log("Pool Manager:", address(POOLMANAGER));
        console.log("CREATE2 Deployer:", CREATE2_DEPLOYER);
        console.log("Salt:", vm.toString(salt));
        console.log("========================================");
        console.log("Mined Hook Address:", hookAddress);
        console.log("========================================");
        console.log("");
        console.log("Update Config.sol with this address:");
        console.log("IHooks constant hookContract =");
        console.log("    IHooks(address(", hookAddress, "));");
    }
}
