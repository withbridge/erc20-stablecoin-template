// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IIdempotencyKeyErrors } from "./IIdempotencyKeyErrors.sol";
import { IIdempotencyKeyRegistry } from "./IIdempotencyKeyRegistry.sol";

/// @title IIdempotencyKeys
/// @author Bridge
/// @notice Interface for using and retiring idempotency keys on a controller.
/// @dev Implementations hold no key state. Every mutating function forwards to the shared
/// {IIdempotencyKeyRegistry} so that keys are single-use across all controller deployments rather
/// than once per controller. Events are emitted here, by the controller, so the recorded actor is
/// the original caller.
interface IIdempotencyKeys is IIdempotencyKeyErrors {

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an idempotency key is marked used.
    /// @param caller The address that used the key.
    /// @param key The key that was marked used.
    event KeyUsed(address indexed caller, bytes32 indexed key);

    /// @notice Emitted when the shared idempotency-key registry is changed.
    /// @param admin The address that set the registry.
    /// @param oldRegistry The previous registry.
    /// @param newRegistry The new registry.
    event IdempotencyKeyRegistrySet(
        address indexed admin, address indexed oldRegistry, address indexed newRegistry
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Points this controller at a different shared idempotency-key registry.
     * @dev Intended for migrating to a new registry deployment. Two operational caveats:
     *      1. Keys used in the old registry are not carried over. They become free in the new
     *         registry and can be used again, so drain in-flight keys before migrating.
     *      2. This controller must be granted CONTROLLER_ROLE on the new registry, which this
     *         function enforces, otherwise every key operation would revert.
     * @param registry The new shared idempotency-key registry.
     */
    function setIdempotencyKeyRegistry(address registry) external;

    /**
     * @notice The shared registry that owns all idempotency-key state.
     * @dev Shared across controller deployments so keys are single-use globally.
     */
    function idempotencyKeyRegistry() external view returns (IIdempotencyKeyRegistry);

}
