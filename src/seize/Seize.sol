// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPolicyRegistry } from "./interfaces/IPolicyRegistry.sol";
import { IPausableERC20 } from "./interfaces/ISeizableStablecoin.sol";
import { ISeize } from "./interfaces/ISeize.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/// @notice Controller base that enforces the rules every seize must follow and leaves only the
/// coin-specific move to the implementer.
/// @dev Template method: {seize} runs the shared pre-checks, snapshots balances, supply, and pause
/// state, calls {_executeSeize}, then asserts that nothing but `amount` moved from `from` to `to`.
/// A bug in any implementer's move therefore reverts rather than silently breaking supply or
/// reserve backing.
/// @dev Holds no state. Declaring storage here would insert slots ahead of the inheriting
/// controller's existing sequential variables and shift its layout (the same constraint as
/// {MintIntent}). Implementers store their own seize settings and expose them through
/// {_seizureWalletList}.
/// @dev No reentrancy guard: {seize} calls only the admin-configured stablecoin and its list
/// registry, and none of the supported stablecoins call out during mint, burn, or transfer. The
/// post-conditions would revert any balance drift a reentrant path could cause.
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
                                    Structs
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Balances, supply, and pause state captured before the move, compared after it.
    struct SeizeSnapshot {
        uint256 holderBalance;
        uint256 destinationBalance;
        uint256 controllerBalance;
        uint256 totalSupply;
        bool paused;
    }

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

        IPausableERC20 stablecoin = IPausableERC20(stablecoinContract);
        SeizeSnapshot memory snapshot = SeizeSnapshot({
            holderBalance: stablecoin.balanceOf(from),
            destinationBalance: stablecoin.balanceOf(to),
            controllerBalance: stablecoin.balanceOf(address(this)),
            totalSupply: stablecoin.totalSupply(),
            paused: stablecoin.paused()
        });
        require(
            amount > 0 && amount <= snapshot.holderBalance,
            InvalidSeizeAmount(amount, snapshot.holderBalance)
        );

        _executeSeize(stablecoinContract, from, to, amount, snapshot.holderBalance);

        _requireSeizePostConditions(stablecoinContract, from, to, amount, snapshot);

        emit Seized(stablecoinContract, from, to, amount, msg.sender);
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

    /// @dev Asserts the move conserved every balance and left the stablecoin as it was found.
    function _requireSeizePostConditions(
        address stablecoinContract,
        address from,
        address to,
        uint256 amount,
        SeizeSnapshot memory snapshot
    ) private view {
        IPausableERC20 stablecoin = IPausableERC20(stablecoinContract);

        _requireBalance(stablecoin, from, snapshot.holderBalance - amount);
        _requireBalance(stablecoin, to, snapshot.destinationBalance + amount);
        _requireBalance(stablecoin, address(this), snapshot.controllerBalance);

        uint256 totalSupplyAfter = stablecoin.totalSupply();
        require(
            totalSupplyAfter == snapshot.totalSupply,
            SeizeTotalSupplyChanged(snapshot.totalSupply, totalSupplyAfter)
        );
        require(stablecoin.paused() == snapshot.paused, PauseStateNotRestored(snapshot.paused));
        require(_isHolderBlocked(stablecoinContract, from), HolderNotBlocked(from));
    }

    function _requireBalance(IPausableERC20 stablecoin, address account, uint256 expectedBalance)
        private
        view
    {
        uint256 actualBalance = stablecoin.balanceOf(account);
        require(
            actualBalance == expectedBalance,
            SeizeBalanceMismatch(account, expectedBalance, actualBalance)
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

    /// @dev Returns whether `holder` is frozen on the stablecoin.
    function _isHolderBlocked(address stablecoinContract, address holder)
        internal
        view
        virtual
        returns (bool);

    /**
     * @dev Moves `amount` of `from`'s coins to `to`. Called only after every pre-check passed.
     * Must leave supply, this controller's balance, the pause state, and the freeze on `from`
     * exactly as found; {seize} asserts all of them afterwards.
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
