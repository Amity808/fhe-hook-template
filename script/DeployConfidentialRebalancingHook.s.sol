// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ConfidentialRebalancingHook} from "../src/ConfidentialRebalancingHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/**
 * @title DeployConfidentialRebalancingHook
 * @dev Deployment script for ConfidentialRebalancingHook
 *
 * This script deploys the ConfidentialRebalancingHook to a specific address
 * with the correct hook permissions encoded in the address.
 *
 * Hook Permissions:
 * - BEFORE_SWAP_FLAG: Execute confidential rebalancing before swaps
 * - AFTER_SWAP_FLAG: Update positions after swaps
 * - BEFORE_ADD_LIQUIDITY_FLAG: Handle liquidity additions
 * - BEFORE_REMOVE_LIQUIDITY_FLAG: Handle liquidity removals
 */
contract DeployConfidentialRebalancingHook is Script {
    // CREATE2 Deployer address (standard for Uniswap v4 hooks)
    address constant CREATE2_DEPLOYER =
        address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Pool Manager address (set this to your deployed PoolManager)
    address constant POOL_MANAGER =
        address(0x1234567890123456789012345678901234567890); // TODO: Set actual address

    // Governance address (set this to your governance contract)
    address constant GOVERNANCE =
        address(0x2345678901234567890123456789012345678901); // TODO: Set actual address

    // Authorized executors (set these to trusted addresses)
    address constant EXECUTOR_1 =
        address(0x3456789012345678901234567890123456789012); // TODO: Set actual address
    address constant EXECUTOR_2 =
        address(0x4567890123456789012345678901234567890123); // TODO: Set actual address

    function run() public {
        // Hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(ConfidentialRebalancingHook).creationCode,
            constructorArgs
        );

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        console.log("Pool Manager:", POOL_MANAGER);

        // Deploy the hook using CREATE2
        vm.broadcast();
        ConfidentialRebalancingHook hook = new ConfidentialRebalancingHook{
            salt: salt
        }(IPoolManager(POOL_MANAGER));

        require(
            address(hook) == hookAddress,
            "DeployConfidentialRebalancingHook: hook address mismatch"
        );

        console.log("ConfidentialRebalancingHook deployed at:", address(hook));
        console.log("Hook permissions verified");

        // Set up governance and authorized executors
        vm.startBroadcast();

        // Set governance (only hook owner can do this initially)
        hook.setGovernance(GOVERNANCE);
        console.log("Governance set to:", GOVERNANCE);

        // Add authorized executors
        hook.addAuthorizedExecutor(EXECUTOR_1);
        console.log("Added authorized executor:", EXECUTOR_1);

        hook.addAuthorizedExecutor(EXECUTOR_2);
        console.log("Added authorized executor:", EXECUTOR_2);

        vm.stopBroadcast();

        // Verify deployment
        _verifyDeployment(hook);

        console.log("Deployment completed successfully!");
        console.log("Next steps:");
        console.log("1. Update POOL_MANAGER address in this script");
        console.log("2. Set GOVERNANCE address");
        console.log("3. Configure AUTHORIZED_EXECUTORS");
        console.log("4. Deploy to testnet first");
        console.log("5. Test with real pools before mainnet deployment");
    }

    /**
     * @dev Verify the deployment was successful
     */
    function _verifyDeployment(ConfidentialRebalancingHook hook) internal view {
        // Verify hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        require(permissions.beforeSwap, "beforeSwap permission not set");
        require(permissions.afterSwap, "afterSwap permission not set");
        require(
            permissions.beforeAddLiquidity,
            "beforeAddLiquidity permission not set"
        );
        require(
            permissions.beforeRemoveLiquidity,
            "beforeRemoveLiquidity permission not set"
        );

        console.log("Hook permissions verified:");
        console.log("- beforeSwap:", permissions.beforeSwap);
        console.log("- afterSwap:", permissions.afterSwap);
        console.log("- beforeAddLiquidity:", permissions.beforeAddLiquidity);
        console.log(
            "- beforeRemoveLiquidity:",
            permissions.beforeRemoveLiquidity
        );

        // Verify governance is set
        require(
            hook.governance() == GOVERNANCE,
            "Governance not set correctly"
        );
        console.log("Governance verified:", hook.governance());

        // Verify authorized executors
        require(
            hook.authorizedExecutors(EXECUTOR_1),
            "Authorized executor 1 not set correctly"
        );
        require(
            hook.authorizedExecutors(EXECUTOR_2),
            "Authorized executor 2 not set correctly"
        );
        console.log("Authorized executors verified");
    }
}

/**
 * @title DeployConfidentialRebalancingHookTestnet
 * @dev Testnet-specific deployment script
 */
contract DeployConfidentialRebalancingHookTestnet is Script {
    // Testnet addresses (update these for your testnet)
    address constant TESTNET_POOL_MANAGER =
        address(0x1234567890123456789012345678901234567890);
    address constant TESTNET_GOVERNANCE =
        address(0x2345678901234567890123456789012345678901);

    function run() public {
        // Use the main deployment script with testnet addresses
        DeployConfidentialRebalancingHook deployer = new DeployConfidentialRebalancingHook();

        // Override addresses for testnet
        vm.startBroadcast();

        // Deploy hook
        ConfidentialRebalancingHook hook = new ConfidentialRebalancingHook(
            IPoolManager(TESTNET_POOL_MANAGER)
        );

        // Set up testnet configuration
        hook.setGovernance(TESTNET_GOVERNANCE);

        // Add test accounts as authorized executors
        hook.addAuthorizedExecutor(address(this)); // Script deployer
        hook.addAuthorizedExecutor(msg.sender); // Transaction sender

        vm.stopBroadcast();

        console.log("Testnet deployment completed!");
        console.log("Hook address:", address(hook));
        console.log("Pool Manager:", TESTNET_POOL_MANAGER);
        console.log("Governance:", TESTNET_GOVERNANCE);
    }
}
