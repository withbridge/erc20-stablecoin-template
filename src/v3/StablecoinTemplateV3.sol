// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Mintable } from "../utils/IERC20Mintable.sol";
import { StablecoinTemplateV3Base } from "./StablecoinTemplateV3Base.sol";
import {
    StablecoinTemplateV3Storage,
    StablecoinTemplateV3StorageLib
} from "./StablecoinTemplateV3Storage.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StablecoinTemplateV3 is StablecoinTemplateV3Base {

    using SafeERC20 for IERC20Mintable;

    IERC20Mintable public immutable RESERVE_LEDGER_ADDRESS;

    constructor(address _reserveLedgerAddress, address _authRegistry)
        StablecoinTemplateV3Base(_authRegistry)
    {
        _disableInitializers();
        RESERVE_LEDGER_ADDRESS = IERC20Mintable(_reserveLedgerAddress);
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `to`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     * Emits a {Minted} event with `to` set to to, `amount` set to the amount, and `sender` set to
     * the sender.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `to` must be on the list of addresses that can accept a minted tokens
     * - This function requires that the caller has approved at least `amount` of the reserve ledger
     * token to the contract.
     */
    function wrap(address to, uint256 amount) public {
        require(amount > 0, AmountCannotBeZero());
        require(isMintRecipient(to), AccountNotValidRecipient());

        RESERVE_LEDGER_ADDRESS.safeTransferFrom(msg.sender, address(this), amount);

        _mint(to, amount);

        emit Wrapped(amount, to, msg.sender);
    }

    /**
     * @dev Destroys `amount` tokens from `sender`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     * Emits a {Burned} event with `amount` set to the amount, and `sender` set to the sender.
     *
     * Requirements:
     *
     * - `sender` must have at least `amount` tokens.
     * - This function requires that the caller has the MINTER_ROLE.
     */
    function unwrap(uint256 amount) public onlyRole(MINTER_ROLE) {
        _burn(msg.sender, amount);
        RESERVE_LEDGER_ADDRESS.safeTransfer(msg.sender, amount);

        emit Unwrapped(amount, msg.sender);
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `to`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     * Emits a {Minted} event with `to` set to to, `amount` set to the amount, and `sender` set to
     * the sender.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - The sum of `amount` and totalSupply cannot go over the maxSupply.
     * - `to` must be on the list of addresses that can accept a minted tokens
     */
    function mint(address to, uint256 amount) public virtual onlyRole(MINTER_ROLE) {
        require(
            !StablecoinTemplateV3StorageLib.getStorage()._migrationToWrappedCompleted,
            MigrationToWrappedCompleted()
        );
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        require(totalSupply() + amount <= $._maxSupply, MaxSupplyExceeded());
        require(isMintRecipient(to), AccountNotValidRecipient());

        _mint(to, amount);

        emit Minted(amount, to, msg.sender);
    }

    /**
     * @dev Destroys `amount` tokens from `sender`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     * Emits a {Burned} event with `amount` set to the amount, and `sender` set to the sender.
     *
     * Requirements:
     *
     * - `sender` must have at least `amount` tokens.
     */
    function burn(uint256 amount) public virtual onlyRole(MINTER_ROLE) {
        require(
            !StablecoinTemplateV3StorageLib.getStorage()._migrationToWrappedCompleted,
            MigrationToWrappedCompleted()
        );
        _burn(msg.sender, amount);

        emit Burned(amount, msg.sender);
    }

    function completeMigrationToWrapped() public onlyRole(DEFAULT_ADMIN_ROLE) {
        StablecoinTemplateV3StorageLib.getStorage()._migrationToWrappedCompleted = true;
        require(
            RESERVE_LEDGER_ADDRESS.balanceOf(address(this)) == totalSupply(),
            ReserveLedgerBalanceMismatch()
        );
        emit MigrationHasCompleted(msg.sender);
    }

    /**
     * @dev Burns the entire balance of a blocked address.
     *
     * This function temporarily unblocks the address to allow the burn operation,
     * then re-blocks it after the burn is complete. Rather than burning the underlying reserve
     * ledger token,
     * this function transfers the balance of the blocked address to the caller.
     *
     * Requirements:
     * - `account` must be blocked
     * - `account` must have a balance greater than 0
     * - This function requires that the caller has the BLOCKED_ADDRESS_BURNER_ROLE.
     */
    function burnFromBlockedAddress(address account) public onlyRole(BLOCKED_ADDRESS_BURNER_ROLE) {
        require(isBlocked(account), AddressIsNotBlocked());

        uint256 accountBalance = balanceOf(account);
        require(accountBalance > 0, NoBalanceToBurn());

        // Temporarily unblock the address to allow the burn to go through. This is needed because
        // _update prevents transfers to and from blocked addresses. _burn() treats
        // burns as transfers to the zero address.
        StablecoinTemplateV3StorageLib.setTemporaryUnblockStatus(true);
        _burn(account, accountBalance);
        RESERVE_LEDGER_ADDRESS.safeTransfer(msg.sender, accountBalance);
        StablecoinTemplateV3StorageLib.setTemporaryUnblockStatus(false);

        emit BurnedFromBlockedAddress(accountBalance, account, msg.sender);
    }

}
