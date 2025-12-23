// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    ConfidentialRebalancingHook
} from "../src/ConfidentialRebalancingHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Constants} from "./base/Constants.sol";

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
contract DeployConfidentialRebalancingHook is Script, Constants {
    // Governance address options:
    // 1. For testing: Use your deployer address (msg.sender) - see run() function
    // 2. For production: Deploy a governance contract (multisig/DAO) first, then use that address
    // 3. For simple testing: Use a specific EOA address you control
    address constant GOVERNANCE =
        address(0x2345678901234567890123456789012345678901); // TODO: Set actual address or use deployer

    // Authorized executors (set these to trusted addresses)
    // For testing, you can use the deployer address or leave as-is
    address constant EXECUTOR_1 =
        address(0x3456789012345678901234567890123456789012); // TODO: Set actual address
    address constant EXECUTOR_2 =
        address(0x4567890123456789012345678901234567890123); // TODO: Set actual address

    function run() public {
        // Get the deployer address (the address that will deploy the contract)
        // Try to get from PRIVATE_KEY env var, fallback to msg.sender
        address deployer;
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            deployer = vm.addr(pk);
        } catch {
            // If PRIVATE_KEY not set, use the address that will broadcast
            deployer = msg.sender;
        }
        // Check deployer balance (informational - will fail later if insufficient)
        uint256 balance = deployer.balance;
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", balance / 1e18, "ETH");

        if (balance < 0.001 ether) {
            console.log(
                "WARNING: Low balance detected. You may need to fund your account."
            );
            console.log("Estimated gas cost: ~0.003 ETH");
            console.log("Get Sepolia ETH from: https://sepoliafaucet.com/");
        }

        // Option: Use deployer address as governance for testing
        // For testing, uncomment the line below to use deployer as governance
        // address governanceAddress = deployer;

        // Or use the constant defined above (for production with a governance contract)
        address governanceAddress = GOVERNANCE;

        // If GOVERNANCE is still the placeholder, use deployer as fallback
        if (
            governanceAddress ==
            address(0x2345678901234567890123456789012345678901)
        ) {
            governanceAddress = deployer;
            console.log(
                "Using deployer address as governance (testing mode):",
                deployer
            );
        }
        // Hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
        // Pass governance address (or address(0) if not set) to constructor
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

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        console.log("Pool Manager:", address(POOLMANAGER));

        // Deploy the hook using CREATE2
        vm.broadcast();
        ConfidentialRebalancingHook hook = new ConfidentialRebalancingHook{
            salt: salt
        }(POOLMANAGER, governanceAddress);

        require(
            address(hook) == hookAddress,
            "DeployConfidentialRebalancingHook: hook address mismatch"
        );

        console.log("ConfidentialRebalancingHook deployed at:", address(hook));
        console.log("Hook permissions verified");

        // Set up authorized executors
        // Note: Governance is already set in constructor, so we don't need to call setGovernance
        vm.startBroadcast();

        console.log("Governance set in constructor to:", governanceAddress);

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
        console.log("1. Set GOVERNANCE address");
        console.log("2. Configure AUTHORIZED_EXECUTORS");
        console.log("3. Deploy to testnet first");
        console.log("4. Test with real pools before mainnet deployment");
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

        // Verify governance is set (skip if using deployer address for testing)
        if (GOVERNANCE != address(0x2345678901234567890123456789012345678901)) {
            require(
                hook.governance() == GOVERNANCE,
                "Governance not set correctly"
            );
        }
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
contract DeployConfidentialRebalancingHookTestnet is Script, Constants {
    // Testnet governance address (update this for your testnet)
    address constant TESTNET_GOVERNANCE =
        address(0x2345678901234567890123456789012345678901);

    function run() public {
        // Get deployer address for governance
        address deployer;
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            deployer = vm.addr(pk);
        } catch {
            deployer = msg.sender;
        }
        address governanceAddress = TESTNET_GOVERNANCE;
        if (
            governanceAddress ==
            address(0x2345678901234567890123456789012345678901)
        ) {
            governanceAddress = deployer;
            console.log(
                "Using deployer address as governance (testing mode):",
                deployer
            );
        }

        // Hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
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

        // Deploy hook using CREATE2
        vm.broadcast();
        ConfidentialRebalancingHook hook = new ConfidentialRebalancingHook{
            salt: salt
        }(POOLMANAGER, governanceAddress);

        require(
            address(hook) == hookAddress,
            "DeployConfidentialRebalancingHookTestnet: hook address mismatch"
        );

        // Set up testnet configuration
        // Note: Governance is already set in constructor
        vm.startBroadcast();

        // Add test accounts as authorized executors
        hook.addAuthorizedExecutor(address(this)); // Script deployer
        hook.addAuthorizedExecutor(msg.sender); // Transaction sender
        vm.stopBroadcast();

        console.log("Testnet deployment completed!");
        console.log("Hook address:", address(hook));
        console.log("Pool Manager:", address(POOLMANAGER));
        console.log("Governance:", governanceAddress);
    }
}



// == Logs ==
//   Deployer address: 0x8822F2965090Ddc102F7de354dfd6E642C090269
//   Deployer balance: 0 ETH
//   Using deployer address as governance (testing mode): 0x8822F2965090Ddc102F7de354dfd6E642C090269
//   Mined hook address: 0xd6F8dDC186434d891B8653FF2083436067114aC0
//   Salt: 0x0000000000000000000000000000000000000000000000000000000000004112
//   Pool Manager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
//   ConfidentialRebalancingHook deployed at: 0xd6F8dDC186434d891B8653FF2083436067114aC0
//   Hook permissions verified
//   Governance set in constructor to: 0x8822F2965090Ddc102F7de354dfd6E642C090269
//   Added authorized executor: 0x3456789012345678901234567890123456789012
//   Added authorized executor: 0x4567890123456789012345678901234567890123
//   Hook permissions verified:
//   - beforeSwap: true
//   - afterSwap: true
//   - beforeAddLiquidity: true
//   - beforeRemoveLiquidity: true
//   Governance verified: 0x8822F2965090Ddc102F7de354dfd6E642C090269
//   Authorized executors verified
//   Deployment completed successfully!
