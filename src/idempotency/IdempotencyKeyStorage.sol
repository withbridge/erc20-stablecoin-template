// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Lifecycle of an idempotency key.
/// @dev A key leaves `FREE` exactly once. `USED` is terminal, which is what makes an idempotency
/// key single-use.
enum IdempotencyKeyState {
    /// @dev Never seen. Available to consume.
    FREE,
    /// @dev Already consumed. Terminal.
    USED
}

/// @notice Idempotency-key state, owned by the shared registry.
/// @dev Held in a single ERC-7201 namespace rather than per-controller storage. See
/// {IdempotencyKeyStorageLib-IDEMPOTENCY_KEY_STORAGE_LOCATION}.
/// @param _idempotencyKeyStates Idempotency key to its lifecycle state.
struct IdempotencyKeyStorage {
    mapping(bytes32 idempotencyKey => IdempotencyKeyState state) _idempotencyKeyStates;
}

/// @title IdempotencyKeyStorageLib
/// @author Bridge
/// @notice Storage accessor for idempotency-key state.
/// @dev The storage slot is a fixed constant, so any contract using this library reads and writes
/// the same namespace within its own address space. Key state is therefore only shared when
/// contracts delegate to one registry address.
library IdempotencyKeyStorageLib {

    /// @notice The ERC-7201 storage slot for {IdempotencyKeyStorage}.
    /// @custom:storage-location eip7201:bridge.IdempotencyKeyStorage
    bytes32 constant IDEMPOTENCY_KEY_STORAGE_LOCATION =
        0x9fb7408bbee7b8e924cfdf4c44ebbd07a3dddb4380e17cbbcb789eabcb367a00;

    /// @notice Returns a pointer to the idempotency-key storage struct.
    /// @return s The idempotency-key storage.
    function getStorage() internal pure returns (IdempotencyKeyStorage storage s) {
        assembly {
            s.slot := IDEMPOTENCY_KEY_STORAGE_LOCATION
        }
    }

    /// @notice Marks the idempotency key as used.
    /// @param idempotencyKey The idempotency key to mark.
    function setUsed(bytes32 idempotencyKey) internal {
        IdempotencyKeyStorage storage s = getStorage();
        s._idempotencyKeyStates[idempotencyKey] = IdempotencyKeyState.USED;
    }

    /// @notice Whether the idempotency key has never been used.
    /// @param idempotencyKey The idempotency key to check.
    /// @return True if the key is still {IdempotencyKeyState-FREE}.
    function isFree(bytes32 idempotencyKey) internal view returns (bool) {
        IdempotencyKeyStorage storage s = getStorage();
        return s._idempotencyKeyStates[idempotencyKey] == IdempotencyKeyState.FREE;
    }

}
