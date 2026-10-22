// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Version } from "../Version.sol";
import { IdempotencyKeyStorageLib } from "./IdempotencyKeyStorage.sol";
import { IIdempotencyKeyRegistry } from "./interfaces/IIdempotencyKeyRegistry.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title IdempotencyKeyRegistry
/// @author Bridge
/// @notice Shared registry that owns idempotency-key state for every controller deployment.
/// @dev Keys are only single-use within the storage that tracks them. When each controller keeps
/// its own mapping, the same key can be used once per controller. Pointing every controller at one
/// registry instance makes those keys single-use across all of them.
/// @dev Controllers are granted {CONTROLLER_ROLE} and must authorize their own callers as part of
/// the same atomic operation. Key consumption may precede authorization checks; a failed check
/// reverts the operation and rolls back key consumption.
/// @dev Any controller with {CONTROLLER_ROLE} may use a still-free key. Uniqueness is
/// registry-wide; authority over an individual key is not recorded.
contract IdempotencyKeyRegistry is
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    IIdempotencyKeyRegistry,
    Version
{

    /*//////////////////////////////////////////////////////////////////////////
                                    Role Constants
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Role held by each controller that shares this registry.
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Constructor
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructs the IdempotencyKeyRegistry contract
     * @param disableInitializer Whether to disable the initializer (for proxy pattern)
     */
    constructor(bool disableInitializer) {
        if (disableInitializer) {
            _disableInitializers();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the IdempotencyKeyRegistry contract
     * @param admin The address to be granted the admin role
     */
    function initialize(address admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIdempotencyKeyRegistry
    function useKeys(bytes32[] calldata keys) external onlyRole(CONTROLLER_ROLE) {
        require(keys.length > 0, InvalidIdempotencyKeys());

        for (uint256 i = 0; i < keys.length; ++i) {
            bytes32 key = keys[i];
            require(key != bytes32(0), InvalidIdempotencyKey());
            require(IdempotencyKeyStorageLib.isFree(key), IdempotencyKeyUsed(key));
            IdempotencyKeyStorageLib.setUsed(key);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                View Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIdempotencyKeyRegistry
    function isFree(bytes32 key) external view returns (bool) {
        return IdempotencyKeyStorageLib.isFree(key);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Upgrade Logic
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by admin role, required by UUPS pattern
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    { }

}
