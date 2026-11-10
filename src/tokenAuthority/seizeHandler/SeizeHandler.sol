// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Version } from "../../Version.sol";
import { ISeize } from "../../seize/interfaces/ISeize.sol";
import { ReserveLedger } from "../../v3/ReserveLedger.sol";
import { ITokenAuthority } from "../ITokenAuthority.sol";
import { ISeizeHandler } from "./ISeizeHandler.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC165, IERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";

/// @title SeizeHandler
/// @author Bridge
/// @notice Abstract base contract for seize handlers with TokenAuthority access control
/// @dev Mirrors {TokenHandler}: only the TokenAuthority may call, and ERC165 lets the
/// TokenAuthority reject anything that is not a seize handler when one is configured. Unlike a
/// token handler it holds one setting, the Seizure Wallet list, which the TokenAuthority's admin
/// sets: the handler takes its authority from its TokenAuthority instead of having an admin.
/// @dev Holds the seize rules for the TokenAuthority's stablecoins ({seize}); the TokenAuthority
/// only routes. The TIP20Controller, which has no seize handlers, keeps its own copy of the same
/// rules, and both raise the shared {ISeize} errors.
/// @dev No reentrancy guard: {seize} calls only the admin-configured stablecoin and the
/// AuthRegistry, and none of the supported stablecoins call out during mint, burn, or transfer.
abstract contract SeizeHandler is ISeizeHandler, ERC165, Version {

    /// @notice The address of the token authority that controls this handler
    address public immutable TOKEN_AUTHORITY;

    /// @notice The AuthRegistry holding the TokenAuthority's Seizure Wallet list
    /// @dev Read from the TokenAuthority's reserve ledger at construction, so it is always the
    /// registry that entity's lists live in.
    IAuthRegistry public immutable AUTH_REGISTRY;

    /// @dev OpenZeppelin's DEFAULT_ADMIN_ROLE, checked on the TokenAuthority.
    bytes32 private constant TOKEN_AUTHORITY_ADMIN_ROLE = 0x00;

    /// @inheritdoc ISeizeHandler
    uint64 public seizureWalletPolicyId;

    /// @notice Restricts function access to only the token authority
    modifier onlyTokenAuthority() {
        require(msg.sender == TOKEN_AUTHORITY, OnlyTokenAuthority());
        _;
    }

    /// @notice Initializes the seize handler with the token authority address
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) {
        require(_tokenAuthority != address(0), ZeroAddress());
        TOKEN_AUTHORITY = _tokenAuthority;
        AUTH_REGISTRY =
            ReserveLedger(ITokenAuthority(_tokenAuthority).RESERVE_LEDGER_TOKEN()).AUTH_REGISTRY();
    }

    /// @inheritdoc ISeizeHandler
    function setSeizureWalletPolicyId(uint64 policyId) external {
        require(
            IAccessControl(TOKEN_AUTHORITY).hasRole(TOKEN_AUTHORITY_ADMIN_ROLE, msg.sender),
            OnlyTokenAuthorityAdmin()
        );

        seizureWalletPolicyId = policyId;

        emit SeizureWalletPolicyIdSet(msg.sender, policyId);
    }

    /// @inheritdoc ISeizeHandler
    function seize(address stablecoinContract, address from, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        require(seizureWalletPolicyId != 0, ISeize.SeizeNotConfigured(stablecoinContract));

        // Seizing to the holder would be a no-op that still unblocks it on the partial V2 path.
        // Seizing to the TokenAuthority or this handler would leave coins only a seize could move.
        require(
            to != from && to != TOKEN_AUTHORITY && to != address(this),
            ISeize.InvalidSeizeDestination(to)
        );
        require(_isSeizureWallet(to), ISeize.DestinationNotSeizureWallet(to));
        require(_isHolderBlocked(stablecoinContract, from), ISeize.HolderNotBlocked(from));

        IERC20 stablecoin = IERC20(stablecoinContract);
        uint256 holderBalance = stablecoin.balanceOf(from);
        require(
            amount > 0 && amount <= holderBalance, ISeize.InvalidSeizeAmount(amount, holderBalance)
        );
        uint256 destinationBalanceBefore = stablecoin.balanceOf(to);

        _executeSeize(stablecoinContract, from, to, amount, holderBalance);

        // The one outcome every move must produce; anything specific to how a stablecoin moves is
        // asserted by that move itself.
        uint256 destinationBalanceAfter = stablecoin.balanceOf(to);
        require(
            destinationBalanceAfter == destinationBalanceBefore + amount,
            ISeize.SeizeBalanceMismatch(
                to, destinationBalanceBefore + amount, destinationBalanceAfter
            )
        );

        emit Seized(stablecoinContract, from, to, amount);
    }

    /// @notice Checks if the contract supports a given interface
    /// @param interfaceId The interface identifier to check
    /// @return bool True if the interface is supported
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(ISeizeHandler).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Whether `account` is on this handler's Seizure Wallet list in {AUTH_REGISTRY}. Reverts
     * with {ISeize-InvalidSeizureWalletList} if the list authorizes the TokenAuthority itself: a
     * whitelist of Bridge-held Seizure Wallets never contains it, while the built-in allow-all
     * policy (1) and every blacklist-type list authorize it by default, so this one probe rejects
     * all of them. Runs on every seize, so it also catches a list edited later.
     */
    function _isSeizureWallet(address account) internal view returns (bool) {
        uint64 policyId = seizureWalletPolicyId;
        require(
            !AUTH_REGISTRY.isAuthorized(policyId, TOKEN_AUTHORITY),
            ISeize.InvalidSeizureWalletList(address(AUTH_REGISTRY), policyId)
        );

        return AUTH_REGISTRY.isAuthorized(policyId, account);
    }

    /// @dev Returns whether `holder` is frozen, read through the stablecoin's own type.
    function _isHolderBlocked(address stablecoinContract, address holder)
        internal
        view
        virtual
        returns (bool);

    /**
     * @dev Moves `amount` of `from`'s coins to `to`. Called only after every rule passed. Must
     * leave supply, the pause state, and the freeze on `from` exactly as found, and assert whatever
     * its own mechanism could get wrong; {seize} only checks that `to` received `amount`.
     * @param holderBalance `from`'s balance read before the move
     */
    function _executeSeize(
        address stablecoinContract,
        address from,
        address to,
        uint256 amount,
        uint256 holderBalance
    ) internal virtual;

}
