// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Approval, OperationState } from "../MintIntentStorage.sol";
import { IMintIntent } from "./IMintIntent.sol";
import { IMintIntentErrors } from "./IMintIntentErrors.sol";

/// @notice Interface for the shared mint intent registry.
/// @dev A single registry instance is shared by every controller deployment (e.g. TokenAuthority,
/// TIP20Controller) so that operation IDs and hold IDs are single-use across all of them rather
/// than only within one controller's own storage.
/// @dev The registry validates and mutates intent state but does not emit the {IMintIntent}
/// lifecycle events. It returns the derived identifiers so the calling controller emits them with
/// the original caller as the actor.
/// @dev Two separate guarantees, deliberately scoped differently:
/// 1. UNIQUENESS is registry-wide. An operation ID or hold ID can be used once across every
///    controller sharing the registry, so one source operation is processed exactly once.
/// 2. AUTHORITY over an individual approval is per-controller. The controller that published an
///    approval is recorded on it, and only that controller may consume, revoke, or extend it.
///    Sharing an ID namespace does not mean sharing control of each other's approvals; attempts by
///    another controller revert with {NotApprovalController}.
interface IMintIntentRegistry is IMintIntentErrors {

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the registry.
     * @param _admin The address to be granted the admin role, which controls which controllers may
     * share this registry.
     */
    function initialize(address _admin) external;

    /// @notice The role a controller must hold to publish, revoke, extend, and consume intents.
    function CONTROLLER_ROLE() external view returns (bytes32);

    /**
     * @notice Publishes a mint approval.
     * @dev Records the calling controller as the approval's owner. Reverts if the operation ID or
     * hold ID has been used by ANY controller sharing this registry.
     * @param _params The parameters for publishing the approval.
     * @param _expiry The timestamp when the intent expires.
     */
    function publishApproval(IMintIntent.ApprovalParams calldata _params, uint64 _expiry) external;

    /**
     * @notice Revokes an existing mint approval.
     * @dev Restricted to the controller that published the approval; others revert with
     * {NotApprovalController}.
     * @param _holdId The hold ID associated with the approval.
     * @return operationId The operation ID associated with the revoked approval.
     */
    function revokeApproval(bytes32 _holdId) external returns (uint256 operationId);

    /**
     * @notice Revokes an operation ID.
     * @dev Can revoke either an unused operation ID or an active approval's operation ID. When an
     * approval exists this revokes it too, so it is restricted to the publishing controller and
     * otherwise reverts with {NotApprovalController}. An operation ID with no approval has no owner
     * and may be revoked by any controller, which permanently retires it registry-wide.
     * @param _operationId The operation ID to revoke.
     * @return holdId The hold ID associated with the approval, bytes32(0) if not applicable.
     */
    function revokeOperationId(uint256 _operationId) external returns (bytes32 holdId);

    /**
     * @notice Extends the expiry of an existing mint approval.
     * @dev Restricted to the controller that published the approval; others revert with
     * {NotApprovalController}.
     * @param _holdId The hold ID associated with the approval.
     * @param _newExpiry The updated approval expiry timestamp.
     * @return operationId The operation ID associated with the extended approval.
     */
    function extendApproval(bytes32 _holdId, uint64 _newExpiry)
        external
        returns (uint256 operationId);

    /**
     * @notice Consumes a published mint approval.
     * @dev Restricted to the controller that published the approval; others revert with
     * {NotApprovalController}. A hold ID with no approval has no owner and surfaces as
     * {InvalidApprovalParams}.
     * @param _params The parameters that must match the published approval.
     */
    function consumeApproval(IMintIntent.ApprovalParams calldata _params) external;

    /**
     * @notice Consumes an operation ID that has no published approval, e.g. for a burn.
     * @dev No approval exists, so there is no owner to check. Consuming permanently retires the
     * operation ID registry-wide, for every controller.
     * @param _operationId The operation ID to consume.
     */
    function consumeUnusedOperationId(uint256 _operationId) external;

    /**
     * @notice Retrieves the mint approval for a given hold ID.
     * @param _holdId The hold ID associated with the approval.
     * @return The mint approval.
     */
    function getApproval(bytes32 _holdId) external view returns (Approval memory);

    /**
     * @notice Retrieves the hold ID associated with an operation ID.
     * @param _operationId The operation ID to look up.
     * @return holdId The associated hold ID, bytes32(0) if none.
     */
    function getOperationHoldId(uint256 _operationId) external view returns (bytes32 holdId);

    /**
     * @notice Retrieves the state of an operation ID.
     * @param _operationId The operation ID to look up.
     * @return state The operation state.
     */
    function getOperationState(uint256 _operationId) external view returns (OperationState state);

}
