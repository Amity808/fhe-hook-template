// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    CurrencyLibrary,
    Currency
} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    IPositionManager
} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {
    LiquidityAmounts
} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {Constants} from "./base/Constants.sol";
import {Config} from "./base/Config.sol";

contract AddLiquidityScript is Script, Constants, Config {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /////////////////////////////////////
    // --- Parameters to Configure --- //
    /////////////////////////////////////

    // --- pool configuration --- //
    // fees paid by swappers that accrue to liquidity providers
    uint24 lpFee = 3000; // 0.30%
    int24 tickSpacing = 60;

    // --- liquidity position configuration --- //
    uint256 public token0Amount = 1e18;
    uint256 public token1Amount = 1e18;

    // range of the position
    int24 tickLower = -600; // must be a multiple of tickSpacing
    int24 tickUpper = 600;
    /////////////////////////////////////

    function run() external {
        // Get the recipient address (the address that will receive the liquidity position)
        address recipient;
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            recipient = vm.addr(pk);
        } catch {
            // Try OWNER_PRIVATE_KEY if PRIVATE_KEY is not set
            try vm.envUint("OWNER_PRIVATE_KEY") returns (uint256 pk) {
                recipient = vm.addr(pk);
            } catch {
                // If neither is set, use msg.sender
                recipient = msg.sender;
            }
        }
        PoolKey memory pool = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        (uint160 sqrtPriceX96, , , ) = POOLMANAGER.getSlot0(pool.toId());

        // Converts token amounts to liquidity units
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        // slippage limits
        uint256 amount0Max = token0Amount + 1 wei;
        uint256 amount1Max = token1Amount + 1 wei;

        bytes memory hookData = new bytes(0);

        // Encode mint liquidity parameters
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory mintParams = new bytes[](2);
        mintParams[0] = abi.encode(
            pool,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            recipient,
            hookData
        );
        mintParams[1] = abi.encode(pool.currency0, pool.currency1);

        // Check token balances before proceeding
        if (!currency0.isAddressZero()) {
            uint256 token0Balance = token0.balanceOf(recipient);
            console.log("Token0 balance:", token0Balance);
            console.log("Token0 required:", amount0Max);
            if (token0Balance < amount0Max) {
                console.log("ERROR: Insufficient Token0 balance");
                console.log("Token0 address:", address(token0));
                console.log("Account:", recipient);
                console.log(
                    "Please ensure your account has at least",
                    amount0Max,
                    "Token0"
                );
                revert("Insufficient Token0 balance");
            }
        }

        if (!currency1.isAddressZero()) {
            uint256 token1Balance = token1.balanceOf(recipient);
            console.log("Token1 balance:", token1Balance);
            console.log("Token1 required:", amount1Max);
            if (token1Balance < amount1Max) {
                console.log("ERROR: Insufficient Token1 balance");
                console.log("Token1 address:", address(token1));
                console.log("Account:", recipient);
                console.log(
                    "Please ensure your account has at least",
                    amount1Max,
                    "Token1"
                );
                revert("Insufficient Token1 balance");
            }
        }

        console.log(
            "Token balance checks passed, proceeding with liquidity addition..."
        );

        // Handle native ETH if currency0 is ETH
        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;

        vm.startBroadcast();
        tokenApprovals();
        vm.stopBroadcast();

        vm.startBroadcast();
        posm.modifyLiquidities{value: valueToPass}(
            abi.encode(actions, mintParams),
            block.timestamp + 60
        );
        vm.stopBroadcast();
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
}
