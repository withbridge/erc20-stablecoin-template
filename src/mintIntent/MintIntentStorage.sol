// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum ApprovalFlag {
    CONSUMED,
    REVOKED
}

enum OperationState {
    UNUSED,
    RESERVED,
    CONSUMED,
    REVOKED
}

struct Approval {
    uint256 amount;
    address recipient;
    address stablecoin;
    uint64 expiry;
    uint8 flags;
    uint256 operationId;
}

struct MintIntentStorage {
    mapping(uint256 operationId => bytes32 holdId) _operationHoldId;
    mapping(bytes32 holdId => Approval approval) _holdIdApproval;
    mapping(uint256 operationId => OperationState state) _operationStates;
}

library MintIntentStorageLib {

    uint8 constant DEFAULT_FLAGS = 0;

    /// @custom:storage-location eip7201:bridge.MintIntent
    bytes32 constant MINT_APPROVAL_STORAGE_LOCATION =
        0xa44b4a5b24691b7f103f9088d37093c6ce132ff15220e58e4235459e9b76d500;

    function getStorage() internal pure returns (MintIntentStorage storage s) {
        assembly {
            s.slot := MINT_APPROVAL_STORAGE_LOCATION
        }
    }

    function isConsumed(Approval storage approval) internal view returns (bool) {
        return approval.flags & (uint8(1) << uint8(ApprovalFlag.CONSUMED)) != 0;
    }

    function isRevoked(Approval storage approval) internal view returns (bool) {
        return approval.flags & (uint8(1) << uint8(ApprovalFlag.REVOKED)) != 0;
    }

    function setConsumed(Approval storage approval) internal {
        approval.flags |= uint8(1) << uint8(ApprovalFlag.CONSUMED);
    }

    function setRevoked(Approval storage approval) internal {
        approval.flags |= uint8(1) << uint8(ApprovalFlag.REVOKED);
    }

    function isValid(Approval storage approval) internal view returns (bool) {
        return approval.flags == DEFAULT_FLAGS;
    }

}
