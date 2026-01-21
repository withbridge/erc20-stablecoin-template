// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReserveStore } from "../../reserveStore/ReserveStore.sol";
import { IERC20Mintable } from "../../utils/IERC20Mintable.sol";
import { IWrappedERC20 } from "../../utils/IWrappedERC20.sol";
import { TokenHandler } from "./TokenHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ReserveLedgerBackedHandler
/// @notice Token handler for stablecoins backed by reserve ledger tokens held in separate reserve
/// stores @dev Each stablecoin has its own ReserveStore contract that holds the collateral
contract ReserveLedgerBackedHandler is TokenHandler {

    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Mintable;

    /// @notice The address of the reserve ledger token used as collateral
    address public immutable RESERVE_LEDGER_TOKEN;

    /// @notice Mapping from stablecoin contract address to its reserve store address
    mapping(address stablecoinContract => address reserveStore) public reserveStores;

    /// @notice Thrown when attempting to burn or unwrap from a stablecoin with no reserve store
    error ReserveStoreNotFound();

    /// @notice Initializes the handler with the reserve ledger token and token authority
    /// @param _reserveLedgerToken The address of the reserve ledger token
    /// @param _tokenAuthority The address of the token authority
    constructor(address _reserveLedgerToken, address _tokenAuthority)
        TokenHandler(_tokenAuthority)
    {
        RESERVE_LEDGER_TOKEN = _reserveLedgerToken;
    }

    /**
     * @notice Mints reserve ledger tokens to a reserve store and mints stablecoins to the recipient
     * @dev Creates a new ReserveStore if one doesn't exist for the stablecoin
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the minted stablecoins
     * @param amount The amount of tokens to mint
     */
    function mint(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        IERC20Mintable(RESERVE_LEDGER_TOKEN).mint(address(this), amount);
        address reserveStore = reserveStores[stablecoinContract];
        if (reserveStore == address(0)) {
            reserveStore =
                address(new ReserveStore(RESERVE_LEDGER_TOKEN, address(this), stablecoinContract));
            reserveStores[stablecoinContract] = reserveStore;
        }
        IERC20(RESERVE_LEDGER_TOKEN).transfer(reserveStore, amount);
        IERC20Mintable(stablecoinContract).mint(to, amount);
        emit Minted(stablecoinContract, to, amount);
    }

    /**
     * @notice Burns stablecoins and the corresponding reserve ledger tokens from the reserve store
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of stablecoins to burn
     */
    function burn(address stablecoinContract, uint256 amount) external onlyTokenAuthority {
        address reserveStore = reserveStores[stablecoinContract];
        require(reserveStore != address(0), ReserveStoreNotFound());
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).burn(amount);
        IERC20(RESERVE_LEDGER_TOKEN).safeTransferFrom(reserveStore, address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).burn(amount);
        emit Burned(stablecoinContract, amount);
    }

    /**
     * @notice Wraps reserve ledger tokens into stablecoins by transferring to reserve store
     * @dev Creates a new ReserveStore if one doesn't exist for the stablecoin
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the wrapped stablecoins
     * @param amount The amount of reserve ledger tokens to wrap
     */
    function wrap(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        address reserveStore = reserveStores[stablecoinContract];
        if (reserveStore == address(0)) {
            reserveStore =
                address(new ReserveStore(RESERVE_LEDGER_TOKEN, address(this), stablecoinContract));
            reserveStores[stablecoinContract] = reserveStore;
        }
        IERC20(RESERVE_LEDGER_TOKEN).safeTransferFrom(msg.sender, reserveStore, amount);
        IERC20Mintable(stablecoinContract).mint(to, amount);
        emit Wrapped(stablecoinContract, to, amount);
    }

    /**
     * @notice Unwraps stablecoins into reserve ledger tokens from the reserve store
     * @param stablecoinContract The address of the stablecoin contract
     * @param to The address to receive the reserve ledger tokens
     * @param amount The amount of stablecoins to unwrap
     */
    function unwrap(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        address reserveStore = reserveStores[stablecoinContract];
        require(reserveStore != address(0), ReserveStoreNotFound());
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).burn(amount);
        IERC20(RESERVE_LEDGER_TOKEN).safeTransferFrom(reserveStore, to, amount);
        emit Unwrapped(stablecoinContract, to, amount);
    }

}
