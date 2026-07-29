// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface for publishing, revoking, consuming, and extending mint approvals.
/// @dev Approvals are identified by both an operation ID and a hold ID.
interface IMintApproval {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an approval already exists for an operation ID.
    /// @param _operation_id The operation ID that already has an approval.
    error ApprovalExistsForOperationId(uint256 _operation_id);

    /// @notice Thrown when an approval already exists for a hold ID.
    /// @param _hold_id The hold ID that already has an approval.
    error ApprovalExistsForHoldId(bytes32 _hold_id);

    /// @notice Thrown when an approval does not exist for an operation ID.
    /// @param _operation_id The operation ID without an approval.
    error ApprovalNotExistsForOperationId(uint256 _operation_id);

    /// @notice Thrown when an approval does not exist for a hold ID.
    /// @param _hold_id The hold ID without an approval.
    error ApprovalNotExistsForHoldId(bytes32 _hold_id);

    error ApprovalExpired(
        uint256 _operation_id, bytes32 _hold_id, uint64 _expiry, uint256 _block_timestamp
    );

    error OperationIdHoldIdMismatch(uint256 _operation_id, bytes32 _hold_id);

    error ApprovalAlreadyConsumed(bytes32 _hold_id);

    error ApprovalInvalid(uint256 _operation_id, bytes32 _hold_id);

    error ApprovalExpiryNotExtended(bytes32 _hold_id, uint64 _new_expiry, uint64 _old_expiry);

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a mint approval is published.
    /// @param _publisher The address that published the approval.
    /// @param _operation_id The operation ID associated with the approval.
    /// @param _hold_id The hold ID associated with the approval.
    /// @param _stablecoin The stablecoin contract approved for minting.
    /// @param _recipient The address approved to receive the minted tokens.
    /// @param _amount The amount of tokens approved for minting.
    /// @param _expiry The timestamp when the approval expires.
    event ApprovalPublished(
        address indexed _publisher,
        uint256 indexed _operation_id,
        bytes32 indexed _hold_id,
        address _stablecoin,
        address _recipient,
        uint256 _amount,
        uint256 _expiry
    );

    /// @notice Emitted when a mint approval is revoked.
    /// @param _publisher The address that revoked the approval.
    /// @param _hold_id The hold ID associated with the approval.
    event ApprovalRevoked(address indexed _publisher, bytes32 indexed _hold_id);

    /// @notice Emitted when a mint approval is consumed.
    /// @param _publisher The address that consumed the approval.
    /// @param _operation_id The operation ID associated with the approval.
    /// @param _hold_id The hold ID associated with the approval.
    event ApprovalConsumed(
        address indexed _publisher, uint256 indexed _operation_id, bytes32 indexed _hold_id
    );

    /// @notice Emitted when a mint approval's expiry is extended.
    /// @param _publisher The address that extended the approval.
    /// @param _hold_id The hold ID associated with the approval.
    /// @param _new_expiry The updated approval expiry timestamp.
    event ApprovalExtended(
        address indexed _publisher, bytes32 indexed _hold_id, uint256 _new_expiry
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Publishes a mint approval.
     * @param _operation_id The operation ID to associate with the approval.
     * @param _hold_id The hold ID to associate with the approval.
     * @param _stablecoin The stablecoin contract approved for minting.
     * @param _recipient The address approved to receive the minted tokens.
     * @param _amount The amount of tokens approved for minting.
     * @param _expiry The timestamp when the approval expires.
     */
    function publishApproval(
        uint256 _operation_id,
        bytes32 _hold_id,
        address _stablecoin,
        address _recipient,
        uint256 _amount,
        uint64 _expiry
    ) external;

    /**
     * @notice Revokes an existing mint approval.
     * @param _hold_id The hold ID associated with the approval.
     */
    function revokeApproval(bytes32 _hold_id) external;

    /**
     * @notice Consumes an existing mint approval.
     * @param _operation_id The operation ID associated with the approval.
     * @param _hold_id The hold ID associated with the approval.
     * @param _stablecoin The stablecoin contract used for the mint.
     * @param _recipient The address receiving the minted tokens.
     * @param _amount The amount of tokens minted.
     */
    function consumeApproval(
        uint256 _operation_id,
        bytes32 _hold_id,
        address _stablecoin,
        address _recipient,
        uint256 _amount
    ) external;

    /**
     * @notice Extends the expiry of an existing mint approval.
     * @param _hold_id The hold ID associated with the approval.
     * @param _new_expiry The updated approval expiry timestamp.
     */
    function extendApproval(bytes32 _hold_id, uint64 _new_expiry) external;

}
