// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IIdempotencyKeyRegistry } from "./interfaces/IIdempotencyKeyRegistry.sol";
import { IIdempotencyKeys } from "./interfaces/IIdempotencyKeys.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Client base that exposes idempotency-key operations on a controller and forwards them to
/// the shared {IdempotencyKeyRegistry}.
/// @dev Key state is deliberately NOT held here. Each controller proxy would otherwise keep its
/// own mapping, which makes a key single-use per controller rather than across every controller
/// deployment. All state lives in the shared registry.
/// @dev The registry validates and mutates; this base emits {IIdempotencyKeys-KeyUsed} so the actor
/// recorded is the original caller rather than the controller.
/// @dev Implementers must store the registry pointer themselves and expose it through
/// {_setIdempotencyKeyRegistry} and {_idempotencyKeyRegistry}. Declaring it here would insert a
/// slot ahead of the inheriting controller's existing variables and shift its storage layout.
abstract contract IdempotencyKeys is AccessControlEnumerableUpgradeable, IIdempotencyKeys {

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    function __IdempotencyKeys_init(address registry) internal onlyInitializing {
        require(registry != address(0), InvalidRegistry());

        _setIdempotencyKeyRegistry(IIdempotencyKeyRegistry(registry));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIdempotencyKeys
    function setIdempotencyKeyRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(registry != address(0), InvalidRegistry());

        // Reject a registry this controller is not authorized on, which would otherwise leave
        // every key operation reverting until the role were granted.
        IIdempotencyKeyRegistry newRegistry = IIdempotencyKeyRegistry(registry);
        require(
            IAccessControl(registry).hasRole(newRegistry.CONTROLLER_ROLE(), address(this)),
            ControllerNotAuthorizedOnRegistry(registry)
        );

        address oldRegistry = address(_idempotencyKeyRegistry());
        _setIdempotencyKeyRegistry(newRegistry);

        emit IdempotencyKeyRegistrySet(msg.sender, oldRegistry, registry);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Forwards to the shared registry and emits {KeyUsed} for each key.
    ///      If `isOptional` is false, empty `keys` reverts here; callers that want a no-op skip this function.
    function _useKeys(bool isOptional, bytes32[] calldata keys) internal {
        require(isOptional || keys.length > 0, InvalidIdempotencyKeys());

        _idempotencyKeyRegistry().useKeys(keys);

        for (uint256 i = 0; i < keys.length; ++i) {
            emit KeyUsed(msg.sender, keys[i]);
        }
    }

    /// @dev Persists the shared registry pointer in the implementer's own storage.
    function _setIdempotencyKeyRegistry(IIdempotencyKeyRegistry registry) internal virtual;

    /// @dev Returns the shared registry that owns all idempotency-key state.
    function _idempotencyKeyRegistry() internal view virtual returns (IIdempotencyKeyRegistry);

}
