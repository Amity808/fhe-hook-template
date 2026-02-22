// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {SimpleSwapRouter} from "../src/SimpleSwapRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

/**
 * @title DeploySimpleSwapRouter
 * @notice Deploys the SimpleSwapRouter for Sepolia testnet
 */
contract DeploySimpleSwapRouter is Script, Constants, Config {
    function run() external {
        console.log("=== Deploying SimpleSwapRouter ===");
        console.log("PoolManager:", address(POOLMANAGER));
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();

        SimpleSwapRouter router = new SimpleSwapRouter(POOLMANAGER);

        console.log("=== Deployment Complete ===");
        console.log("SimpleSwapRouter deployed at:", address(router));
        console.log("");
        console.log("Update your scripts to use this address:");
        console.log("SWAP_ROUTER_ADDRESS=", address(router));

        vm.stopBroadcast();
    }
}
