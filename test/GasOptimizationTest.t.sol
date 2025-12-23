// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    ConfidentialRebalancingHook
} from "../src/ConfidentialRebalancingHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    FHE,
    InEuint128,
    euint128
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {
    LiquidityAmounts
} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {
    IPositionManager
} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {SortTokens} from "./utils/SortTokens.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";
import {IFHERC20} from "../src/interface/IFHERC20.sol";

/**
 * @title GasOptimizationTest
 * @dev Comprehensive gas optimization testing and analysis for ConfidentialRebalancingHook
 *
 * This test suite focuses on:
 * - Identifying gas-intensive operations
 * - Measuring gas usage across different scenarios
 * - Testing optimization strategies
 * - Validating performance improvements
 */
contract GasOptimizationTest is Test, Fixtures {
    using PoolIdLibrary for PoolKey;

    ConfidentialRebalancingHook public hook;
    CoFheTest private CFT;

    address public user = address(0x1001);
    address public executor = address(0x1002);
    bytes32 public strategyId = keccak256("gas_test_strategy");

    function setUp() public {
        // Initialize CFT
        CFT = new CoFheTest(true);

        // Create the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();

        // Deploy FHE tokens
        bytes memory token0Args = abi.encode("TOKEN0", "TOK0");
        deployCodeTo(
            "HybridFHERC20.sol:HybridFHERC20",
            token0Args,
            address(123)
        );

        bytes memory token1Args = abi.encode("TOKEN1", "TOK1");
        deployCodeTo(
            "HybridFHERC20.sol:HybridFHERC20",
            token1Args,
            address(456)
        );

        // Set up currencies
        vm.startPrank(user);
        (currency0, currency1) = mintAndApprove2Currencies(
            address(123),
            address(456)
        );
        vm.stopPrank();

        // Deploy the hook
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );

        bytes memory constructorArgs = abi.encode(manager, address(0));
        deployCodeTo(
            "ConfidentialRebalancingHook.sol:ConfidentialRebalancingHook",
            constructorArgs,
            flags
        );
        hook = ConfidentialRebalancingHook(flags);

        // Set up governance (test contract is authorized executor from constructor)
        hook.setGovernance(address(this));

        // Add authorized executor (as governance)
        vm.prank(address(this));
        hook.addAuthorizedExecutor(executor);

        vm.label(address(hook), "hook");
        vm.label(user, "user");
        vm.label(executor, "executor");
    }

    function testStrategyCreationGasUsage() public {
        console.log("=== Strategy Creation Gas Analysis ===");

        vm.startPrank(user);

        // Measure gas for strategy creation
        uint256 gasStart = gasleft();

        InEuint128 memory executionWindow = CFT.createInEuint128(3600, user);
        InEuint128 memory spreadBlocks = CFT.createInEuint128(100, user);
        InEuint128 memory maxSlippage = CFT.createInEuint128(500, user);

        bool success = hook.createStrategy(
            strategyId,
            100,
            executionWindow,
            spreadBlocks,
            maxSlippage
        );

        uint256 gasUsed = gasStart - gasleft();

        assertTrue(success, "Strategy creation should succeed");
        console.log("Strategy creation gas used:", gasUsed);

        // Target: < 800K gas (includes FHE encryption operations)
        assertTrue(
            gasUsed < 800000,
            "Strategy creation should be under 800K gas"
        );

        vm.stopPrank();
    }

    function testTargetAllocationGasUsage() public {
        console.log("=== Target Allocation Gas Analysis ===");

        // First create strategy
        vm.startPrank(user);
        _createBasicStrategy();
        vm.stopPrank();

        vm.startPrank(user);

        // Measure gas for setting target allocations
        uint256 gasStart = gasleft();

        InEuint128 memory targetPercentage = CFT.createInEuint128(5000, user);
        InEuint128 memory minThreshold = CFT.createInEuint128(100, user);
        InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);

        hook.setTargetAllocation(
            strategyId,
            currency0,
            targetPercentage,
            minThreshold,
            maxThreshold
        );

        uint256 gasUsed = gasStart - gasleft();

        console.log("Single target allocation gas used:", gasUsed);

        // Target: < 1.2M gas
        assertTrue(
            gasUsed < 1200000,
            "Target allocation should be under 1.2M gas"
        );

        vm.stopPrank();
    }

    function testBatchOperationsGasUsage() public {
        console.log("=== Batch Operations Gas Analysis ===");

        // First create strategy
        vm.startPrank(user);
        _createBasicStrategy();
        vm.stopPrank();

        vm.startPrank(user);

        // Measure gas for batch operations
        uint256 gasStart = gasleft();

        // Set multiple target allocations in one transaction
        InEuint128 memory targetPercentage = CFT.createInEuint128(5000, user);
        InEuint128 memory minThreshold = CFT.createInEuint128(100, user);
        InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);

        hook.setTargetAllocation(
            strategyId,
            currency0,
            targetPercentage,
            minThreshold,
            maxThreshold
        );

        hook.setTargetAllocation(
            strategyId,
            currency1,
            targetPercentage,
            minThreshold,
            maxThreshold
        );

        // Set encrypted positions
        InEuint128 memory position = CFT.createInEuint128(500000, user);
        hook.setEncryptedPosition(strategyId, currency0, position);
        hook.setEncryptedPosition(strategyId, currency1, position);

        uint256 gasUsed = gasStart - gasleft();

        console.log("Batch operations gas used:", gasUsed);

        // Target: < 2.5M gas for batch operations
        assertTrue(
            gasUsed < 2500000,
            "Batch operations should be under 2.5M gas"
        );

        vm.stopPrank();
    }

    function testRebalancingCalculationGasUsage() public {
        console.log("=== Rebalancing Calculation Gas Analysis ===");

        // Set up complete strategy
        vm.startPrank(user);
        _createCompleteStrategy();
        vm.stopPrank();

        // Measure gas for rebalancing calculation
        uint256 gasStart = gasleft();

        vm.prank(user);
        bool success = hook.calculateRebalancing(strategyId);

        uint256 gasUsed = gasStart - gasleft();

        assertTrue(success, "Rebalancing calculation should succeed");
        console.log("Rebalancing calculation gas used:", gasUsed);

        // Target: < 2.5M gas
        assertTrue(
            gasUsed < 2500000,
            "Rebalancing calculation should be under 2.5M gas"
        );

        vm.stopPrank();
    }

    function testRebalancingExecutionGasUsage() public {
        console.log("=== Rebalancing Execution Gas Analysis ===");

        // Set up complete strategy
        vm.startPrank(user);
        _createCompleteStrategy();
        vm.stopPrank();

        // Calculate rebalancing first
        vm.prank(user);
        hook.calculateRebalancing(strategyId);

        // Advance blocks to meet frequency requirement
        vm.roll(block.number + 100);

        // Measure gas for rebalancing execution
        uint256 gasStart = gasleft();

        vm.prank(executor);
        bool success = hook.executeRebalancing(strategyId);

        uint256 gasUsed = gasStart - gasleft();

        assertTrue(success, "Rebalancing execution should succeed");
        console.log("Rebalancing execution gas used:", gasUsed);

        // Target: < 3.5M gas
        assertTrue(
            gasUsed < 3500000,
            "Rebalancing execution should be under 3.5M gas"
        );

        vm.stopPrank();
    }

    function testFHEOperationsGasUsage() public {
        console.log("=== FHE Operations Gas Analysis ===");

        vm.startPrank(user);
        _createCompleteStrategy();
        vm.stopPrank();

        // Test individual FHE operations
        vm.startPrank(user);

        // Test encrypted position updates
        uint256 gasStart = gasleft();
        InEuint128 memory position = CFT.createInEuint128(1000000, user);
        hook.setEncryptedPosition(strategyId, currency0, position);
        uint256 positionGas = gasStart - gasleft();

        console.log("Encrypted position update gas:", positionGas);

        // Test encrypted allocation updates
        gasStart = gasleft();
        InEuint128 memory target = CFT.createInEuint128(6000, user);
        InEuint128 memory minThreshold = CFT.createInEuint128(100, user);
        InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);

        hook.setTargetAllocation(
            strategyId,
            currency1,
            target,
            minThreshold,
            maxThreshold
        );
        uint256 allocationGas = gasStart - gasleft();

        console.log("Encrypted allocation update gas:", allocationGas);

        vm.stopPrank();
    }

    function testCrossPoolCoordinationGasUsage() public {
        console.log("=== Cross-Pool Coordination Gas Analysis ===");

        vm.startPrank(user);
        _createCompleteStrategy();
        vm.stopPrank();

        vm.startPrank(user);

        // Measure gas for cross-pool coordination setup
        uint256 gasStart = gasleft();

        PoolId[] memory pools = new PoolId[](1);
        pools[0] = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        }).toId();

        hook.enableCrossPoolCoordination(strategyId, pools);

        uint256 gasUsed = gasStart - gasleft();

        console.log("Cross-pool coordination setup gas:", gasUsed);

        // Target: < 500K gas
        assertTrue(
            gasUsed < 500000,
            "Cross-pool coordination should be under 500K gas"
        );

        vm.stopPrank();
    }

    function testComplianceReportingGasUsage() public {
        console.log("=== Compliance Reporting Gas Analysis ===");

        vm.startPrank(user);
        _createCompleteStrategy();

        // Enable compliance reporting
        uint256 gasStart = gasleft();
        hook.enableComplianceReporting(strategyId, user);
        uint256 enableGas = gasStart - gasleft();

        console.log("Enable compliance reporting gas:", enableGas);

        vm.stopPrank();

        // Test compliance report generation
        vm.prank(user);
        hook.calculateRebalancing(strategyId);

        vm.startPrank(user);
        gasStart = gasleft();
        bool success = hook.generateComplianceReport(strategyId);
        uint256 reportGas = gasStart - gasleft();

        console.log("Generate compliance report gas:", reportGas);

        // Target: < 1M gas for compliance operations
        assertTrue(
            enableGas < 1000000,
            "Enable compliance should be under 1M gas"
        );
        assertTrue(
            reportGas < 1000000,
            "Generate report should be under 1M gas"
        );

        vm.stopPrank();
    }

    function testLargeScaleOperationsGasUsage() public {
        console.log("=== Large Scale Operations Gas Analysis ===");

        vm.startPrank(user);

        // Create multiple strategies to test scalability
        bytes32[] memory strategyIds = new bytes32[](5);

        uint256 totalGasStart = gasleft();

        for (uint256 i = 0; i < 5; i++) {
            strategyIds[i] = keccak256(abi.encodePacked("strategy_", i));

            InEuint128 memory executionWindow = CFT.createInEuint128(
                3600,
                user
            );
            InEuint128 memory spreadBlocks = CFT.createInEuint128(100, user);
            InEuint128 memory maxSlippage = CFT.createInEuint128(500, user);

            hook.createStrategy(
                strategyIds[i],
                100,
                executionWindow,
                spreadBlocks,
                maxSlippage
            );

            // Set up allocations for each strategy
            InEuint128 memory target = CFT.createInEuint128(5000, user);
            InEuint128 memory minThreshold = CFT.createInEuint128(100, user);
            InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);

            hook.setTargetAllocation(
                strategyIds[i],
                currency0,
                target,
                minThreshold,
                maxThreshold
            );

            InEuint128 memory position = CFT.createInEuint128(500000, user);
            hook.setEncryptedPosition(strategyIds[i], currency0, position);
        }

        uint256 totalGasUsed = totalGasStart - gasleft();

        console.log("Large scale operations total gas:", totalGasUsed);
        console.log("Average gas per strategy:", totalGasUsed / 5);

        // Target: < 15M gas for 5 strategies
        assertTrue(
            totalGasUsed < 15000000,
            "Large scale operations should be under 15M gas"
        );

        vm.stopPrank();
    }

    function testGasOptimizationRecommendations() public {
        console.log("=== Gas Optimization Recommendations ===");

        // Analyze current gas usage patterns
        vm.startPrank(user);
        _createCompleteStrategy();

        // Test different optimization strategies
        _testBatchOptimization();
        _testCachingOptimization();
        _testReducedFHEOperations();

        vm.stopPrank();
        console.log("Gas optimization analysis completed");
    }

    // Helper functions

    function _createBasicStrategy() internal {
        InEuint128 memory executionWindow = CFT.createInEuint128(3600, user);
        InEuint128 memory spreadBlocks = CFT.createInEuint128(100, user);
        InEuint128 memory maxSlippage = CFT.createInEuint128(500, user);

        hook.createStrategy(
            strategyId,
            100,
            executionWindow,
            spreadBlocks,
            maxSlippage
        );
    }

    function _createCompleteStrategy() internal {
        _createBasicStrategy();

        InEuint128 memory targetPercentage = CFT.createInEuint128(5000, user);
        InEuint128 memory minThreshold = CFT.createInEuint128(100, user);
        InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);

        hook.setTargetAllocation(
            strategyId,
            currency0,
            targetPercentage,
            minThreshold,
            maxThreshold
        );

        hook.setTargetAllocation(
            strategyId,
            currency1,
            targetPercentage,
            minThreshold,
            maxThreshold
        );

        InEuint128 memory position = CFT.createInEuint128(500000, user);
        hook.setEncryptedPosition(strategyId, currency0, position);
        hook.setEncryptedPosition(strategyId, currency1, position);
    }

    function _testBatchOptimization() internal {
        console.log("Testing batch optimization strategies...");

        // Test batching multiple operations
        uint256 gasStart = gasleft();

        // Batch multiple target allocations
        InEuint128 memory target = CFT.createInEuint128(5000, user);
        InEuint128 memory minThreshold = CFT.createInEuint128(100, user);
        InEuint128 memory maxThreshold = CFT.createInEuint128(1000, user);

        hook.setTargetAllocation(
            strategyId,
            currency0,
            target,
            minThreshold,
            maxThreshold
        );
        hook.setTargetAllocation(
            strategyId,
            currency1,
            target,
            minThreshold,
            maxThreshold
        );

        uint256 gasUsed = gasStart - gasleft();
        console.log("Batch optimization gas used:", gasUsed);
    }

    function _testCachingOptimization() internal {
        console.log("Testing caching optimization strategies...");

        // Test reusing encrypted values
        uint256 gasStart = gasleft();

        InEuint128 memory cachedValue = CFT.createInEuint128(5000, user);

        // Reuse the same encrypted value multiple times
        hook.setEncryptedPosition(strategyId, currency0, cachedValue);
        hook.setEncryptedPosition(strategyId, currency1, cachedValue);

        uint256 gasUsed = gasStart - gasleft();
        console.log("Caching optimization gas used:", gasUsed);
    }

    function _testReducedFHEOperations() internal {
        console.log("Testing reduced FHE operations...");

        // Test minimizing FHE operations
        uint256 gasStart = gasleft();

        // Use simpler operations where possible
        InEuint128 memory simpleValue = CFT.createInEuint128(1000, user);
        hook.setEncryptedPosition(strategyId, currency0, simpleValue);

        uint256 gasUsed = gasStart - gasleft();
        console.log("Reduced FHE operations gas used:", gasUsed);
    }

    function mintAndApprove2Currencies(
        address tokenA,
        address tokenB
    ) internal returns (Currency, Currency) {
        Currency _currencyA = mintAndApproveCurrency(tokenA);
        Currency _currencyB = mintAndApproveCurrency(tokenB);

        (currency0, currency1) = SortTokens.sort(
            Currency.unwrap(_currencyA),
            Currency.unwrap(_currencyB)
        );
        return (currency0, currency1);
    }

    function mintAndApproveCurrency(
        address token
    ) internal returns (Currency currency) {
        IFHERC20(token).mint(user, 2 ** 250);
        IFHERC20(token).mint(address(this), 2 ** 250);

        InEuint128 memory amountUser = CFT.createInEuint128(2 ** 120, user);
        IFHERC20(token).mintEncrypted(user, amountUser);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            IFHERC20(token).approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(token);
    }
}
