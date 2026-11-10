// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IIdempotencyKeyErrors
/// @author Bridge
/// @notice Errors shared by the idempotency-key client ({IIdempotencyKeys}) and the shared registry
/// ({IIdempotencyKeyRegistry}).
/// @dev The registry raises these while validating, and controllers surface them unchanged when
/// forwarding. Defining them once here lets a consumer of either interface decode any revert from
/// the key flow, without duplicating declarations across the two.
interface IIdempotencyKeyErrors {

    /// @notice Thrown when `useKeys` is called with an empty array.
    /// @dev Callers that want a no-op skip `useKeys` instead of passing an empty array.
    error InvalidIdempotencyKeys();

    /// @notice Thrown when an idempotency key is the zero value.
    error InvalidIdempotencyKey();

    /// @notice Thrown when an idempotency key has already been used.
    /// @dev Also raised for a duplicate key in the same `useKeys` call, since the first visit marks
    /// it `USED`.
    /// @param key The key that is no longer free.
    error IdempotencyKeyUsed(bytes32 key);

    /// @notice Thrown when the shared idempotency-key registry address is the zero address.
    error InvalidRegistry();

    /// @notice Thrown when setting a registry on which this controller lacks CONTROLLER_ROLE.
    /// @dev Guards against a migration that would leave every key operation reverting.
    /// @param registry The registry the controller is not authorized on.
    error ControllerNotAuthorizedOnRegistry(address registry);

}
