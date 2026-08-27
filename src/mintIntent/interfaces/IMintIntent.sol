// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

import { Approval } from "../MintIntentStorage.sol";
import { IMintIntentErrors } from "./IMintIntentErrors.sol";
import { IMintIntentRegistry } from "./IMintIntentRegistry.sol";

/// @title IMintIntent
/// @author Bridge
/// @notice Interface for publishing, revoking, consuming, and extending mint intents on a
/// controller.
/// @dev Intents are identified by both an operation ID and a hold ID.
/// @dev Implementations hold no intent state. Every function forwards to the shared
/// {IMintIntentRegistry} so that operation IDs and hold IDs are single-use across all controller
/// deployments rather than once per controller. Events are emitted here, by the controller, so the
/// recorded actor is the original caller.
interface IMintIntent is IMintIntentErrors {

    /*//////////////////////////////////////////////////////////////////////////
                                    Structs
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Identifying and validating fields of a mint intent.
    /// @dev Supplied on publish, then supplied again on consume where every field must match.
    /// @param operationId The globally single-use operation ID.
    /// @param holdId The hold ID that reserves the operation ID.
    /// @param amount The amount of tokens approved for minting.
    /// @param recipient The only address that may receive the minted tokens.
    /// @param stablecoin The stablecoin approved for minting.
    struct ApprovalParams {
        uint256 operationId;
        bytes32 holdId;
        uint256 amount;
        address recipient;
        address stablecoin;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a mint approval is published.
    /// @param _publisher The address that published the intent.
    /// @param _operationId The operation ID associated with the intent.
    /// @param _holdId The hold ID associated with the intent.
    /// @param _stablecoin The stablecoin contract approved for minting.
    /// @param _recipient The address approved to receive the minted tokens.
    /// @param _amount The amount of tokens approved for minting.
    /// @param _expiry The timestamp when the intent expires.
    event ApprovalPublished(
        address indexed _publisher,
        uint256 indexed _operationId,
        bytes32 indexed _holdId,
        address _stablecoin,
        address _recipient,
        uint256 _amount,
        uint256 _expiry
    );

    /// @notice Emitted when a mint approval is revoked.
    /// @param _publisher The address that revoked the approval.
    /// @param _holdId The hold ID associated with the approval.
    /// @param _operationId The operation ID associated with the approval.
    event ApprovalRevoked(
        address indexed _publisher, bytes32 indexed _holdId, uint256 indexed _operationId
    );

    /// @notice Emitted when a mint approval is consumed.
    /// @param _publisher The address that consumed the approval.
    /// @param _operationId The operation ID associated with the approval.
    /// @param _holdId The hold ID associated with the approval.
    event ApprovalConsumed(
        address indexed _publisher, uint256 indexed _operationId, bytes32 indexed _holdId
    );

    /// @notice Emitted when a mint approval's expiry is extended.
    /// @param _publisher The address that extended the approval.
    /// @param _holdId The hold ID associated with the approval.
    /// @param _operationId The operation ID associated with the approval.
    /// @param _newExpiry The updated approval expiry timestamp.
    event ApprovalExtended(
        address indexed _publisher,
        bytes32 indexed _holdId,
        uint256 indexed _operationId,
        uint256 _newExpiry
    );

    /// @notice Emitted when an operation ID is revoked.
    /// @param _publisher The address that revoked the operation ID.
    /// @param _operationId The revoked operation ID.
    /// @param _holdId Optional hold ID associated with the approval, bytes32(0) if not applicable.
    event OperationIdRevoked(
        address indexed _publisher, uint256 indexed _operationId, bytes32 indexed _holdId
    );

    /// @notice Emitted when the shared mint intent registry is changed.
    /// @param _admin The address that set the registry.
    /// @param _oldRegistry The previous registry.
    /// @param _newRegistry The new registry.
    event MintIntentRegistrySet(
        address indexed _admin, address indexed _oldRegistry, address indexed _newRegistry
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The role required to publish, revoke, and extend mint intents on this controller.
    /// @dev Distinct from the registry's CONTROLLER_ROLE, which the controller itself must hold.
    function PUBLISHER_ROLE() external view returns (bytes32);

    /**
     * @notice Publishes a mint approval.
     * @param _params The parameters for publishing the approval.
     * @custom:param _params.operationId The operation ID to associate with the intent.
     * @custom:param _params.holdId The hold ID to associate with the intent.
     * @custom:param _params.stablecoin The stablecoin contract approved for minting.
     * @custom:param _params.recipient The address approved to receive the minted tokens.
     * @custom:param _params.amount The amount of tokens approved for minting.
     * @custom:param _expiry The timestamp when the intent expires.
     */
    function publishApproval(ApprovalParams calldata _params, uint64 _expiry) external;

    /**
     * @notice Revokes an existing mint approval.
     * @param _holdId The hold ID associated with the approval.
     */
    function revokeApproval(bytes32 _holdId) external;

    /**
     * @notice Revokes an operation ID.
     * @dev Can revoke either an unused operation ID or an active approval's operation ID.
     * @param _operationId The operation ID to revoke.
     */
    function revokeOperationId(uint256 _operationId) external;

    /**
     * @notice Extends the expiry of an existing mint approval.
     * @param _holdId The hold ID associated with the approval.
     * @param _newExpiry The updated approval expiry timestamp.
     */
    function extendApproval(bytes32 _holdId, uint64 _newExpiry) external;

    /**
     * @notice Retrieves the mint approval for a given hold ID.
     * @param _holdId The hold ID associated with the approval.
     * @return The mint approval.
     */
    function getApproval(bytes32 _holdId) external view returns (Approval memory);

    /**
     * @notice Points this controller at a different shared mint intent registry.
     * @dev Intended for migrating to a new registry deployment. Two operational caveats:
     *      1. Intents published in the old registry are not carried over. Their operation IDs
     *         become unused in the new registry and can be published again, so drain or revoke
     *         in-flight intents before migrating.
     *      2. This controller must be granted CONTROLLER_ROLE on the new registry, which this
     *         function enforces, otherwise every intent operation would revert.
     * @param _registry The new shared mint intent registry.
     */
    function setMintIntentRegistry(address _registry) external;

    /**
     * @notice The shared registry that owns all mint intent state.
     * @dev Shared across controller deployments so operation IDs are single-use globally.
     */
    function mintIntentRegistry() external view returns (IMintIntentRegistry);

}
