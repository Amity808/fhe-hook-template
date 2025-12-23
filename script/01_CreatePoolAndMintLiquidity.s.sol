// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    CurrencyLibrary,
    Currency
} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {
    LiquidityAmounts
} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

contract CreatePoolAndAddLiquidityScript is Script, Constants, Config {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // starting price of the pool, in sqrtPriceX96
    uint160 startingPrice = 79228162514264337593543950336; // floor(sqrt(1) * 2^96)

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 1e18;
    uint256 public token1Amount = 1e18;

    // range of the position
    int24 tickLower = -600; // must be a multiple of tickSpacing
    int24 tickUpper = 600;
    /////////////////////////////////////

    function run() external {
        // Get the deployer address (the address that will deploy the contract)
        address recipient = _resolveRecipient();
        // Check account balance before proceeding
        uint256 balance = recipient.balance;
        uint256 minRequiredBalance = 0.00001 ether; // Minimum ~0.00001 ETH for gas (10,000 gwei)

        console.log("Account:", recipient);
        console.log("Current balance:", balance);
        console.log("Minimum required:", minRequiredBalance);

        if (balance < minRequiredBalance) {
            console.log("ERROR: Insufficient ETH balance");
            console.log("Please fund your account with at least 0.00001 ETH");
            revert("Insufficient ETH balance for gas");
        }

        console.log("ETH balance check passed, proceeding with transaction...");

        // Check token balances
        if (!currency0.isAddressZero()) {
            uint256 token0Balance = token0.balanceOf(recipient);
            console.log("Token0 balance:", token0Balance);
            console.log("Token0 required:", token0Amount);
            if (token0Balance < token0Amount) {
                console.log("ERROR: Insufficient Token0 balance");
                console.log("Token0 address:", address(token0));
                console.log(
                    "Please ensure your account has at least",
                    token0Amount,
                    "Token0"
                );
                revert("Insufficient Token0 balance");
            }
        }

        if (!currency1.isAddressZero()) {
            uint256 token1Balance = token1.balanceOf(recipient);
            console.log("Token1 balance:", token1Balance);
            console.log("Token1 required:", token1Amount);
            if (token1Balance < token1Amount) {
                console.log("ERROR: Insufficient Token1 balance");
                console.log("Token1 address:", address(token1));
                console.log(
                    "Please ensure your account has at least",
                    token1Amount,
                    "Token1"
                );
                revert("Insufficient Token1 balance");
            }
        }

        console.log("All balance checks passed!");

        // tokens should be sorted
        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });
        bytes memory hookData = new bytes(0);

        // --------------------------------- //

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        // slippage limits
        uint256 amount0Max = token0Amount + 1 wei;
        uint256 amount1Max = token1Amount + 1 wei;

        (
            bytes memory actions,
            bytes[] memory mintParams
        ) = _mintLiquidityParams(
                pool,
                tickLower,
                tickUpper,
                liquidity,
                amount0Max,
                amount1Max,
                recipient,
                hookData
            );

        // if the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        // Check if pool is already initialized using getSlot0 (library function reads storage)
        // This avoids Foundry simulation issues by checking before broadcasting
        PoolId poolId = pool.toId();
        bool poolAlreadyInitialized = false;

        // getSlot0 reads storage directly - if pool doesn't exist, it returns zeros
        // We check if sqrtPriceX96 is non-zero to determine if pool is initialized
        (uint160 sqrtPriceX96, , , ) = POOLMANAGER.getSlot0(poolId);

        if (sqrtPriceX96 != 0) {
            poolAlreadyInitialized = true;
            console.log(
                "Pool already initialized, proceeding to add liquidity..."
            );
        }
        // If sqrtPriceX96 is 0, pool doesn't exist - will initialize it
        // Execute all operations in a single broadcast block
        vm.startBroadcast();

        // Approve tokens
        tokenApprovals();

        // Initialize pool only if it's not already initialized
        if (!poolAlreadyInitialized) {
            IPoolManager(POOLMANAGER).initialize(pool, startingPrice);
            console.log("Pool initialized successfully!");
        }

        // Now add liquidity (pool is either newly initialized or already exists)
        posm.modifyLiquidities{value: valueToPass}(
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );

        vm.stopBroadcast();
    }

    /// @dev helper function for encoding mint liquidity operation
    /// @dev does NOT encode SWEEP, developers should take care when minting liquidity on an ETH pair
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            _tickLower,
            _tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            recipient,
            hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        return (actions, params);
    }

    function tokenApprovals() public {
        if (!currency0.isAddressZero()) {
            token0.approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(
                address(token0),
                address(posm),
                type(uint160).max,
                type(uint48).max
            );
        }
        if (!currency1.isAddressZero()) {
            token1.approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(
                address(token1),
                address(posm),
                type(uint160).max,
                type(uint48).max
            );
        }
    }

    function _resolveRecipient() internal view returns (address) {
        // Preferred env var
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            return vm.addr(pk);
        } catch {}
        // Legacy env var with typo kept for backward compatibility
        try vm.envUint("PRVATE_KEY11") returns (uint256 pkLegacy) {
            return vm.addr(pkLegacy);
        } catch {}
        // Owner fallback
        try vm.envUint("OWNER_PRIVATE_KEY") returns (uint256 ownerPk) {
            return vm.addr(ownerPk);
        } catch {}
        // Final fallback to msg.sender
        return msg.sender;
    }
}
