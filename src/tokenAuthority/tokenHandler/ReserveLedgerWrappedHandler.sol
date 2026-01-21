// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Mintable } from "../../utils/IERC20Mintable.sol";
import { IWrappedERC20 } from "../../utils/IWrappedERC20.sol";
import { TokenHandler } from "./TokenHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ReserveLedgerWrappedHandler is TokenHandler {

    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWrappedERC20;
    using SafeERC20 for IERC20;

    address public immutable RESERVE_LEDGER_TOKEN;

    constructor(address _reserveLedgerToken, address _tokenAuthority)
        TokenHandler(_tokenAuthority)
    {
        RESERVE_LEDGER_TOKEN = _reserveLedgerToken;
    }

    /**
     * @notice Mints reserve ledger tokens to a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to mint the reserve ledger tokens to
     * @param amount The amount of reserve ledger tokens to mint
     */
    function mint(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        IERC20Mintable(RESERVE_LEDGER_TOKEN).mint(address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).approve(stablecoinContract, amount);
        IWrappedERC20(stablecoinContract).wrap(to, amount);
    }

    /**
     * @notice Burns tokens from a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     */
    function burn(address stablecoinContract, uint256 amount) external onlyTokenAuthority {
        IERC20Mintable(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).approve(stablecoinContract, amount);
        IWrappedERC20(stablecoinContract).unwrap(amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).burn(amount);
    }

    /**
     * @notice Wraps tokens from a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to wrap the tokens to
     * @param amount The amount of tokens to wrap
     */
    function wrap(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        IERC20Mintable(RESERVE_LEDGER_TOKEN).transferFrom(msg.sender, address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).approve(stablecoinContract, amount);
        IWrappedERC20(stablecoinContract).wrap(to, amount);
    }

    /**
     * @notice Unwraps tokens from a specified address
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to unwrap the tokens to
     * @param amount The amount of tokens to unwrap
     */
    function unwrap(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IWrappedERC20(stablecoinContract).unwrap(amount);
        IERC20(RESERVE_LEDGER_TOKEN).safeTransfer(to, amount);
    }

}
