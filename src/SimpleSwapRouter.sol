// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title SimpleSwapRouter
 * @notice Production-ready swap router for Uniswap V4 on testnet
 * @dev Properly implements the unlock callback pattern required by V4
 */
contract SimpleSwapRouter {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    // Transient storage for swap parameters during unlock callback
    struct SwapCallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /**
     * @notice Execute a swap on a Uniswap V4 pool
     * @param key The pool key
     * @param params The swap parameters
     * @return delta The balance changes from the swap
     */
    function swap(
        PoolKey memory key,
        SwapParams memory params
    ) external payable returns (BalanceDelta delta) {
        // Encode callback data
        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            key: key,
            params: params
        });

        // Call unlock with our callback - encode the data as bytes
        delta = abi.decode(
            poolManager.unlock(abi.encode(data)),
            (BalanceDelta)
        );
    }

    /**
     * @notice Callback function called by PoolManager during unlock
     * @dev This is where the actual swap happens while the pool is unlocked
     * @param rawData Encoded SwapCallbackData
     */
    function unlockCallback(
        bytes calldata rawData
    ) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Decode the callback data
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        // Execute the swap while unlocked
        BalanceDelta delta = poolManager.swap(data.key, data.params, "");

        // Handle settlement based on delta signs
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle negative deltas (we owe tokens to pool)
        if (delta0 < 0) {
            _settle(data.key.currency0, data.sender, uint128(-delta0));
        }
        if (delta1 < 0) {
            _settle(data.key.currency1, data.sender, uint128(-delta1));
        }

        // Take positive deltas (pool owes us tokens)
        if (delta0 > 0) {
            _take(data.key.currency0, data.sender, uint128(delta0));
        }
        if (delta1 > 0) {
            _take(data.key.currency1, data.sender, uint128(delta1));
        }

        // Sync both currencies to finalize settlement
        // This is required even after take() to update PoolManager's internal accounting
        if (delta0 != 0) {
            poolManager.sync(data.key.currency0);
        }
        if (delta1 != 0) {
            poolManager.sync(data.key.currency1);
        }

        return abi.encode(delta);
    }

    /**
     * @notice Settle (pay) tokens to the pool manager
     */
    function _settle(Currency currency, address payer, uint128 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            // ETH
            poolManager.settle{value: amount}();
        } else {
            // ERC20 - transfer to this contract first, then sync
            IERC20 token = IERC20(Currency.unwrap(currency));
            require(
                token.transferFrom(payer, address(this), amount),
                "Transfer failed"
            );
            // Transfer from router to pool manager
            token.transfer(address(poolManager), amount);
            // Sync to update pool manager's accounting
            poolManager.sync(currency);
        }
    }

    /**
     * @notice Take tokens from the pool manager
     */
    function _take(Currency currency, address recipient, uint128 amount) internal {
        if (amount == 0) return;

        poolManager.take(currency, recipient, amount);
    }

    receive() external payable {}
}
