// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Bit positions for the lifecycle flags on an {Approval}.
/// @dev Used as shift amounts against `Approval.flags`, not as values.
enum ApprovalFlag {
    /// @dev The approval has been consumed by a mint.
    CONSUMED,
    /// @dev The approval has been revoked by a publisher.
    REVOKED
}

/// @notice Lifecycle of an operation ID within the shared registry.
/// @dev An operation ID leaves `UNUSED` exactly once. `CONSUMED` and `REVOKED` are terminal, which
/// is what makes an operation ID single-use across every controller that shares the registry.
enum OperationState {
    /// @dev Never seen. Available to publish or to consume directly via a burn.
    UNUSED,
    /// @dev Reserved by a published approval, awaiting consumption.
    RESERVED,
    /// @dev Spent, by either a mint against an approval or a burn. Terminal.
    CONSUMED,
    /// @dev Cancelled by a publisher and permanently unusable. Terminal.
    REVOKED
}

/// @notice A published authorization to mint a specific amount to a specific recipient.
/// @param amount The amount of tokens approved for minting.
/// @param recipient The only address that may receive the minted tokens.
/// @param stablecoin The stablecoin approved for minting. Non-zero indicates the approval exists.
/// @param expiry Timestamp after which the approval can no longer be consumed.
/// @param flags Bitmap of {ApprovalFlag}; `DEFAULT_FLAGS` (0) means neither consumed nor revoked.
/// @param operationId The operation ID this approval reserves.
/// @param controller The controller that published this approval, and the only one that may
/// consume, revoke, or extend it. Operation and hold IDs are unique across the whole registry, but
/// authority over an individual approval is not shared between controllers.
struct Approval {
    uint256 amount;
    address recipient;
    address stablecoin;
    uint64 expiry;
    uint8 flags;
    uint256 operationId;
    address controller;
}

/// @notice Mint intent state, owned by the shared registry.
/// @dev Held in a single ERC-7201 namespace rather than per-controller storage. See
/// {MintIntentStorageLib-MINT_APPROVAL_STORAGE_LOCATION}.
/// @param _operationHoldId Operation ID to the hold ID that reserved it.
/// @param _holdIdApproval Hold ID to its published approval.
/// @param _operationStates Operation ID to its lifecycle state.
struct MintIntentStorage {
    mapping(uint256 operationId => bytes32 holdId) _operationHoldId;
    mapping(bytes32 holdId => Approval approval) _holdIdApproval;
    mapping(uint256 operationId => OperationState state) _operationStates;
}

/// @title MintIntentStorageLib
/// @author Bridge
/// @notice Storage accessor and flag helpers for mint intent state.
/// @dev The storage slot is a fixed constant, so any contract using this library reads and writes
/// the same namespace within its own address space. Intent state is therefore only shared when
/// contracts delegate to one registry address — which is the point of {MintIntentRegistry}.
library MintIntentStorageLib {

    /// @notice Flag bitmap of a live approval: neither consumed nor revoked.
    uint8 constant DEFAULT_FLAGS = 0;

    /// @notice The ERC-7201 storage slot for {MintIntentStorage}.
    /// @custom:storage-location eip7201:bridge.MintIntent
    bytes32 constant MINT_APPROVAL_STORAGE_LOCATION =
        0xa44b4a5b24691b7f103f9088d37093c6ce132ff15220e58e4235459e9b76d500;

    /// @notice Returns a pointer to the mint intent storage struct.
    /// @return s The mint intent storage.
    function getStorage() internal pure returns (MintIntentStorage storage s) {
        assembly {
            s.slot := MINT_APPROVAL_STORAGE_LOCATION
        }
    }

    /// @notice Marks the approval consumed.
    /// @param approval The approval to mark.
    function setConsumed(Approval storage approval) internal {
        approval.flags |= uint8(1) << uint8(ApprovalFlag.CONSUMED);
    }

    /// @notice Marks the approval revoked.
    /// @param approval The approval to mark.
    function setRevoked(Approval storage approval) internal {
        approval.flags |= uint8(1) << uint8(ApprovalFlag.REVOKED);
    }

    /// @notice Whether the approval is still actionable.
    /// @dev Only checks the flags. Expiry is validated separately at consume time.
    /// @param approval The approval to check.
    /// @return True if neither consumed nor revoked.
    function isValid(Approval storage approval) internal view returns (bool) {
        return approval.flags == DEFAULT_FLAGS;
    }

}
