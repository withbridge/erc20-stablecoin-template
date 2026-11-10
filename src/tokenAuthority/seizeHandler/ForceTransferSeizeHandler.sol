// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StablecoinTemplateV3 } from "../../v3/StablecoinTemplateV3.sol";
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

    /// @inheritdoc SeizeHandler
    /// @dev The stablecoin bypasses its own pause and freeze for this one move, so no pause
    /// handling is needed here.
    function _executeSeize(
        address stablecoinContract,
        address from,
        address to,
        uint256 amount,
        uint256
    ) internal override {
        StablecoinTemplateV3(stablecoinContract).forceTransfer(from, to, amount);
    }

    /// @inheritdoc SeizeHandler
    function _isHolderBlocked(address stablecoinContract, address holder)
        internal
        view
        override
        returns (bool)
    {
        return StablecoinTemplateV3(stablecoinContract).isBlocked(holder);
    }

}
