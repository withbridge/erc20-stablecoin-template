// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITokenHandler {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the caller is not the token authority
    error OnlyTokenAuthority();

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
     * @notice Wraps tokens from a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to wrap the tokens to
     * @param amount The amount of tokens to wrap
     */
    function wrap(address stablecoinContract, address to, uint256 amount) external;

    /**
     * @notice Unwraps tokens from a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to unwrap the tokens to
     * @param amount The amount of tokens to unwrap
     */
    function unwrap(address stablecoinContract, address to, uint256 amount) external;

}
