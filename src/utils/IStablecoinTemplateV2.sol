// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IStablecoinTemplateV2
/// @author Bridge
/// @notice Interface for the live StablecoinTemplateV2 coins
/// @dev Mirrors `withbridge/stablecoin-template` `contracts/v2/StablecoinTemplateV2.sol` at
/// `8cf3a4049cd61e85c42c1d9165ef596c025353d5`, which is not upgraded by this repo. That contract
/// inherits ERC20, ERC20Permit, Pausable, Ownable and AccessControl (OpenZeppelin v4); their
/// external functions keep the same ABI in v5, so the OpenZeppelin interfaces cover them here.
/// The initializer and the UUPS upgrade functions are left out: nothing in this repo deploys or
/// upgrades a V2 coin.
interface IStablecoinTemplateV2 is IERC20Metadata, IERC20Permit, IAccessControl {

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    event Minted(uint256 amount, address indexed to, address indexed sender);
    event Burned(uint256 amount, address indexed sender);
    event BurnedFromBlockedAddress(uint256 amount, address indexed account, address indexed sender);
    event IncreasedMaxSupply(uint256 value, address indexed sender);
    event DecreasedMaxSupply(uint256 value, address indexed sender);
    event BlockedAddress(address indexed account, address indexed sender);
    event UnblockedAddress(address indexed account, address indexed sender);
    event AddedMintRecipient(address indexed account, address indexed sender);
    event RemovedMintRecipient(address indexed account, address indexed sender);

    /*//////////////////////////////////////////////////////////////////////////
                                    Roles
    //////////////////////////////////////////////////////////////////////////*/

    function MINTER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function UNPAUSER_ROLE() external view returns (bytes32);
    function BLOCKER_ROLE() external view returns (bytes32);
    function UNBLOCKER_ROLE() external view returns (bytes32);
    function BLOCKED_ADDRESS_BURNER_ROLE() external view returns (bytes32);

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Mints to a mint-recipient-listed `to`, within max supply
    /// @dev Requires MINTER_ROLE
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` of the caller's own balance
    /// @dev Requires MINTER_ROLE
    function burn(uint256 amount) external;

    /// @notice Burns the entire balance of a blocked `account`, leaving it blocked
    /// @dev Requires BLOCKED_ADDRESS_BURNER_ROLE
    function burnFromBlockedAddress(address account) external;

    /// @notice Pauses transfers, mints, and burns
    /// @dev Requires PAUSER_ROLE
    function pause() external;

    /// @notice Unpauses transfers, mints, and burns
    /// @dev Requires UNPAUSER_ROLE
    function unpause() external;

    /// @notice Whether transfers, mints, and burns are paused
    function paused() external view returns (bool);

    /// @notice Blocks `account`
    /// @dev Requires BLOCKER_ROLE
    function blockAddress(address account) external;

    /// @notice Unblocks `account`
    /// @dev Requires UNBLOCKER_ROLE
    function unblockAddress(address account) external;

    /// @notice Raises the max supply by `amount`
    /// @dev Requires DEFAULT_ADMIN_ROLE
    function increaseMaxSupply(uint256 amount) external;

    /// @notice Lowers the max supply by `amount`
    /// @dev Requires DEFAULT_ADMIN_ROLE
    function decreaseMaxSupply(uint256 amount) external;

    /// @notice Allows `account` to receive mints
    /// @dev Requires DEFAULT_ADMIN_ROLE
    function addMintRecipient(address account) external;

    /// @notice Stops `account` from receiving mints
    /// @dev Requires DEFAULT_ADMIN_ROLE
    function removeMintRecipient(address account) external;

    /// @notice Whether `account` is blocked
    function isBlocked(address account) external view returns (bool);

    /// @notice The max supply
    function getMaxSupply() external view returns (uint256);

    /// @notice The owner, set alongside DEFAULT_ADMIN_ROLE
    function owner() external view returns (address);

    /// @notice Transfers ownership to `newOwner`
    /// @dev Requires the caller to be the owner
    function transferOwnership(address newOwner) external;

    /// @notice Leaves the contract without an owner
    /// @dev Requires the caller to be the owner
    function renounceOwnership() external;

}
