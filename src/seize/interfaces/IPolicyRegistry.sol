// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPolicyRegistry
/// @author Bridge
/// @notice The one function seize needs from a list registry
/// @dev Implemented by the AuthRegistry, Base's PolicyRegistry, and Tempo's TIP-403 registry
/// precompile. Seize deliberately depends on nothing else so the same code serves all three.
interface IPolicyRegistry {

    /// @notice Whether `user` is authorized under `policyId`
    function isAuthorized(uint64 policyId, address user) external view returns (bool);

}
