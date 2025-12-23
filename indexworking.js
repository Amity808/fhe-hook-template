/**
 * @file index.js
 * @description Example script demonstrating how to use cofhejs to interact with
 * the ConfidentialRebalancingHook contract. This shows the frontend integration
 * pattern for FHE-enabled contracts.
 *
 * This script demonstrates:
 * 1. Initializing cofhejs client
 * 2. Encrypting values before sending to contract
 * 3. Creating permits for sealed data access
 * 4. Unsealing encrypted results from the contract
 */

const { cofhejs, FheTypes, Encryptable } = require("cofhejs/node");
const { ethers } = require("ethers");

// Configuration - Addresses from deployment on Sepolia
const CONFIG = {
  // RPC endpoint - Sepolia testnet
  RPC_URL:
    process.env.RPC_URL ||
    "https://sepolia.infura.io/v3/709bdd438a58422b891043c58e636a64",
  ENVIRONMENT: process.env.ENVIRONMENT || "TESTNET", // LOCAL, TESTNET, or MAINNET

  // Contract addresses from deployment (Sepolia chain ID: 11155111)
  HOOK_ADDRESS:
    process.env.HOOK_ADDRESS || "0xd6F8dDC186434d891B8653FF2083436067114aC0", // ConfidentialRebalancingHook
  POOL_MANAGER_ADDRESS:
    process.env.POOL_MANAGER_ADDRESS ||
    "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543", // Uniswap V4 PoolManager

  // Token addresses (from Config.sol)
  TOKEN0_ADDRESS:
    process.env.TOKEN0_ADDRESS || "0x2794a0b7187BFCd81D2b6d05E8a6e6cAE3F97fFa", // MockTokenA
  TOKEN1_ADDRESS:
    process.env.TOKEN1_ADDRESS || "0xEa20820719c5Ae04Bce9A098E209f4d8C60DAF06", // MockTokenB

  // Private key for signing transactions
  PRIVATE_KEY: process.env.PRIVATE_KEY || "0x...", // REQUIRED: Set your private key
};

// Contract ABI - minimal interface for the hook functions we'll use
const HOOK_ABI = [
  "function createStrategy(bytes32 strategyId, uint256 rebalanceFrequency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) executionWindow, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) spreadBlocks, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxSlippage) external returns (bool)",
  "function setTargetAllocation(bytes32 strategyId, address currency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) targetPercentage, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) minThreshold, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxThreshold) external",
  "function setEncryptedPosition(bytes32 strategyId, address currency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) position) external",
  "function enableCrossPoolCoordination(bytes32 strategyId, bytes32[] pools) external",
  "function getStrategy(bytes32 strategyId) external view returns (tuple(bytes32 strategyId, address owner, bool isActive, uint256 lastRebalanceBlock, uint256 rebalanceFrequency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) executionWindow, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) spreadBlocks, uint256 priorityFee, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxSlippage))",
  "function getEncryptedPosition(bytes32 strategyId, address currency) external view returns (uint256)",
];

/**
 * Initialize cofhejs client with ethers provider
 */
async function initializeCofhejs(provider, wallet) {
  console.log("Initializing cofhejs client...");

  await cofhejs.initializeWithEthers({
    ethersProvider: provider,
    ethersSigner: wallet,
    environment: CONFIG.ENVIRONMENT,
  });

  console.log("✓ cofhejs initialized successfully");
}

/**
 * Log encryption state for better UX
 */
const logEncryptState = (state) => {
  console.log(`  Encryption State: ${state}`);
  // Return nothing - callback should not interfere with encryption
};

/**
 * Create a rebalancing strategy with encrypted parameters
 * Returns true if strategy was created, false if it already exists
 */
async function createStrategy(contract, strategyId, deployerAddress) {
  console.log("\n=== Creating Strategy with Encrypted Parameters ===");

  // Check if strategy already exists
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

  // Debug: Log the structure of encryptedValues
  console.log("Debug - encryptedValues structure:", {
    type: typeof encryptedValues,
    isArray: Array.isArray(encryptedValues),
    isNull: encryptedValues === null,
    isUndefined: encryptedValues === undefined,
    hasData: !!encryptedValues?.data,
    keys: encryptedValues ? Object.keys(encryptedValues) : null,
  });

  // Extract encrypted values - cofhejs returns array directly or in .data property
  // Based on cofhejs docs, encrypt() returns an array of CoFheInUint128 objects
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
    // If .data is null/undefined, check if the object itself is usable
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

  // Create strategy
  console.log("Calling createStrategy on contract...");
  try {
    const tx = await contract.createStrategy(
      strategyId,
      10, // rebalanceFrequency: 10 blocks
      executionWindow,
      spreadBlocks,
      maxSlippage
    );

    console.log(`  Transaction hash: ${tx.hash}`);
    await tx.wait();
    console.log("✓ Strategy created successfully");
    return true; // Strategy was created
  } catch (error) {
    if (error.reason && error.reason.includes("already exists")) {
      console.log("Strategy already exists, skipping creation...");
      return false; // Strategy already exists
    }
    throw error; // Re-throw if it's a different error
  }
}

/**
 * Set encrypted target allocation for a currency
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

  // Extract encrypted values - handle both array and .data formats
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

  // Set target allocation
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

  // Extract encrypted value - handle both array and .data formats
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

  // Set encrypted position
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
 * Read encrypted position and unseal it
 */
async function readAndUnsealPosition(
  contract,
  strategyId,
  currencyAddress,
  deployerAddress
) {
  console.log("\n=== Reading and Unsealing Encrypted Position ===");

  // Get or create permit for unsealing
  console.log("Getting permit for unsealing...");
  let permit;
  try {
    // Try to get existing permit first
    permit = await cofhejs.getPermit({
      type: "self",
      issuer: deployerAddress,
    });
    console.log("✓ Using existing permit");
  } catch (error) {
    // If no permit exists, create one
    console.log("No existing permit found, creating new one...");
    permit = await cofhejs.createPermit({
      type: "self",
      issuer: deployerAddress,
    });
    console.log("✓ Permit created");
  }

  // Check permit structure - permit might be the data directly or have a .data property
  const permitData = permit?.data || permit;
  if (!permitData) {
    console.error("ERROR: Failed to create/get permit");
    console.error("Permit object:", JSON.stringify(permit, null, 2));
    throw new Error("Permit creation failed - permit data is null");
  }

  // Read encrypted position from contract
  console.log("Reading encrypted position from contract...");
  const encryptedPosition = await contract.getEncryptedPosition(
    strategyId,
    currencyAddress
  );
  console.log(`  Encrypted position (ctHash): ${encryptedPosition.toString()}`);

  // Unseal the encrypted value
  // Note: The encryptedPosition from contract is just a ctHash (uint256),
  // but unseal might need the full InEuint128 structure
  console.log("Unsealing encrypted position...");

  try {
    const unsealed = await cofhejs.unseal(
      encryptedPosition,
      FheTypes.Uint128,
      permitData.issuer || deployerAddress,
      permitData.getHash ? permitData.getHash() : permitData.hash
    );

    console.log(`✓ Position unsealed: ${unsealed.toString()}`);
    return unsealed;
  } catch (error) {
    console.error("Error unsealing:", error.message);
    console.log(
      "Note: Unsealing requires the contract to seal the data with your public key first."
    );
    console.log(
      "The position was set encrypted, but may not be sealed for your address yet."
    );
    throw error;
  }
}

/**
 * Enable cross-pool coordination
 */
async function enableCrossPoolCoordination(contract, strategyId, poolIds) {
  console.log("\n=== Enabling Cross-Pool Coordination ===");

  console.log(`Registering ${poolIds.length} pool(s) to strategy...`);
  const tx = await contract.enableCrossPoolCoordination(strategyId, poolIds);

  console.log(`  Transaction hash: ${tx.hash}`);
  await tx.wait();
  console.log("✓ Cross-pool coordination enabled");
}

/**
 * Main execution function
 */
async function main() {
  console.log("=== FHE Hook Frontend Integration Example ===\n");

  // Validate configuration
  if (CONFIG.PRIVATE_KEY === "0x...") {
    console.error("ERROR: Please set your PRIVATE_KEY");
    console.error("You can set it via environment variable:");
    console.error("  export PRIVATE_KEY=0x...");
    console.error("\nOr update CONFIG.PRIVATE_KEY in index.js");
    process.exit(1);
  }

  console.log("Configuration:");
  console.log(`  RPC URL: ${CONFIG.RPC_URL}`);
  console.log(`  Environment: ${CONFIG.ENVIRONMENT}`);
  console.log(`  Hook Address: ${CONFIG.HOOK_ADDRESS}`);
  console.log(`  Pool Manager: ${CONFIG.POOL_MANAGER_ADDRESS}`);
  console.log(`  Token0: ${CONFIG.TOKEN0_ADDRESS}`);
  console.log(`  Token1: ${CONFIG.TOKEN1_ADDRESS}`);

  // Initialize provider and wallet
  console.log("Initializing provider and wallet...");
  const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);
  const wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider);
  console.log(`  Wallet address: ${wallet.address}`);

  // Initialize cofhejs
  await initializeCofhejs(provider, wallet);

  // Create contract instance
  const hookContract = new ethers.Contract(
    CONFIG.HOOK_ADDRESS,
    HOOK_ABI,
    wallet
  );

  // Example: Create a strategy
  // Use a unique strategy ID - you can change this to create a new strategy
  const strategyId = ethers.keccak256(ethers.toUtf8Bytes("my-strategy-001"));

  try {
    // Step 1: Create strategy with encrypted parameters (or use existing)
    const strategyCreated = await createStrategy(
      hookContract,
      strategyId,
      wallet.address
    );

    if (!strategyCreated) {
      console.log("\nUsing existing strategy for remaining operations...");
    }

    // Step 2: Set target allocations (example for currency0)
    await setTargetAllocation(
      hookContract,
      strategyId,
      CONFIG.TOKEN0_ADDRESS,
      wallet.address
    );

    // Step 3: Set encrypted positions
    const positionValue = "1000000000000000000000000"; // 1M tokens (with 18 decimals)
    await setEncryptedPosition(
      hookContract,
      strategyId,
      CONFIG.TOKEN0_ADDRESS,
      positionValue,
      wallet.address
    );

    // Step 4: Read and unseal position (demonstrates decryption)
    await readAndUnsealPosition(
      hookContract,
      strategyId,
      CONFIG.TOKEN0_ADDRESS,
      wallet.address
    );

    // Step 5: Enable cross-pool coordination (example)
    // const poolIds = [ethers.keccak256(ethers.toUtf8Bytes("pool-1"))];
    // await enableCrossPoolCoordination(hookContract, strategyId, poolIds);

    console.log("\n=== All operations completed successfully! ===");
  } catch (error) {
    console.error("\n=== Error occurred ===");
    console.error(error);
    process.exit(1);
  }
}

// Run the script
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
};
