// Shim localStorage for Node.js compatibility (required by @cofhe/sdk permit store)
// MUST BE AT THE VERY TOP before any SDK requires
if (typeof localStorage === "undefined") {
  global.localStorage = {
    _data: {},
    setItem: function(id, val) { this._data[id] = String(val); },
    getItem: function(id) { return this._data.hasOwnProperty(id) ? this._data[id] : null; },
    removeItem: function(id) { delete this._data[id]; },
    clear: function() { this._data = {}; }
  };
}

/**
 * Frontend integration script for Uniswap v4 Hook using @cofhe/sdk
 */

const { createCofheClient, createCofheConfig } = require("@cofhe/sdk/node");

const { Encryptable, FheTypes } = require("@cofhe/sdk");
const { PermitUtils } = require("@cofhe/sdk/permits");
const { Ethers6Adapter } = require("@cofhe/sdk/adapters");
const { sepolia } = require("@cofhe/sdk/chains");
const { ethers } = require("ethers");
require("dotenv").config();

const { setGlobalDispatcher, Agent } = require('undici');

// Increase undici global connect timeout to 60s for slow testnet ZK verification
setGlobalDispatcher(new Agent({
  connect: { timeout: 60000 },
  bodyTimeout: 60000,
  headersTimeout: 60000
}));

// Patch global fetch timeout for slow ZK verification on testnet
const originalFetch = globalThis.fetch;
globalThis.fetch = (url, options) => {
  // Force 60s timeout even if the caller provides a shorter one or uses a different timeout property
  return originalFetch(url, {
    ...options,
    timeout: 60000,
    signal: AbortSignal.timeout(60000)
  });
};

const CONFIG = {
  // RPC endpoint - Sepolia testnet with Fhenix CoFHE support
  RPC_URL: process.env.SEPOLIA_RPC_URL || "https://sepolia.infura.io/v3/709bdd438a58422b891043c58e636a64",
  
  // Contract addresses from deployment (Sepolia chain ID: 11155111)
  HOOK_ADDRESS: ethers.getAddress((process.env.HOOK_ADDRESS || "0x6A755997D7B06900Fc3AFA8085A76C7182658aC8").toLowerCase()),
  POOL_MANAGER_ADDRESS: ethers.getAddress((process.env.POOL_MANAGER_ADDRESS || "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543").toLowerCase()),
  SWAP_ROUTER_ADDRESS: ethers.getAddress((process.env.SWAP_ROUTER_ADDRESS || "0xcAc2474F8AAA489A7739B21Ced73c184b35C1821").toLowerCase()),

  // Token addresses
  TOKEN0_ADDRESS: ethers.getAddress((process.env.TOKEN0_ADDRESS || "0x2794a0b7187BFCd81D2b6d05E8a6e6cAE3F97fFa").toLowerCase()),
  TOKEN1_ADDRESS: ethers.getAddress((process.env.TOKEN1_ADDRESS || "0xEa20820719c5Ae04Bce9A098E209f4d8C60DAF06").toLowerCase()),

  // Pool parameters
  POOL_FEE: 3000,
  TICK_SPACING: 60,

  PRIVATE_KEY: process.env.PRIVATE_KEY,
};

const HOOK_ABI = [
  "function createStrategy(bytes32 strategyId, uint256 rebalanceFrequency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) executionWindow, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) spreadBlocks, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxSlippage) external returns (bool)",
  "function setTargetAllocation(bytes32 strategyId, address currency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) targetPercentage, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) minThreshold, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxThreshold) external",
  "function setEncryptedPosition(bytes32 strategyId, address currency, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) position) external",
  "function getStrategy(bytes32 strategyId) external view returns (tuple(bytes32 strategyId, address owner, bool isActive, uint256 lastRebalanceBlock, uint256 rebalanceFrequency, tuple(tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) executionWindow, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) spreadBlocks, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) priorityFee, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) maxSlippage) executionParams))",
  "function getEncryptedPosition(bytes32 strategyId, address currency) external view returns (uint256)",
  "function getDarkOrderBook(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey) external view returns (tuple(address owner, uint256 encryptedAmount, uint128 plainAmount, uint128 filledAmount, bool isBuy, bool isActive)[])",
  "function getDarkOrder(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, uint256 orderId) external view returns (tuple(address owner, uint256 encryptedAmount, uint128 plainAmount, uint128 filledAmount, bool isBuy, bool isActive))",
  "event DarkOrderPlaced(bytes32 indexed poolId, uint256 indexed orderId, address indexed owner, bool isBuy)",
  "event DarkOrderFilled(bytes32 indexed poolId, uint256 indexed orderId, uint128 matchedAmount)",
  "event DarkOrderClaimed(bytes32 indexed poolId, uint256 indexed orderId, uint128 claimedAmount)",
  "function placeDarkOrder(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, uint128 plainAmount, tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature) encAmount, bool isBuy) external payable returns (uint256 orderId)",
  "function cancelDarkOrder(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, uint256 orderId) external",
  "function claimDarkOrder(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, uint256 orderId) external",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
];

const SWAP_ROUTER_ABI = [
  "function swap(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, tuple(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, bytes hookData) external payable returns (tuple(int128 amount0, int128 amount1) delta)",
];

/**
 * Initialize @cofhe/sdk client using Ethers adapter
 */
async function initializeCofheClient(provider, wallet) {
  console.log("Initializing @cofhe/sdk client...");

  try {
    // Manual storage implementation to avoid SDK/Zustand incompatibility
    const manualStorage = {
      getItem: async (name) => null,
      setItem: async (name, value) => { /* no-op or in-memory */ },
      removeItem: async (name) => { /* no-op */ }
    };

    console.log("  Creating config...");
    const config = createCofheConfig({ 
      environment: 'node',
      supportedChains: [sepolia],
      fheKeyStorage: manualStorage
    });
    
    console.log("  Creating client...");
    const client = createCofheClient(config);
    
    // Convert Ethers provider/wallet to Viem clients via adapter
    console.log("  Adapting Ethers to Viem...");
    const { publicClient, walletClient } = await Ethers6Adapter(provider, wallet);
    console.log("  ✓ Adapter finished");
    
    console.log("  Connecting client...");
    await client.connect(publicClient, walletClient);
    console.log("✓ @cofhe/sdk client initialized and connected");
    return client;
  } catch (error) {
    console.error("✗ @cofhe/sdk initialization failed:", error.message);
    throw error;
  }
}

async function approveTokensIfNeeded(tokenAddress, ownerWallet, spenderAddress, amount, tokenName) {
  const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, ownerWallet);
  const currentAllowance = await tokenContract.allowance(ownerWallet.address, spenderAddress);

  if (currentAllowance >= amount) {
    console.log(`  ✓ ${tokenName} already approved`);
    return;
  }

  console.log(`  Approving ${tokenName} for ${spenderAddress}...`);
  const tx = await tokenContract.approve(spenderAddress, ethers.MaxUint256);
  await tx.wait();
  console.log(`  ✓ ${tokenName} approved`);
}

async function placeDarkOrder(client, hookContract, poolKey, amount, isBuy) {
  console.log("\n=== Placing Encrypted Dark Order (@cofhe/sdk) ===");
  console.log(`  Direction: ${isBuy ? "BUY" : "SELL"}`);
  console.log(`  Amount: ${ethers.formatEther(amount)} tokens`);

  // 1. Encrypt via new SDK
  console.log("  Encrypting amount using @cofhe/sdk...");
  const [encAmount] = await client.encryptInputs([Encryptable.uint128(amount)]).execute();
  console.log("  ✓ Order amount encrypted");

  // 2. Submit transaction
  console.log("  Submitting placeDarkOrder transaction...");
  const tx = await hookContract.placeDarkOrder(
    poolKey,
    amount,      // plainAmount
    encAmount,   // FHE-encrypted input
    isBuy,
    { gasLimit: 2000000 }
  );

  console.log(`  Transaction submitted: ${tx.hash}`);
  console.log("  Waiting for confirmation...");
  const receipt = await tx.wait();
  console.log(`  ✓ Transaction confirmed in block ${receipt.blockNumber}`);
  
  // Parse orderId from events
  console.log("  Parsing events for orderId...");
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() === CONFIG.HOOK_ADDRESS.toLowerCase()) {
      try {
        const parsed = hookContract.interface.parseLog(log);
        if (parsed && parsed.name === "DarkOrderPlaced") {
          console.log(`  ✓ Dark order placed! orderId=${parsed.args.orderId}`);
          return Number(parsed.args.orderId);
        }
      } catch (e) {
        // Skip logs that don't match the ABI (e.g. other hook events)
      }
    }
  }
  
  console.log("  ⚠ No DarkOrderPlaced event found in logs.");
  return 0;
}

/**
 * Strategy Management Functions (@cofhe/sdk)
 */

async function createStrategy(client, hookContract, strategyId) {
  console.log("\n=== Creating Strategy with Encrypted Parameters (@cofhe/sdk) ===");

  try {
    const existingStrategy = await hookContract.getStrategy(strategyId);
    if (existingStrategy.strategyId !== ethers.ZeroHash) {
      console.log(`  ✓ Strategy already exists (ID: ${strategyId})`);
      return false;
    }
  } catch (error) {
    console.log("  Strategy check failed, attempting to create...");
  }

  // Encrypt execution parameters
  console.log("  Encrypting strategy parameters...");
  const [executionWindow, spreadBlocks, maxSlippage] = await client.encryptInputs([
    Encryptable.uint128(100n), // 100 blocks
    Encryptable.uint128(10n),  // 10 blocks
    Encryptable.uint128(500n), // 500 basis points (5%)
  ]).execute();

  console.log("  Submitting createStrategy transaction...");
  try {
    const tx = await hookContract.createStrategy(
      strategyId,
      10, // rebalanceFrequency
      executionWindow,
      spreadBlocks,
      maxSlippage
    );
    console.log(`  Transaction: ${tx.hash}`);
    await tx.wait();
    console.log("  ✓ Strategy created successfully");
  } catch (error) {
    if (error.message.includes("Strategy already exists")) {
      console.log(`  ✓ Strategy already exists (handled from revert)`);
      return false;
    }
    throw error;
  }
  return true;
}

async function setTargetAllocation(client, hookContract, strategyId, currencyAddress) {
  console.log(`\n=== Setting Target Allocation for ${currencyAddress} ===`);

  console.log("  Encrypting allocation parameters...");
  const [targetPercentage, minThreshold, maxThreshold] = await client.encryptInputs([
    Encryptable.uint128(5000n), // 50%
    Encryptable.uint128(100n),  // 1%
    Encryptable.uint128(1000n), // 10%
  ]).execute();

  const tx = await hookContract.setTargetAllocation(
    strategyId,
    currencyAddress,
    targetPercentage,
    minThreshold,
    maxThreshold
  );

  console.log(`  Transaction: ${tx.hash}`);
  await tx.wait();
  console.log("  ✓ Target allocation set");
}

async function setEncryptedPosition(client, hookContract, strategyId, currencyAddress, amount) {
  console.log(`\n=== Setting Encrypted Position for ${currencyAddress} ===`);

  console.log(`  Encrypting position value: ${ethers.formatEther(amount)}`);
  const [position] = await client.encryptInputs([
    Encryptable.uint128(amount)
  ]).execute();

  const tx = await hookContract.setEncryptedPosition(strategyId, currencyAddress, position);
  console.log(`  Transaction: ${tx.hash}`);
  await tx.wait();
  console.log("  ✓ Encrypted position set");
}

async function readAndUnsealPosition(client, hookContract, strategyId, currencyAddress, provider, wallet) {
  console.log("\n=== Reading and Unsealing Encrypted Position (@cofhe/sdk) ===");

  console.log("  Reading encrypted position (CtHash) from contract...");
  const ctHash = await hookContract.getEncryptedPosition(strategyId, currencyAddress);
  console.log(`  CtHash: ${ctHash.toString()}`);

  if (ctHash === 0n || ctHash === undefined) {
    console.log("  ⚠ No encrypted position found (CtHash is 0)");
    return 0n;
  }

  console.log("  Creating FHE permit manually (bypassing persistence store)...");
  const { publicClient, walletClient } = await Ethers6Adapter(provider, wallet);
  const permit = await PermitUtils.createSelfAndSign(
    { issuer: wallet.address, name: "Ephemeral Position Permit" },
    publicClient,
    walletClient
  );

  console.log("  Decrypting and unsealing via CoFHE coprocessor (explicit permit)...");
  try {
    const unsealed = await client.decryptForView(ctHash, FheTypes.Uint128)
      .withPermit(permit)
      .execute();
    
    console.log(`  ✓ Position unsealed: ${unsealed.toString()} (${ethers.formatEther(unsealed)} tokens)`);
    return unsealed;
  } catch (error) {
    console.error("  ✗ Unseal failed:", error.message);
    console.log("  Note: Ensure the contract has FHE.allow() for your address on this CtHash.");
    return 0n;
  }
}

async function viewDarkOrderBook(hookContract, poolKey) {
  console.log("\n=== Dark Order Book ===");
  try {
    const orders = await hookContract.getDarkOrderBook(poolKey);
    if (orders.length === 0) {
      console.log("  (empty)");
      return;
    }

    orders.forEach((o, i) => {
      const side = o.isBuy ? "BUY" : "SELL";
      const status = o.isActive ? "ACTIVE" : "INACTIVE";
      console.log(`  #${i} | ${side} | ${status} | Plain: ${ethers.formatEther(o.plainAmount)} | Filled: ${ethers.formatEther(o.filledAmount)}`);
    });
  } catch (err) {
    console.log(`  ⚠ Could not read order book: ${err.message}`);
  }
}

async function performSwap(wallet, poolKey, amount, zeroForOne, strategyId = "0x0000000000000000000000000000000000000000000000000000000000000000") {
  console.log("\n=== Executing Public Swap to Match Dark Orders ===");
  const swapRouter = new ethers.Contract(CONFIG.SWAP_ROUTER_ADDRESS, SWAP_ROUTER_ABI, wallet);
  const routerInterface = new ethers.Interface(SWAP_ROUTER_ABI);
  
  // Approve router
  const tokenIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
  await approveTokensIfNeeded(tokenIn, wallet, CONFIG.SWAP_ROUTER_ADDRESS, amount, "TokenIn");

  console.log(`  Swapping ${ethers.formatEther(amount)} tokens...`);
  console.log(`  Strategy ID: ${strategyId}`);
  
  // Check balance
  const tokenContract = new ethers.Contract(tokenIn, ["function balanceOf(address) view returns (uint256)"], wallet);
  const balance = await tokenContract.balanceOf(wallet.address);
  console.log(`  TokenIn Balance: ${ethers.formatEther(balance)}`);
  if (balance < amount) {
    console.error("  ✗ Insufficient balance for swap!");
  }
  
  // sqrtPriceLimitX96 for Sepolia (from index.js)
  const sqrtPriceLimit = zeroForOne ? 4295128740n : 1461446703485210103287273052203988822378723970341n;

  const swapParams = {
    zeroForOne: zeroForOne,
    amountSpecified: -amount,
    sqrtPriceLimitX96: sqrtPriceLimit
  };

  // Use strategyId as hookData, ensuring it's valid hex bytes
  const hookData = strategyId === "0x" ? "0x" : strategyId;

  console.log("  Debug - PoolKey:", JSON.stringify(poolKey, (key, value) => typeof value === 'bigint' ? value.toString() : value, 2));
  console.log("  Debug - SwapParams:", JSON.stringify(swapParams, (key, value) => typeof value === 'bigint' ? value.toString() : value, 2));
  console.log("  Debug - HookData:", hookData);

  console.log("  Simulating swap transaction...");
  try {
    const calldata = routerInterface.encodeFunctionData("swap", [
      poolKey,
      swapParams,
      hookData
    ]);

    await wallet.connect(wallet.provider).call({
      to: CONFIG.SWAP_ROUTER_ADDRESS,
      data: calldata,
      from: wallet.address
    });
    console.log("  ✓ Simulation successful");
  } catch (error) {
    console.error("  ✗ Simulation failed!");
    if (error.data) {
      console.error(`    Revert data: ${error.data}`);
    }
    throw new Error(`Swap simulation failed: ${error.message}`);
  }

  const tx = await swapRouter.swap(
    poolKey,
    swapParams,
    hookData,
    { gasLimit: 5000000 }
  );

  console.log(`  Transaction hash: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log("  ✓ Swap transaction confirmed");
  
  // Check for Dark Pool Fill events
  receipt.logs.forEach(log => {
    if (log.address.toLowerCase() === CONFIG.HOOK_ADDRESS.toLowerCase()) {
      try {
        const hookInterface = new ethers.Interface(HOOK_ABI);
        const parsed = hookInterface.parseLog(log);
        if (parsed && parsed.name === "DarkOrderFilled") {
          console.log(`  ✨ MATCH! Order #${parsed.args.orderId} filled with ${ethers.formatEther(parsed.args.matchedAmount)} tokens`);
        }
      } catch (e) {}
    }
  });
}

async function main() {
  console.log("=== @cofhe/sdk Dark Pool Migration Demo ===\n");

  if (!CONFIG.PRIVATE_KEY) {
    console.error("ERROR: PRIVATE_KEY not found in .env");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL, undefined, {
    staticNetwork: true,
    timeout: 60000 
  });
  const wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider);
  console.log(`Wallet: ${wallet.address}`);

  const client = await initializeCofheClient(provider, wallet);
  const hookContract = new ethers.Contract(CONFIG.HOOK_ADDRESS, HOOK_ABI, wallet);

  // Define Pool Key
  const poolKey = {
    currency0: CONFIG.TOKEN0_ADDRESS,
    currency1: CONFIG.TOKEN1_ADDRESS,
    fee: 3000,
    tickSpacing: 60,
    hooks: CONFIG.HOOK_ADDRESS
  };

  // Ensure tokens are sorted as per Uniswap v4
  if (BigInt(poolKey.currency0) > BigInt(poolKey.currency1)) {
    [poolKey.currency0, poolKey.currency1] = [poolKey.currency1, poolKey.currency0];
  }

  // Pool state: v4 PoolManager uses internal mapping + extsload, no public pools() getter
  const poolId = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"],
    [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks]
  ));
  console.log(`Pool Id: ${poolId}`);

  // Diagnostic: Check hook's ERC20 balances (needed for dark order settlement)
  const token0Contract = new ethers.Contract(poolKey.currency0, ERC20_ABI, wallet);
  const token1Contract = new ethers.Contract(poolKey.currency1, ERC20_ABI, wallet);
  const hookToken0Bal = await token0Contract.balanceOf(CONFIG.HOOK_ADDRESS);
  const hookToken1Bal = await token1Contract.balanceOf(CONFIG.HOOK_ADDRESS);
  console.log(`Hook token0 balance: ${ethers.formatEther(hookToken0Bal)}`);
  console.log(`Hook token1 balance: ${ethers.formatEther(hookToken1Bal)}`);

  await viewDarkOrderBook(hookContract, poolKey);

  // --- Rebalancing Strategy Flow ---
  const strategyId = ethers.id("STRATEGY_SDK_DEMO_FINAL");
  console.log(`Using Strategy ID: ${strategyId}`);

  await createStrategy(client, hookContract, strategyId);
  await setTargetAllocation(client, hookContract, strategyId, poolKey.currency0);
  await setTargetAllocation(client, hookContract, strategyId, poolKey.currency1);
  
  const initialPos = ethers.parseEther("0.05");
  await setEncryptedPosition(client, hookContract, strategyId, poolKey.currency0, initialPos);

  // 1. Place a Dark Order
  const orderAmount = ethers.parseEther("0.01");
  const depositToken = poolKey.currency1; // BUY deposits c1
  await approveTokensIfNeeded(depositToken, wallet, CONFIG.HOOK_ADDRESS, orderAmount, "Currency1");
  
  const orderId = await placeDarkOrder(client, hookContract, poolKey, orderAmount, true);
  
  await viewDarkOrderBook(hookContract, poolKey);

  // 2. Test swap in !zeroForOne direction first (no BUY order match = no settlement)
  console.log("\n--- Testing Swap !zeroForOne (no dark order match) ---");
  await performSwap(wallet, poolKey, orderAmount, false, "0x");

  // 3. Test swap in zeroForOne direction (matches BUY orders, requires settlement)
  console.log("\n--- Testing Swap zeroForOne (matches dark BUY orders) ---");
  await performSwap(wallet, poolKey, orderAmount, true, "0x");

  await viewDarkOrderBook(hookContract, poolKey);

  // 3. Unseal updated position
  await readAndUnsealPosition(client, hookContract, strategyId, poolKey.currency0, provider, wallet);

  // 4. Finalize Dark Order
  console.log("\n=== Finalizing Order ===");
  try {
    console.log(`  Checking status of order #${orderId}...`);
    const order = await hookContract.getDarkOrder(poolKey, orderId);
    console.log(`  Order Side: ${order.isBuy ? "BUY" : "SELL"}, Active: ${order.isActive}, Filled: ${ethers.formatEther(order.filledAmount)}`);
    
    if (order.filledAmount > 0n) {
      console.log(`  Claiming ${ethers.formatEther(order.filledAmount)} filled tokens...`);
      const tx = await hookContract.claimDarkOrder(poolKey, orderId);
      await tx.wait();
      console.log("  ✓ Claimed successfully!");
    } else {
      console.log("  Order not filled. Cancelling...");
      const tx = await hookContract.cancelDarkOrder(poolKey, orderId);
      await tx.wait();
      console.log("  ✓ Cancelled successfully!");
    }
  } catch (err) {
    console.log(`  ⚠ Finalization failed: ${err.message}`);
    if (err.data) console.log(`  Error Data: ${err.data}`);
  }

  console.log("\n=== Migration Demo Finished ===");
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
