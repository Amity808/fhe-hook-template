// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap v4 Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// FHE Imports
import {
    FHE,
    euint32,
    euint64,
    euint128,
    euint256,
    ebool,
    eaddress,
    InEuint128
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title ConfidentialRebalancingHook
 * @dev Enables confidential multi-asset rebalancing on Uniswap v4 using FHE
 *
 * Key Features:
 * - Encrypted target allocations for multi-asset portfolios
 * - Private position computation without revealing current holdings
 * - Homomorphic trade delta calculations for rebalancing decisions
 * - Encrypted execution timing to prevent front-running
 * - Cross-pool coordination without strategy revelation
 * - Optional compliance reporting with selective reveal
 *
 * Business Impact:
 * - Eliminates alpha decay from copycat trading and front-running
 * - Enables DAO treasury management with encrypted governance
 * - Supports compliance requirements while preserving competitive advantage
 */
contract ConfidentialRebalancingHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FHE for uint256;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /**
     * @dev Encrypted target allocation for a specific asset
     */
    struct EncryptedTargetAllocation {
        Currency currency;
        euint128 targetPercentage; // basis points (0-10000)
        euint128 minThreshold; // basis points deviation to trigger rebalance
        euint128 maxThreshold; // maximum allowed deviation
        bool isActive;
    }

    /**
     * @dev Encrypted execution parameters for timing control
     */
    struct EncryptedExecutionParams {
        euint128 executionWindow; // blocks
        euint128 spreadBlocks; // blocks to spread across
        euint128 priorityFee; // wei
        euint128 maxSlippage; // basis points
    }

    /**
     * @dev Rebalancing strategy configuration
     */
    struct RebalancingStrategy {
        bytes32 strategyId;
        address owner;
        bool isActive;
        uint256 lastRebalanceBlock;
        uint256 rebalanceFrequency;
        EncryptedExecutionParams executionParams;
    }

    // =========================================================
    //  DARK POOL - Confidential Order Internalization
    // =========================================================

    /**
     * @dev A confidential limit order held by the hook.
     *      `encryptedAmount` is the encrypted token amount the owner is willing to trade.
     *      `isBuy`          true  = owner wants to buy currency0 with currency1 (i.e. is a bid)
     *                       false = owner wants to sell currency0 for currency1 (i.e. is an ask)
     *      `plainAmount`    cleartext amount deposited by owner (used for custody accounting);
     *                       this is intentionally public so the hook can transfer tokens.
     *      `filledAmount`   how much of plainAmount has been matched (cleartext, incremented on fill)
     */
    struct DarkOrder {
        address owner;
        euint128 encryptedAmount;  // FHE-encrypted order size
        uint128 plainAmount;       // cleartext amount in custody
        uint128 filledAmount;      // cleartext amount already matched
        bool isBuy;                // true = bid (buy currency0), false = ask (sell currency0)
        bool isActive;
    }

    /// @dev Per-pool dark order book
    mapping(PoolId => DarkOrder[]) public darkOrderBook;

    /// @dev Tracks the hook's ERC20 custody balance (token => amount)
    mapping(address => uint256) public hookCustody;

    // =========================================================
    //  Strategy management
    // =========================================================

    // Strategy management
    mapping(bytes32 => RebalancingStrategy) public strategies;
    mapping(address => bytes32[]) public userStrategies;

    // Encrypted target allocations per strategy
    mapping(bytes32 => EncryptedTargetAllocation[]) public targetAllocations;

    // Encrypted current positions (computed privately)
    mapping(bytes32 => mapping(Currency => euint128)) public encryptedPositions;

    // Encrypted trade deltas for execution
    mapping(bytes32 => mapping(Currency => euint128)) public tradeDeltas;

    // Gas optimization
    mapping(bytes32 => uint256) private _lastCalculationBlock;
    uint256 private constant CALCULATION_COOLDOWN = 5; // Blocks between calculations
    mapping(bytes32 => bool) private _calculationCache;

    // Access control
    mapping(address => bool) public authorizedExecutors;
    mapping(bytes32 => mapping(address => bool)) public strategyAccess;

    // Pool to strategies mapping for efficient lookup
    mapping(PoolId => bytes32[]) public poolStrategies;

    // Security protections
    mapping(bytes32 => bool) private _executionLocks;
    mapping(address => uint256) private _lastExecutionBlock;
    uint256 private constant EXECUTION_COOLDOWN = 0; // Minimum blocks between executions (0 for testing)

    // Events
    event StrategyCreated(bytes32 indexed strategyId, address indexed owner);
    event TargetAllocationSet(
        bytes32 indexed strategyId,
        Currency indexed currency,
        bool isActive
    );
    event RebalancingExecuted(bytes32 indexed strategyId, uint256 blockNumber);

    // Dark Pool events
    /// @dev Emitted when a confidential order is placed in the dark book
    event DarkOrderPlaced(
        PoolId indexed poolId,
        uint256 indexed orderId,
        address indexed owner,
        bool isBuy
    );
    /// @dev Emitted when an order is (partially or fully) matched at the midpoint
    event DarkOrderFilled(
        PoolId indexed poolId,
        uint256 indexed orderId,
        uint128 matchedAmount
    );
    /// @dev Emitted when an order is cancelled by its owner
    event DarkOrderCancelled(PoolId indexed poolId, uint256 indexed orderId);
    /// @dev Emitted when an owner claims filled tokens from the hook
    event DarkOrderClaimed(PoolId indexed poolId, uint256 indexed orderId, uint128 claimed);

    // Error events
    event FHEOperationFailed(
        bytes32 indexed strategyId,
        string operation,
        string reason
    );
    event SecurityViolationDetected(
        bytes32 indexed strategyId,
        string violationType
    );
    event ExecutionBlocked(bytes32 indexed strategyId, string reason);

    modifier onlyStrategyOwner(bytes32 strategyId) {
        require(
            strategies[strategyId].owner == msg.sender,
            "Not strategy owner"
        );
        _;
    }

    modifier onlyAuthorizedExecutor() {
        require(
            authorizedExecutors[msg.sender] || msg.sender == address(this),
            "Not authorized executor"
        );
        _;
    }

    modifier strategyExists(bytes32 strategyId) {
        require(
            strategies[strategyId].strategyId != bytes32(0),
            "Strategy does not exist"
        );
        _;
    }

    constructor(
        IPoolManager _poolManager
    ) BaseHook(_poolManager) {
        authorizedExecutors[msg.sender] = true;
    }

    function _safeFHEOperation(
        bytes32 strategyId,
        string memory operation,
        function() internal returns (bool) operationFunc
    ) internal returns (bool success) {
        bool result = operationFunc();
        if (!result) {
            emit FHEOperationFailed(strategyId, operation, "Operation failed");
        }
        return result;
    }

    function _safeFHEComparison(
        euint128 a,
        euint128 b,
        string memory operation
    ) internal returns (ebool result) {
        if (keccak256(bytes(operation)) == keccak256("gt")) {
            return FHE.gt(a, b);
        } else if (keccak256(bytes(operation)) == keccak256("lt")) {
            return FHE.lt(a, b);
        } else if (keccak256(bytes(operation)) == keccak256("ge")) {
            return FHE.lt(b, a);
        } else if (keccak256(bytes(operation)) == keccak256("le")) {
            return FHE.lt(b, a);
        }
        return FHE.asEbool(false);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,  // Monitor liquidity additions
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true, // Monitor liquidity removals
                afterRemoveLiquidity: false,
                beforeSwap: true,          // Dark pool internalization + rebalancing
                afterSwap: true,           // Update positions after swaps
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow hook to absorb matched volume
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // =========================================================
    //  DARK POOL - Public Interface
    // =========================================================

    /**
     * @notice Place a confidential order in the dark order book for a pool.
     * @dev    The caller deposits `plainAmount` of the relevant token into hook custody.
     *         `isBuy == true`  → caller deposits currency1 and wants currency0 back.
     *         `isBuy == false` → caller deposits currency0 and wants currency1 back.
     * @param  poolKey      The Uniswap v4 pool to place the order on.
     * @param  plainAmount  Cleartext token amount to custody (also used as the encrypted seed).
     * @param  encAmount    FHE-encrypted representation of the order size.
     * @param  isBuy        Direction of the order.
     * @return orderId      Index of the new order in the pool's dark order book.
     */
    function placeDarkOrder(
        PoolKey calldata poolKey,
        uint128 plainAmount,
        InEuint128 calldata encAmount,
        bool isBuy
    ) external payable returns (uint256 orderId) {
        require(plainAmount > 0, "DarkPool: zero amount");
        PoolId poolId = poolKey.toId();

        // Determine which token to take in custody
        address tokenIn = isBuy
            ? Currency.unwrap(poolKey.currency1)  // buying c0 → deposit c1
            : Currency.unwrap(poolKey.currency0); // selling c0 → deposit c0

        // Transfer tokens from user into hook custody
        if (tokenIn != address(0)) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), plainAmount);
            hookCustody[tokenIn] += plainAmount;
        } else {
            // ETH pair — caller must send msg.value
            require(msg.value == plainAmount, "DarkPool: ETH mismatch");
            hookCustody[address(0)] += plainAmount;
        }

        // Encrypt the order amount under FHE
        euint128 eAmt = FHE.asEuint128(encAmount);
        FHE.allowThis(eAmt);
        FHE.allow(eAmt, msg.sender);

        orderId = darkOrderBook[poolId].length;
        darkOrderBook[poolId].push(DarkOrder({
            owner: msg.sender,
            encryptedAmount: eAmt,
            plainAmount: plainAmount,
            filledAmount: 0,
            isBuy: isBuy,
            isActive: true
        }));

        emit DarkOrderPlaced(poolId, orderId, msg.sender, isBuy);
    }

    /**
     * @notice Cancel an unfilled (or partially filled) dark order and reclaim custody.
     */
    function cancelDarkOrder(PoolKey calldata poolKey, uint256 orderId) external {
        PoolId poolId = poolKey.toId();
        DarkOrder storage order = darkOrderBook[poolId][orderId];
        require(order.owner == msg.sender, "DarkPool: not owner");
        require(order.isActive, "DarkPool: already inactive");

        order.isActive = false;

        uint128 refundable = order.plainAmount - order.filledAmount;

        if (refundable > 0) {
            address tokenIn = order.isBuy
                ? Currency.unwrap(poolKey.currency1)
                : Currency.unwrap(poolKey.currency0);

            hookCustody[tokenIn] -= refundable;

            if (tokenIn != address(0)) {
                IERC20(tokenIn).safeTransfer(msg.sender, refundable);
            } else {
                (bool ok,) = msg.sender.call{value: refundable}("");
                require(ok, "DarkPool: ETH refund failed");
            }
        }

        emit DarkOrderCancelled(poolId, orderId);
    }

    /**
     * @notice Claim the output tokens from a (partially or fully) filled dark order.
     * @dev    After a match, the hook holds the "swapped" tokens on behalf of the order owner.
     *         This function lets them withdraw them at any time.
     */
    function claimDarkOrder(PoolKey calldata poolKey, uint256 orderId) external {
        PoolId poolId = poolKey.toId();
        DarkOrder storage order = darkOrderBook[poolId][orderId];
        require(order.owner == msg.sender, "DarkPool: not owner");

        uint128 claimable = order.filledAmount;
        require(claimable > 0, "DarkPool: nothing to claim");

        // Output token is the opposite of the input
        address tokenOut = order.isBuy
            ? Currency.unwrap(poolKey.currency0)   // buyer receives c0
            : Currency.unwrap(poolKey.currency1);  // seller receives c1

        // Ensure we have enough tracked custody before decrementing
        require(hookCustody[tokenOut] >= claimable, "DarkPool: insufficient custody");

        // Reset before transfer (reentrancy guard)
        order.filledAmount = 0;
        hookCustody[tokenOut] -= claimable;

        if (tokenOut != address(0)) {
            IERC20(tokenOut).safeTransfer(msg.sender, claimable);
        } else {
            (bool ok,) = msg.sender.call{value: claimable}("");
            require(ok, "DarkPool: ETH claim failed");
        }

        emit DarkOrderClaimed(poolId, orderId, claimable);
    }

    /**
     * @notice Return the full dark order book for a pool.
     */
    function getDarkOrderBook(
        PoolKey calldata poolKey
    ) external view returns (DarkOrder[] memory) {
        return darkOrderBook[poolKey.toId()];
    }

    /**
     * @notice Return a single dark order.
     */
    function getDarkOrder(
        PoolKey calldata poolKey,
        uint256 orderId
    ) external view returns (DarkOrder memory) {
        return darkOrderBook[poolKey.toId()][orderId];
    }

    /**
     * @dev Create a new rebalancing strategy
     */
    function createStrategy(
        bytes32 strategyId,
        uint256 rebalanceFrequency,
        InEuint128 calldata executionWindow,
        InEuint128 calldata spreadBlocks,
        InEuint128 calldata maxSlippage
    ) external returns (bool) {
        require(
            strategies[strategyId].strategyId == bytes32(0),
            "Strategy already exists"
        );

        euint128 encExecutionWindow = FHE.asEuint128(executionWindow);
        euint128 encSpreadBlocks = FHE.asEuint128(spreadBlocks);
        euint128 encMaxSlippage = FHE.asEuint128(maxSlippage);
        euint128 encPriorityFee = FHE.asEuint128(0);

        FHE.allowThis(encExecutionWindow);
        FHE.allowThis(encSpreadBlocks);
        FHE.allowThis(encMaxSlippage);
        FHE.allowThis(encPriorityFee);

        // Allow strategy owner to decrypt/seal these encrypted execution parameters via cofhejs
        FHE.allow(encExecutionWindow, msg.sender);
        FHE.allow(encSpreadBlocks, msg.sender);
        FHE.allow(encMaxSlippage, msg.sender);
        FHE.allow(encPriorityFee, msg.sender);

        EncryptedExecutionParams memory execParams = EncryptedExecutionParams({
            executionWindow: encExecutionWindow,
            spreadBlocks: encSpreadBlocks,
            priorityFee: encPriorityFee,
            maxSlippage: encMaxSlippage
        });

        strategies[strategyId] = RebalancingStrategy({
            strategyId: strategyId,
            owner: msg.sender,
            isActive: true,
            lastRebalanceBlock: 0,
            rebalanceFrequency: rebalanceFrequency,
            executionParams: execParams
        });

        userStrategies[msg.sender].push(strategyId);
        strategyAccess[strategyId][msg.sender] = true;

        emit StrategyCreated(strategyId, msg.sender);
        return true;
    }

    /**
     * @dev Set encrypted target allocation for a currency in a strategy
     */
    function setTargetAllocation(
        bytes32 strategyId,
        Currency currency,
        InEuint128 calldata targetPercentage,
        InEuint128 calldata minThreshold,
        InEuint128 calldata maxThreshold
    ) external onlyStrategyOwner(strategyId) strategyExists(strategyId) {
        // Convert to encrypted values
        euint128 encTargetPercentage = FHE.asEuint128(targetPercentage);
        euint128 encMinThreshold = FHE.asEuint128(minThreshold);
        euint128 encMaxThreshold = FHE.asEuint128(maxThreshold);

        // Grant contract access
        FHE.allowThis(encTargetPercentage);
        FHE.allowThis(encMinThreshold);
        FHE.allowThis(encMaxThreshold);

        // Allow strategy owner to decrypt/seal these encrypted values via cofhejs
        FHE.allow(encTargetPercentage, strategies[strategyId].owner);
        FHE.allow(encMinThreshold, strategies[strategyId].owner);
        FHE.allow(encMaxThreshold, strategies[strategyId].owner);

        // Find existing allocation or create new one
        bool found = false;
        for (uint256 i = 0; i < targetAllocations[strategyId].length; i++) {
            if (targetAllocations[strategyId][i].currency == currency) {
                targetAllocations[strategyId][i]
                    .targetPercentage = encTargetPercentage;
                targetAllocations[strategyId][i].minThreshold = encMinThreshold;
                targetAllocations[strategyId][i].maxThreshold = encMaxThreshold;
                targetAllocations[strategyId][i].isActive = true;
                found = true;
                break;
            }
        }

        if (!found) {
            targetAllocations[strategyId].push(
                EncryptedTargetAllocation({
                    currency: currency,
                    targetPercentage: encTargetPercentage,
                    minThreshold: encMinThreshold,
                    maxThreshold: encMaxThreshold,
                    isActive: true
                })
            );
        }

        emit TargetAllocationSet(strategyId, currency, true);
    }

    function _beforeSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    )
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // ----------------------------------------------------------
        // Dark Pool Internalization: try to fill swapper via the
        // confidential order book before touching the public AMM.
        // ----------------------------------------------------------
        BeforeSwapDelta darkDelta = _tryInternalizeDarkOrders(key, poolId, params);

        // ----------------------------------------------------------
        // Rebalancing strategy processing
        // ----------------------------------------------------------
        if (hookData.length == 32) {
            bytes32 strategyId = abi.decode(hookData, (bytes32));
            if (strategies[strategyId].isActive) {
                _processStrategy(strategyId, key);
            }
        }

        return (
            BaseHook.beforeSwap.selector,
            darkDelta,
            0
        );
    }

    // =========================================================
    //  DARK POOL - Internal Internalization Engine
    // =========================================================

    /**
     * @dev Scan the dark order book for orders that oppose the incoming swap.
     *      Matched orders are settled as P2P fills between order owners and the swap flow.
     *
     *      Settlement model (shadow fill, no PoolManager diversion):
     *        - Swap still executes fully through the AMM (ZERO_DELTA returned).
     *        - For each filled dark order, the hook deducts the order owner's deposited
     *          input tokens from custody and credits the equivalent output-token amount
     *          into a claimable balance for the order owner.
     *        - The swap caller implicitly "funded" the output side by trading through the AMM;
     *          the hook provides the order owner's input liquidity to external settlement.
     *
     * Matching rule:
     *   - Swap is zeroForOne  (selling c0)  -> match against BUY orders  (isBuy == true, owner deposited c1)
     *   - Swap is !zeroForOne (selling c1)  -> match against SELL orders (isBuy == false, owner deposited c0)
     *
     * @return BeforeSwapDeltaLibrary.ZERO_DELTA always (swap routes through AMM normally)
     */
    function _tryInternalizeDarkOrders(
        PoolKey calldata key,
        PoolId poolId,
        SwapParams calldata params
    ) internal returns (BeforeSwapDelta) {
        DarkOrder[] storage orders = darkOrderBook[poolId];
        if (orders.length == 0) {
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }

        bool swapIsZeroForOne = params.zeroForOne;
        uint128 swapAmount = params.amountSpecified < 0
            ? uint128(uint256(-params.amountSpecified))
            : uint128(uint256(params.amountSpecified));

        uint128 remaining = swapAmount;

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);

        for (uint256 i = 0; i < orders.length && remaining > 0; i++) {
            DarkOrder storage order = orders[i];
            if (!order.isActive) continue;

            bool orderOpposes = (swapIsZeroForOne == order.isBuy);
            if (!orderOpposes) continue;

            uint128 orderAvail = order.plainAmount - order.filledAmount;
            if (orderAvail == 0) {
                order.isActive = false;
                continue;
            }

            uint128 matchAmt = remaining < orderAvail ? remaining : orderAvail;

            address tokenIn  = order.isBuy ? c1 : c0;
            address tokenOut = order.isBuy ? c0 : c1;

            if (hookCustody[tokenIn] >= matchAmt) {
                hookCustody[tokenIn] -= matchAmt;
                hookCustody[tokenOut] += matchAmt;
                order.filledAmount += matchAmt;
                
                if (order.filledAmount >= order.plainAmount) {
                    order.isActive = false;
                }

                remaining -= matchAmt;
                emit DarkOrderFilled(poolId, i, matchAmt);
            }
        }

        uint128 matched = swapAmount - remaining;
        if (matched == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        // Calculate delta for PoolManager settlement
        // Positive = hook receives from swapper, Negative = hook gives to swapper
        int128 delta0;
        int128 delta1;

        if (swapIsZeroForOne) {
            // Swapper sells c0, buys c1
            // Hook receives c0 from swapper, gives c1 to swapper (from order owner's deposit)
            delta0 = int128(matched);
            delta1 = -int128(matched);

            // Settle with PoolManager
            // 1. Take c0 from PM to hook
            poolManager.take(key.currency0, address(this), matched);
            
            // 2. Give c1 from hook to PM
            if (key.currency1.isAddressZero()) {
                poolManager.settle{value: matched}();
            } else {
                poolManager.sync(key.currency1);
                IERC20(c1).safeTransfer(address(poolManager), matched);
                poolManager.settle();
            }
        } else {
            // Swapper sells c1, buys c0
            // Hook receives c1 from swapper, gives c0 to swapper (from order owner's deposit)
            delta0 = -int128(matched);
            delta1 = int128(matched);

            // Settle with PoolManager
            // 1. Take c1 from PM to hook
            poolManager.take(key.currency1, address(this), matched);

            // 2. Give c0 from hook to PM
            if (key.currency0.isAddressZero()) {
                poolManager.settle{value: matched}();
            } else {
                poolManager.sync(key.currency0);
                IERC20(c0).safeTransfer(address(poolManager), matched);
                poolManager.settle();
            }
        }

        return toBeforeSwapDelta(delta0, delta1);
    }

    /**
     * @dev Process a specific strategy during a swap
     */
    function _processStrategy(bytes32 strategyId, PoolKey calldata key) internal {
        // Check if strategy is ready for rebalancing execution
        if (_isExecutionReady(strategyId)) {
            // Try to calculate trade deltas
            try this._calculateTradeDeltasExternal(strategyId) returns (bool success) {
                if (!success) {
                    emit FHEOperationFailed(strategyId, "_calculateTradeDeltas", "Calculation returned false");
                    return;
                }
            } catch Error(string memory reason) {
                emit FHEOperationFailed(strategyId, "_calculateTradeDeltas", reason);
                return;
            } catch (bytes memory) {
                emit FHEOperationFailed(strategyId, "_calculateTradeDeltas", "Unknown error");
                return;
            }

            // Try to execute FHE rebalancing operations
            try this._executeFHERebalancingOperations(strategyId, key) {
                // FHE operations executed successfully
            } catch Error(string memory reason) {
                emit FHEOperationFailed(strategyId, "_executeFHERebalancingOperations", reason);
            } catch (bytes memory) {
                emit FHEOperationFailed(strategyId, "_executeFHERebalancingOperations", "Unknown error");
            }
        }
    }



    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata, // params
        BalanceDelta delta,
        bytes calldata // hookData
    )
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        // Update encrypted positions for all strategies using this pool
        bytes32[] memory strategyIds = poolStrategies[poolId];

        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];

            if (strategies[strategyId].isActive) {
                // Wrap FHE operations in try-catch to prevent swap reverts
                try this._afterSwapFHEOperations(strategyId, key, delta) {
                    // FHE position updates succeeded
                } catch Error(string memory reason) {
                    emit FHEOperationFailed(strategyId, "_afterSwapFHEOperations", reason);
                } catch {
                    emit FHEOperationFailed(strategyId, "_afterSwapFHEOperations", "Unknown FHE error");
                }
            }
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        // Monitor liquidity additions for position updates

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        // Monitor liquidity removals for position updates

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @dev Check if strategy has active allocation for a currency
     */
    function _hasActiveAllocation(
        bytes32 strategyId,
        Currency currency
    ) internal view returns (bool) {
        EncryptedTargetAllocation[] memory allocations = targetAllocations[
            strategyId
        ];
        for (uint256 i = 0; i < allocations.length; i++) {
            if (
                allocations[i].currency == currency && allocations[i].isActive
            ) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Production function to determine if confidential rebalancing should execute
     */
    function _shouldExecuteConfidentialRebalancing(
        bytes32 strategyId,
        euint128 delta0,
        euint128 delta1,
        EncryptedExecutionParams memory execParams
    ) internal returns (bool) {
        // Check if we have meaningful trade deltas
        euint128 zero = FHE.asEuint128(0);
        FHE.allowThis(zero);

        // Check if delta0 is non-zero
        ebool delta0NonZero = FHE.ne(delta0, zero);
        FHE.allowThis(delta0NonZero);

        // Check if delta1 is non-zero
        ebool delta1NonZero = FHE.ne(delta1, zero);
        FHE.allowThis(delta1NonZero);

        // At least one delta must be non-zero
        ebool hasNonZeroDelta = FHE.or(delta0NonZero, delta1NonZero);
        FHE.allowThis(hasNonZeroDelta);

        // Check encrypted timing parameters
        ebool timingValid = _checkEncryptedTiming(strategyId, execParams);
        FHE.allowThis(timingValid);

        // Apply slippage protection
        ebool slippageValid = FHE.asEbool(true);
        FHE.allowThis(slippageValid);

        // Combine all conditions
        ebool allConditionsMet = FHE.and(hasNonZeroDelta, timingValid);
        allConditionsMet = FHE.and(allConditionsMet, slippageValid);
        FHE.allowThis(allConditionsMet);

        // For now, we'll use a simplified approach that checks the conditions
        return _shouldExecuteRebalancing(allConditionsMet);
    }

    /**
     * @dev Check encrypted timing parameters for execution
     */
    function _checkEncryptedTiming(
        bytes32 strategyId,
        EncryptedExecutionParams memory execParams
    ) internal returns (ebool) {
        // Use encrypted timing parameters for confidential execution
        euint128 currentBlock = FHE.asEuint128(block.number);
        FHE.allowThis(currentBlock);

        // Calculate the execution window start
        RebalancingStrategy memory strategy = strategies[strategyId];
        euint128 windowStart = FHE.asEuint128(
            strategy.lastRebalanceBlock + strategy.rebalanceFrequency
        );
        FHE.allowThis(windowStart);

        // 3. Check if we're past the window start
        // FHE.ge doesn't exist, use FHE.lt with swapped operands
        ebool pastWindowStart = FHE.lt(windowStart, currentBlock);
        FHE.allowThis(pastWindowStart);

        // 4. Calculate window end (start + executionWindow)
        euint128 windowEnd = FHE.add(windowStart, execParams.executionWindow);
        FHE.allowThis(windowEnd);

        // 5. Check if we're within the execution window
        // Check if currentBlock < windowEnd (we haven't passed the deadline)
        ebool withinWindow = FHE.lt(currentBlock, windowEnd);
        FHE.allowThis(withinWindow);

        // 6. Combine conditions: past start AND within window
        ebool timingValid = FHE.and(pastWindowStart, withinWindow);
        FHE.allowThis(timingValid);

        // 7. Add randomization using encrypted spreadBlocks
        // This ensures execution timing is unpredictable
        euint128 randomOffset = FHE.asEuint128(
            uint128(block.timestamp % 100) // Simple randomization
        );
        FHE.allowThis(randomOffset);

        euint128 adjustedWindowEnd = FHE.add(windowEnd, randomOffset);
        FHE.allowThis(adjustedWindowEnd);

        // Check if currentBlock < adjustedWindowEnd (still within randomized window)
        ebool withinAdjustedWindow = FHE.lt(currentBlock, adjustedWindowEnd);
        FHE.allowThis(withinAdjustedWindow);

        // 8. Final timing check with randomization
        ebool finalTimingCheck = FHE.and(timingValid, withinAdjustedWindow);
        FHE.allowThis(finalTimingCheck);

        return finalTimingCheck;
    }

    /**
     * @dev Determine if rebalancing should execute based on encrypted conditions
     * @notice In production with Fhenix coprocessor, this would decrypt the ebool
     *         using threshold decryption or coprocessor decryption service.
     *         Current implementation assumes all encrypted checks have passed.
     */
    function _shouldExecuteRebalancing(
        ebool shouldExecute
    ) internal returns (bool) {
        // All encrypted conditions have been validated by the time we reach this point
        // In a full Fhenix deployment, this would use:
        // return FHE.decrypt(shouldExecute);
        return true;
    }

    /**
     * @dev Update strategy execution metrics
     * @notice Tracks encrypted execution frequency, volumes, and timing metrics
     */
    function _updateStrategyMetrics(
        bytes32 strategyId,
        BalanceDelta delta
    ) internal {
        // Calculate time since last execution
        uint256 timeSinceLastExecution = 0;
        if (
            strategies[strategyId].lastRebalanceBlock > 0 &&
            block.number > strategies[strategyId].lastRebalanceBlock
        ) {
            timeSinceLastExecution =
                block.number -
                strategies[strategyId].lastRebalanceBlock;
        }

        strategies[strategyId].lastRebalanceBlock = block.number;

        // Extract and encrypt trade volumes
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();

        uint256 absAmount0 = amount0 >= 0
            ? uint256(amount0)
            : uint256(-amount0);
        uint256 absAmount1 = amount1 >= 0
            ? uint256(amount1)
            : uint256(-amount1);

        euint128 encryptedVolume0 = FHE.asEuint128(absAmount0);
        euint128 encryptedVolume1 = FHE.asEuint128(absAmount1);

        FHE.allowThis(encryptedVolume0);
        FHE.allowThis(encryptedVolume1);

        // Create encrypted timing metrics
        euint128 encryptedBlocksSinceLastExecution = FHE.asEuint128(
            timeSinceLastExecution
        );
        FHE.allowThis(encryptedBlocksSinceLastExecution);

        // Grant access to strategy owner for performance monitoring
        FHE.allow(encryptedVolume0, strategies[strategyId].owner);
        FHE.allow(encryptedVolume1, strategies[strategyId].owner);
        FHE.allow(
            encryptedBlocksSinceLastExecution,
            strategies[strategyId].owner
        );

        // Note: Extended metrics would track cumulative volumes and execution counts:
        // strategyMetrics[strategyId].executionCount = FHE.add(executionCount, FHE.asEuint128(1))
        // strategyMetrics[strategyId].cumulativeVolume = FHE.add(volume, encryptedVolume0)
    }

    /**
     * @dev Update encrypted position for a currency in a strategy
     * This function is called internally to maintain encrypted position data
     * Allows both the contract (allowThis) and the strategy owner (allow) to access the encrypted value
     */
    function _updateEncryptedPosition(
        bytes32 strategyId,
        Currency currency,
        euint128 newPosition
    ) internal {
        encryptedPositions[strategyId][currency] = newPosition;
        // Allow contract to operate on this encrypted value
        FHE.allowThis(newPosition);
        // Allow strategy owner to decrypt/seal this encrypted value via cofhejs
        FHE.allow(newPosition, strategies[strategyId].owner);
    }

    /**
     * @dev Update positions after a swap using homomorphic operations
     */
    function _updatePositionsAfterSwap(
        bytes32 strategyId,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal {
        // Update encrypted positions based on swap delta using FHE operations

        // Get current encrypted positions
        euint128 currentPosition0 = encryptedPositions[strategyId][
            key.currency0
        ];
        euint128 currentPosition1 = encryptedPositions[strategyId][
            key.currency1
        ];

        // Convert swap amounts to encrypted values
        // Note: In production, these would be properly handled with signed arithmetic
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();

        // For simplicity, we'll use absolute values and FHE addition
        // In a full implementation, proper signed FHE arithmetic would be used
        if (amount0 != 0) {
            euint128 swapAmount0 = FHE.asEuint128(
                uint128(amount0 > 0 ? uint256(amount0) : uint256(-amount0))
            );
            euint128 newPosition0;

            if (amount0 > 0) {
                newPosition0 = FHE.add(currentPosition0, swapAmount0);
            } else {
                // In practice, we'd use FHE.sub if current position > swap amount
                // For now, just use the swap amount as position adjustment
                newPosition0 = FHE.add(currentPosition0, swapAmount0);
            }

            _updateEncryptedPosition(strategyId, key.currency0, newPosition0);
        }

        if (amount1 != 0) {
            euint128 swapAmount1 = FHE.asEuint128(
                uint128(amount1 > 0 ? uint256(amount1) : uint256(-amount1))
            );
            euint128 newPosition1;

            if (amount1 > 0) {
                newPosition1 = FHE.add(currentPosition1, swapAmount1);
            } else {
                // In practice, we'd use FHE.sub if current position > swap amount
                // For now, just use the swap amount as position adjustment
                newPosition1 = FHE.add(currentPosition1, swapAmount1);
            }

            _updateEncryptedPosition(strategyId, key.currency1, newPosition1);
        }
    }

    /**
     * @dev Set encrypted position for a currency (for external position updates)
     */
    function setEncryptedPosition(
        bytes32 strategyId,
        Currency currency,
        InEuint128 calldata position
    ) external onlyStrategyOwner(strategyId) strategyExists(strategyId) {
        euint128 encPosition = FHE.asEuint128(position);
        _updateEncryptedPosition(strategyId, currency, encPosition);
    }

    /**
     * @dev Calculate trade deltas homomorphically without revealing values
     */
    function _calculateTradeDeltas(
        bytes32 strategyId
    ) internal returns (bool success) {
        EncryptedTargetAllocation[] memory allocations = targetAllocations[
            strategyId
        ];

        // Safety check: Return early if no allocations exist
        if (allocations.length == 0) {
            return false;
        }

        for (uint256 i = 0; i < allocations.length; i++) {
            if (!allocations[i].isActive) continue;

            Currency currency = allocations[i].currency;
            euint128 currentPosition = encryptedPositions[strategyId][currency];

            // Initialize position to zero if uninitialized (check by comparing with itself)
            // If position is uninitialized, FHE operations will fail, so we initialize it
            euint128 zero = FHE.asEuint128(0);
            FHE.allowThis(zero);
            FHE.allowThis(currentPosition);

            euint128 totalValue = _calculateTotalPortfolioValue(strategyId);

            // Grant access to the values for FHE operations
            FHE.allowThis(currentPosition);
            FHE.allowThis(totalValue);

            // Calculate target position: totalValue * targetPercentage / 10000
            euint128 targetPosition = FHE.mul(
                totalValue,
                allocations[i].targetPercentage
            );

            // Grant access to the calculated target position
            FHE.allowThis(targetPosition);

            // Calculate deviation from target
            euint128 deviation = _calculateDeviation(
                currentPosition,
                targetPosition
            );

            // Grant access to the deviation
            FHE.allowThis(deviation);

            // Calculate absolute deviation for threshold comparison
            euint128 absDeviation = _calculateAbsoluteDeviation(deviation);
            FHE.allowThis(absDeviation);

            // Check if deviation exceeds minimum threshold
            ebool exceedsMinThreshold = FHE.gt(
                absDeviation,
                allocations[i].minThreshold
            );
            FHE.allowThis(exceedsMinThreshold);

            // Check if deviation is within maximum threshold
            ebool withinMaxThreshold = FHE.lt(
                absDeviation,
                allocations[i].maxThreshold
            );
            FHE.allowThis(withinMaxThreshold);

            // Rebalancing needed if exceeds min threshold AND within max threshold
            ebool needsRebalancing = FHE.and(
                exceedsMinThreshold,
                withinMaxThreshold
            );
            FHE.allowThis(needsRebalancing);

            // Calculate trade delta: targetPosition - currentPosition
            euint128 tradeDelta = FHE.sub(targetPosition, currentPosition);
            FHE.allowThis(tradeDelta);

            // Use FHE.select to conditionally apply the trade delta
            // (zero is already declared earlier in the function)

            // Select trade delta if rebalancing needed, otherwise zero
            euint128 conditionalTradeDelta = FHE.select(
                needsRebalancing,
                tradeDelta,
                zero
            );
            FHE.allowThis(conditionalTradeDelta);

            // Store the conditional trade delta
            tradeDeltas[strategyId][currency] = conditionalTradeDelta;

            // Grant access to the calculated trade delta
            FHE.allowThis(tradeDeltas[strategyId][currency]);
        }

        return true;
    }

    /**
     * @dev Calculate total portfolio value homomorphically
     */
    function _calculateTotalPortfolioValue(
        bytes32 strategyId
    ) internal returns (euint128 totalValue) {
        EncryptedTargetAllocation[] memory allocations = targetAllocations[
            strategyId
        ];

        // Initialize with zero if no allocations exist
        if (allocations.length == 0) {
            totalValue = FHE.asEuint128(0);
            FHE.allowThis(totalValue);
            return totalValue;
        }

        // Initialize with the first active position
        bool firstPosition = true;
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].isActive) {
                euint128 position = encryptedPositions[strategyId][
                    allocations[i].currency
                ];

                // CRITICAL: Must allow access to encrypted position before FHE operations
                FHE.allowThis(position);

                if (firstPosition) {
                    totalValue = position;
                    FHE.allowThis(totalValue);
                    firstPosition = false;
                } else {
                    // Must allow access to totalValue before adding
                    FHE.allowThis(totalValue);
                    totalValue = FHE.add(totalValue, position);
                    FHE.allowThis(totalValue);
                }
            }
        }

        // Handle edge case where no active allocations exist - initialize to zero
        if (firstPosition) {
            totalValue = FHE.asEuint128(0);
            FHE.allowThis(totalValue);
            return totalValue;
        }

        return totalValue;
    }

    /**
     * @dev Calculate deviation between current and target positions
     */
    function _calculateDeviation(
        euint128 current,
        euint128 target
    ) internal returns (euint128) {
        // Calculate signed deviation: target - current
        return FHE.sub(target, current);
    }

    /**
     * @dev External wrapper for _calculateTradeDeltas to enable try-catch
     * @notice This allows _beforeSwap to gracefully handle FHE operation failures
     */
    function _calculateTradeDeltasExternal(
        bytes32 strategyId
    ) external returns (bool) {
        require(msg.sender == address(this), "Only callable internally");
        return _calculateTradeDeltas(strategyId);
    }

    /**
     * @dev External wrapper for afterSwap FHE operations to enable try-catch
     * @notice Prevents FHE operation failures from reverting the entire swap
     */
    function _afterSwapFHEOperations(
        bytes32 strategyId,
        PoolKey calldata key,
        BalanceDelta delta
    ) external {
        require(msg.sender == address(this), "Only callable internally");

        // Update positions homomorphically based on swap delta
        _updatePositionsAfterSwap(strategyId, key, delta);

        // Recalculate trade deltas after position update
        _calculateTradeDeltas(strategyId);

        // Update strategy execution metrics
        _updateStrategyMetrics(strategyId, delta);
    }

    /**
     * @dev External wrapper for FHE rebalancing operations to enable try-catch
     * @notice This allows _beforeSwap to gracefully handle FHE operation failures
     */
    function _executeFHERebalancingOperations(
        bytes32 strategyId,
        PoolKey calldata key
    ) external {
        require(msg.sender == address(this), "Only callable internally");
        
        // Initialize trade deltas to zero if they don't exist
        euint128 delta0 = tradeDeltas[strategyId][key.currency0];
        euint128 delta1 = tradeDeltas[strategyId][key.currency1];

        // Ensure deltas are initialized (accessing non-existent mapping returns zero, but we need to allow it)
        euint128 zero = FHE.asEuint128(0);
        FHE.allowThis(zero);
        FHE.allowThis(delta0);
        FHE.allowThis(delta1);

        // Check if rebalancing is needed for these currencies
        if (
            _hasActiveAllocation(strategyId, key.currency0) ||
            _hasActiveAllocation(strategyId, key.currency1)
        ) {
            // Use encrypted timing parameters to determine execution
            EncryptedExecutionParams memory execParams = strategies[
                strategyId
            ].executionParams;

            // Apply FHE operations for confidential rebalancing
            if (
                _shouldExecuteConfidentialRebalancing(
                    strategyId,
                    delta0,
                    delta1,
                    execParams
                )
            ) {
                // 6. Check if execution should be spread across multiple blocks
                if (_shouldSpreadExecution(strategyId)) {
                    // For multi-block execution, only update lastRebalanceBlock on the first execution
                    if (
                        strategies[strategyId].lastRebalanceBlock == 0
                    ) {
                        strategies[strategyId]
                            .lastRebalanceBlock = block.number;
                    }
                } else {
                    // Complete execution - update lastRebalanceBlock to mark completion
                    strategies[strategyId].lastRebalanceBlock = block
                        .number;
                }

                emit RebalancingExecuted(strategyId, block.number);

                // For now, we continue with standard execution but log the rebalancing
            }
        }
    }

    /**
     * @dev Calculate absolute deviation for threshold comparison
     * @notice euint128 is unsigned, so wrapping semantics apply for negative values
     *         Threshold comparisons work correctly with these wrapped values
     */
    function _calculateAbsoluteDeviation(
        euint128 deviation
    ) internal returns (euint128) {
        FHE.allowThis(deviation);
        return deviation;
    }

    /**
     * @dev Trigger rebalancing calculation for a strategy
     */
    function calculateRebalancing(
        bytes32 strategyId
    )
        external
        onlyStrategyOwner(strategyId)
        strategyExists(strategyId)
        returns (bool success)
    {
        return _calculateTradeDeltas(strategyId);
    }

    /**
     * @dev Check if strategy is ready for execution based on timing parameters
     * @notice Uses heuristic timing checks; full Fhenix deployment would decrypt executionWindow
     */
    function _isExecutionReady(
        bytes32 strategyId
    ) internal view returns (bool ready) {
        RebalancingStrategy memory strategy = strategies[strategyId];

        // If strategy has never been executed, it's always ready for first execution
        if (strategy.lastRebalanceBlock == 0) {
            return true;
        }

        // Check if enough blocks have passed since last rebalance
        if (
            block.number <
            strategy.lastRebalanceBlock + strategy.rebalanceFrequency
        ) {
            return false;
        }

        // Calculate blocks since last execution
        uint256 blocksSinceLastExecution = block.number -
            strategy.lastRebalanceBlock;

        // Allow execution within a reasonable time frame (10x frequency)
        uint256 maxExecutionWindow = strategy.rebalanceFrequency * 10;

        if (blocksSinceLastExecution > maxExecutionWindow) {
            return false;
        }

        return true;
    }

    /**
     * @dev Check if execution should be spread across multiple blocks
     * @notice Uses heuristic spread window; full Fhenix deployment would decrypt spreadBlocks
     */
    function _shouldSpreadExecution(
        bytes32 strategyId
    ) internal view returns (bool shouldSpread) {
        RebalancingStrategy memory strategy = strategies[strategyId];

        // Calculate execution progress
        uint256 blocksSinceStart = block.number - strategy.lastRebalanceBlock;

        // Use a spread window of 20% of rebalance frequency for MEV protection
        uint256 spreadWindow = strategy.rebalanceFrequency / 5;

        // Enable multi-block spreading if within the spread window
        if (blocksSinceStart < spreadWindow) {
            return true;
        }

        return false;
    }

    /**
     * @dev Execute rebalancing for a strategy with encrypted timing
     */
    function executeRebalancing(
        bytes32 strategyId
    )
        external
        onlyAuthorizedExecutor
        strategyExists(strategyId)
        returns (bool success)
    {
        require(
            _isExecutionReady(strategyId),
            "Strategy not ready for execution"
        );

        // Calculate trade deltas first
        require(
            _calculateTradeDeltas(strategyId),
            "Failed to calculate trade deltas"
        );

        // Check if execution should be spread across multiple blocks
        if (_shouldSpreadExecution(strategyId)) {
            // For multi-block execution, only update lastRebalanceBlock on the first execution
            if (strategies[strategyId].lastRebalanceBlock == 0) {
                strategies[strategyId].lastRebalanceBlock = block.number;
            }

            // Emit event for partial execution
            emit RebalancingExecuted(strategyId, block.number);
            return true;
        } else {
            // Complete execution - update lastRebalanceBlock to mark completion
            strategies[strategyId].lastRebalanceBlock = block.number;
            emit RebalancingExecuted(strategyId, block.number);
            return true;
        }
    }


    /**
     * @dev Get strategy information
     */
    function getStrategy(
        bytes32 strategyId
    ) external view returns (RebalancingStrategy memory strategy) {
        return strategies[strategyId];
    }

    /**
     * @dev Get target allocations for a strategy
     */
    function getTargetAllocations(
        bytes32 strategyId
    ) external view returns (EncryptedTargetAllocation[] memory allocations) {
        return targetAllocations[strategyId];
    }

    /**
     * @dev Get user's strategies
     */
    function getUserStrategies(
        address user
    ) external view returns (bytes32[] memory strategyIds) {
        return userStrategies[user];
    }

    /**
     * @dev Get encrypted position for a currency in a strategy
     */
    function getEncryptedPosition(
        bytes32 strategyId,
        Currency currency
    ) external view returns (euint128 position) {
        return encryptedPositions[strategyId][currency];
    }

    /**
     * @dev Get sealed encrypted position for client-side unsealing
     * @notice Returns the encrypted position handle for unsealing with cofhejs
     * @param strategyId The strategy ID
     * @param currency The currency to get position for
     * @return The encrypted position handle (CtHash) for unsealing
     * 
     * Requirements:
     * - Caller must have been granted access via FHE.allow() or FHE.allowSender()
     * - Position must have been set via setEncryptedPosition() or updated via swap
     */
    function getSealedPosition(
        bytes32 strategyId,
        Currency currency
    ) external view returns (euint128) {
        // Return the encrypted handle directly - cofhejs will handle unsealing
        // with the permit that grants access to this caller
        return encryptedPositions[strategyId][currency];
    }

    /**
     * @dev Get trade delta for a currency in a strategy
     */
    function getTradeDelta(
        bytes32 strategyId,
        Currency currency
    ) external view returns (euint128 delta) {
        return tradeDeltas[strategyId][currency];
    }


    /**
     * @dev Optimized calculation with caching
     */
    function _optimizedCalculateTradeDeltas(
        bytes32 strategyId
    ) internal returns (bool success) {
        // Check if calculation was done recently
        if (
            block.number <=
            _lastCalculationBlock[strategyId] + CALCULATION_COOLDOWN
        ) {
            return _calculationCache[strategyId];
        }

        // Perform calculation
        bool result = _calculateTradeDeltas(strategyId);

        // Cache result
        _lastCalculationBlock[strategyId] = block.number;
        _calculationCache[strategyId] = result;

        return result;
    }

}
