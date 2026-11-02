// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISeize
/// @author Bridge
/// @notice Interface for moving a frozen holder's coins into an approved Seizure Wallet.
/// @dev Shared by every controller that can seize (`TokenAuthority`, `TIP20Controller`) so that
/// the function signature, role ID, event topic, and error selectors are identical on each. Off-
/// chain signing policies allow exactly `seize(address,address,address,uint256)`, so the
/// signature must not drift between controllers.
/// @dev A seize never changes supply or reserve backing: the coins either move between holders
/// (force transfer) or are burned and re-minted in the same amount, never through a token
/// handler or reserve-minting path.
interface ISeize {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the stablecoin has no seize settings on this controller
    error SeizeNotConfigured(address stablecoinContract);

    /// @notice Thrown when a Seizure Wallet list is unusable: the registry is the zero address, the
    /// list ID is a registry built-in (0 = always-reject, 1 = always-allow), or the list
    /// authorizes this controller itself (true of allow-all and blacklist-type lists)
    error InvalidSeizureWalletList(address registry, uint64 listId);

    /// @notice Thrown when the destination is the holder or this controller
    error InvalidSeizeDestination(address to);

    /// @notice Thrown when the destination is not on the stablecoin's Seizure Wallet list
    error DestinationNotSeizureWallet(address to);

    /// @notice Thrown when the holder is not frozen, before or after the seize
    error HolderNotBlocked(address holder);

    /// @notice Thrown when the amount is zero or above the holder's balance
    error InvalidSeizeAmount(uint256 amount, uint256 holderBalance);

    /// @notice Thrown when a seize leaves an account with an unexpected balance
    /// @dev Checked for the holder, the destination, and this controller. Should never happen.
    error SeizeBalanceMismatch(address account, uint256 expectedBalance, uint256 actualBalance);

    /// @notice Thrown when a seize changes the stablecoin's total supply. Should never happen.
    error SeizeTotalSupplyChanged(uint256 totalSupplyBefore, uint256 totalSupplyAfter);

    /// @notice Thrown when a seize leaves the stablecoin in a different pause state than it
    /// started in. Should never happen.
    error PauseStateNotRestored(bool pausedBefore);

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when coins are seized from a frozen holder
    /// @dev Reconciliation, supply monitoring, and case evidence key on this event. On the burn and
    /// re-mint path the holder's own history shows a full burn and a transfer back of the
    /// remainder; this event ties those together.
    /// @param stablecoinContract The stablecoin seized
    /// @param from The frozen holder
    /// @param to The Seizure Wallet that received the coins
    /// @param amount The amount seized
    /// @param caller The account holding SEIZER_ROLE that performed the seize
    event Seized(
        address indexed stablecoinContract,
        address indexed from,
        address indexed to,
        uint256 amount,
        address caller
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Role that may seize. Granted only to the entity's Seize Authority vault.
    function SEIZER_ROLE() external view returns (bytes32);

    /**
     * @notice Moves `amount` of a frozen holder's coins to an approved Seizure Wallet
     * @dev Requires SEIZER_ROLE, seize settings for the stablecoin, a frozen `from`, a listed `to`,
     * and `0 < amount <= balanceOf(from)`. Ignores this controller's own per-stablecoin pause,
     * which
     * halts issuance rather than compliance actions.
     * @param stablecoinContract The stablecoin to seize
     * @param from The frozen holder
     * @param to The Seizure Wallet
     * @param amount The amount to seize
     */
    function seize(address stablecoinContract, address from, address to, uint256 amount) external;

}
