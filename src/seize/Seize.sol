// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
/// {IdempotencyKeys}). Implementers store their own seize settings (the TokenAuthority in its seize
/// handlers, the TIP20Controller in itself) and expose them through {_seizureWalletList}.
/// @dev Never reads a list registry itself: each implementer checks the Seizure Wallet list in
/// {_isSeizureWallet} against its own fixed registry (the TokenAuthority through the stablecoin's
/// seize handler, the TIP20Controller through TIP-403), so no shared registry interface is needed.
/// @dev No reentrancy guard: {seize} calls only the admin-configured stablecoin, its seize handler,
/// and its list registry, and none of the supported stablecoins call out during mint, burn, or
/// transfer.
abstract contract Seize is AccessControlEnumerableUpgradeable, ISeize {

    /*//////////////////////////////////////////////////////////////////////////
                                    Constants
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant SEIZER_ROLE = keccak256("SEIZER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISeize
    function seize(address stablecoinContract, address from, address to, uint256 amount)
        external
        onlyRole(SEIZER_ROLE)
    {
        uint64 listId = _seizureWalletList(stablecoinContract);

        // Seizing to the holder would be a no-op that still unblocks it on the partial V2 path, and
        // seizing to this controller would leave coins only a seize could move again.
        require(to != from && to != address(this), InvalidSeizeDestination(to));
        require(_isSeizureWallet(stablecoinContract, listId, to), DestinationNotSeizureWallet(to));
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

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the list ID holding the stablecoin's Seizure Wallets.
     * Must revert with {SeizeNotConfigured} when the stablecoin has no seize settings.
     */
    function _seizureWalletList(address stablecoinContract)
        internal
        view
        virtual
        returns (uint64 listId);

    /**
     * @dev Returns whether `account` is on Seizure Wallet list `listId` in the implementer's fixed
     * registry. Must revert with {InvalidSeizureWalletList} when the list authorizes the seizing
     * controller itself: a whitelist of Bridge-held Seizure Wallets never contains it, while the
     * built-in allow-all policy (1) and every blacklist-type list authorize it by default, so this
     * one probe rejects all of them.
     */
    function _isSeizureWallet(address stablecoinContract, uint64 listId, address account)
        internal
        view
        virtual
        returns (bool);

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
