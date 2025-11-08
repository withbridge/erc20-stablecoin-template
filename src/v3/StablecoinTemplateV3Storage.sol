// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct StablecoinTemplateV3Storage {
    mapping(address => bool) __DEPRECATED_blockedList;
    mapping(address => bool) __DEPRECATED_mintRecipientList;
    uint256 _maxSupply;
    uint8 _decimals;
    uint64 _transferPolicyId;
    uint64 _mintRecipientPolicyId;
    bool _migrationToWrappedCompleted;
}

library StablecoinTemplateV3StorageLib {

    /// @custom:storage-location eip7201:bridge.StablecoinTemplateV3
    bytes32 constant BRIDGE_STABLECOIN_TEMPLATE_V3_SLOT =
        0x2d699f1ca8e44cb022a552a94873e088a70e90e635268d6acfefb642c4cd3400;

    /// @custom:storage-location eip7201:bridge.TemporaryUnblock
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
