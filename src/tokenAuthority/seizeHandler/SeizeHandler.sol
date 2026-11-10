// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Version } from "../../Version.sol";
import { ISeize } from "../../seize/interfaces/ISeize.sol";
import { ReserveLedger } from "../../v3/ReserveLedger.sol";
import { ITokenAuthority } from "../ITokenAuthority.sol";
import { ISeizeHandler } from "./ISeizeHandler.sol";
import { ERC165, IERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";

/// @title SeizeHandler
/// @author Bridge
/// @notice Abstract base contract for seize handlers with TokenAuthority access control
/// @dev Mirrors {TokenHandler}: only the TokenAuthority may call, and ERC165 lets the
/// TokenAuthority reject anything that is not a seize handler when one is configured
abstract contract SeizeHandler is ISeizeHandler, ERC165, Version {

    /// @notice The address of the token authority that controls this handler
    address public immutable TOKEN_AUTHORITY;

    /// @notice The AuthRegistry holding the TokenAuthority's Seizure Wallet list
    /// @dev Read from the TokenAuthority's reserve ledger at construction, so it is always the
    /// registry that entity's lists live in. The TokenAuthority stores only the list's policy ID.
    IAuthRegistry public immutable AUTH_REGISTRY;

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
        AUTH_REGISTRY =
            ReserveLedger(ITokenAuthority(_tokenAuthority).RESERVE_LEDGER_TOKEN()).AUTH_REGISTRY();
    }

    /// @inheritdoc ISeizeHandler
    function isSeizureWallet(uint64 policyId, address account) external view returns (bool) {
        require(
            !AUTH_REGISTRY.isAuthorized(policyId, TOKEN_AUTHORITY),
            ISeize.InvalidSeizureWalletList(address(AUTH_REGISTRY), policyId)
        );

        return AUTH_REGISTRY.isAuthorized(policyId, account);
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
