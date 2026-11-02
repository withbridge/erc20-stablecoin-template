// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Test double for the live StablecoinTemplateV2 coins
/// @dev Ports the behaviour of `withbridge/stablecoin-template`
/// `contracts/v2/StablecoinTemplateV2.sol` (OpenZeppelin v4) to OpenZeppelin v5 so it compiles in
/// this repo. Role names, the storage
/// blocklist, the mint-recipient list, the max supply, pause gating, and revert strings match the
/// original. `_update` stands in for v4's `_beforeTokenTransfer` and is gated identically. It is
/// not upgradeable because the tests never upgrade it.
contract MockStablecoinTemplateV2 is ERC20, Pausable, AccessControl {

    event Minted(uint256 amount, address indexed to, address indexed sender);
    event BurnedFromBlockedAddress(uint256 amount, address indexed account, address indexed sender);
    event BlockedAddress(address indexed account, address indexed sender);
    event UnblockedAddress(address indexed account, address indexed sender);
    event AddedMintRecipient(address indexed account, address indexed sender);
    event RemovedMintRecipient(address indexed account, address indexed sender);

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant BLOCKER_ROLE = keccak256("BLOCKER_ROLE");
    bytes32 public constant UNBLOCKER_ROLE = keccak256("UNBLOCKER_ROLE");
    bytes32 public constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");

    mapping(address => bool) private _blockedList;
    mapping(address => bool) private _mintRecipientList;

    uint256 private _maxSupply;
    uint8 private immutable _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_, address admin)
        ERC20(name, symbol)
    {
        require(admin != address(0), "admin cannot be the zero address");
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= _maxSupply, "Max supply exceeded");
        require(_mintRecipientList[to], "Account not a valid recipient");

        _mint(to, amount);

        emit Minted(amount, to, _msgSender());
    }

    function burn(uint256 amount) public onlyRole(MINTER_ROLE) {
        _burn(_msgSender(), amount);
    }

    function burnFromBlockedAddress(address account) public onlyRole(BLOCKED_ADDRESS_BURNER_ROLE) {
        require(_blockedList[account], "Address is not blocked");

        uint256 accountBalance = balanceOf(account);
        require(accountBalance > 0, "No balance to burn");

        _blockedList[account] = false;
        _burn(account, accountBalance);
        _blockedList[account] = true;

        emit BurnedFromBlockedAddress(accountBalance, account, _msgSender());
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    function blockAddress(address account) public onlyRole(BLOCKER_ROLE) {
        require(account != address(0), "account cannot be the zero address");

        if (!_blockedList[account]) {
            _blockedList[account] = true;
            emit BlockedAddress(account, _msgSender());
        }
    }

    function unblockAddress(address account) public onlyRole(UNBLOCKER_ROLE) {
        if (_blockedList[account]) {
            delete _blockedList[account];
            emit UnblockedAddress(account, _msgSender());
        }
    }

    function increaseMaxSupply(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _maxSupply += amount;
    }

    function addMintRecipient(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_mintRecipientList[account]) {
            _mintRecipientList[account] = true;
            emit AddedMintRecipient(account, _msgSender());
        }
    }

    function removeMintRecipient(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_mintRecipientList[account]) {
            delete _mintRecipientList[account];
            emit RemovedMintRecipient(account, _msgSender());
        }
    }

    function isBlocked(address account) public view returns (bool) {
        return _blockedList[account];
    }

    function getMaxSupply() public view returns (uint256) {
        return _maxSupply;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev V2's `_beforeTokenTransfer` gate: not paused, and neither side blocked. Applies to
    /// mints and burns too, where one side is the zero address.
    function _update(address from, address to, uint256 amount) internal override whenNotPaused {
        require(!_blockedList[from], "Address is blocked");
        require(!_blockedList[to], "Address is blocked");
        super._update(from, to, amount);
    }

}
