// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {
    CurrencyLibrary,
    Currency
} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {
    ConfidentialRebalancingHook
} from "../src/ConfidentialRebalancingHook.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

/**
 * @title SwapScript
 * @dev Performs swaps on Uniswap v4 pools with ConfidentialRebalancingHook
 *
 * Hook Integration:
 * - The hook is automatically called during swaps via beforeSwap() and afterSwap()
 * - If strategies are registered to the pool, the hook will:
 *   1. Calculate trade deltas for rebalancing
 *   2. Update encrypted positions after swaps
 *   3. Execute confidential rebalancing logic
 * - If no strategies are registered, the hook will still be called but won't execute rebalancing
 *
 * To enable rebalancing:
 * 1. Create a strategy: hook.createStrategy(strategyId, ...)
 * 2. Set target allocations: hook.setTargetAllocation(strategyId, currency, ...)
 * 3. Set encrypted positions: hook.setEncryptedPosition(strategyId, currency, ...)
 * 4. Register pool to strategy: hook.enableCrossPoolCoordination(strategyId, [poolId])
 */
contract SwapScript is Script, Constants, Config {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // slippage tolerance to allow for unlimited price impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // PoolSwapTest Contract address on Sepolia
    PoolSwapTest swapRouter =
        PoolSwapTest(0xf13D190e9117920c703d79B5F33732e10049b115);

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // --- swap configuration --- //
    uint256 public swapAmount = 0.1e18; // Amount to swap (in token0 if zeroForOne = true)
    bool public zeroForOne = true; // true = swap token0 -> token1, false = swap token1 -> token0

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
        require(
            sqrtPriceX96 != 0,
            "Pool not initialized. Run 01_CreatePoolAndMintLiquidity.s.sol first"
        );

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

        // Check hook integration
        // Note: poolStrategies mapping getter has compatibility issues with PoolId type
        // The hook will still be called during swaps regardless of strategy registration
        console.log("Hook address:", address(hookContract));
        console.log("Hook will be called during swap execution");

        // Approve tokens to the swap router
        vm.startBroadcast();

        if (zeroForOne && !currency0.isAddressZero()) {
            token0.approve(address(swapRouter), type(uint256).max);
            console.log("Token0 approved to swap router");
        }
        if (!zeroForOne && !currency1.isAddressZero()) {
            token1.approve(address(swapRouter), type(uint256).max);
            console.log("Token1 approved to swap router");
        }

        // Prepare swap parameters
        // Note: Negative amountSpecified = exact input swap (sending exact amount in)
        //       Positive amountSpecified = exact output swap (requesting exact amount out)
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount), // Negative for exact input swap
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT // unlimited impact
        });

        // In v4, users have the option to receive native ERC20s or wrapped ERC1155 tokens
        // Here, we'll take the ERC20s
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        // Hook data - can be used to pass additional data to the hook
        // For ConfidentialRebalancingHook, this can be used for strategy-specific parameters
        bytes memory hookData = new bytes(0);

        console.log("Executing swap...");
        BalanceDelta delta = swapRouter.swap(
            pool,
            params,
            testSettings,
            hookData
        );

        console.log("=== Swap Completed ===");
        console.log("Delta amount0:", int256(delta.amount0()));
        console.log("Delta amount1:", int256(delta.amount1()));
        console.log("Hook was called during swap execution");

        vm.stopBroadcast();
    }
}
