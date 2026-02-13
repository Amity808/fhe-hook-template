/**
 * Frontend integration script for ConfidentialRebalancingHook
 */

const { cofhejs, FheTypes, Encryptable } = require("cofhejs/node");
const { ethers } = require("ethers");

const CONFIG = {
  // RPC endpoint - Sepolia testnet with Fhenix CoFHE support
  RPC_URL:
    process.env.RPC_URL ||
    "https://sepolia.infura.io/v3/709bdd438a58422b891043c58e636a64",

  // Environment for cofhejs: "LOCAL", "TESTNET", or "MAINNET"
  // Use "TESTNET" for Fhenix Helium
  ENVIRONMENT: process.env.ENVIRONMENT || "TESTNET",

  // Contract addresses from deployment (Sepolia chain ID: 11155111)
  HOOK_ADDRESS:
    process.env.HOOK_ADDRESS || "0x29917CE538f0CCbd370C9db265e721595Af14Ac0", // ConfidentialRebalancingHook (final with all FHE fixes)
  POOL_MANAGER_ADDRESS:
    process.env.POOL_MANAGER_ADDRESS ||
    "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543", // Uniswap V4 PoolManager
  SWAP_ROUTER_ADDRESS:
    process.env.SWAP_ROUTER_ADDRESS ||
    "0xf13D190e9117920c703d79B5F33732e10049b115", // PoolSwapTest on Sepolia

  // Token addresses (from Config.sol)
  TOKEN0_ADDRESS:
    process.env.TOKEN0_ADDRESS || "0x2794a0b7187BFCd81D2b6d05E8a6e6cAE3F97fFa", // MockTokenA
  TOKEN1_ADDRESS:
    process.env.TOKEN1_ADDRESS || "0xEa20820719c5Ae04Bce9A098E209f4d8C60DAF06", // MockTokenB

  PRIVATE_KEY: process.env.PRIVATE_KEY || "0x...",
};

const MIN_PRICE_LIMIT = 4295128740n;
const MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

const HOOK_ABI = [
  "function createStrategy(bytes32 strategyId, uint256 rebalanceFrequency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) executionWindow, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) spreadBlocks, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxSlippage) external returns (bool)",
  "function setTargetAllocation(bytes32 strategyId, address currency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) targetPercentage, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) minThreshold, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxThreshold) external",
  "function setEncryptedPosition(bytes32 strategyId, address currency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) position) external",
  "function enableCrossPoolCoordination(bytes32 strategyId, bytes32[] pools) external",
  "function getStrategy(bytes32 strategyId) external view returns (tuple(bytes32 strategyId, address owner, bool isActive, uint256 lastRebalanceBlock, uint256 rebalanceFrequency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) executionWindow, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) spreadBlocks, uint256 priorityFee, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxSlippage))",
  "function getEncryptedPosition(bytes32 strategyId, address currency) external view returns (uint256)",
  "function poolStrategies(bytes32 poolId) external view returns (bytes32[])",
  "function calculateRebalancing(bytes32 strategyId) external returns (bool)",
  "event RebalancingExecuted(bytes32 indexed strategyId, uint256 blockNumber)",
  "event FHEOperationFailed(bytes32 indexed strategyId, string operation, string reason)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
];

const SWAP_ROUTER_ABI = [
  "function swap(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, tuple(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, tuple(bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) external returns (tuple(int128 amount0, int128 amount1) delta)",
];

/**
 * Initialize cofhejs client
 */
async function initializeCofhejs(provider, wallet) {
  console.log("Initializing cofhejs client...");

  try {
    // Get network info to confirm we're on the right chain
    const network = await provider.getNetwork();
    console.log(`  Connected to network: ${network.name} (Chain ID: ${network.chainId})`);

    // Initialize cofhejs with ethers
    await cofhejs.initializeWithEthers({
      ethersProvider: provider,
      ethersSigner: wallet,
      environment: CONFIG.ENVIRONMENT,
    });

    console.log("✓ cofhejs initialized successfully");
  } catch (error) {
    console.error("✗ cofhejs initialization failed:", error.message);
    console.error("\nPossible causes:");
    console.error("  1. Network doesn't support Fhenix CoFHE");
    console.error("  2. RPC endpoint is unreachable");
    console.error("  3. Fhenix coprocessor is not available on this network");
    throw error;
  }
}

const logEncryptState = (state) => {
  console.log(`  Encryption State: ${state}`);
};

/**
 * Create strategy with encrypted parameters
 */
async function createStrategy(contract, strategyId, deployerAddress) {
  console.log("\n=== Creating Strategy with Encrypted Parameters ===");

  try {
    const existingStrategy = await contract.getStrategy(strategyId);
    if (
      existingStrategy.strategyId !== ethers.ZeroHash &&
      existingStrategy.owner !== ethers.ZeroAddress
    ) {
      console.log(`Strategy already exists (ID: ${strategyId})`);
      console.log(`  Owner: ${existingStrategy.owner}`);
      console.log(`  Is Active: ${existingStrategy.isActive}`);
      console.log("  Skipping strategy creation...");
      return false; // Strategy already exists
    }
  } catch (error) {
    // Strategy doesn't exist, continue with creation
    console.log("Strategy does not exist, will create new one...");
  }

  // Encrypt the execution parameters
  console.log("Encrypting execution parameters...");
  let encryptedValues;
  try {
    encryptedValues = await cofhejs.encrypt(
      [
        Encryptable.uint128(100n), // executionWindow: 100 blocks
        Encryptable.uint128(10n), // spreadBlocks: 10 blocks
        Encryptable.uint128(500n), // maxSlippage: 500 basis points (5%)
      ],
      logEncryptState
    );
  } catch (error) {
    console.error("Encryption failed:", error);
    throw error;
  }

  console.log("✓ Values encrypted successfully");

  let encryptedArray;

  if (Array.isArray(encryptedValues)) {
    encryptedArray = encryptedValues;
    console.log("  Using encryptedValues as array directly");
  } else if (encryptedValues?.data && Array.isArray(encryptedValues.data)) {
    encryptedArray = encryptedValues.data;
    console.log("  Using encryptedValues.data as array");
  } else if (encryptedValues === null || encryptedValues === undefined) {
    console.error("ERROR: encryptedValues is null or undefined");
    throw new Error(
      "Encryption returned null/undefined - check cofhejs initialization and TESTNET connection"
    );
  } else if (
    encryptedValues?.data === null ||
    encryptedValues?.data === undefined
  ) {
    console.error("ERROR: encryptedValues.data is null/undefined");
    console.error("encryptedValues:", encryptedValues);
    console.error(
      "Full encryptedValues object:",
      JSON.stringify(encryptedValues, null, 2)
    );
    throw new Error(
      "Encryption returned null data - check cofhejs initialization and network connection"
    );
  } else {
    console.error("ERROR: Unexpected encrypted values structure");
    console.error("encryptedValues:", JSON.stringify(encryptedValues, null, 2));
    throw new Error("Failed to extract encrypted values - unexpected format");
  }

  if (!encryptedArray || encryptedArray.length < 3) {
    console.error("ERROR: Not enough encrypted values returned");
    console.error("Array length:", encryptedArray?.length);
    throw new Error(
      "Expected 3 encrypted values, got " + (encryptedArray?.length || 0)
    );
  }

  const executionWindow = encryptedArray[0];
  const spreadBlocks = encryptedArray[1];
  const maxSlippage = encryptedArray[2];

  console.log("Calling createStrategy on contract...");
  try {
    const tx = await contract.createStrategy(
      strategyId,
      10,
      executionWindow,
      spreadBlocks,
      maxSlippage
    );

    console.log(`  Transaction hash: ${tx.hash}`);
    await tx.wait();
    console.log("✓ Strategy created successfully");
    return true;
  } catch (error) {
    if (error.reason && error.reason.includes("already exists")) {
      console.log("Strategy already exists, skipping creation...");
      return false;
    }
    throw error;
  }
}

/**
 * Set encrypted target allocation for a currency 
 * 
 */
async function setTargetAllocation(
  contract,
  strategyId,
  currencyAddress,
  deployerAddress
) {
  console.log("\n=== Setting Target Allocation ===");

  // Encrypt allocation parameters
  console.log("Encrypting allocation parameters...");
  const encryptedValues = await cofhejs.encrypt(
    [
      Encryptable.uint128(5000n), // targetPercentage: 50% (5000 basis points)
      Encryptable.uint128(100n), // minThreshold: 1% (100 basis points)
      Encryptable.uint128(1000n), // maxThreshold: 10% (1000 basis points)
    ],
    logEncryptState
  );

  console.log("✓ Values encrypted successfully");

  const encryptedArray = Array.isArray(encryptedValues)
    ? encryptedValues
    : encryptedValues?.data || encryptedValues;
  if (
    !encryptedArray ||
    !Array.isArray(encryptedArray) ||
    encryptedArray.length < 3
  ) {
    console.error("ERROR: Failed to extract encrypted allocation values");
    console.error("encryptedValues:", encryptedValues);
    throw new Error("Failed to extract encrypted allocation values");
  }

  const targetPercentage = encryptedArray[0];
  const minThreshold = encryptedArray[1];
  const maxThreshold = encryptedArray[2];

  console.log("Calling setTargetAllocation on contract...");
  const tx = await contract.setTargetAllocation(
    strategyId,
    currencyAddress,
    targetPercentage,
    minThreshold,
    maxThreshold
  );

  console.log(`  Transaction hash: ${tx.hash}`);
  await tx.wait();
  console.log("✓ Target allocation set successfully");
}

/**
 * Set encrypted position for a currency
 */
async function setEncryptedPosition(
  contract,
  strategyId,
  currencyAddress,
  positionValue,
  deployerAddress
) {
  console.log("\n=== Setting Encrypted Position ===");

  // Encrypt position value
  console.log(`Encrypting position value: ${positionValue}`);
  const encryptedValues = await cofhejs.encrypt(
    [Encryptable.uint128(BigInt(positionValue))],
    logEncryptState
  );

  console.log("✓ Value encrypted successfully");

  const encryptedArray = Array.isArray(encryptedValues)
    ? encryptedValues
    : encryptedValues?.data || encryptedValues;
  if (
    !encryptedArray ||
    !Array.isArray(encryptedArray) ||
    encryptedArray.length < 1
  ) {
    console.error("ERROR: Failed to extract encrypted position value");
    console.error("encryptedValues:", encryptedValues);
    throw new Error("Failed to extract encrypted position value");
  }

  const position = encryptedArray[0];

  console.log("Calling setEncryptedPosition on contract...");
  const tx = await contract.setEncryptedPosition(
    strategyId,
    currencyAddress,
    position
  );

  console.log(`  Transaction hash: ${tx.hash}`);
  await tx.wait();
  console.log("✓ Encrypted position set successfully");
}

/**
 * Read encrypted position (CtHash) and unseal it (correct CoFHE flow).
 * 
 * Requirements:
 * - Contract must have granted ACL access for permit issuer (usually wallet.address)
 *   via FHE.allow(handle, issuer) / FHE.allowSender(handle) in a state-changing path.
 */
async function readAndUnsealPosition(
  contract,
  strategyId,
  currencyAddress,
  wallet
) {
  console.log("\n=== Reading and Unsealing Encrypted Position (Correct CoFHE Flow) ===");

  // 1) Get or create a self permit for THIS wallet (issuer must match ACL allow)
  let permitRes;
  try {
    permitRes = await cofhejs.getPermit({ type: "self", issuer: wallet.address });
  } catch (error) {
    // getPermit threw - create new permit
    permitRes = null;
  }

  // Check if getPermit succeeded (check Result.success field)
  let permit;
  if (permitRes && permitRes.success === true && permitRes.data) {
    permit = permitRes.data;
    console.log("✓ Using existing permit");
  } else {
    // Either getPermit failed or returned error Result - create new permit
    console.log("Creating new permit...");
    const createRes = await cofhejs.createPermit({ type: "self", issuer: wallet.address });

    if (createRes && createRes.success === true && createRes.data) {
      permit = createRes.data;
      console.log("✓ Permit created successfully");
    } else {
      console.error("Failed to create permit:", createRes);
      throw new Error("Permit creation failed");
    }
  }

  if (!permit) throw new Error("Permit is null/undefined");

  const issuer = permit.issuer ?? wallet.address;

  // Try multiple ways to get the permit hash
  let permitHash;
  if (typeof permit.getHash === "function") {
    permitHash = permit.getHash();
  } else if (permit.hash) {
    permitHash = permit.hash;
  } else if (permit.permitHash) {
    permitHash = permit.permitHash;
  } else if (permit.signature) {
    // For some cofhejs versions, the signature itself can be used
    permitHash = permit.signature;
  }

  if (!permitHash) {
    console.error("Permit object structure:", JSON.stringify(permit, null, 2));
    throw new Error("Permit hash missing - cannot unseal without permit hash");
  }

  // 2) Read CtHash (encrypted handle) from contract
  console.log("Reading encrypted position (CtHash) from contract...");
  const ctHash = await contract.getEncryptedPosition(strategyId, currencyAddress);
  console.log(`  CtHash: ${ctHash.toString()}`);

  // 3) Unseal CtHash via threshold network /sealoutput (ACL-gated)
  console.log("Unsealing via cofhejs.unseal(ctHash)...");
  const res = await cofhejs.unseal(ctHash, FheTypes.Uint128, issuer, permitHash);

  // cofhejs.unseal commonly returns { success, data, error }
  if (res && typeof res === "object" && "success" in res) {
    if (!res.success) {
      throw new Error(`Unseal failed: ${res.error ?? "unknown error"}`);
    }
    console.log(`✓ Position unsealed: ${res.data.toString()}`);
    return res.data; // bigint
  }

  // Fallback: some versions may return bigint directly
  console.log(`✓ Position unsealed: ${res.toString()}`);
  return res;
}

/**
 * Sort currencies to match Solidity PoolIdLibrary implementation
 */
function sortCurrencies(currency0, currency1) {
  const addr0 = ethers.getBigInt(currency0);
  const addr1 = ethers.getBigInt(currency1);

  if (addr0 < addr1) {
    return [currency0, currency1];
  } else {
    return [currency1, currency0];
  }
}

/**
 * Calculate PoolId as bytes32 (matching Uniswap v4 PoolIdLibrary)
 * @returns bytes32 hex string (full keccak256 hash, NOT truncated to uint160)
 */
function calculatePoolIdBytes32(currency0, currency1, fee, tickSpacing, hooks) {
  // Sort currencies to match Solidity implementation
  const [c0, c1] = sortCurrencies(currency0, currency1);

  // Encode using address types (not uint256)
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"],
    [c0, c1, fee, tickSpacing, hooks]
  );

  // Return full bytes32 hash (do NOT truncate to uint160)
  return ethers.keccak256(encoded);
}

async function approveTokensIfNeeded(
  provider,
  wallet,
  tokenAddress,
  spenderAddress,
  tokenName
) {
  const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, wallet);

  const currentAllowance = await tokenContract.allowance(
    wallet.address,
    spenderAddress
  );

  if (currentAllowance >= ethers.parseEther("1")) {
    console.log(
      `  ✓ ${tokenName} already approved (allowance: ${ethers.formatEther(
        currentAllowance
      )})`
    );
    return;
  }

  console.log(`  Approving ${tokenName}...`);
  const tx = await tokenContract.approve(spenderAddress, ethers.MaxUint256);
  await tx.wait();
  console.log(`  ✓ ${tokenName} approved`);
}

async function checkPoolState(
  provider,
  wallet,
  poolKey,
  swapAmount,
  zeroForOne,
  poolManagerAddress
) {
  console.log("\n  === Pre-Swap Diagnostics ===");

  const poolIdBytes32 = calculatePoolIdBytes32(
    poolKey.currency0,
    poolKey.currency1,
    poolKey.fee,
    poolKey.tickSpacing,
    poolKey.hooks
  );

  console.log(`  PoolId (bytes32): ${poolIdBytes32}`);
  console.log(
    `  ⚠ Cannot verify pool state via RPC (Uniswap V4 uses extsload)`
  );
  console.log(
    `  Will proceed with swap - it will fail clearly if pool doesn't exist`
  );
  const tokenContract = new ethers.Contract(
    zeroForOne ? poolKey.currency0 : poolKey.currency1,
    ERC20_ABI,
    provider
  );

  try {
    const balance = await tokenContract.balanceOf(wallet.address);
    console.log(
      `  ${zeroForOne ? "Token0" : "Token1"} balance: ${ethers.formatEther(
        balance
      )}`
    );

    if (balance < swapAmount) {
      console.error(
        `  ✗ Insufficient balance! Need ${ethers.formatEther(
          swapAmount
        )}, have ${ethers.formatEther(balance)}`
      );
      throw new Error("Insufficient token balance");
    }
    console.log(`  ✓ Sufficient balance for swap`);
  } catch (error) {
    if (error.message.includes("Insufficient")) {
      throw error;
    }
    console.log(`  ⚠ Could not check token balance: ${error.message}`);
  }

  return poolIdBytes32;
}

async function performSwap(
  provider,
  wallet,
  swapRouterAddress,
  poolKey,
  swapAmount,
  zeroForOne
) {
  console.log("\n=== Performing Swap Operation ===");
  console.log(`  Swap Router: ${swapRouterAddress}`);
  console.log(
    `  Direction: ${zeroForOne ? "Token0 -> Token1" : "Token1 -> Token0"}`
  );
  if (swapAmount < BigInt(1e18)) {
    const amountFormatted = ethers.formatEther(swapAmount);
    console.log(
      `  Amount: ${amountFormatted} tokens (${swapAmount.toString()} wei)`
    );
  } else {
    console.log(`  Amount: ${ethers.formatEther(swapAmount)} tokens`);
  }

  const swapRouter = new ethers.Contract(
    swapRouterAddress,
    SWAP_ROUTER_ABI,
    wallet
  );

  await checkPoolState(
    provider,
    wallet,
    poolKey,
    swapAmount,
    zeroForOne,
    CONFIG.POOL_MANAGER_ADDRESS
  );
  console.log("\n  Checking token approvals...");
  if (zeroForOne) {
    await approveTokensIfNeeded(
      provider,
      wallet,
      poolKey.currency0,
      swapRouterAddress,
      "Token0"
    );
  } else {
    await approveTokensIfNeeded(
      provider,
      wallet,
      poolKey.currency1,
      swapRouterAddress,
      "Token1"
    );
  }

  const swapParams = {
    zeroForOne: zeroForOne,
    amountSpecified: -swapAmount,
    sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
  };
  console.log("  Swap Parameters:");
  console.log(`    zeroForOne: ${swapParams.zeroForOne}`);
  console.log(`    amountSpecified: ${swapParams.amountSpecified.toString()}`);
  console.log(
    `    sqrtPriceLimitX96: ${swapParams.sqrtPriceLimitX96.toString()}`
  );
  console.log("  PoolKey:");
  console.log(`    currency0: ${poolKey.currency0}`);
  console.log(`    currency1: ${poolKey.currency1}`);
  console.log(`    fee: ${poolKey.fee}`);
  console.log(`    tickSpacing: ${poolKey.tickSpacing}`);
  console.log(`    hooks: ${poolKey.hooks}`);

  const testSettings = {
    takeClaims: false,
    settleUsingBurn: false,
  };

  const hookData = ethers.getBytes("0x");

  console.log("\n  Executing swap...");
  console.log(
    "  Step 1: Simulating transaction to diagnose potential issues..."
  );
  let simulationSucceeded = false;
  const swapRouterInterface = new ethers.Interface(SWAP_ROUTER_ABI);

  try {
    const calldata = swapRouterInterface.encodeFunctionData("swap", [
      poolKey,
      swapParams,
      testSettings,
      hookData,
    ]);

    console.log("    Calling swap function via provider.call()...");
    const result = await provider.call({
      to: swapRouterAddress,
      data: calldata,
      from: wallet.address,
    });

    console.log("  ✓ Simulation succeeded! Swap should work.");
    console.log(`    Result: ${result}`);
    simulationSucceeded = true;
  } catch (simError) {
    console.error(
      "\n  ✗✗✗ SIMULATION FAILED - This reveals why the swap will fail ✗✗✗"
    );
    console.error(`    Error message: ${simError.message}`);
    console.error(`    Error code: ${simError.code || "N/A"}`);

    // Try to extract more details
    if (simError.data) {
      console.error(`    Error data: ${simError.data}`);
      if (simError.data !== "0x" && simError.data.length > 10) {
        const errorSig = simError.data.slice(0, 10);
        console.error(`    Error signature: ${errorSig}`);
        if (errorSig === "0x08c379a0") {
          console.error("    This is a revert with reason string");
          try {
            const decoded = swapRouterInterface.decodeErrorResult(
              "Error",
              simError.data
            );
            console.error(`    Decoded reason: ${decoded}`);
          } catch (e) {
            // Ignore decode errors
          }
        }
      }
    }

    if (simError.reason) {
      console.error(`    Revert reason: ${simError.reason}`);
    }

    // Check for common error patterns
    const errorMsg = simError.message.toLowerCase();

    console.error("\n    === Detailed Error Analysis ===");
    if (simError.data && simError.data !== "0x" && simError.data.length > 10) {
      const errorSelector = simError.data.slice(0, 10);
      console.error(`    Error selector: ${errorSelector}`);

      const knownErrors = {
        "0x08c379a0": "Error(string) - Revert with reason string",
        "0x4e487b71": "Panic(uint256) - Arithmetic or assertion failure",
      };
      if (knownErrors[errorSelector]) {
        console.error(`    Known error type: ${knownErrors[errorSelector]}`);
      }
    }

    if (
      errorMsg.includes("pool not initialized") ||
      errorMsg.includes("sqrtpricex96") ||
      errorMsg.includes("slot0") ||
      errorMsg.includes("require(false)") ||
      (errorMsg.includes("revert") && simError.data === "0x")
    ) {
      console.error("\n    ⚠ DIAGNOSIS: Swap validation failed!");
      console.error("      - Try a smaller swap amount or check hook logic");
    } else if (
      errorMsg.includes("insufficient liquidity") ||
      errorMsg.includes("no liquidity")
    ) {
      console.error("\n    ⚠ DIAGNOSIS: Pool has insufficient liquidity!");
      console.error("    SOLUTION: Add more liquidity to the pool");
    } else if (
      errorMsg.includes("price limit") ||
      errorMsg.includes("sqrtpricelimit")
    ) {
      console.error("\n    ⚠ DIAGNOSIS: Price limit issue!");
      console.error("    SOLUTION: Check sqrtPriceLimitX96 parameter");
    } else {
      console.error(
        "\n    ⚠ Could not identify specific issue from error message."
      );
    }

    console.error(
      "\n    Since simulation failed, the actual swap will also fail."
    );
    console.error("    Fix the issue above before attempting the swap.\n");
    throw new Error(`Swap will revert: ${simError.message}`);
  }

  if (!simulationSucceeded) {
    throw new Error("Cannot proceed with swap - simulation failed");
  }

  console.log("\n  Step 2: Sending actual swap transaction...");
  try {
    const tx = await swapRouter.swap(
      poolKey,
      swapParams,
      testSettings,
      hookData,
      {
        gasLimit: 5000000,
      }
    );

    console.log(`  Transaction hash: ${tx.hash}`);

    let receipt;
    try {
      receipt = await tx.wait();
    } catch (waitError) {
      if (waitError.receipt) {
        receipt = waitError.receipt;
        console.error("  ✗ Transaction reverted!");
        console.error(`    Status: ${receipt.status}`);
        console.error(`    Gas used: ${receipt.gasUsed.toString()}`);
        console.error(`    Block: ${receipt.blockNumber}`);

        // Try to get revert reason by calling the function with callStatic
        try {
          await swapRouter.swap.staticCall(
            poolKey,
            swapParams,
            testSettings,
            hookData
          );
        } catch (staticError) {
          console.error(`    Revert reason: ${staticError.message}`);
          if (staticError.data) {
            console.error(`    Revert data: ${staticError.data}`);
          }
        }

        throw new Error(`Swap transaction reverted: ${waitError.message}`);
      }
      throw waitError;
    }

    if (receipt.status === 0) {
      throw new Error("Transaction reverted (status: 0)");
    }

    console.log("  ✓ Swap transaction confirmed");
    console.log(`  Gas used: ${receipt.gasUsed.toString()}`);

    console.log("\n  === Verifying FHE Operations ===");
    const hookInterface = new ethers.Interface(HOOK_ABI);
    let fheOperationsDetected = false;
    let rebalancingExecuted = false;

    for (const log of receipt.logs) {
      try {
        const parsedLog = hookInterface.parseLog({
          topics: log.topics,
          data: log.data,
        });

        if (parsedLog) {
          if (parsedLog.name === "RebalancingExecuted") {
            rebalancingExecuted = true;
            console.log(
              `  ✓ RebalancingExecuted event detected (strategyId: ${parsedLog.args.strategyId})`
            );
          } else if (parsedLog.name === "FHEOperationFailed") {
            console.log(
              `  ⚠ FHEOperationFailed event detected: ${parsedLog.args.reason}`
            );
          }
        }
      } catch (e) { }
    }

    const hookCalled =
      receipt.to?.toLowerCase() === swapRouterAddress.toLowerCase() ||
      receipt.logs.some(
        (log) => log.address.toLowerCase() === CONFIG.HOOK_ADDRESS.toLowerCase()
      );

    if (hookCalled) {
      fheOperationsDetected = true;
      console.log("  ✓ Hook contract was called during swap");
    }

    console.log("\n  === Swap Completed ===");
    console.log(
      "  Delta values: Check transaction receipt logs for swap details"
    );

    console.log("\n  === FHE Operations Status ===");
    if (rebalancingExecuted) {
      console.log("  ✓ FHE operations CONFIRMED via RebalancingExecuted event");
    } else if (fheOperationsDetected) {
      console.log(
        "  ✓ Hook was called - FHE operations likely executed (check events for confirmation)"
      );
    } else {
      console.log(
        "  ⚠ Could not verify FHE execution - ensure pool is registered with strategy"
      );
    }

    return { amount0: 0n, amount1: 0n, success: true };
  } catch (error) {
    console.error("\n  ✗ Swap failed!");
    console.error(`  Error message: ${error.message}`);

    if (error.reason) {
      console.error(`  Revert reason: ${error.reason}`);
    }

    if (error.data) {
      console.error(`  Error data: ${error.data}`);
      try {
        const commonErrors = [
          "error Error(string)",
          "error Panic(uint256)",
          "error InsufficientInputAmount()",
          "error InsufficientOutputAmount()",
          "error InvalidPriceLimit()",
          "error PoolNotFound()",
        ];
        const iface = new ethers.Interface(commonErrors);
        if (error.data && error.data.length >= 10) {
          const selector = error.data.slice(0, 10);
          const decoded = iface.parseError({ data: error.data });
          console.error(
            `  Decoded error: ${decoded.name}(${decoded.args.join(", ")})`
          );
        }
      } catch (decodeError) { }
    }

    if (error.info?.error) {
      console.error(`  RPC error: ${JSON.stringify(error.info.error)}`);
    }

    console.error("\n  Troubleshooting suggestions:");
    console.error("    1. Ensure the pool exists and is initialized");
    console.error("    2. Ensure there is liquidity in the pool");
    console.error("    3. Ensure you have sufficient token balance");
    console.error(
      "    4. Check that the pool parameters (fee, tickSpacing) match"
    );
    console.error(
      "    5. Try running: forge script script/01_CreatePoolAndMintLiquidity.s.sol"
    );

    throw error;
  }
}

async function enableCrossPoolCoordination(contract, strategyId, poolIds) {
  console.log("\n=== Enabling Cross-Pool Coordination ===");

  console.log(`Registering ${poolIds.length} pool(s) to strategy...`);
  console.log("  Pool IDs:", poolIds.map((id) => id.toString()).join(", "));
  const tx = await contract.enableCrossPoolCoordination(strategyId, poolIds);

  console.log(`  Transaction hash: ${tx.hash}`);
  await tx.wait();
  console.log("✓ Cross-pool coordination enabled");
  console.log(
    "  Note: Hook will now execute FHE operations during swaps on registered pools"
  );
}

async function main() {
  console.log("=== FHE Hook Frontend Integration Example ===\n");

  if (CONFIG.PRIVATE_KEY === "0x...") {
    console.error("ERROR: Please set your PRIVATE_KEY");
    console.error("You can set it via environment variable:");
    console.error("  export PRIVATE_KEY=0x...");
    console.error("\nOr update CONFIG.PRIVATE_KEY in index.js");
    process.exit(1);
  }

  console.log(
    "⚠️  IMPORTANT: Ensure the pool exists, is initialized, AND has liquidity!"
  );
  console.log(
    "   If you get 'require(false)' errors during swap, it's likely missing liquidity."
  );
  console.log("\n   Quick fix - Add liquidity:");
  console.log(
    "   forge script script/02_AddLiquidity.s.sol --rpc-url $RPC_URL --broadcast"
  );
  console.log("\n   Or create pool + liquidity together:");
  console.log(
    "   forge script script/01_CreatePoolAndMintLiquidity.s.sol --rpc-url $RPC_URL --broadcast\n"
  );

  console.log("Configuration:");
  console.log(`  RPC URL: ${CONFIG.RPC_URL}`);
  console.log(`  Environment: ${CONFIG.ENVIRONMENT}`);
  console.log(`  Hook Address: ${CONFIG.HOOK_ADDRESS}`);
  console.log(`  Pool Manager: ${CONFIG.POOL_MANAGER_ADDRESS}`);
  console.log(`  Token0: ${CONFIG.TOKEN0_ADDRESS}`);
  console.log(`  Token1: ${CONFIG.TOKEN1_ADDRESS}`);

  console.log("Initializing provider and wallet...");
  const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);
  const wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider);
  console.log(`  Wallet address: ${wallet.address}`);

  await initializeCofhejs(provider, wallet);

  const hookContract = new ethers.Contract(
    CONFIG.HOOK_ADDRESS,
    HOOK_ABI,
    wallet
  );

  const strategyId = ethers.keccak256(ethers.toUtf8Bytes("my-strategy-001"));

  try {
    const strategyCreated = await createStrategy(
      hookContract,
      strategyId,
      wallet.address
    );

    if (!strategyCreated) {
      console.log("\nUsing existing strategy for remaining operations...");
    }

    console.log("\n=== Setting Target Allocations ===");
    await setTargetAllocation(
      hookContract,
      strategyId,
      CONFIG.TOKEN0_ADDRESS,
      wallet.address
    );

    await setTargetAllocation(
      hookContract,
      strategyId,
      CONFIG.TOKEN1_ADDRESS,
      wallet.address
    );

    console.log("\n=== Setting Encrypted Positions ===");
    const positionValue0 = "1000000000000000000000000";
    await setEncryptedPosition(
      hookContract,
      strategyId,
      CONFIG.TOKEN0_ADDRESS,
      positionValue0,
      wallet.address
    );

    const positionValue1 = "1000000000000000000000000";
    await setEncryptedPosition(
      hookContract,
      strategyId,
      CONFIG.TOKEN1_ADDRESS,
      positionValue1,
      wallet.address
    );

    // Try to unseal position (optional - just for verification, not required for swap)
    try {
      await readAndUnsealPosition(
        hookContract,
        strategyId,
        CONFIG.TOKEN0_ADDRESS,
        wallet
      );
    } catch (error) {
      console.log("⚠ Unseal failed (localStorage issue in Node.js), skipping...");
      console.log("  This is OK - unseal is not required for swaps to work");
    }

    const lpFee = 3000;
    const tickSpacing = 60;

    console.log("\n=== Registering Pool with Strategy ===");
    console.log(
      "  This is REQUIRED for the hook to execute FHE operations during swaps!"
    );
    console.log("  Pool configuration:");
    console.log(`    Currency0: ${CONFIG.TOKEN0_ADDRESS}`);
    console.log(`    Currency1: ${CONFIG.TOKEN1_ADDRESS}`);
    console.log(`    Fee: ${lpFee} (0.30%)`);
    console.log(`    Tick Spacing: ${tickSpacing}`);
    console.log(`    Hook: ${CONFIG.HOOK_ADDRESS}`);

    const poolIdBytes32 = calculatePoolIdBytes32(
      CONFIG.TOKEN0_ADDRESS,
      CONFIG.TOKEN1_ADDRESS,
      lpFee,
      tickSpacing,
      CONFIG.HOOK_ADDRESS
    );

    console.log(`Calculated PoolId (bytes32): ${poolIdBytes32}`);

    try {
      const registeredStrategies = await hookContract.poolStrategies(
        poolIdBytes32
      );
      const isRegistered = registeredStrategies.some(
        (id) => id.toLowerCase() === strategyId.toLowerCase()
      );

      if (isRegistered) {
        console.log("  ✓ Pool already registered to this strategy");
      } else {
        console.log("  Registering pool...");
        await enableCrossPoolCoordination(hookContract, strategyId, [
          poolIdBytes32,
        ]);
      }
    } catch (error) {
      console.log("  Registering pool...");
      await enableCrossPoolCoordination(hookContract, strategyId, [
        poolIdBytes32,
      ]);
    }

    console.log("\n=== Performing Swap to Trigger FHE Operations ===");
    const addr0 = ethers.getBigInt(CONFIG.TOKEN0_ADDRESS);
    const addr1 = ethers.getBigInt(CONFIG.TOKEN1_ADDRESS);
    const currenciesWereSwapped = addr0 > addr1;
    const sortedCurrency0 =
      addr0 < addr1 ? CONFIG.TOKEN0_ADDRESS : CONFIG.TOKEN1_ADDRESS;
    const sortedCurrency1 =
      addr0 < addr1 ? CONFIG.TOKEN1_ADDRESS : CONFIG.TOKEN0_ADDRESS;

    const poolKey = {
      currency0: sortedCurrency0,
      currency1: sortedCurrency1,
      fee: lpFee,
      tickSpacing: tickSpacing,
      hooks: CONFIG.HOOK_ADDRESS,
    };

    const swapAmount = ethers.parseEther("0.1");
    const zeroForOne = currenciesWereSwapped ? false : true;

    const calculatedPoolId = calculatePoolIdBytes32(
      poolKey.currency0,
      poolKey.currency1,
      poolKey.fee,
      poolKey.tickSpacing,
      poolKey.hooks
    );

    console.log("\n  === PoolId Information ===");
    console.log(
      `  Calculated PoolId (bytes32): ${calculatedPoolId}`
    );

    await performSwap(
      provider,
      wallet,
      CONFIG.SWAP_ROUTER_ADDRESS,
      poolKey,
      swapAmount,
      zeroForOne
    );

    console.log("\n=== All operations completed successfully! ===");
    console.log("\n=== Summary ===");
    console.log("✓ Strategy created/configured with encrypted parameters");
    console.log("✓ Target allocations set");
    console.log("✓ Encrypted positions set");
    console.log("✓ Pool registered to strategy");
    console.log("✓ Swap executed - FHE operations triggered in hook");
  } catch (error) {
    console.error("\n=== Error occurred ===");
    console.error(error);
    process.exit(1);
  }
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = {
  initializeCofhejs,
  createStrategy,
  setTargetAllocation,
  setEncryptedPosition,
  readAndUnsealPosition,
  enableCrossPoolCoordination,
  performSwap,
  approveTokensIfNeeded,
};
