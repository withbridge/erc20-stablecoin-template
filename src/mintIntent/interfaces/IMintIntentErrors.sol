// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMintIntentErrors
/// @author Bridge
/// @notice Errors shared by the mint intent client ({IMintIntent}) and the shared registry
/// ({IMintIntentRegistry}).
/// @dev The registry raises these while validating, and controllers surface them unchanged when
/// forwarding. Defining them once here lets a consumer of either interface decode any revert from
/// the intent flow, without duplicating declarations across the two.
interface IMintIntentErrors {

    /// @notice Thrown when an approval already exists for an operation ID.
    /// @dev Also raised when the operation ID was already consumed or revoked, in this or any other
    /// controller sharing the registry.
    /// @param _operationId The operation ID that already has an approval.
    error ApprovalExistsForOperationId(uint256 _operationId);

    /// @notice Thrown when an approval already exists for a hold ID.
    /// @param _holdId The hold ID that already has an approval.
    error ApprovalExistsForHoldId(bytes32 _holdId);

    /// @notice Thrown when an approval does not exist for a hold ID.
    /// @param _holdId The hold ID without an approval.
    error ApprovalNotExistsForHoldId(bytes32 _holdId);

    /// @notice Thrown when an approval has already been consumed or revoked.
    /// @param _holdId The hold ID of the approval.
    /// @param _flags The approval's flag bitmap, per `ApprovalFlag`.
    error InvalidApproval(bytes32 _holdId, uint256 _flags);

    /// @notice Thrown when an extension would not move the expiry later.
    /// @param _holdId The hold ID of the approval.
    /// @param _newExpiry The requested expiry.
    /// @param _oldExpiry The current expiry.
    error ApprovalExpiryNotExtended(bytes32 _holdId, uint64 _newExpiry, uint64 _oldExpiry);

    /// @notice Thrown when the hold ID is the zero value.
    error InvalidHoldId();

    /// @notice Thrown when the expiry is not in the future.
    error InvalidExpiry();

    /// @notice Thrown when the operation ID is zero, or is not in a state that permits the action.
    error InvalidOperationId();

    /// @notice Thrown when the approval amount is zero.
    error InvalidAmount();

    /// @notice Thrown when the recipient is the zero address.
    error InvalidRecipient();

    /// @notice Thrown when the stablecoin is the zero address.
    error InvalidStablecoin();

    /// @notice Thrown when the shared mint intent registry address is the zero address.
    error InvalidRegistry();

    /// @notice Thrown when setting a registry on which this controller lacks CONTROLLER_ROLE.
    /// @dev Guards against a migration that would leave every intent operation reverting.
    /// @param _registry The registry the controller is not authorized on.
    error ControllerNotAuthorizedOnRegistry(address _registry);

    /// @notice Thrown when a controller tries to act on an approval published by another
    /// controller. @dev Operation and hold IDs are unique registry-wide, but authority over an
    /// individual
    /// approval stays with the controller that published it. Consuming, revoking, or extending is
    /// restricted to that controller.
    /// @param _holdId The hold ID of the approval.
    /// @param _controller The controller that published the approval.
    /// @param _caller The controller that attempted the action.
    error NotApprovalController(bytes32 _holdId, address _controller, address _caller);

    /// @notice Thrown when the params supplied to consume an approval do not match the approval.
    /// @dev The params are flattened rather than grouped in a struct so that block explorers and
    /// clients decode each failure individually instead of an opaque tuple.
    /// @param _invalidHoldId Whether the hold ID is invalid.
    /// @param _invalidOperationId Whether the operation ID is invalid.
    /// @param _invalidAmount Whether the amount does not match the approval.
    /// @param _invalidRecipient Whether the recipient does not match the approval.
    /// @param _stablecoinIsWrong Whether the stablecoin does not match the approval.
    /// @param _invalidExpiry Whether the approval has expired.
    error InvalidApprovalParams(
        bool _invalidHoldId,
        bool _invalidOperationId,
        bool _invalidAmount,
        bool _invalidRecipient,
        bool _stablecoinIsWrong,
        bool _invalidExpiry
    );

}
