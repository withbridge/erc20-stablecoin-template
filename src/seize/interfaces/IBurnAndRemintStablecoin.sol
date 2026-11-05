// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISeizableStablecoin } from "./ISeizableStablecoin.sol";

/// @title IBurnAndRemintStablecoin
/// @author Bridge
/// @notice The existing StablecoinTemplateV2 surface a burn and re-mint seize drives
/// @dev Matches `withbridge/stablecoin-template` `contracts/v2/StablecoinTemplateV2.sol`, which is
/// not upgraded. Each call needs the matching V2 role on the seize handler.
interface IBurnAndRemintStablecoin is ISeizableStablecoin {

    /// @notice Burns the entire balance of a blocked `account`, leaving it blocked
    /// @dev Requires BLOCKED_ADDRESS_BURNER_ROLE
    function burnFromBlockedAddress(address account) external;

    /// @notice Mints to a mint-recipient-listed `to`, within max supply
    /// @dev Requires MINTER_ROLE
    function mint(address to, uint256 amount) external;

    /// @notice Blocks `account`
    /// @dev Requires BLOCKER_ROLE
    function blockAddress(address account) external;

    /// @notice Unblocks `account`
    /// @dev Requires UNBLOCKER_ROLE
    function unblockAddress(address account) external;

    /// @notice Pauses transfers, mints, and burns
    /// @dev Requires PAUSER_ROLE
    function pause() external;

    /// @notice Unpauses transfers, mints, and burns
    /// @dev Requires UNPAUSER_ROLE
    function unpause() external;

}
