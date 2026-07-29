// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct Approval {
    bytes32 mintCommitment;
    uint64 expiry;
    bool consumed;
}

struct MintApprovalStorage {
    mapping(uint256 operationId => bytes32 holdId) _operationHoldId;
    mapping(bytes32 holdId => Approval approval) _holdIdApproval;
}

library MintApprovalStorageLib {

    /// @custom:storage-location eip7201:bridge.MintApproval
    bytes32 constant MINT_APPROVAL_STORAGE_LOCATION =
        0xa44b4a5b24691b7f103f9088d37093c6ce132ff15220e58e4235459e9b76d500;

    function getStorage() internal pure returns (MintApprovalStorage storage s) {
        bytes32 slot = keccak256("mintApproval.storage");
        assembly {
            s.slot := slot
        }
    }

}
