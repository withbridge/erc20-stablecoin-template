// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPausableERC20 } from "./IPausableERC20.sol";

/// @title ISeizableStablecoin
/// @author Bridge
/// @notice The read surface seize needs from every EVM stablecoin behind a TokenAuthority
/// @dev Exposed identically by StablecoinTemplateV2 and StablecoinTemplateV3. TIP-20 has no
/// `isBlocked`; its freeze is read from the TIP-403 registry instead.
interface ISeizableStablecoin is IPausableERC20 {

    /// @notice Whether `account` is frozen on this stablecoin
    function isBlocked(address account) external view returns (bool);

}
