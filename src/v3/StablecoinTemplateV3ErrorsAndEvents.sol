// SPDX-License-Identifier: MIT
/**
 * @title StablecoinTemplateV3ErrorsAndEvents
 * @notice Interface for common events and errors in Stablecoin Template V3 contracts.
 */
pragma solidity ^0.8.24;

interface StablecoinTemplateV3ErrorsAndEvents {

    /**
     * @notice Emitted when tokens are minted.
     * @param amount The amount of tokens minted.
     * @param to The address receiving the minted tokens.
     * @param sender The address that triggered the mint.
     */
    event Minted(uint256 amount, address indexed to, address indexed sender);

    /**
     * @notice Emitted when tokens are burned.
     * @param amount The amount of tokens burned.
     * @param sender The address whose tokens were burned.
     */
    event Burned(uint256 amount, address indexed sender);

    /**
     * @notice Emitted when the entire balance of a blocked address is burned.
     * @param amount The amount burned (should be the entire balance).
     * @param account The blocked address from which tokens are burned.
     * @param sender The address that triggered the burn.
     */
    event BurnedFromBlockedAddress(uint256 amount, address indexed account, address indexed sender);

    /**
     * @notice Emitted when the maximum supply is set.
     * @param value The new maximum supply.
     * @param sender The address that set the max supply.
     */
    event MaxSupplySet(uint256 value, address indexed sender);

    /**
     * @notice Emitted when an address has been added to the blocked list.
     * @param account The address that was blocked.
     * @param sender The address that added the block.
     */
    event BlockedAddress(address indexed account, address indexed sender);

    /**
     * @notice Emitted when an address has been removed from the blocked list.
     * @param account The address that was unblocked.
     * @param sender The address that removed the block.
     */
    event UnblockedAddress(address indexed account, address indexed sender);

    /**
     * @notice Emitted when an address is added as a valid mint recipient.
     * @param account The address added as mint recipient.
     * @param sender The address that performed the addition.
     */
    event AddedMintRecipient(address indexed account, address indexed sender);

    /**
     * @notice Emitted when an address is removed as a valid mint recipient.
     * @param account The address removed from mint recipients.
     * @param sender The address that performed the removal.
     */
    event RemovedMintRecipient(address indexed account, address indexed sender);

    /**
     * @notice Emitted when wrapped tokens are unwrapped (burned to withdraw underlying).
     * @param amount The amount unwrapped.
     * @param sender The address that performed the unwrapping.
     */
    event Unwrapped(uint256 amount, address indexed sender);

    /**
     * @notice Emitted when the transfer policy ID is updated.
     * @param sender The address that set the policy.
     * @param policyId The new transfer policy ID.
     */
    event TransferPolicyIdSet(address indexed sender, uint64 policyId);

    /**
     * @notice Emitted when the mint recipient policy ID is updated.
     * @param sender The address that set the policy.
     * @param policyId The new mint recipient policy ID.
     */
    event MintRecipientPolicyIdSet(address indexed sender, uint64 policyId);

    /**
     * @notice Emitted when the migration to wrapped is completed.
     * @param sender The address that completed the migration.
     */
    event MigrationHasCompleted(address indexed sender);

    /////////////
    // Errors  //
    /////////////

    /**
     * @notice Thrown when an address is blocked and not allowed to interact.
     */
    error AddressBlocked();

    /**
     * @notice Thrown when the admin address is set to the zero address.
     */
    error AdminCannotBeZeroAddress();

    /**
     * @notice Thrown when a minting operation exceeds the maximum supply.
     */
    error MaxSupplyExceeded();

    /**
     * @notice Thrown when an account is not a valid recipient for minting.
     */
    error AccountNotValidRecipient();

    /**
     * @notice Thrown when trying to operate on an address that is not blocked.
     */
    error AddressIsNotBlocked();

    /**
     * @notice Thrown when attempting to burn and there is no balance to burn.
     */
    error NoBalanceToBurn();

    /**
     * @notice Thrown when max supply is set to less than current total supply.
     */
    error MaxSupplyMustBeGreaterThanOrEqualToTotalSupply();

    /**
     * @notice Thrown when trying to revoke the last admin role, which is not allowed.
     */
    error CannotRevokeLastAdminRole();

    /**
     * @notice Thrown when an operation is restricted to the owner or admin.
     */
    error OnlyOwnerOrAdmin();

    /**
     * @notice Thrown when there is a mismatch in reserve ledger balance.
     */
    error ReserveLedgerBalanceMismatch();

    /**
     * @notice Thrown when the migration to wrapped is completed.
     */
    error MigrationToWrappedCompleted();

    /**
     * @notice Thrown when the migration to wrapped is not completed.
     */
    error MigrationToWrappedNotCompleted();

}
