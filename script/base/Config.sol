// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Shared configuration between scripts
contract Config {
    /// @dev Deployed mock tokens on Sepolia
    /// MockTokenA (token0): 0x2794a0b7187BFCd81D2b6d05E8a6e6cAE3F97fFa
    /// MockTokenB (token1): 0xEa20820719c5Ae04Bce9A098E209f4d8C60DAF06
    /// Tokens must be sorted: token0 address < token1 address
    IERC20 constant token0 =
        IERC20(address(0x2794a0b7187BFCd81D2b6d05E8a6e6cAE3F97fFa));
    IERC20 constant token1 =
        IERC20(address(0xEa20820719c5Ae04Bce9A098E209f4d8C60DAF06));

    /// @dev Hook contract address - Dark Pool Hook (with FHE + BEFORE_SWAP_RETURNS_DELTA)
    /// Deployed at: 0x6A755997D7B06900Fc3AFA8085A76C7182658aC8
    IHooks constant hookContract =
        IHooks(address(0x6A755997D7B06900Fc3AFA8085A76C7182658aC8));

    Currency constant currency0 = Currency.wrap(address(token0));
    Currency constant currency1 = Currency.wrap(address(token1));
}
