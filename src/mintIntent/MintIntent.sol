// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

import { Approval, MintIntentStorage, MintIntentStorageLib } from "./MintIntentStorage.sol";
import { IMintIntent } from "./interfaces/IMintIntent.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

abstract contract MintIntent is AccessControlEnumerableUpgradeable, IMintIntent {

    using MintIntentStorageLib for MintIntentStorage;
    using MintIntentStorageLib for Approval;

    /*//////////////////////////////////////////////////////////////////////////
                                    Role Constants
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Error Constants
    //////////////////////////////////////////////////////////////////////////*/

    uint256 constant INVALID_HOLD_ID_FLAG = 1;
    uint256 constant INVALID_OPERATION_ID_FLAG = 2;
    uint256 constant INVALID_AMOUNT_FLAG = 4;
    uint256 constant INVALID_RECIPIENT_FLAG = 8;
    uint256 constant INVALID_STABLECOIN_FLAG = 16;
    uint256 constant INVALID_EXPIRY_FLAG = 32;

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    function __MintIntent_init(address _publisher) internal onlyInitializing {
        _grantRole(PUBLISHER_ROLE, _publisher);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    function publishApproval(ApprovalParams calldata _params, uint64 _expiry)
        external
        onlyRole(PUBLISHER_ROLE)
    {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        // Validate input parameters
        require(_params.operationId != 0, InvalidOperationId());
        require(_params.holdId != bytes32(0), InvalidHoldId());
        require(_params.amount > 0, InvalidAmount());
        require(_params.stablecoin != address(0), InvalidStablecoin());
        require(_params.recipient != address(0), InvalidRecipient());
        require(_expiry > block.timestamp, InvalidExpiry());

        // Check that the _holdId and _operationId are not already in use
        require(
            $._operationHoldId[_params.operationId] == bytes32(0),
            ApprovalExistsForOperationId(_params.operationId)
        );
        require(
            $._holdIdApproval[_params.holdId].stablecoin == address(0),
            ApprovalExistsForHoldId(_params.holdId)
        );

        // Store operationId for the holdId and the intent for the holdId
        $._operationHoldId[_params.operationId] = _params.holdId;
        $._holdIdApproval[_params.holdId] = Approval({
            amount: _params.amount,
            recipient: _params.recipient,
            stablecoin: _params.stablecoin,
            expiry: _expiry,
            flags: MintIntentStorageLib.DEFAULT_FLAGS
        });

        emit ApprovalPublished(
            msg.sender,
            _params.operationId,
            _params.holdId,
            _params.stablecoin,
            _params.recipient,
            _params.amount,
            _expiry
        );
    }

    function revokeApproval(bytes32 _holdId) external onlyRole(PUBLISHER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Approval storage approval = $._holdIdApproval[_holdId];

        // Check that the approval exists and has not been consumed or revoked
        require(approval.stablecoin != address(0), ApprovalNotExistsForHoldId(_holdId));
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
        require(approval.stablecoin != address(0), ApprovalNotExistsForHoldId(_holdId));
        require(approval.isValid(), InvalidApproval(_holdId, approval.flags));

        uint64 expiry = approval.expiry;
        require(_expiry > expiry, ApprovalExpiryNotExtended(_holdId, _expiry, expiry));

        // Extend the approval
        approval.expiry = _expiry;

        emit ApprovalExtended(msg.sender, _holdId, _expiry);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                View Functions
    //////////////////////////////////////////////////////////////////////////*/

    function getApproval(bytes32 _holdId) external view returns (Approval memory) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        return $._holdIdApproval[_holdId];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    function _consumeApproval(ApprovalParams memory _params) internal {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        bytes32 holdId = $._operationHoldId[_params.operationId];
        Approval storage approval = $._holdIdApproval[_params.holdId];

        uint256 errors = 0;

        if (_params.holdId == bytes32(0)) {
            errors |= INVALID_HOLD_ID_FLAG;
        }

        if (_params.operationId == 0 || _params.holdId != holdId) {
            errors |= INVALID_OPERATION_ID_FLAG;
        }

        if (_params.amount != approval.amount) {
            errors |= INVALID_AMOUNT_FLAG;
        }

        if (_params.recipient != approval.recipient) {
            errors |= INVALID_RECIPIENT_FLAG;
        }

        if (_params.stablecoin != approval.stablecoin) {
            errors |= INVALID_STABLECOIN_FLAG;
        }

        if (approval.expiry <= block.timestamp) {
            errors |= INVALID_EXPIRY_FLAG;
        }
        require(approval.isValid(), InvalidApproval(_params.holdId, approval.flags));

        require(errors == 0, InvalidApprovalParams(_convertToInvalidApprovalError(errors)));

        // Consume the approval
        approval.setConsumed();

        emit ApprovalConsumed(msg.sender, _params.operationId, _params.holdId);
    }

    function _convertToInvalidApprovalError(uint256 _errors)
        internal
        pure
        returns (InvalidApprovalError memory err)
    {
        err.invalidHoldId = _errors & INVALID_HOLD_ID_FLAG != 0;
        err.invalidOperationId = _errors & INVALID_OPERATION_ID_FLAG != 0;
        err.invalidAmount = _errors & INVALID_AMOUNT_FLAG != 0;
        err.invalidRecipient = _errors & INVALID_RECIPIENT_FLAG != 0;
        err.stablecoinIsWrong = _errors & INVALID_STABLECOIN_FLAG != 0;
        err.invalidExpiry = _errors & INVALID_EXPIRY_FLAG != 0;
    }

}
