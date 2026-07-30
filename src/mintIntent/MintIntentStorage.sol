// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum IntentFlag {
    CONSUMED,
    REVOKED
}

struct Intent {
    bytes32 mintCommitment;
    uint64 expiry;
    uint256 flags;
}

struct MintIntentStorage {
    mapping(uint256 operationId => bytes32 holdId) _operationHoldId;
    mapping(bytes32 holdId => Intent intent) _holdIdIntent;
}

library MintIntentStorageLib {

    uint256 constant DEFAULT_FLAGS = 0;

    /// @custom:storage-location eip7201:bridge.MintIntent
    bytes32 constant MINT_APPROVAL_STORAGE_LOCATION =
        0xa44b4a5b24691b7f103f9088d37093c6ce132ff15220e58e4235459e9b76d500;

    function getStorage() internal pure returns (MintIntentStorage storage s) {
        assembly {
            s.slot := MINT_APPROVAL_STORAGE_LOCATION
        }
    }

    function isConsumed(Intent storage intent) internal view returns (bool) {
        return intent.flags & (1 << uint8(IntentFlag.CONSUMED)) != 0;
    }

    function isRevoked(Intent storage intent) internal view returns (bool) {
        return intent.flags & (1 << uint8(IntentFlag.REVOKED)) != 0;
    }

    function setConsumed(Intent storage intent) internal {
        intent.flags |= 1 << uint8(IntentFlag.CONSUMED);
    }

    function setRevoked(Intent storage intent) internal {
        intent.flags |= 1 << uint8(IntentFlag.REVOKED);
    }

    function isValid(Intent storage intent) internal view returns (bool) {
        return intent.flags == DEFAULT_FLAGS;
    }

}
