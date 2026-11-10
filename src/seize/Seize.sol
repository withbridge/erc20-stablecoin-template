// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPolicyRegistry } from "./interfaces/IPolicyRegistry.sol";
import { ISeize } from "./interfaces/ISeize.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Controller base that enforces the rules every seize must follow and leaves only the
/// coin-specific move to the implementer.
/// @dev Template method: {seize} runs the shared pre-checks, calls {_executeSeize}, then asserts
/// the Seizure Wallet received exactly `amount`, the one outcome every move must produce. Anything
/// specific to how a coin moves (pause handling, the burn-and-re-mint handler's own balances) is
/// handled by that move itself.
/// @dev Holds no state. Declaring storage here would insert slots ahead of the inheriting
/// controller's existing sequential variables and shift its layout (the same constraint as
/// {IdempotencyKeys}). Implementers store their own seize settings and expose them through
/// {_seizureWalletList}, {_seizureWalletRegistry}, and {_setSeizureWalletPolicyId}.
/// @dev No reentrancy guard: {seize} calls only the admin-configured stablecoin, its seize handler,
/// and its list registry, and none of the supported stablecoins call out during mint, burn, or
/// transfer.
abstract contract Seize is AccessControlEnumerableUpgradeable, ISeize {

    /*//////////////////////////////////////////////////////////////////////////
                                    Constants
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant SEIZER_ROLE = keccak256("SEIZER_ROLE");

    /// @dev Highest built-in policy ID shared by the AuthRegistry and TIP-403: 0 always rejects
    /// and 1 always allows. Neither can be a Seizure Wallet list, and 1 would make every address
    /// one.
    uint64 internal constant ALWAYS_ALLOW_POLICY_ID = 1;

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISeize
    function seize(address stablecoinContract, address from, address to, uint256 amount)
        external
        onlyRole(SEIZER_ROLE)
    {
        (address registry, uint64 listId) = _seizureWalletList(stablecoinContract);

        // Seizing to the holder would be a no-op that still unblocks it on the partial V2 path, and
        // seizing to this controller would leave coins only a seize could move again.
        require(to != from && to != address(this), InvalidSeizeDestination(to));
        require(IPolicyRegistry(registry).isAuthorized(listId, to), DestinationNotSeizureWallet(to));
        require(_isHolderBlocked(stablecoinContract, from), HolderNotBlocked(from));

        IERC20 stablecoin = IERC20(stablecoinContract);
        uint256 holderBalance = stablecoin.balanceOf(from);
        require(amount > 0 && amount <= holderBalance, InvalidSeizeAmount(amount, holderBalance));
        uint256 destinationBalanceBefore = stablecoin.balanceOf(to);

        _executeSeize(stablecoinContract, from, to, amount, holderBalance);

        uint256 destinationBalanceAfter = stablecoin.balanceOf(to);
        require(
            destinationBalanceAfter == destinationBalanceBefore + amount,
            SeizeBalanceMismatch(to, destinationBalanceBefore + amount, destinationBalanceAfter)
        );

        emit Seized(stablecoinContract, from, to, amount, msg.sender);
    }

    /**
     * @inheritdoc ISeize
     * @dev Shared by every controller, like {IdempotencyKeys-setIdempotencyKeyRegistry}. Only the
     * policy ID is configurable: each controller reads it from one fixed registry.
     */
    function setSeizureWalletPolicyId(uint64 policyId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (policyId != 0) {
            _requireValidSeizureWalletList(_seizureWalletRegistry(), policyId);
        }

        _setSeizureWalletPolicyId(policyId);

        emit SeizureWalletPolicyIdSet(msg.sender, policyId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Reverts unless `registry` and `listId` can safely hold Seizure Wallets
     * @dev A whitelist of Bridge-held Seizure Wallets never contains this controller, while an
     * allow-all or blacklist-type list authorizes it by default. Probing `address(this)` catches
     * both misconfigurations through `isAuthorized` alone, which is all every supported registry
     * is guaranteed to expose.
     * @param registry The list registry
     * @param listId The list ID within `registry`
     */
    function _requireValidSeizureWalletList(address registry, uint64 listId) internal view {
        require(
            registry != address(0) && listId > ALWAYS_ALLOW_POLICY_ID
                && !IPolicyRegistry(registry).isAuthorized(listId, address(this)),
            InvalidSeizureWalletList(registry, listId)
        );
    }

    /**
     * @dev Returns the registry and list ID holding the stablecoin's Seizure Wallets.
     * Must revert with {SeizeNotConfigured} when the stablecoin has no seize settings.
     */
    function _seizureWalletList(address stablecoinContract)
        internal
        view
        virtual
        returns (address registry, uint64 listId);

    /// @dev Returns the fixed registry the Seizure Wallet policy ID is read from.
    function _seizureWalletRegistry() internal view virtual returns (address);

    /// @dev Persists the Seizure Wallet policy ID in the implementer's own storage.
    function _setSeizureWalletPolicyId(uint64 policyId) internal virtual;

    /// @dev Returns whether `holder` is frozen on the stablecoin.
    function _isHolderBlocked(address stablecoinContract, address holder)
        internal
        view
        virtual
        returns (bool);

    /**
     * @dev Moves `amount` of `from`'s coins to `to`. Called only after every pre-check passed.
     * Must leave supply, the pause state, and the freeze on `from` exactly as found, and assert
     * whatever its own mechanism could get wrong; {seize} only checks that `to` received `amount`.
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
