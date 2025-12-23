// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    CurrencyLibrary,
    Currency
} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

contract CreatePoolOnly is Script, Constants, Config {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // NOTE: Be sure to set the addresses in Constants.sol and Config.sol

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // starting price of the pool, in sqrtPriceX96
    uint160 startingPrice = 79228162514264337593543950336; // floor(sqrt(1) * 2^96)
    /////////////////////////////////////

    function run() external {
        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        PoolId poolId = pool.toId();

        console.log("=== Pool Creation Script ===");
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("Currency0:", Currency.unwrap(currency0));
        console.log("Currency1:", Currency.unwrap(currency1));
        console.log("Hook:", address(hookContract));
        console.log("Fee:", lpFee);
        console.log("Tick Spacing:", tickSpacing);
        console.log("Starting price (sqrtPriceX96):", startingPrice);

        // Check if pool is already initialized using getSlot0 (library function reads storage)
        // This avoids Foundry simulation issues by checking before broadcasting
        (uint160 sqrtPriceX96, , , ) = POOLMANAGER.getSlot0(poolId);
        bool poolAlreadyInitialized = sqrtPriceX96 != 0;

        if (poolAlreadyInitialized) {
            console.log("\nPool already exists and is initialized!");
            console.log("Current sqrtPriceX96:", sqrtPriceX96);
            console.log("No action needed - pool is ready to use.");
            console.log("\nNext steps:");
            console.log(
                "1. Add liquidity: forge script script/02_AddLiquidity.s.sol --rpc-url $RPC_URL --broadcast"
            );
            console.log("2. Create strategy and swap: node index.js");
            return; // Exit early - pool already exists
        }

        // Pool doesn't exist - initialize it
        console.log("\nPool does not exist. Initializing pool...");
        vm.startBroadcast();

        IPoolManager(POOLMANAGER).initialize(pool, startingPrice);

        console.log("Pool initialized successfully!");
        console.log("\nNext steps:");
        console.log(
            "1. Add liquidity: forge script script/02_AddLiquidity.s.sol --rpc-url $RPC_URL --broadcast"
        );
        console.log("2. Create strategy and swap: node index.js");

        vm.stopBroadcast();
    }
}
