// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ISeizeHandler
/// @author Bridge
/// @notice Interface for the contracts that move coins during a TokenAuthority seize
/// @dev The seize counterpart of {ITokenHandler}. A token handler issues and redeems a stablecoin;
/// a seize handler only moves a frozen holder's coins, using the functions that stablecoin already
/// exposes. Seize handlers are separate from token handlers so that adding seize does not replace
/// the deployed token handlers, which own the reserve stores of backed stablecoins. Seize never
/// touches reserve ledger tokens, so a seize handler holds only its Seizure Wallet list and can be
/// swapped freely.
/// @dev The TokenAuthority only checks SEIZER_ROLE and routes, like `mint`. The handler enforces
/// every rule a seize must satisfy (listed destination, frozen holder, amount bounds, the
/// destination receiving exactly `amount`) and raises the shared {ISeize} errors.
interface ISeizeHandler is IERC165 {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the caller is not the configured TokenAuthority
    error OnlyTokenAuthority();

    /// @notice Thrown when the address is the zero address
    error ZeroAddress();

    /// @notice Thrown when the caller does not hold the TokenAuthority's DEFAULT_ADMIN_ROLE
    error OnlyTokenAuthorityAdmin();

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when coins are moved out of a frozen holder
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param from The frozen holder
    /// @param to The Seizure Wallet
    /// @param amount The amount moved
    event Seized(
        address indexed stablecoinContract, address indexed from, address indexed to, uint256 amount
    );

    /// @notice Emitted when this handler's Seizure Wallet list is set or cleared
    /// @param sender The TokenAuthority admin that set the list
    /// @param policyId The new Seizure Wallet policy ID; 0 disables seize for this handler's coins
    event SeizureWalletPolicyIdSet(address indexed sender, uint64 policyId);

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The only address permitted to call this handler
     * @dev Implementations revert with {OnlyTokenAuthority} for any other caller
     */
    function TOKEN_AUTHORITY() external view returns (address);

    /**
     * @notice The AuthRegistry policy listing the approved Seizure Wallets for the stablecoins this
     * handler serves; 0 when seize is disabled for them
     */
    function seizureWalletPolicyId() external view returns (uint64);

    /**
     * @notice Sets or clears this handler's Seizure Wallet list
     * @dev Only callable by an account holding the TokenAuthority's DEFAULT_ADMIN_ROLE, so the
     * handler needs no admin of its own. Pass 0 to disable seize. The list is validated on every
     * seize ({seize}), not here.
     * @param policyId The Seizure Wallet policy ID
     */
    function setSeizureWalletPolicyId(uint64 policyId) external;

    /**
     * @notice Moves `amount` of a frozen holder's coins to an approved Seizure Wallet
     * @dev Called only by the TokenAuthority, after it has checked SEIZER_ROLE. Checks every rule
     * itself, then asserts `to` received exactly `amount`. Reverts with the {ISeize} errors.
     * @param stablecoinContract The address of the stablecoin contract
     * @param from The frozen holder
     * @param to The Seizure Wallet
     * @param amount The amount to move
     */
    function seize(address stablecoinContract, address from, address to, uint256 amount) external;

}
