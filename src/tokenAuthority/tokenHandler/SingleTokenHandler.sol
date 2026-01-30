// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Mintable } from "../../utils/IERC20Mintable.sol";
import { TokenHandler } from "./TokenHandler.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SingleTokenHandler
/// @notice A token handler for simple tokens that only supports minting and burning (no wrapping)
contract SingleTokenHandler is TokenHandler {

    using SafeERC20 for IERC20Mintable;

    /// @notice Thrown when wrap or unwrap is called, as these operations are not supported
    error NotSupported();

    /// @notice Initializes the single token handler
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) TokenHandler(_tokenAuthority) { }

    /// @notice Mints tokens directly to the specified address
    /// @param stablecoinContract The address of the token contract to mint from
    /// @param to The address to receive the minted tokens
    /// @param amount The amount of tokens to mint
    function mint(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        IERC20Mintable(stablecoinContract).mint(to, amount);
        emit Minted(stablecoinContract, to, amount);
    }

    /// @notice Burns tokens from the caller
    /// @param stablecoinContract The address of the token contract to burn from
    /// @param amount The amount of tokens to burn
    function burn(address stablecoinContract, uint256 amount) external onlyTokenAuthority {
        IERC20Mintable(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).burn(amount);
        emit Burned(stablecoinContract, amount);
    }

    /// @notice Not supported for single token handler
    /// @dev Always reverts with NotSupported error
    function wrap(address, address, uint256) external view onlyTokenAuthority {
        revert NotSupported();
    }

    /// @notice Not supported for single token handler
    /// @dev Always reverts with NotSupported error
    function unwrap(address, address, uint256) external view onlyTokenAuthority {
        revert NotSupported();
    }

}
