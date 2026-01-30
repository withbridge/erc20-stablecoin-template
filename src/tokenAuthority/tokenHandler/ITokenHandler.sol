// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenHandler
/// @author Bridge
/// @notice Interface for token handlers that manage minting, burning, wrapping, and unwrapping of
/// tokens
/// @dev Token handlers are called by TokenAuthority to execute token operations
interface ITokenHandler {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the caller is not the token authority
    error OnlyTokenAuthority();

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when tokens are minted
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param to The address receiving the minted tokens
    /// @param amount The amount of tokens minted
    event Minted(address indexed stablecoinContract, address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param amount The amount of tokens burned
    event Burned(address indexed stablecoinContract, uint256 amount);

    /// @notice Emitted when reserve ledger tokens are wrapped into stablecoins
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param to The address receiving the wrapped tokens
    /// @param amount The amount of tokens wrapped
    event Wrapped(address indexed stablecoinContract, address indexed to, uint256 amount);

    /// @notice Emitted when stablecoins are unwrapped into reserve ledger tokens
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param to The address receiving the unwrapped tokens
    /// @param amount The amount of tokens unwrapped
    event Unwrapped(address indexed stablecoinContract, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints tokens to a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to mint the tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address stablecoinContract, address to, uint256 amount) external;

    /**
     * @notice Burns tokens from a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     */
    function burn(address stablecoinContract, uint256 amount) external;

    /**
     * @notice Wraps reserve ledger tokens into stablecoins
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the wrapped stablecoins
     * @param amount The amount of tokens to wrap
     */
    function wrap(address stablecoinContract, address to, uint256 amount) external;

    /**
     * @notice Unwraps stablecoins into reserve ledger tokens
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the unwrapped reserve ledger tokens
     * @param amount The amount of tokens to unwrap
     */
    function unwrap(address stablecoinContract, address to, uint256 amount) external;

}
