// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    StablecoinTemplateV3Storage,
    StablecoinTemplateV3StorageLib
} from "./StablecoinTemplateV3Storage.sol";

import { StablecoinTemplateV3Base } from "./StablecoinTemplateV3Base.sol";

contract ReserveLedger is StablecoinTemplateV3Base {

    constructor(address _authRegistry) StablecoinTemplateV3Base(_authRegistry) { }

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
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        require(totalSupply() + amount <= $._maxSupply, MaxSupplyExceeded());
        require($._mintRecipientList[to], AccountNotValidRecipient());

        _mint(to, amount);

        emit Minted(amount, to, _msgSender());
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
        _burn(_msgSender(), amount);

        emit Burned(amount, _msgSender());
    }

    /**
     * @dev Burns the entire balance of a blocked address.
     *
     * This function temporarily unblocks the address to allow the burn operation,
     * then re-blocks it after the burn is complete.
     *
     * Requirements:
     * - `account` must be blocked
     * - `account` must have a balance greater than 0
     */
    function burnFromBlockedAddress(address account)
        public
        virtual
        onlyRole(BLOCKED_ADDRESS_BURNER_ROLE)
    {
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        require(isBlocked(account), AddressIsNotBlocked());

        uint256 accountBalance = balanceOf(account);
        require(accountBalance > 0, NoBalanceToBurn());

        // Temporarily unblock the address to allow the burn to go through. This is needed because
        // _update prevents transfers to and from blocked addresses. _burn() treats
        // burns as transfers to the zero address.
        StablecoinTemplateV3StorageLib.setTemporaryUnblockStatus(true);
        _burn(account, accountBalance);
        StablecoinTemplateV3StorageLib.setTemporaryUnblockStatus(false);

        emit BurnedFromBlockedAddress(accountBalance, account, _msgSender());
    }

    /**
     * @dev Sets the max supply.
     *
     * Emits a {MaxSupplySet} event with `amount` set to the amount, and `sender` set to the sender.
     *
     * Requirements:
     *
     * - `amount` must be greater than or equal to the total supply.
     */
    function setMaxSupply(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount >= totalSupply(), MaxSupplyMustBeGreaterThanOrEqualToTotalSupply());

        StablecoinTemplateV3StorageLib.getStorage()._maxSupply = amount;

        emit MaxSupplySet(amount, _msgSender());
    }

}
