// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct StablecoinTemplateV3Storage {
    mapping(address => bool) _blockedList;
    mapping(address => bool) _mintRecipientList;
    uint256 _maxSupply;
    uint8 _decimals;
}

library StablecoinTemplateV3StorageLib {

    ///@custom:storage-location eip7201:bridge.StablecoinTemplateV3
    bytes32 constant BRIDGE_STABLECOIN_TEMPLATE_V3_SLOT =
        0x2d699f1ca8e44cb022a552a94873e088a70e90e635268d6acfefb642c4cd3400;

    function getStorage() internal pure returns (StablecoinTemplateV3Storage storage s) {
        bytes32 slot = BRIDGE_STABLECOIN_TEMPLATE_V3_SLOT;
        assembly {
            s.slot := slot
        }
    }

}
