// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IIdempotencyKeyErrors } from "./IIdempotencyKeyErrors.sol";
import { IIdempotencyKeyRegistry } from "./IIdempotencyKeyRegistry.sol";

/// @title IIdempotencyKeys
/// @author Bridge
/// @notice Interface for using and retiring idempotency keys on a controller.
/// @dev Controllers store their registry pointer locally; key state lives in the shared
/// {IIdempotencyKeyRegistry}. Key consumption is forwarded to that registry, making keys
/// single-use across controllers that share it. Controllers emit events with the original caller
/// as the recorded actor.
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
     * @dev WARNING: This function does not migrate used-key state. Before switching registries,
     *      prevent key-consuming operations, migrate all previously used keys, and coordinate
     *      the cutover across every controller sharing the registry. Draining in-flight requests
     *      alone does not prevent replay of historical keys. Upgrading the existing registry
     *      proxy preserves its key state without changing the registry address.
     * @dev This controller must be granted CONTROLLER_ROLE on the new registry, which this
     *      function enforces, otherwise every key operation would revert.
     * @param registry The new shared idempotency-key registry.
     */
    function setIdempotencyKeyRegistry(address registry) external;

    /**
     * @notice The shared registry that owns all idempotency-key state.
     * @dev Shared across controller deployments so keys are single-use globally.
     */
    function idempotencyKeyRegistry() external view returns (IIdempotencyKeyRegistry);

}
