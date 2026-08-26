// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITokenHandler } from "./ITokenHandler.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC165, IERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @title TokenHandler
/// @author Bridge
/// @notice Abstract base contract for token handlers that restricts access to the token authority
/// @dev Implements access control modifier for token authority and stores the authority address
abstract contract TokenHandler is ITokenHandler, ERC165 {

    /// @notice The address of the token authority that can call handler functions
    address public immutable TOKEN_AUTHORITY;

    /// @notice Restricts function access to the token authority
    modifier onlyTokenAuthority() {
        require(msg.sender == TOKEN_AUTHORITY, OnlyTokenAuthority());
        _;
    }

    /// @notice Ensures that precision is equal
    modifier requireEqualPrecision(address _reserveLedger, address _stablecoin) {
        uint256 reserveLedgerPrecision = IERC20Metadata(_reserveLedger).decimals();
        uint256 stablecoinPrecision = IERC20Metadata(_stablecoin).decimals();
        require(
            reserveLedgerPrecision == stablecoinPrecision,
            PrecisionMismatch(reserveLedgerPrecision, stablecoinPrecision)
        );
        _;
    }

    /// @notice Initializes the token handler with the token authority address
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) {
        require(_tokenAuthority != address(0), ZeroAddress());
        TOKEN_AUTHORITY = _tokenAuthority;
    }

    /// @notice Returns true if the contract implements the given interface
    /// @param interfaceId The interface identifier to check
    /// @return True if the contract implements the interface, false otherwise
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(ITokenHandler).interfaceId
            || super.supportsInterface(interfaceId);
    }

}
