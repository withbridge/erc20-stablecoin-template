// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import {
    DeterministicProxyFactoryFixture
} from "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";
import { Test } from "forge-std/Test.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";

import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";
import {
    StablecoinTemplateV3ErrorsAndEvents
} from "src/v3/StablecoinTemplateV3ErrorsAndEvents.sol";
import { StablecoinTemplateV3SampleUpgrade } from "src/v3/StablecoinTemplateV3SampleUpgrade.sol";

contract StablecoinTemplateV3Test is Test, StablecoinTemplateV3ErrorsAndEvents {

    // Define the Ownable error locally
    error OwnableUnauthorizedAccount(address account);

    StablecoinTemplateV3 token;
    ReserveLedger reserveLedger;
    address admin;
    address minter;
    address pauser;
    address unpauser;
    address blockedBurner;
    address user1;
    address user2;
    address user3;
    AuthRegistry authRegistry;
    uint64 transferPolicyId;
    uint64 mintRecipientPolicyId;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        blockedBurner = makeAddr("blockedBurner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        authRegistry = new AuthRegistry();
        transferPolicyId = authRegistry.createPolicy(admin, IAuthRegistry.PolicyType.BLACKLIST);
        mintRecipientPolicyId = authRegistry.createPolicy(admin, IAuthRegistry.PolicyType.WHITELIST);

        address reserveLedgerImplementation = address(new ReserveLedger(address(authRegistry)));
        reserveLedger = ReserveLedger(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 4),
                initialOwner: address(this),
                implementation: reserveLedgerImplementation,
                callData: abi.encodeCall(
                    StablecoinTemplateV3Base.reinitialize,
                    (
                        "Test Reserve",
                        "TR",
                        6,
                        address(this),
                        transferPolicyId,
                        mintRecipientPolicyId
                    )
                )
            })
        );

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit TransferPolicyIdSet(admin, transferPolicyId);
        reserveLedger.setTransferPolicyId(transferPolicyId);

        assertEq(reserveLedger.getTransferPolicyId(), transferPolicyId);

        address implementation =
            address(new StablecoinTemplateV3(address(reserveLedger), address(authRegistry)));
        token = StablecoinTemplateV3(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 0),
                initialOwner: address(this),
                implementation: implementation,
                callData: abi.encodeCall(
                    StablecoinTemplateV3Base.reinitialize,
                    ("Test Coin", "TC", 6, address(this), transferPolicyId, mintRecipientPolicyId)
                )
            })
        );

        // set up transfer policy
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit TransferPolicyIdSet(admin, transferPolicyId);
        token.setTransferPolicyId(transferPolicyId);

        // set up mint recipient policy
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit MintRecipientPolicyIdSet(admin, mintRecipientPolicyId);
        reserveLedger.setMintRecipientPolicyId(mintRecipientPolicyId);

        authRegistry.modifyPolicyWhitelist(mintRecipientPolicyId, user1, true);
        authRegistry.modifyPolicyWhitelist(mintRecipientPolicyId, minter, true);
        authRegistry.modifyPolicyWhitelist(mintRecipientPolicyId, address(this), true);
        vm.stopPrank();

        assertEq(token.getTransferPolicyId(), transferPolicyId);
        assertEq(token.getMintRecipientPolicyId(), mintRecipientPolicyId);

        // set up access roles
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        token.grantRole(token.UNPAUSER_ROLE(), unpauser);
        token.grantRole(token.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);

        // set up reserve ledger
        reserveLedger.setMaxSupply(100);
        reserveLedger.grantRole(reserveLedger.MINTER_ROLE(), admin);
        reserveLedger.grantRole(reserveLedger.MINTER_ROLE(), address(token));
        reserveLedger.mint(address(minter), 100);

        vm.prank(minter);
        reserveLedger.approve(address(token), 100);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Deployment Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_sets_admin() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_reverts_zero_admin() public {
        // Create a new implementation contract
        StablecoinTemplateV3 implementation =
            new StablecoinTemplateV3(address(reserveLedger), address(authRegistry));

        // Create a proxy with the implementation but without initialization
        StablecoinTemplateV3 proxy = StablecoinTemplateV3(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 1),
                initialOwner: address(this),
                implementation: address(implementation),
                callData: ""
            })
        );

        // The proxy should revert with AdminCannotBeZeroAddress when trying to initialize with zero
        // address
        vm.expectRevert(abi.encodeWithSelector(AdminCannotBeZeroAddress.selector));
        proxy.reinitialize(
            "Test Coin", "TC", 6, address(0), transferPolicyId, mintRecipientPolicyId
        );
    }

    function test_reinitialize_revert_not_owner() public {
        // Create a new proxy to test reinitialize
        address implementation =
            address(new StablecoinTemplateV3(address(reserveLedger), address(authRegistry)));
        StablecoinTemplateV3 proxy = StablecoinTemplateV3(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 1),
                initialOwner: address(this),
                implementation: implementation,
                callData: ""
            })
        );

        // Try to reinitialize as a non-owner
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(OnlyOwnerOrAdmin.selector));
        proxy.reinitialize("New Coin", "NC", 8, user1, transferPolicyId, mintRecipientPolicyId);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Minting / Wrapping Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit Wrapped(100, user1, minter);
        token.wrap(user1, 100);
        assertEq(token.totalSupply(), 100);
        assertEq(token.balanceOf(user1), 100);
    }

    function test_mint_revert_no_allowance() public {
        vm.startPrank(user1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(token), 0, 100
            )
        );
        token.wrap(user1, 100);
        vm.stopPrank();
    }

    function test_mint_revert_not_recipient() public {
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountNotValidRecipient.selector));
        token.wrap(user2, 100);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Burning / Unwrapping Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_burn_success() public {
        vm.startPrank(minter);
        reserveLedger.approve(address(token), 100);
        token.wrap(address(minter), 100);
        vm.stopPrank();

        vm.startPrank(minter);
        vm.expectEmit(true, true, true, true);
        emit Unwrapped(100, minter);
        token.unwrap(100);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(minter), 0);
    }

    function test_burn_revert_not_unwrapper() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, token.MINTER_ROLE()
            )
        );
        token.unwrap(1);
        vm.stopPrank();
    }

    function test_burn_revert_exceeds_balance() public {
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 0, 1)
        );
        token.unwrap(1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Burn From Blocked Address Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_transferFromBlockedAddress_success() public {
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);

        vm.stopPrank();

        vm.startPrank(minter);
        reserveLedger.approve(address(token), 100);
        token.wrap(user1, 100);
        vm.stopPrank();

        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);

        vm.prank(blockedBurner);
        vm.expectEmit(true, true, true, true);
        emit BurnedFromBlockedAddress(100, user1, blockedBurner);
        token.burnFromBlockedAddress(user1);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(user1), 0);
        assertEq(reserveLedger.balanceOf(blockedBurner), 100);
    }

    function test_burnFromBlockedAddress_revert_not_blocked() public {
        vm.prank(admin);
        token.grantRole(token.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);
        vm.prank(blockedBurner);
        vm.expectRevert(abi.encodeWithSelector(AddressIsNotBlocked.selector));
        token.burnFromBlockedAddress(user1);
    }

    function test_burnFromBlockedAddress_revert_no_balance() public {
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        vm.prank(blockedBurner);
        vm.expectRevert(abi.encodeWithSelector(NoBalanceToBurn.selector));
        token.burnFromBlockedAddress(user1);
    }

    function test_burnFromBlockedAddress_revert_not_burner() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.BLOCKED_ADDRESS_BURNER_ROLE()
            )
        );
        token.burnFromBlockedAddress(user1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Pausability Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_pause_unpause_success() public {
        vm.prank(admin);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        vm.prank(pauser);
        token.pause();
        assertTrue(token.paused());
        vm.prank(admin);
        token.grantRole(token.UNPAUSER_ROLE(), unpauser);
        vm.prank(unpauser);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_pause_revert_not_pauser() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, token.PAUSER_ROLE()
            )
        );
        token.pause();
        vm.stopPrank();
    }

    function test_unpause_revert_not_unpauser() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.UNPAUSER_ROLE()
            )
        );
        token.unpause();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Blocking/Unblocking Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_blockAddress_success() public {
        vm.prank(minter);
        token.wrap(user1, 100);

        vm.prank(user1);
        assertTrue(token.transfer(user2, 50));

        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        assertTrue(token.isBlocked(user1));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AddressBlocked.selector));
        assertFalse(token.transfer(user2, 100));
    }

    function test_blockAddress_revert_not_blocker() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAuthRegistry.Unauthorized.selector));
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        vm.stopPrank();
    }

    function test_unblockAddress_success() public {
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        assertTrue(token.isBlocked(user1));
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, false);
        assertFalse(token.isBlocked(user1));
    }

    function test_unblockAddress_revert_not_unblocker() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAuthRegistry.Unauthorized.selector));
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, false);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                      isBlocked, getMaxSupply, decimals Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_isBlocked_returns_true_false() public {
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        assertTrue(token.isBlocked(user1));
        assertFalse(token.isBlocked(user2));
    }

    function test_decimals_returns_value() public view {
        assertEq(token.decimals(), 6);
    }

    function test_isMintRecipient_returns_true_false() public view {
        assertTrue(token.isMintRecipient(user1));
    }

    function test_revokeRole_non_admin_role() public {
        // Grant and then revoke MINTER_ROLE
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        assertTrue(token.hasRole(token.MINTER_ROLE(), minter));
        vm.prank(admin);
        token.revokeRole(token.MINTER_ROLE(), minter);
        assertFalse(token.hasRole(token.MINTER_ROLE(), minter));
    }

    function test_revokeRole_admin_role_multiple_admins() public {
        // Add a second admin
        address admin2 = makeAddr("admin2");
        vm.prank(admin);
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), admin2);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin2));
        // Revoke admin2
        vm.prank(admin);
        token.revokeRole(token.DEFAULT_ADMIN_ROLE(), admin2);
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin2));
    }

    function test_revokeRole_admin_role_reverts_on_last_admin() public {
        // Only one admin (the test contract)
        assertEq(token.getRoleMemberCount(token.DEFAULT_ADMIN_ROLE()), 1);

        // Get the role value BEFORE expectRevert
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(CannotRevokeLastAdminRole.selector));
        token.revokeRole(adminRole, admin);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Legacy Mint/Burn Tests (Pre-Migration)
    //////////////////////////////////////////////////////////////////////////*/

    function test_legacy_mint_success() public {
        // Set max supply to allow legacy mint
        vm.prank(admin);
        token.setMaxSupply(1000);

        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit Minted(50, user1, minter);
        token.mint(user1, 50);

        assertEq(token.totalSupply(), 50);
        assertEq(token.balanceOf(user1), 50);
    }

    function test_legacy_mint_revert_not_recipient() public {
        // Set max supply to allow legacy mint
        vm.prank(admin);
        token.setMaxSupply(1000);

        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountNotValidRecipient.selector));
        token.mint(user2, 50);
    }

    function test_legacy_mint_revert_max_supply() public {
        // Set max supply on the wrapped token
        vm.prank(admin);
        token.setMaxSupply(50);

        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MaxSupplyExceeded.selector));
        token.mint(user1, 100);
    }

    function test_legacy_burn_success() public {
        // Set max supply to allow legacy mint
        vm.prank(admin);
        token.setMaxSupply(1000);

        // First mint some tokens using legacy mint
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        token.mint(user1, 50);

        // Transfer to minter for burning
        vm.prank(user1);
        token.transfer(minter, 50);

        // Now burn
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit Burned(50, minter);
        token.burn(50);

        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(minter), 0);
    }

    function test_legacy_burn_revert_exceeds_balance() public {
        // Set max supply to allow legacy mint
        vm.prank(admin);
        token.setMaxSupply(1000);

        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 0, 100)
        );
        token.burn(100);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Migration Completion Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_completeMigrationToWrapped_success() public {
        // First, wrap some tokens to match reserve ledger balance
        vm.prank(minter);
        token.wrap(user1, 100);

        assertEq(token.totalSupply(), 100);
        assertEq(reserveLedger.balanceOf(address(token)), 100);

        // Complete migration
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit MigrationHasCompleted(admin);
        token.completeMigrationToWrapped();
    }

    function test_completeMigrationToWrapped_revert_balance_mismatch() public {
        // Wrap some tokens
        vm.prank(minter);
        token.wrap(user1, 50);

        assertEq(token.totalSupply(), 50);
        assertEq(reserveLedger.balanceOf(address(token)), 50);

        // Now use legacy mint to create a mismatch
        vm.prank(admin);
        token.setMaxSupply(1000);

        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        token.mint(user1, 25);

        // Now total supply is 75 but reserve ledger balance is only 50
        assertEq(token.totalSupply(), 75);
        assertEq(reserveLedger.balanceOf(address(token)), 50);

        // This should revert because reserve ledger balance doesn't match total supply
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReserveLedgerBalanceMismatch.selector));
        token.completeMigrationToWrapped();
    }

    function test_completeMigrationToWrapped_revert_not_admin() public {
        // Set up valid state for migration
        vm.prank(minter);
        token.wrap(user1, 100);

        // Get the role before the prank
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, adminRole
            )
        );
        token.completeMigrationToWrapped();
    }

    function test_legacy_mint_revert_after_migration() public {
        // Complete migration first
        vm.prank(minter);
        token.wrap(user1, 100);

        vm.prank(admin);
        token.completeMigrationToWrapped();

        // Now try to use legacy mint - should revert
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MigrationToWrappedCompleted.selector));
        token.mint(user1, 50);
    }

    function test_legacy_burn_revert_after_migration() public {
        // Wrap all reserve tokens to complete migration
        vm.prank(minter);
        token.wrap(user1, 100);

        vm.prank(admin);
        token.completeMigrationToWrapped();

        // Grant minter role
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        // Transfer some tokens to minter
        vm.prank(user1);
        token.transfer(minter, 50);

        // Now try to use legacy burn - should revert
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MigrationToWrappedCompleted.selector));
        token.burn(50);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Upgrade Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_upgradeTo_revert_not_admin() public {
        StablecoinTemplateV3SampleUpgrade upgradeImpl =
            new StablecoinTemplateV3SampleUpgrade(address(0), address(authRegistry));
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        token.upgradeToAndCall(address(upgradeImpl), "");
        vm.stopPrank();
    }

    function test_upgradeTo_success() public {
        StablecoinTemplateV3SampleUpgrade upgradeImpl =
            new StablecoinTemplateV3SampleUpgrade(address(0), address(authRegistry));
        vm.prank(admin);
        token.upgradeToAndCall(address(upgradeImpl), "");
        // No revert
    }

}

contract StablecoinTemplateV3SampleUpgradeTest is Test {

    StablecoinTemplateV3SampleUpgrade upgradeImpl;
    AuthRegistry authRegistry;
    uint64 transferPolicyId;
    uint64 mintRecipientPolicyId;

    function setUp() public {
        authRegistry = new AuthRegistry();
        // Create implementation contract
        StablecoinTemplateV3SampleUpgrade implementation =
            new StablecoinTemplateV3SampleUpgrade(address(0), address(authRegistry));

        // Create proxy with implementation
        upgradeImpl = StablecoinTemplateV3SampleUpgrade(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 2),
                initialOwner: address(this),
                implementation: address(implementation),
                callData: abi.encodeCall(
                    StablecoinTemplateV3Base.reinitialize,
                    ("Test Coin", "TC", 6, address(this), transferPolicyId, mintRecipientPolicyId)
                )
            })
        );
    }

    function test_name_override() public view {
        assertEq(upgradeImpl.name(), "StablecoinTemplateV3 Sample Upgrade");
    }

    function test_eip712Name_override() public view {
        // _EIP712Name is internal, but it's used by eip712Domain()
        // We can verify the domain separator is computed correctly with the overridden name
        (, string memory name,,,,,) = upgradeImpl.eip712Domain();

        assertEq(
            name, "StablecoinTemplateV3 Sample Upgrade", "EIP712 domain name should match override"
        );
    }

}
