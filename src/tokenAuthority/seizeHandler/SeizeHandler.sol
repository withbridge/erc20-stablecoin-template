// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISeizeHandler } from "./ISeizeHandler.sol";
import { ERC165, IERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @title SeizeHandler
/// @author Bridge
/// @notice Abstract base contract for seize handlers with TokenAuthority access control
/// @dev Mirrors {TokenHandler}: only the TokenAuthority may call, and ERC165 lets the
/// TokenAuthority reject anything that is not a seize handler when one is configured
abstract contract SeizeHandler is ISeizeHandler, ERC165 {

    /// @notice The address of the token authority that controls this handler
    address public immutable TOKEN_AUTHORITY;

    /// @notice Restricts function access to only the token authority
    modifier onlyTokenAuthority() {
        require(msg.sender == TOKEN_AUTHORITY, OnlyTokenAuthority());
        _;
    }

    /// @notice Initializes the seize handler with the token authority address
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) {
        require(_tokenAuthority != address(0), ZeroAddress());
        TOKEN_AUTHORITY = _tokenAuthority;
    }

    /// @notice Checks if the contract supports a given interface
    /// @param interfaceId The interface identifier to check
    /// @return bool True if the interface is supported
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(ISeizeHandler).interfaceId
            || super.supportsInterface(interfaceId);
    }

}
