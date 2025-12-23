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
import {
    FHE,
    InEuint128,
    euint128
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

/**
 * @title SwapWithFHEScript
 * @dev Performs swaps with FHE encryption testing
 *
 * PRODUCTION FRONTEND IMPLEMENTATION:
 * The frontend will use Fhenix SDK (cofhejs) to encrypt values - NO manual struct construction needed.
 *
 * Frontend code example (TypeScript/JavaScript):
 *   import { cofhejs, Encryptable } from 'cofhejs';
 *   const encryptedValues = await cofhejs.encrypt([
 *     Encryptable.uint128(100n),  // executionWindow
 *     Encryptable.uint128(10n),   // spreadBlocks
 *     Encryptable.uint128(500n)   // maxSlippage
 *   ]);
 *   await hook.createStrategy(strategyId, frequency, encryptedValues[0], encryptedValues[1], encryptedValues[2]);
 *
 * NOTE: This script requires encrypted InEuint128 values to be provided externally (e.g., from frontend).
 * For testing, use the test suite which has proper FHE test helpers.
 *
 * This script demonstrates the flow:
 * 1. Sets up a rebalancing strategy with encrypted parameters
 * 2. Sets encrypted target allocations
 * 3. Sets encrypted positions
 * 4. Registers the pool to the strategy
 * 5. Performs a swap that triggers FHE operations
 *
 * Uses the same approach as: test/ConfidentialRebalancingHook.t.sol
 */
contract SwapWithFHEScript is Script, Constants, Config {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // slippage tolerance to allow for unlimited price impact
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // PoolSwapTest Contract address on Sepolia
    PoolSwapTest swapRouter =
        PoolSwapTest(0xf13D190e9117920c703d79B5F33732e10049b115);

    // Pool configuration
    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // Swap configuration
    uint256 public swapAmount = 0.1e18;
    bool public zeroForOne = true;

    // Strategy configuration
    bytes32 public strategyId = keccak256("test-strategy-001");
    uint256 public rebalanceFrequency = 10; // blocks

    function run() external {
        address deployer = _resolveRecipient();

        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        PoolId poolId = pool.toId();
        ConfidentialRebalancingHook hook = ConfidentialRebalancingHook(
            address(hookContract)
        );

        // Check if pool is initialized
        (uint160 sqrtPriceX96, , , ) = POOLMANAGER.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "Pool not initialized");

        console.log("=== FHE Swap Test Setup ===");
        console.log("Deployer:", deployer);
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("Hook:", address(hook));

        // Check if strategy already exists
        ConfidentialRebalancingHook.RebalancingStrategy
            memory existingStrategy = hook.getStrategy(strategyId);
        if (existingStrategy.strategyId != bytes32(0)) {
            console.log(
                "WARNING: Strategy already exists:",
                vm.toString(strategyId)
            );
            console.log("Owner:", existingStrategy.owner);
            console.log("Is active:", existingStrategy.isActive);
            console.log(
                "Skipping strategy creation, using existing strategy..."
            );
        } else {
            console.log("Strategy does not exist, will create new one");
        }

        vm.startBroadcast();

        // Step 1: Verify strategy exists (cannot create without CoFheTest)
        console.log("\n--- Step 1: Verifying Strategy ---");

        // NOTE: Strategy creation requires encrypted InEuint128 values.
        // Since CoFheTest (test-only helper) has been removed, this script
        // can only work with existing strategies. To create a strategy, use:
        // 1. The test suite (which has CoFheTest), or
        // 2. A frontend using cofhejs SDK to encrypt values
        require(
            existingStrategy.strategyId != bytes32(0),
            "Strategy does not exist. Cannot create without encrypted values. Use test suite or frontend to create strategy first."
        );
        console.log("Strategy exists, proceeding with swap...");

        // Step 2: Ensure pool is registered to strategy
        // Note: We can't easily check if pool is registered without iterating through indices,
        // so we'll attempt to register it. If it's already registered, the transaction will
        // still succeed (the hook allows re-registration).
        console.log("\n--- Step 2: Ensuring Pool Registration ---");
        console.log(
            "Registering pool to strategy (safe to call if already registered)..."
        );
        PoolId[] memory pools = new PoolId[](1);
        pools[0] = poolId;
        hook.enableCrossPoolCoordination(strategyId, pools);
        console.log(
            "Pool registered to strategy - hook will execute during swaps"
        );

        // Step 3: Approve tokens for swap
        console.log("\n--- Step 4: Approving Tokens ---");
        if (zeroForOne && !currency0.isAddressZero()) {
            token0.approve(address(swapRouter), type(uint256).max);
            console.log("Token0 approved");
        }
        if (!zeroForOne && !currency1.isAddressZero()) {
            token1.approve(address(swapRouter), type(uint256).max);
            console.log("Token1 approved");
        }

        // Step 4: Execute swap (this will trigger FHE operations)
        console.log("\n--- Step 5: Executing Swap with FHE Operations ---");
        console.log("Swap amount:", swapAmount);
        console.log(
            "Direction:",
            zeroForOne ? "Token0 -> Token1" : "Token1 -> Token0"
        );

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes memory hookData = new bytes(0);

        // Execute swap - hook will be called and FHE operations will execute
        BalanceDelta delta = swapRouter.swap(
            pool,
            params,
            testSettings,
            hookData
        );

        console.log("\n=== Swap Completed ===");
        console.log("Delta amount0:", int256(delta.amount0()));
        console.log("Delta amount1:", int256(delta.amount1()));
        console.log("\nFHE Operations Executed:");
        console.log("- beforeSwap: Calculated encrypted trade deltas");
        console.log("- afterSwap: Updated encrypted positions using FHE.add");
        console.log("- Recalculated trade deltas with encrypted comparisons");

        // Verify strategy was updated
        ConfidentialRebalancingHook.RebalancingStrategy memory strategy = hook
            .getStrategy(strategyId);
        console.log("\nStrategy Status:");
        console.log("Last rebalance block:", strategy.lastRebalanceBlock);
        console.log("Is active:", strategy.isActive);

        vm.stopBroadcast();
    }

    function _resolveRecipient() internal view returns (address) {
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            return vm.addr(pk);
        } catch {}
        try vm.envUint("PRVATE_KEY11") returns (uint256 pkLegacy) {
            return vm.addr(pkLegacy);
        } catch {}
        try vm.envUint("OWNER_PRIVATE_KEY") returns (uint256 ownerPk) {
            return vm.addr(ownerPk);
        } catch {}
        return msg.sender;
    }
}
