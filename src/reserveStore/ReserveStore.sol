// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ReserveStore
/// @author Bridge
/// @notice A minimal contract to hold reserve ledger tokens for a specific stablecoin
/// @dev Deployed per stablecoin to keep ledger token reserves separate for reconciliation purposes.
///      Pre-approves the controller to transfer tokens on its behalf.
contract ReserveStore {

    /// @notice Error thrown when zero address is used
    error AmountCannotBeZero();

    /// @notice The reserve ledger token
    IERC20 public immutable RESERVE_LEDGER;

    /// @notice The controller that can move tokens from this store
    address public immutable CONTROLLER;

    /// @notice The stablecoin this store backs
    IERC20 public immutable STABLECOIN;

    /// @param reserveLedger The reserve ledger token address
    /// @param controller The controller contract address
    /// @param stablecoin The stablecoin this store backs
    constructor(address reserveLedger, address controller, address stablecoin) {
        require(reserveLedger != address(0), AmountCannotBeZero());
        require(controller != address(0), AmountCannotBeZero());
        require(stablecoin != address(0), AmountCannotBeZero());

        RESERVE_LEDGER = IERC20(reserveLedger);
        CONTROLLER = controller;
        STABLECOIN = IERC20(stablecoin);

        RESERVE_LEDGER.approve(controller, type(uint256).max);
    }

}
