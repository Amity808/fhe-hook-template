// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {SimpleSwapRouter} from "../src/SimpleSwapRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

/**
 * @title SwapWithSimpleRouter
 * @notice Performs swaps using the production SimpleSwapRouter
 */
contract SwapWithSimpleRouter is Script, Constants, Config {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Official Hookmate V4SwapRouter on Sepolia (production-ready)
    address swapRouter = 0x908480BAfaD7a2E76193B281EE0A045b5D6ff079; // SimpleSwapRouter (WORKING)

    // Pool configuration
    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // Swap configuration
    uint256 public swapAmount = 0.1e18;
    bool public zeroForOne = true;

    // Slippage tolerance
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    function run() external {
        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        PoolId poolId = pool.toId();

        // Check if pool is initialized
        (uint160 sqrtPriceX96, , , ) = POOLMANAGER.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "Pool not initialized");

        console.log("=== Swap Configuration ===");
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("Currency0:", Currency.unwrap(currency0));
        console.log("Currency1:", Currency.unwrap(currency1));
        console.log("Hook:", address(hookContract));
        console.log(
            "Swap direction:",
            zeroForOne ? "Token0 -> Token1" : "Token1 -> Token0"
        );
        console.log("Swap amount:", swapAmount);
        console.log("Current sqrtPriceX96:", sqrtPriceX96);
        console.log("SimpleSwapRouter:", address(swapRouter));

        vm.startBroadcast();

        // Approve tokens to the swap router
        if (zeroForOne && !currency0.isAddressZero()) {
            token0.approve(address(swapRouter), type(uint256).max);
            console.log("Token0 approved to SimpleSwapRouter");
        }
        if (!zeroForOne && !currency1.isAddressZero()) {
            token1.approve(address(swapRouter), type(uint256).max);
            console.log("Token1 approved to SimpleSwapRouter");
        }

        // Prepare swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        console.log("Executing swap...");
        BalanceDelta delta = SimpleSwapRouter(payable(swapRouter)).swap(pool, params);

        console.log("=== Swap Completed Successfully! ===");
        console.log("Delta amount0:", int256(delta.amount0()));
        console.log("Delta amount1:", int256(delta.amount1()));
        console.log("Hook was called during swap execution");

        vm.stopBroadcast();
    }
}
