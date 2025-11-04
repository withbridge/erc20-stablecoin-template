// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC20WrapUnwrap
/// @notice Interface for ERC20 tokens that support wrapping and unwrapping functionality
/// @dev Extends the standard ERC20 interface to enable conversion between wrapped and underlying
/// tokens
interface IERC20WrapUnwrap is IERC20 {

    /// @notice Wraps underlying tokens into wrapped tokens
    /// @dev Transfers underlying tokens from the caller and mints wrapped tokens to the specified
    /// address
    /// @param to The address that will receive the wrapped tokens
    /// @param amount The amount of underlying tokens to wrap
    function wrap(address to, uint256 amount) external;

    /// @notice Unwraps a specified amount of wrapped tokens held by the caller
    /// @dev Burns the caller's wrapped token balance and transfers underlying tokens to the caller
    /// @param amount The amount of wrapped tokens to unwrap
    function unwrap(uint256 amount) external;

}
