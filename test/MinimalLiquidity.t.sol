// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {ConfidentialRebalancingHook} from "../src/ConfidentialRebalancingHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";
import {FHE, euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract MinimalLiquidityTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    ConfidentialRebalancingHook hook;
    HybridFHERC20 token0H;
    HybridFHERC20 token1H;
    CoFheTest CFT;

    function setUp() public {
        CFT = new CoFheTest(true);
        deployFreshManagerAndRouters();
        
        token0H = new HybridFHERC20("T0", "T0");
        token1H = new HybridFHERC20("T1", "T1");
        
        if (address(token0H) < address(token1H)) {
            currency0 = Currency.wrap(address(token0H));
            currency1 = Currency.wrap(address(token1H));
        } else {
            currency0 = Currency.wrap(address(token1H));
            currency1 = Currency.wrap(address(token0H));
        }

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(ConfidentialRebalancingHook).creationCode,
            abi.encode(address(manager))
        );
        hook = new ConfidentialRebalancingHook{salt: salt}(manager);
    }

    function testAddLiquidity() public {
        // Mint tokens to ourselves
        HybridFHERC20(Currency.unwrap(currency0)).mint(address(this), 100e18);
        HybridFHERC20(Currency.unwrap(currency1)).mint(address(this), 100e18);

        // Approve
        IERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize pool
        manager.initialize(
            PoolKey(currency0, currency1, 3000, 60, IHooks(hook)),
            SQRT_PRICE_1_1
        );

        // Add liquidity using the test router (which doesn't use Permit2 by default in this setup)
        modifyLiquidityRouter.modifyLiquidity(
            PoolKey(currency0, currency1, 3000, 60, IHooks(hook)),
            LIQUIDITY_PARAMS,
            ZERO_BYTES
        );
    }
}
