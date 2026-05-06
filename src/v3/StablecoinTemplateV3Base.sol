// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EIP3009Upgradeable } from "./EIP3009Upgradeable.sol";
import { StablecoinTemplateV3ErrorsAndEvents } from "./StablecoinTemplateV3ErrorsAndEvents.sol";

import {
    StablecoinTemplateV3Storage,
    StablecoinTemplateV3StorageLib
} from "./StablecoinTemplateV3Storage.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";

/// @title StablecoinTemplateV3Base
/// @author Bridge
/// @notice Abstract base contract for stablecoin implementations with access control and
/// pausability @dev Combines ERC20, permit, pausable, ownable, access control, and UUPS
/// upgradeability
abstract contract StablecoinTemplateV3Base is
    Initializable,
    ERC20Upgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC20PermitUpgradeable,
    EIP3009Upgradeable,
    UUPSUpgradeable,
    StablecoinTemplateV3ErrorsAndEvents
{

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");
    bytes32 public constant UNWRAPPER_ROLE = keccak256("UNWRAPPER_ROLE");

    IAuthRegistry public immutable AUTH_REGISTRY;

    modifier onlyOwnerOrAdmin() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || owner() == msg.sender, OnlyOwnerOrAdmin()
        );
        _;
    }

    constructor(address _authRegistry) {
        require(_authRegistry != address(0), ZeroAddress());
        AUTH_REGISTRY = IAuthRegistry(_authRegistry);
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
        address admin,
        uint64 _transferPolicyId,
        uint64 _mintRecipientPolicyId
    ) public initializer {
        _initialize(_name, _symbol, __decimals, admin, _transferPolicyId, _mintRecipientPolicyId);
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
        address admin,
        uint64 _transferPolicyId,
        uint64 _mintRecipientPolicyId
    ) public reinitializer(2) onlyOwnerOrAdmin {
        _initialize(_name, _symbol, __decimals, admin, _transferPolicyId, _mintRecipientPolicyId);
    }

    function _initialize(
        string calldata _name,
        string calldata _symbol,
        uint8 __decimals,
        address admin,
        uint64 _transferPolicyId,
        uint64 _mintRecipientPolicyId
    ) internal onlyInitializing {
        require(admin != address(0), ZeroAddress());

        StablecoinTemplateV3Storage storage $ = StablecoinTemplateV3StorageLib.getStorage();

        $._maxSupply = totalSupply();
        $._decimals = __decimals;

        $._transferPolicyId = _transferPolicyId;
        $._mintRecipientPolicyId = _mintRecipientPolicyId;

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
            StablecoinTemplateV3StorageLib.getTemporaryUnblockStatus()
                || AUTH_REGISTRY.isAuthorized(
                    StablecoinTemplateV3StorageLib.getStorage()._transferPolicyId, account
                ),
            AddressBlocked()
        );
        _;
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
     * @dev Returns `true` if `account` is blocked
     */
    function isBlocked(address account) public view returns (bool) {
        return !AUTH_REGISTRY.isAuthorized(
            StablecoinTemplateV3StorageLib.getStorage()._transferPolicyId, account
        );
    }

    /**
     * @dev Returns `true` if `account` is a valid mint recipient
     */
    function isMintRecipient(address account) public view returns (bool) {
        return AUTH_REGISTRY.isAuthorized(
            StablecoinTemplateV3StorageLib.getStorage()._mintRecipientPolicyId, account
        );
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
     * @dev Retrieves `transferPolicyId`.
     */
    function getTransferPolicyId() public view returns (uint64) {
        return StablecoinTemplateV3StorageLib.getStorage()._transferPolicyId;
    }

    /**
     * @dev Retrieves `mintRecipientPolicyId`.
     */
    function getMintRecipientPolicyId() public view returns (uint64) {
        return StablecoinTemplateV3StorageLib.getStorage()._mintRecipientPolicyId;
    }

    /**
     * @dev Sets `transferPolicyId`.
     *
     * Requirements:
     *
     * - The caller must have the DEFAULT_ADMIN_ROLE.
     */
    function setTransferPolicyId(uint64 policyId) public onlyRole(DEFAULT_ADMIN_ROLE) {
        StablecoinTemplateV3StorageLib.getStorage()._transferPolicyId = policyId;
        emit TransferPolicyIdSet(msg.sender, policyId);
    }

    /**
     * @dev Sets `mintRecipientPolicyId`.
     *
     * Requirements:
     *
     * - The caller must have the DEFAULT_ADMIN_ROLE.
     */
    function setMintRecipientPolicyId(uint64 policyId) public onlyRole(DEFAULT_ADMIN_ROLE) {
        StablecoinTemplateV3StorageLib.getStorage()._mintRecipientPolicyId = policyId;
        emit MintRecipientPolicyIdSet(msg.sender, policyId);
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

        emit MaxSupplySet(amount, msg.sender);
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
        require(account != address(0), ZeroAddress());

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
        whenNotInBlockedList(to)
        whenNotInBlockedList(from)
    {
        super._update(from, to, amount);
    }

    /**
     * @dev Authorizes the upgrade of the contract.
     *
     * Requirements:
     *
     * - The caller must have the DEFAULT_ADMIN_ROLE.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    { }

}
