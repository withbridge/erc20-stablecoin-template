// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IForceTransferStablecoin } from "../../seize/interfaces/IForceTransferStablecoin.sol";
import { SeizeHandler } from "./SeizeHandler.sol";

/// @title ForceTransferSeizeHandler
/// @author Bridge
/// @notice Seize handler for stablecoins that hold their own reserve backing
/// (StablecoinTemplateV3, issued through the ReserveLedgerWrappedHandler)
/// @dev Moves coins with the stablecoin's `forceTransfer`, so the reserve ledger tokens backing
/// them never leave the coin. Burning and re-minting such a coin would release that backing
/// instead.
/// Needs the stablecoin's FORCE_TRANSFER_ROLE.
contract ForceTransferSeizeHandler is SeizeHandler {

    /// @notice Initializes the seize handler
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) SeizeHandler(_tokenAuthority) { }

    /// @notice Moves `amount` from frozen `from` to `to` with the stablecoin's force transfer
    /// @dev The stablecoin bypasses its own pause and freeze for this one move, so no pause
    /// handling is needed here
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param from The frozen holder
    /// @param to The Seizure Wallet
    /// @param amount The amount to move
    function seize(address stablecoinContract, address from, address to, uint256 amount, uint256)
        external
        onlyTokenAuthority
    {
        IForceTransferStablecoin(stablecoinContract).forceTransfer(from, to, amount);
        emit Seized(stablecoinContract, from, to, amount);
    }

}
