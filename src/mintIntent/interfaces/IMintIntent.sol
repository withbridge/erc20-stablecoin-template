// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface for publishing, revoking, consuming, and extending mint intents.
/// @dev Intents are identified by both an operation ID and a hold ID.
interface IMintIntent {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an intent already exists for an operation ID.
    /// @param _operationId The operation ID that already has an intent.
    error IntentExistsForOperationId(uint256 _operationId);

    /// @notice Thrown when an intent already exists for a hold ID.
    /// @param _holdId The hold ID that already has an intent.
    error IntentExistsForHoldId(bytes32 _holdId);

    /// @notice Thrown when an intent does not exist for an operation ID.
    /// @param _operationId The operation ID without an intent.
    error IntentNotExistsForOperationId(uint256 _operationId);

    /// @notice Thrown when an intent does not exist for a hold ID.
    /// @param _holdId The hold ID without an intent.
    error IntentNotExistsForHoldId(bytes32 _holdId);

    error IntentExpired(
        uint256 _operationId, bytes32 _holdId, uint64 _expiry, uint256 _blockTimestamp
    );

    error OperationIdHoldIdMismatch(uint256 _operationId, bytes32 _holdId);

    error IntentAlreadyConsumed(bytes32 _holdId);

    error IntentInvalid(bytes32 _holdId, uint256 _flags);

    error InvalidMintCommitment(bytes32 _expectedMintCommitment, bytes32 _providedMintCommitment);

    error IntentExpiryNotExtended(bytes32 _holdId, uint64 _newExpiry, uint64 _oldExpiry);

    error InvalidHoldId();

    error InvalidExpiry();

    error IntentAlreadyRevoked(bytes32 _holdId);

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a mint intent is published.
    /// @param _publisher The address that published the intent.
    /// @param _operationId The operation ID associated with the intent.
    /// @param _holdId The hold ID associated with the intent.
    /// @param _stablecoin The stablecoin contract approved for minting.
    /// @param _recipient The address approved to receive the minted tokens.
    /// @param _amount The amount of tokens approved for minting.
    /// @param _expiry The timestamp when the intent expires.
    event IntentPublished(
        address indexed _publisher,
        uint256 indexed _operationId,
        bytes32 indexed _holdId,
        address _stablecoin,
        address _recipient,
        uint256 _amount,
        uint256 _expiry
    );

    /// @notice Emitted when a mint intent is revoked.
    /// @param _publisher The address that revoked the intent.
    /// @param _holdId The hold ID associated with the intent.
    event IntentRevoked(address indexed _publisher, bytes32 indexed _holdId);

    /// @notice Emitted when a mint intent is consumed.
    /// @param _publisher The address that consumed the intent.
    /// @param _operationId The operation ID associated with the intent.
    /// @param _holdId The hold ID associated with the intent.
    event IntentConsumed(
        address indexed _publisher, uint256 indexed _operationId, bytes32 indexed _holdId
    );

    /// @notice Emitted when a mint intent's expiry is extended.
    /// @param _publisher The address that extended the intent.
    /// @param _holdId The hold ID associated with the intent.
    /// @param _newExpiry The updated intent expiry timestamp.
    event IntentExtended(address indexed _publisher, bytes32 indexed _holdId, uint256 _newExpiry);

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Publishes a mint intent.
     * @param _operationId The operation ID to associate with the intent.
     * @param _holdId The hold ID to associate with the intent.
     * @param _stablecoin The stablecoin contract approved for minting.
     * @param _recipient The address approved to receive the minted tokens.
     * @param _amount The amount of tokens approved for minting.
     * @param _expiry The timestamp when the intent expires.
     */
    function publishIntent(
        uint256 _operationId,
        bytes32 _holdId,
        address _stablecoin,
        address _recipient,
        uint256 _amount,
        uint64 _expiry
    ) external;

    /**
     * @notice Revokes an existing mint intent.
     * @param _holdId The hold ID associated with the intent.
     */
    function revokeIntent(bytes32 _holdId) external;

    /**
     * @notice Consumes an existing mint intent.
     * @param _operationId The operation ID associated with the intent.
     * @param _holdId The hold ID associated with the intent.
     * @param _stablecoin The stablecoin contract used for the mint.
     * @param _recipient The address receiving the minted tokens.
     * @param _amount The amount of tokens minted.
     */
    function consumeIntent(
        uint256 _operationId,
        bytes32 _holdId,
        address _stablecoin,
        address _recipient,
        uint256 _amount
    ) external;

    /**
     * @notice Extends the expiry of an existing mint intent.
     * @param _holdId The hold ID associated with the intent.
     * @param _newExpiry The updated intent expiry timestamp.
     */
    function extendIntent(bytes32 _holdId, uint64 _newExpiry) external;

}
