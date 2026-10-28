// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IPausableERC20
/// @author Bridge
/// @notice The read surface every seize snapshots before and after moving coins
/// @dev Exposed identically by StablecoinTemplateV2, StablecoinTemplateV3, and TIP-20.
interface IPausableERC20 is IERC20 {

    /// @notice Whether transfers on this stablecoin are paused
    function paused() external view returns (bool);

}

/// @title ISeizableStablecoin
/// @author Bridge
/// @notice The read surface seize needs from every EVM stablecoin behind a TokenAuthority
/// @dev Exposed identically by StablecoinTemplateV2 and StablecoinTemplateV3. TIP-20 has no
/// `isBlocked`; its freeze is read from the TIP-403 registry instead.
interface ISeizableStablecoin is IPausableERC20 {

    /// @notice Whether `account` is frozen on this stablecoin
    function isBlocked(address account) external view returns (bool);

}

/// @title IForceTransferStablecoin
/// @author Bridge
/// @notice A stablecoin that can move coins out of a frozen holder (StablecoinTemplateV3)
interface IForceTransferStablecoin is ISeizableStablecoin {

    /// @notice The role gating `forceTransfer`; only coins upgraded with `forceTransfer` report it
    function FORCE_TRANSFER_ROLE() external view returns (bytes32);

    /// @notice Moves `amount` from frozen `from` to `to`, past the freeze and pause checks
    function forceTransfer(address from, address to, uint256 amount) external;

}

/// @title IBurnAndRemintStablecoin
/// @author Bridge
/// @notice The existing StablecoinTemplateV2 surface a burn and re-mint seize drives
/// @dev Matches `withbridge/stablecoin-template` `contracts/v2/StablecoinTemplateV2.sol`, which is
/// not upgraded. Each call needs the matching V2 role on the seizing controller.
interface IBurnAndRemintStablecoin is ISeizableStablecoin {

    /// @notice The role gating `unblockAddress`; V3 coins have no storage blocklist and no such
    /// role
    function UNBLOCKER_ROLE() external view returns (bytes32);

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

/// @title IReserveWrappedStablecoin
/// @author Bridge
/// @notice A stablecoin that holds its own reserve ledger backing (StablecoinTemplateV3)
/// @dev Burning such a coin's balance releases that backing, so it must never be burned and
/// re-minted by a seize.
interface IReserveWrappedStablecoin {

    /// @notice The reserve ledger token this stablecoin holds as backing
    function RESERVE_LEDGER_ADDRESS() external view returns (address);

}
