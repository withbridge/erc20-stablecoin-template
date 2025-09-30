// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StablecoinTemplateV3ErrorsAndEvents } from "./StablecoinTemplateV3ErrorsAndEvents.sol";

import {
    StablecoinTemplateV3Storage,
    StablecoinTemplateV3StorageLib
} from "./StablecoinTemplateV3Storage.sol";
import { OwnableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { AccessControlEnumerableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { PausableUpgradeable } from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract StablecoinTemplateV3 is
    Initializable,
    ERC20Upgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable,
    StablecoinTemplateV3ErrorsAndEvents
{

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant BLOCKER_ROLE = keccak256("BLOCKER_ROLE");
    bytes32 public constant UNBLOCKER_ROLE = keccak256("UNBLOCKER_ROLE");
    bytes32 public constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");

    modifier onlyOwnerOrAdmin() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) || owner() == _msgSender(), OnlyOwnerOrAdmin()
        );
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract with the given parameters.
     *
     * Requirements:
     * - `admin` cannot be the zero address
     * - `__decimals` realistically should be 6
     *
     * @param _name The name of the token
     * @param _symbol The symbol of the token
     * @param __decimals The number of decimals of the token
     * @param admin The address of the admin
     */
    function initialize(
        string calldata _name,
        string calldata _symbol,
        uint8 __decimals,
        address admin
    ) public initializer {
        _initialize(_name, _symbol, __decimals, admin);
    }

    /**
     * @dev Reinitializes the contract with new parameters.
     *
     * Requirements:
     * - `admin` cannot be the zero address
     * - `__decimals` realistically should be 6
     */
    function reinitialize(
        string calldata _name,
        string calldata _symbol,
        uint8 __decimals,
        address admin
    ) public reinitializer(2) onlyOwnerOrAdmin {
        _initialize(_name, _symbol, __decimals, admin);
    }

    function _initialize(
        string calldata _name,
        string calldata _symbol,
        uint8 __decimals,
        address admin
    ) internal {
        require(admin != address(0), AdminCannotBeZeroAddress());

        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();

        $._maxSupply = 0;
        $._decimals = __decimals;

        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __Ownable_init(admin);
        __AccessControl_init();
        __ERC20Permit_init(_name);
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    modifier whenNotInBlockedList(address account) {
        require(
            !StablecoinTemplateV3StorageLib.getStorage()._blockedList[account], AddressBlocked()
        );
        _;
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
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
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
    function burn(uint256 amount) public onlyRole(MINTER_ROLE) {
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
    function burnFromBlockedAddress(address account) public onlyRole(BLOCKED_ADDRESS_BURNER_ROLE) {
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        require($._blockedList[account], AddressIsNotBlocked());

        uint256 accountBalance = balanceOf(account);
        require(accountBalance > 0, NoBalanceToBurn());

        // Temporarily unblock the address to allow the burn to go through. This is needed because
        // _update prevents transfers to and from blocked addresses. _burn() treats
        // burns as transfers to the zero address.
        $._blockedList[account] = false;
        _burn(account, accountBalance);
        $._blockedList[account] = true;

        emit BurnedFromBlockedAddress(accountBalance, account, _msgSender());
    }

    /**
     * @dev Triggers stopped state.
     *
     * Emits a {Paused} event with `account` set to the sender.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Returns to normal state.
     *
     * Emits an {Unpaused} event with `account` set to the sender.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function unpause() public onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Blocks the `account` from receiving a mint, burning, and transferring tokens.
     *
     * May emit a {BlockedAddress} event with `account` set to account, and `sender` set to the
     * sender.
     *
     * Requirements:
     *
     * - `account` should not be the zero address.
     */
    function blockAddress(address account) public onlyRole(BLOCKER_ROLE) {
        require(account != address(0), AdminCannotBeZeroAddress());

        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        if (!$._blockedList[account]) {
            $._blockedList[account] = true;
            emit BlockedAddress(account, _msgSender());
        }
    }

    /**
     * @dev Unblocks a minter `account` from receiving a mint and burning. Unblocks any `account`
     * from transferring tokens.
     *
     * May emit a {UnblockedAddress} event with `account` set to account, and `sender` set to the
     * sender.
     */
    function unblockAddress(address account) public onlyRole(UNBLOCKER_ROLE) {
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        if ($._blockedList[account]) {
            delete $._blockedList[account];
            emit UnblockedAddress(account, _msgSender());
        }
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

    /**
     * @dev Adds the `account` to a list of addresses that can receive from a mint.
     *
     * May emit an {AddedMintRecipient} event with `account` set to account, and `sender` set to the
     * sender.
     */
    function addMintRecipient(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        if (!$._mintRecipientList[account]) {
            $._mintRecipientList[account] = true;
            emit AddedMintRecipient(account, _msgSender());
        }
    }

    /**
     * @dev Removes the `account` from a list of addresses that can receive from a mint.
     *
     * May emit a {RemovedMintRecipient} event with `account` set to account, and `sender` set to
     * the sender.
     */
    function removeMintRecipient(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();
        if ($._mintRecipientList[account]) {
            delete $._mintRecipientList[account];
            emit RemovedMintRecipient(account, _msgSender());
        }
    }

    /**
     * @dev Returns `true` if `account` is blocked
     */
    function isBlocked(address account) public view returns (bool) {
        return StablecoinTemplateV3StorageLib.getStorage()._blockedList[account];
    }

    /**
     * @dev Returns `true` if `account` is a valid mint recipient
     */
    function isMintRecipient(address account) public view returns (bool) {
        return StablecoinTemplateV3StorageLib.getStorage()._mintRecipientList[account];
    }

    /**
     * @dev Retrieves `maxSupply`.
     */
    function getMaxSupply() public view returns (uint256) {
        return StablecoinTemplateV3StorageLib.getStorage()._maxSupply;
    }

    /**
     * @dev Retrieves `decimals`.
     */
    function decimals() public view virtual override returns (uint8) {
        return StablecoinTemplateV3StorageLib.getStorage()._decimals;
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * Requirements:
     *
     * - Should not result in an empty DEFAULT_ADMIN_ROLE
     */
    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool) {
        require(
            role != DEFAULT_ADMIN_ROLE || getRoleMemberCount(DEFAULT_ADMIN_ROLE) > 1,
            CannotRevokeLastAdminRole()
        );

        bool revoked = super._revokeRole(role, account);

        return revoked;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * Requirements:
     *
     * - `account` should not be the zero address.
     */
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        require(account != address(0), AdminCannotBeZeroAddress());

        bool granted = super._grantRole(role, account);

        return granted;
    }

    /**
     * @dev Updates the token balances of `from` and `to` after a transfer.
     *
     * Replaces _beforeTokenTransfer and _afterTokenTransfer, so add the relevant modifiers here.
     *
     * - `from` and `to` must not be blocked.
     * - The contract must not be paused.
     */
    function _update(address from, address to, uint256 amount)
        internal
        override
        whenNotPaused
        whenNotInBlockedList(from)
        whenNotInBlockedList(to)
    {
        super._update(from, to, amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    { }

}
