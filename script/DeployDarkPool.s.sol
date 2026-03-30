// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ConfidentialRebalancingHook} from "../src/ConfidentialRebalancingHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Constants} from "./base/Constants.sol";

/**
 * @title DeployDarkPool
 * @notice Deploys the ConfidentialRebalancingHook with the Dark Pool Internalization
 *         feature to Sepolia testnet.
 *
 * New vs original deployment:
 *   + BEFORE_SWAP_RETURNS_DELTA_FLAG  (allows hook to divert matched volume from the AMM)
 *
 * Usage:
 *   1. Copy .env.example to .env and fill in PRIVATE_KEY and SEPOLIA_RPC_URL
 *   2. Run:
 *        forge script script/DeployDarkPool.s.sol:DeployDarkPool \
 *          --rpc-url $SEPOLIA_RPC_URL \
 *          --broadcast \
 *          --verify \
 *          -vvvv
 *
 * Environment variables:
 *   PRIVATE_KEY     - Deployer private key (hex, no 0x prefix needed)
 *   SEPOLIA_RPC_URL - Sepolia RPC endpoint (e.g. from Alchemy or Infura)
 *   GOVERNANCE_ADDR - (optional) governance address; falls back to deployer
 *
 * After deployment:
 *   - Record the hook address printed by the script.
 *   - Run 01_CreatePoolAndMintLiquidity.s.sol with hookContract = <hookAddress>.
 *   - Use 03_Swap.s.sol to trigger dark pool fills on-chain.
 */
contract DeployDarkPool is Script, Constants {

    // ---------------------------------------------------------------------------
    // Configuration -- edit before deploying.
    // ---------------------------------------------------------------------------

    /// @dev Set to your desired governance address, or leave as address(0).
    ///      If address(0) the script will use the deployer address.
    address constant GOVERNANCE_OVERRIDE = address(0);

    // ---------------------------------------------------------------------------
    // Run
    // ---------------------------------------------------------------------------
    function run() external {
        // ── Resolve deployer ──────────────────────────────────────────────────
        uint256 deployerPk;
        try vm.envUint("PRIVATE_KEY") returns (uint256 pk) {
            deployerPk = pk;
        } catch {
            revert("PRIVATE_KEY env var not set");
        }
        address deployer = vm.addr(deployerPk);

        // ── Resolve governance ────────────────────────────────────────────────
        address governance = GOVERNANCE_OVERRIDE != address(0)
            ? GOVERNANCE_OVERRIDE
            : deployer;

        // Prefer explicit env-var governance override
        try vm.envAddress("GOVERNANCE_ADDR") returns (address g) {
            if (g != address(0)) governance = g;
        } catch {}

        // ── Pre-flight logging ────────────────────────────────────────────────
        console.log("==============================================");
        console.log("  Confidential Dark Pool Hook Deployment");
        console.log("  Network:    Sepolia testnet");
        console.log("==============================================");
        console.log("Deployer   :", deployer);
        console.log("Governance :", governance);
        console.log("PoolManager:", address(POOLMANAGER));

        uint256 balance = deployer.balance;
        console.log("ETH balance:", balance / 1e15, "milli-ETH");
        require(balance >= 0.01 ether, "Insufficient ETH; get Sepolia ETH from https://sepoliafaucet.com/");

        // ── Permission flags ──────────────────────────────────────────────────
        // The hook address must encode all permissions it uses.
        // New flag vs the original deploy: BEFORE_SWAP_RETURNS_DELTA_FLAG
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG          |   // runs dark pool + strategy matching
            Hooks.AFTER_SWAP_FLAG           |   // updates positions post-swap
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |   // monitors liquidity additions
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG| // monitors liquidity removals
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG // hook may absorb matched swap volume
        );

        // Mine a salt that will produce a hook address with the correct permissions
        bytes memory constructorArgs = abi.encode(POOLMANAGER);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(ConfidentialRebalancingHook).creationCode,
            constructorArgs
        );

        console.log("Mined hook address:", hookAddress);
        console.log("CREATE2 salt (hex):", vm.toString(salt));

        // ── Deploy ────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerPk);

        ConfidentialRebalancingHook hook = new ConfidentialRebalancingHook{salt: salt}(
            POOLMANAGER
        );

        require(address(hook) == hookAddress, "DeployDarkPool: address mismatch");


        vm.stopBroadcast();

        // ── Post-deploy info ──────────────────────────────────────────────────
        console.log("==============================================");
        console.log("  DEPLOYMENT SUCCESSFUL");
        console.log("==============================================");
        console.log("Hook address       :", address(hook));
        console.log("");
        console.log("Next steps:");
        console.log("  1. Create a pool with this hook:");
        console.log("     forge script script/01_CreatePoolAndMintLiquidity.s.sol \\");
        console.log("       --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv");
        console.log("");
        console.log("  2. Place a dark order:");
        console.log("     Use cast or a frontend to call hook.placeDarkOrder(...)");
        console.log("");
        console.log("  3. Execute a swap to trigger internalization:");
        console.log("     forge script script/03_Swap.s.sol \\");
        console.log("       --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv");
        console.log("");
        console.log("  4. Claim filled proceeds:");
        console.log("     Use cast to call hook.claimDarkOrder(poolKey, orderId)");
        console.log("==============================================");
    }
}
