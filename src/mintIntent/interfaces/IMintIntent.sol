// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

import { Approval } from "../MintIntentStorage.sol";

/// @notice Interface for publishing, revoking, consuming, and extending mint intents.
/// @dev Intents are identified by both an operation ID and a hold ID.
interface IMintIntent {

    struct ApprovalParams {
        uint256 operationId;
        bytes32 holdId;
        uint256 amount;
        address recipient;
        address stablecoin;
    }

    struct InvalidApprovalError {
        bool invalidHoldId;
        bool invalidOperationId;
        bool invalidAmount;
        bool invalidRecipient;
        bool stablecoinIsWrong;
        bool invalidExpiry;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an approval already exists for an operation ID.
    /// @param _operationId The operation ID that already has an approval.
    error ApprovalExistsForOperationId(uint256 _operationId);

    /// @notice Thrown when an approval already exists for a hold ID.
    /// @param _holdId The hold ID that already has an approval.
    error ApprovalExistsForHoldId(bytes32 _holdId);

    /// @notice Thrown when an approval does not exist for a hold ID.
    /// @param _holdId The hold ID without an approval.
    error ApprovalNotExistsForHoldId(bytes32 _holdId);

    error ApprovalExpired(
        uint256 _operationId, bytes32 _holdId, uint64 _expiry, uint256 _blockTimestamp
    );

    error InvalidApproval(bytes32 _holdId, uint256 _flags);

    error ApprovalExpiryNotExtended(bytes32 _holdId, uint64 _newExpiry, uint64 _oldExpiry);

    error InvalidHoldId();

    error InvalidExpiry();

    error InvalidOperationId();

    error InvalidAmount();

    error InvalidRecipient();

    error InvalidStablecoin();

    error InvalidApprovalParams(InvalidApprovalError _error);

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

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

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

}
