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
