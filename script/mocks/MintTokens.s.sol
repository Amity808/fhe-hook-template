// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Config} from "../base/Config.sol";

contract MintTokensScript is Script, Config {
    function run() external {
        // Get the recipient address
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
        console.log("Minting tokens to:", recipient);
        console.log("Token0 address:", address(token0));
        console.log("Token1 address:", address(token1));

        // Amount to mint (1e18 = 1 token)
        uint256 amount = 10e18; // Mint 10 tokens of each

        vm.startBroadcast();

        // Cast to MockERC20 to access mint function
        MockERC20(address(token0)).mint(recipient, amount);
        console.log("Minted", amount, "Token0 to", recipient);

        MockERC20(address(token1)).mint(recipient, amount);
        console.log("Minted", amount, "Token1 to", recipient);

        vm.stopBroadcast();

        console.log("Successfully minted tokens!");
        console.log("Token0 balance:", token0.balanceOf(recipient));
        console.log("Token1 balance:", token1.balanceOf(recipient));
    }
}
