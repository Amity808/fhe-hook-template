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

    /// @dev Hook contract address - set to deployed ConfidentialRebalancingHook on Sepolia
    /// Deployed at: 0x29917CE538f0CCbd370C9db265e721595Af14Ac0 (final with all FHE fixes)
    IHooks constant hookContract =
        IHooks(address(0x29917CE538f0CCbd370C9db265e721595Af14Ac0));

    Currency constant currency0 = Currency.wrap(address(token0));
    Currency constant currency1 = Currency.wrap(address(token1));
}
