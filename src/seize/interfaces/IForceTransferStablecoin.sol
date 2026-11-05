// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISeizableStablecoin } from "./ISeizableStablecoin.sol";

/// @title IForceTransferStablecoin
/// @author Bridge
/// @notice A stablecoin that can move coins out of a frozen holder (StablecoinTemplateV3)
interface IForceTransferStablecoin is ISeizableStablecoin {

    /// @notice Moves `amount` from frozen `from` to `to`, past the freeze and pause checks
    function forceTransfer(address from, address to, uint256 amount) external;

}
