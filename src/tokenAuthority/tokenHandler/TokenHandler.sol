// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITokenHandler } from "./ITokenHandler.sol";

/// @title TokenHandler
/// @author Bridge
/// @notice Abstract base contract for token handlers that restricts access to the token authority
/// @dev Implements access control modifier for token authority and stores the authority address
abstract contract TokenHandler is ITokenHandler {

    /// @notice The address of the token authority that can call handler functions
    address public immutable TOKEN_AUTHORITY;

    /// @notice Restricts function access to the token authority
    modifier onlyTokenAuthority() {
        require(msg.sender == TOKEN_AUTHORITY, OnlyTokenAuthority());
        _;
    }

    /// @notice Initializes the token handler with the token authority address
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) {
        TOKEN_AUTHORITY = _tokenAuthority;
    }

}
