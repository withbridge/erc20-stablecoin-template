// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

import { Intent, MintIntentStorage, MintIntentStorageLib } from "./MintIntentStorage.sol";
import { IMintIntent } from "./interfaces/IMintIntent.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

contract MintIntent is AccessControlEnumerableUpgradeable, IMintIntent {

    using MintIntentStorageLib for MintIntentStorage;
    using MintIntentStorageLib for Intent;

    /*//////////////////////////////////////////////////////////////////////////
                                    Role Constants
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");
    bytes32 public constant CONSUMER_ROLE = keccak256("CONSUMER_ROLE");

    // Are these needed?
    // bytes32 public constant EXTENDER_ROLE = keccak256("EXTENDER_ROLE");
    // bytes32 public constant REVOKER_ROLE = keccak256("REVOKER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Constructor
    //////////////////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    function initialize(address _admin, address _publisher, address _consumer)
        external
        initializer
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PUBLISHER_ROLE, _publisher);
        _grantRole(CONSUMER_ROLE, _consumer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    function publishIntent(
        uint256 _operationId,
        bytes32 _holdId,
        address _stablecoin,
        address _recipient,
        uint256 _amount,
        uint64 _expiry
    ) external onlyRole(PUBLISHER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        // Ensure _holdId is not empty and expiry is valid
        require(_holdId != bytes32(0), InvalidHoldId());
        require(_expiry > block.timestamp, InvalidExpiry());

        // Check that the _holdId and _operationId are not already in use
        require(
            $._operationHoldId[_operationId] == bytes32(0), IntentExistsForOperationId(_operationId)
        );
        require(
            $._holdIdIntent[_holdId].mintCommitment == bytes32(0), IntentExistsForHoldId(_holdId)
        );

        bytes32 mintCommitment = keccak256(abi.encode(_stablecoin, _recipient, _amount));

        // Store operationId for the holdId and the intent for the holdId
        $._operationHoldId[_operationId] = _holdId;
        $._holdIdIntent[_holdId] = Intent({
            mintCommitment: mintCommitment,
            expiry: _expiry,
            flags: MintIntentStorageLib.DEFAULT_FLAGS
        });

        emit IntentPublished(
            msg.sender, _operationId, _holdId, _stablecoin, _recipient, _amount, _expiry
        );
    }

    // If used as a subcontract, we should probably make this internal
    function consumeIntent(
        uint256 _operationId,
        bytes32 _holdId,
        address _stablecoin,
        address _recipient,
        uint256 _amount
    ) public onlyRole(CONSUMER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        bytes32 holdId = $._operationHoldId[_operationId];

        // Check that the holdId stored is the same as the one provided
        require(holdId == _holdId, OperationIdHoldIdMismatch(_operationId, _holdId));

        Intent storage intent = $._holdIdIntent[_holdId];

        // Check that the intent exists and has not been consumed or revoked
        bytes32 storedMintCommitment = intent.mintCommitment;
        require(storedMintCommitment != bytes32(0), IntentNotExistsForHoldId(_holdId));
        require(intent.isValid(), IntentInvalid(_holdId, intent.flags));

        // Check that the intent has not expired
        require(
            intent.expiry > block.timestamp,
            IntentExpired(_operationId, _holdId, intent.expiry, block.timestamp)
        );
        bytes32 providedMintCommitment = keccak256(abi.encode(_stablecoin, _recipient, _amount));
        require(
            storedMintCommitment == providedMintCommitment,
            InvalidMintCommitment(storedMintCommitment, providedMintCommitment)
        );

        // Consume the intent
        intent.setConsumed();

        emit IntentConsumed(msg.sender, _operationId, _holdId);
    }

    function revokeIntent(bytes32 _holdId) external onlyRole(PUBLISHER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Intent storage intent = $._holdIdIntent[_holdId];

        // Check that the intent exists and has not been consumed or revoked
        require(intent.mintCommitment != bytes32(0), IntentNotExistsForHoldId(_holdId));
        require(intent.isValid(), IntentInvalid(_holdId, intent.flags));

        // Revoke the intent
        intent.setRevoked();

        emit IntentRevoked(msg.sender, _holdId);
    }

    // Do we need a version that takes in the operationId instead of the holdId?
    function extendIntent(bytes32 _holdId, uint64 _expiry) external onlyRole(PUBLISHER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Intent storage intent = $._holdIdIntent[_holdId];

        // Check that the intent exists and has not been consumed or revoked
        require(intent.mintCommitment != bytes32(0), IntentNotExistsForHoldId(_holdId));
        require(intent.isValid(), IntentInvalid(_holdId, intent.flags));

        uint64 expiry = intent.expiry;
        require(_expiry > expiry, IntentExpiryNotExtended(_holdId, _expiry, expiry));

        // Extend the intent
        intent.expiry = _expiry;

        emit IntentExtended(msg.sender, _holdId, _expiry);
    }

}
