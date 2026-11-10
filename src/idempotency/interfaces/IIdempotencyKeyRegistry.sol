// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IIdempotencyKeyErrors } from "./IIdempotencyKeyErrors.sol";

/// @title IIdempotencyKeyRegistry
/// @author Bridge
/// @notice Interface for the shared idempotency-key registry.
/// @dev A single registry instance is shared by every controller deployment (e.g. TokenAuthority,
/// TIP20Controller) so that keys are single-use across all of them rather than only within one
/// controller's own storage.
/// @dev The registry validates and mutates key state but does not emit the {IIdempotencyKeys}
/// lifecycle events. The calling controller emits {IIdempotencyKeys-KeyUsed} with the original
/// caller as the actor.
/// @dev Keys in one `useKeys` call are not bound to each other beyond atomicity. The caller
/// supplies every identifier that must be retired together.
interface IIdempotencyKeyRegistry is IIdempotencyKeyErrors {

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the registry.
     * @param admin The address to be granted the admin role, which controls which controllers may
     * share this registry.
     */
    function initialize(address admin) external;

    /// @notice The role a controller must hold to use keys.
    function CONTROLLER_ROLE() external view returns (bytes32);

    /**
     * @notice Marks every key in `keys` used.
     * @dev Each key must be nonzero and {IdempotencyKeyState-FREE}. Duplicates in the same array
     * fail on the second visit. Empty `keys` reverts with {InvalidIdempotencyKeys}.
     * @param keys The keys to mark used.
     */
    function useKeys(bytes32[] calldata keys) external;

    /**
     * @notice Whether the key has never been used.
     * @param key The key to check.
     * @return True if the key is still {IdempotencyKeyState-FREE}.
     */
    function isFree(bytes32 key) external view returns (bool);

}
