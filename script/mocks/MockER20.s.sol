// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract MockToken is MockERC20 {
    constructor(
        string memory _name,
        string memory _symbol
    ) MockERC20(_name, _symbol, 18) {}
}

contract MockTokenScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        MockToken tokenA = new MockToken("MockTokenA", "MOCKA");
        MockToken tokenB = new MockToken("MockTokenB", "MOCKB");

        // Mint tokens to deployer for testing
        address deployer;
        try vm.envUint("PRIVATE_KEY11") returns (uint256 pk) {
            deployer = vm.addr(pk);
        } catch {
            deployer = msg.sender;
        }
        tokenA.mint(deployer, 1000000e18);
        tokenB.mint(deployer, 1000000e18);

        console.log("MockTokenA deployed at:", address(tokenA));
        console.log("MockTokenB deployed at:", address(tokenB));
        console.log("Deployer address:", deployer);
        console.log("Update Config.sol with these addresses!");

        vm.stopBroadcast();
    }
}
