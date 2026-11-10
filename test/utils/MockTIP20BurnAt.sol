// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";

/// @notice Test double for a TIP-20 coin on a T12+ chain, where `burnAt` exists
/// @dev The Tempo Foundry release CI pins (v1.6.0-t3) predates T12, so its TIP-20 precompile has no
/// `burnAt` and seize cannot be exercised against it. This mock implements only what the controller
/// touches, with the semantics of the upstream precompile:
/// - `mint` needs ISSUER_ROLE, respects the supply cap, requires the recipient to be authorized by
///   the coin's TIP-403 transfer policy (checked on the real registry precompile), and works while
///   paused (observed on the v1.6.0-t3 precompile)
/// - `burnAt` needs BURN_AT_ROLE and an unpaused coin, and does not check the transfer policy
/// - `pause` and `unpause` are role-gated and idempotent
/// Balances move only through mint and burn; seize never transfers TIP-20 coins.
contract MockTIP20BurnAt is AccessControl {

    event Mint(address indexed to, uint256 amount);
    event BurnAt(address indexed burner, address indexed from, uint256 indexed amount);
    event PauseStateUpdate(address indexed updater, bool isPaused);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");
    bytes32 public constant BURN_AT_ROLE = keccak256("BURN_AT_ROLE");

    mapping(address account => uint256 balance) public balanceOf;
    uint256 public totalSupply;
    uint256 public supplyCap = type(uint128).max;
    uint64 public transferPolicyId;
    bool public paused;

    constructor(address admin, uint64 _transferPolicyId) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        transferPolicyId = _transferPolicyId;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyRole(ISSUER_ROLE) {
        if (!StdPrecompiles.TIP403_REGISTRY.isAuthorized(transferPolicyId, to)) {
            revert ITIP20.PolicyForbids();
        }
        if (totalSupply + amount > supplyCap) {
            revert ITIP20.SupplyCapExceeded();
        }

        balanceOf[to] += amount;
        totalSupply += amount;

        emit Transfer(address(0), to, amount);
        emit Mint(to, amount);
    }

    function burnAt(address from, uint256 amount) external onlyRole(BURN_AT_ROLE) {
        if (paused) {
            revert ITIP20.ContractPaused();
        }
        uint256 balance = balanceOf[from];
        if (balance < amount) {
            revert ITIP20.InsufficientBalance(balance, amount, address(this));
        }

        balanceOf[from] = balance - amount;
        totalSupply -= amount;

        emit Transfer(from, address(0), amount);
        emit BurnAt(msg.sender, from, amount);
    }

    function pause() external onlyRole(PAUSE_ROLE) {
        paused = true;
        emit PauseStateUpdate(msg.sender, true);
    }

    function unpause() external onlyRole(UNPAUSE_ROLE) {
        paused = false;
        emit PauseStateUpdate(msg.sender, false);
    }

    function changeTransferPolicyId(uint64 newPolicyId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transferPolicyId = newPolicyId;
    }

    function setSupplyCap(uint256 newSupplyCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSupplyCap < totalSupply) {
            revert ITIP20.InvalidSupplyCap();
        }
        supplyCap = newSupplyCap;
    }

}
