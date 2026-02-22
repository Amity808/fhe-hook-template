// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
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

// Test settings for V4SwapRouter
struct TestSettings {
    bool takeClaims;
    bool settleUsingBurn;
}

// V4SwapRouter interface (UniswapV4Router04)
interface IV4SwapRouter {
    function swap(
        int256 amountSpecified,
        uint256 amountLimit,
        bool zeroForOne,
        PoolKey calldata poolKey,
        bytes calldata hookData,
        address receiver,
        uint256 deadline
    ) external payable returns (int256);
}

/**
 * @title SwapWithV4Router
 * @notice Performs swaps using the official Hookmate V4SwapRouter
 */
contract SwapWithV4Router is Script, Constants, Config {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Official Hookmate V4SwapRouter on Sepolia (production-ready)
    address constant V4_SWAP_ROUTER = 0xf13D190e9117920c703d79B5F33732e10049b115;

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
        console.log("V4SwapRouter:", V4_SWAP_ROUTER);

        vm.startBroadcast();

        // Approve tokens to the swap router
        if (zeroForOne && !currency0.isAddressZero()) {
            token0.approve(V4_SWAP_ROUTER, type(uint256).max);
            console.log("Token0 approved to V4SwapRouter");
        }
        if (!zeroForOne && !currency1.isAddressZero()) {
            token1.approve(V4_SWAP_ROUTER, type(uint256).max);
            console.log("Token1 approved to V4SwapRouter");
        }

        // Prepare swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        // Test settings for V4SwapRouter
        TestSettings memory testSettings = TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        console.log("Executing swap...");
        // UniV4SwapRouter04.swap parameters:
        // amountSpecified, amountLimit, zeroForOne, poolKey, hookData, receiver, deadline
        IV4SwapRouter(V4_SWAP_ROUTER).swap(
            -int256(swapAmount), // amountSpecified
            0, // amountLimit (0 for no slippage protection in this test)
            zeroForOne, // zeroForOne
            pool, // poolKey
            "", // hookData
            msg.sender, // receiver
            type(uint256).max // deadline (use max to avoid issues on testnets)
        );

        console.log("=== Swap Completed Successfully! ===");

        vm.stopBroadcast();
    }
}
