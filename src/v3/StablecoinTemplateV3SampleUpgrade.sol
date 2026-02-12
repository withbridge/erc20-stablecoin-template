// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StablecoinTemplateV3 } from "./StablecoinTemplateV3.sol";

/// @title StablecoinTemplateV3SampleUpgrade
/// @author Bridge
/// @notice Sample upgrade contract demonstrating how to upgrade the StablecoinTemplateV3 contract
/// @dev Example implementation showing EIP712 name changes during upgrades
contract StablecoinTemplateV3SampleUpgrade is StablecoinTemplateV3 {

    constructor(address _reserveLedgerAddress, address _authRegistry)
        StablecoinTemplateV3(_reserveLedgerAddress, _authRegistry)
    { }

    /**
     * @dev Retrieves the `name` of the token.
     */
    function name() public view virtual override returns (string memory) {
        return "StablecoinTemplateV3 Sample Upgrade";
    }

    /**
     * @dev Retrieves the `name` for EIP712 domain which is used by the Permit.
     */
    function _EIP712Name() internal view virtual override returns (string memory) {
        return "StablecoinTemplateV3 Sample Upgrade";
    }

}
