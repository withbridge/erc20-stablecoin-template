// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface StablecoinTemplateV3ErrorsAndEvents {

    event Minted(uint256 amount, address indexed to, address indexed sender);
    event Burned(uint256 amount, address indexed sender);
    event BurnedFromBlockedAddress(uint256 amount, address indexed account, address indexed sender);
    event MaxSupplySet(uint256 value, address indexed sender);
    event BlockedAddress(address indexed account, address indexed sender);
    event UnblockedAddress(address indexed account, address indexed sender);
    event AddedMintRecipient(address indexed account, address indexed sender);
    event RemovedMintRecipient(address indexed account, address indexed sender);
    event Unwrapped(uint256 amount, address indexed sender);
    event TransferPolicyIdSet(address indexed sender,uint64 policyId);

    error AddressBlocked();
    error AdminCannotBeZeroAddress();
    error MaxSupplyExceeded();
    error AccountNotValidRecipient();
    error AddressIsNotBlocked();
    error NoBalanceToBurn();
    error MaxSupplyMustBeGreaterThanOrEqualToTotalSupply();
    error CannotRevokeLastAdminRole();
    error OnlyOwnerOrAdmin();
    error ReserveLedgerBalanceMismatch();

}
