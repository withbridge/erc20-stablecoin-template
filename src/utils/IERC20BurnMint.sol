// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC20BurnMint
/// @notice Interface for ERC20 tokens with mint and burn functionality
/// @dev Extends the standard ERC20 interface with controlled token supply management
interface IERC20BurnMint is IERC20 {

    /// @notice Burns tokens from the caller's balance
    /// @dev Reduces the total supply by destroying tokens
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    /// @notice Mints new tokens to a specified address
    /// @dev Increases the total supply by creating new tokens
    /// @param to The address that will receive the newly minted tokens
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external;

}
