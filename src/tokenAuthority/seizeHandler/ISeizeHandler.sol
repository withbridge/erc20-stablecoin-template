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
/// touches reserve ledger tokens, so a seize handler holds no state and can be swapped freely.
/// @dev Every rule a seize must satisfy (role, frozen holder, listed destination, amount bounds,
/// conservation) is enforced by the TokenAuthority before and after calling the handler.
interface ISeizeHandler is IERC165 {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the caller is not the configured TokenAuthority
    error OnlyTokenAuthority();

    /// @notice Thrown when the address is the zero address
    error ZeroAddress();

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

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The only address permitted to call this handler
     * @dev Implementations revert with {OnlyTokenAuthority} for any other caller
     */
    function TOKEN_AUTHORITY() external view returns (address);

    /**
     * @notice Moves `amount` of `from`'s coins to `to`
     * @dev Called by the TokenAuthority only after every seize pre-check passed
     * @param stablecoinContract The address of the stablecoin contract
     * @param from The frozen holder
     * @param to The Seizure Wallet
     * @param amount The amount to move
     * @param holderBalance `from`'s balance read before the move
     */
    function seize(
        address stablecoinContract,
        address from,
        address to,
        uint256 amount,
        uint256 holderBalance
    ) external;

}
