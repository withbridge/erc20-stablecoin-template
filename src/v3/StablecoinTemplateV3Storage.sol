// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title StablecoinTemplateV3Storage
/// @author Bridge
/// @notice Storage struct for StablecoinTemplateV3 contracts using ERC-7201 namespaced storage
/// @dev Contains template-specific persistent state
/// @custom:storage-location erc7201:bridge.StablecoinTemplateV3
struct StablecoinTemplateV3Storage {
    mapping(address => bool) __DEPRECATED_blockedList;
    mapping(address => bool) __DEPRECATED_mintRecipientList;
    uint256 _maxSupply;
    uint8 _decimals;
    uint64 _transferPolicyId;
    uint64 _mintRecipientPolicyId;
    bool _migrationToWrappedCompleted;
}

/// @title StablecoinTemplateV3StorageLib
/// @author Bridge
/// @notice Library for accessing StablecoinTemplateV3 namespaced storage
/// @dev Provides helper functions to access ERC-7201 storage slots and transient storage
library StablecoinTemplateV3StorageLib {

    /// @notice The ERC-7201 storage slot for {StablecoinTemplateV3Storage}.
    bytes32 constant BRIDGE_STABLECOIN_TEMPLATE_V3_SLOT =
        0x2d699f1ca8e44cb022a552a94873e088a70e90e635268d6acfefb642c4cd3400;

    /// @dev Fixed transient-storage slot for this token's temporary transfer-policy bypass.
    bytes32 private constant TEMPORARY_UNBLOCK_STORAGE_LOCATION =
        0xa5b639b0b8427abdcb5252638871cd5b818f821c6efce3055068666cd3e1cb00;

    function getStorage() internal pure returns (StablecoinTemplateV3Storage storage s) {
        bytes32 slot = BRIDGE_STABLECOIN_TEMPLATE_V3_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function getTemporaryUnblockStatus() internal view returns (bool) {
        bytes32 slot = TEMPORARY_UNBLOCK_STORAGE_LOCATION;
        uint256 status;
        assembly {
            status := tload(slot)
        }

        return status != 0;
    }

    function setTemporaryUnblockStatus(bool status) internal {
        bytes32 slot = TEMPORARY_UNBLOCK_STORAGE_LOCATION;
        uint256 value = status ? 1 : 0;
        assembly {
            tstore(slot, value)
        }
    }

}
