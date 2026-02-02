// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Mintable } from "../../utils/IERC20Mintable.sol";
import { IWrappedERC20 } from "../../utils/IWrappedERC20.sol";
import { TokenHandler } from "./TokenHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ReserveLedgerWrappedHandler
/// @author Bridge
/// @notice Token handler for wrapped stablecoins backed by reserve ledger tokens held in the
/// stablecoin contract
/// @dev The stablecoin contract holds the reserve ledger tokens directly as collateral
contract ReserveLedgerWrappedHandler is TokenHandler {

    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWrappedERC20;
    using SafeERC20 for IERC20;

    /// @notice The address of the reserve ledger token used as collateral
    address public immutable RESERVE_LEDGER_TOKEN;

    /// @notice Initializes the handler with the reserve ledger token and token authority
    /// @param _reserveLedgerToken The address of the reserve ledger token
    /// @param _tokenAuthority The address of the token authority
    constructor(address _reserveLedgerToken, address _tokenAuthority)
        TokenHandler(_tokenAuthority)
    {
        require(_reserveLedgerToken != address(0), ZeroAddress());
        RESERVE_LEDGER_TOKEN = _reserveLedgerToken;
    }

    /**
     * @notice Mints reserve ledger tokens and wraps them into stablecoins
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the wrapped stablecoins
     * @param amount The amount of tokens to mint and wrap
     */
    function mint(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        require(to != address(0), ZeroAddress());
        IERC20Mintable(RESERVE_LEDGER_TOKEN).mint(address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).approve(stablecoinContract, amount);
        IWrappedERC20(stablecoinContract).wrap(to, amount);
        emit Minted(stablecoinContract, to, amount);
    }

    /**
     * @notice Unwraps stablecoins and burns the underlying reserve ledger tokens
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of stablecoins to burn
     */
    function burn(address stablecoinContract, uint256 amount) external onlyTokenAuthority {
        IERC20Mintable(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).approve(stablecoinContract, amount);
        IWrappedERC20(stablecoinContract).unwrap(amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).burn(amount);
        emit Burned(stablecoinContract, amount);
    }

    /**
     * @notice Wraps existing reserve ledger tokens into stablecoins
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the wrapped stablecoins
     * @param amount The amount of reserve ledger tokens to wrap
     */
    function wrap(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        require(to != address(0), ZeroAddress());
        IERC20Mintable(RESERVE_LEDGER_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).approve(stablecoinContract, amount);
        IWrappedERC20(stablecoinContract).wrap(to, amount);
        emit Wrapped(stablecoinContract, to, amount);
    }

    /**
     * @notice Unwraps stablecoins into reserve ledger tokens
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the reserve ledger tokens
     * @param amount The amount of stablecoins to unwrap
     */
    function unwrap(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        require(to != address(0), ZeroAddress());
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IWrappedERC20(stablecoinContract).unwrap(amount);
        IERC20(RESERVE_LEDGER_TOKEN).safeTransfer(to, amount);
        emit Unwrapped(stablecoinContract, to, amount);
    }

}
