// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

import { Approval, MintIntentStorage, MintIntentStorageLib } from "./MintIntentStorage.sol";
import { IMintIntent } from "./interfaces/IMintIntent.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

contract MintIntent is AccessControlEnumerableUpgradeable, IMintIntent {

    using MintIntentStorageLib for MintIntentStorage;
    using MintIntentStorageLib for Approval;

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

    function publishApproval(
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
            $._operationHoldId[_operationId] == bytes32(0),
            ApprovalExistsForOperationId(_operationId)
        );
        require(
            $._holdIdApproval[_holdId].mintCommitment == bytes32(0),
            ApprovalExistsForHoldId(_holdId)
        );

        bytes32 mintCommitment = keccak256(abi.encode(_stablecoin, _recipient, _amount));

        // Store operationId for the holdId and the intent for the holdId
        $._operationHoldId[_operationId] = _holdId;
        $._holdIdApproval[_holdId] = Approval({
            mintCommitment: mintCommitment,
            expiry: _expiry,
            flags: MintIntentStorageLib.DEFAULT_FLAGS
        });

        emit ApprovalPublished(
            msg.sender, _operationId, _holdId, _stablecoin, _recipient, _amount, _expiry
        );
    }

    // If used as a subcontract, we should probably make this internal
    function consumeApproval(
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

        Approval storage approval = $._holdIdApproval[_holdId];

        // Check that the approval exists and has not been consumed or revoked
        bytes32 storedMintCommitment = approval.mintCommitment;
        require(storedMintCommitment != bytes32(0), ApprovalNotExistsForHoldId(_holdId));
        require(approval.isValid(), InvalidApproval(_holdId, approval.flags));

        // Check that the approval has not expired
        require(
            approval.expiry > block.timestamp,
            ApprovalExpired(_operationId, _holdId, approval.expiry, block.timestamp)
        );
        bytes32 providedMintCommitment = keccak256(abi.encode(_stablecoin, _recipient, _amount));
        require(
            storedMintCommitment == providedMintCommitment,
            InvalidMintCommitment(storedMintCommitment, providedMintCommitment)
        );

        // Consume the approval
        approval.setConsumed();

        emit ApprovalConsumed(msg.sender, _operationId, _holdId);
    }

    function revokeApproval(bytes32 _holdId) external onlyRole(PUBLISHER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Approval storage approval = $._holdIdApproval[_holdId];

        // Check that the approval exists and has not been consumed or revoked
        require(approval.mintCommitment != bytes32(0), ApprovalNotExistsForHoldId(_holdId));
        require(approval.isValid(), InvalidApproval(_holdId, approval.flags));

        // Revoke the approval
        approval.setRevoked();

        emit ApprovalRevoked(msg.sender, _holdId);
    }

    // Do we need a version that takes in the operationId instead of the holdId?
    function extendApproval(bytes32 _holdId, uint64 _expiry) external onlyRole(PUBLISHER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Approval storage approval = $._holdIdApproval[_holdId];

        // Check that the approval exists and has not been consumed or revoked
        require(approval.mintCommitment != bytes32(0), ApprovalNotExistsForHoldId(_holdId));
        require(approval.isValid(), InvalidApproval(_holdId, approval.flags));

        uint64 expiry = approval.expiry;
        require(_expiry > expiry, ApprovalExpiryNotExtended(_holdId, _expiry, expiry));

        // Extend the approval
        approval.expiry = _expiry;

        emit ApprovalExtended(msg.sender, _holdId, _expiry);
    }

}
