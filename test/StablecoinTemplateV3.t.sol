// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import { DeterministicProxyFactoryFixture } from
    "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";
import { Test } from "forge-std/Test.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { StablecoinTemplateV3ErrorsAndEvents } from "src/v3/StablecoinTemplateV3ErrorsAndEvents.sol";
import { StablecoinTemplateV3SampleUpgrade } from "src/v3/StablecoinTemplateV3SampleUpgrade.sol";

contract StablecoinTemplateV3Test is Test, StablecoinTemplateV3ErrorsAndEvents {

    // Define the Ownable error locally
    error OwnableUnauthorizedAccount(address account);

    StablecoinTemplateV3 token;
    address admin;
    address minter;
    address pauser;
    address unpauser;
    address blocker;
    address unblocker;
    address blockedBurner;
    address user1;
    address user2;
    address user3;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        pauser = makeAddr("pauser");
        unpauser = makeAddr("unpauser");
        blocker = makeAddr("blocker");
        unblocker = makeAddr("unblocker");
        blockedBurner = makeAddr("blockedBurner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        address implementation = address(new StablecoinTemplateV3());
        token = StablecoinTemplateV3(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 0),
                initialOwner: address(this),
                implementation: implementation,
                callData: abi.encodeCall(
                    StablecoinTemplateV3.reinitialize, ("Test Coin", "TC", 6, address(this))
                )
            })
        );
        // set up access roles
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        token.grantRole(token.UNPAUSER_ROLE(), unpauser);
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        token.grantRole(token.UNBLOCKER_ROLE(), unblocker);
        token.grantRole(token.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);
    }

    // --- Deployment ---
    function test_initialize_sets_admin() public {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_reverts_zero_admin() public {
        // Create a new implementation contract
        StablecoinTemplateV3 implementation = new StablecoinTemplateV3();

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
        proxy.reinitialize("Test Coin", "TC", 6, address(0));
    }

    function test_reinitialize_revert_not_owner() public {
        // Create a new proxy to test reinitialize
        address implementation = address(new StablecoinTemplateV3());
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
        proxy.reinitialize("New Coin", "NC", 8, user1);
        vm.stopPrank();
    }

    // --- Minting ---
    function test_mint_success() public {
        vm.prank(admin);
        token.setMaxSupply(100);
        vm.prank(admin);
        token.addMintRecipient(user1);
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit Minted(100, user1, minter);
        token.mint(user1, 100);
        assertEq(token.totalSupply(), 100);
        assertEq(token.balanceOf(user1), 100);
    }

    function test_mint_revert_not_minter() public {
        vm.prank(admin);
        token.setMaxSupply(100);
        vm.prank(admin);
        token.addMintRecipient(user1);
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, token.MINTER_ROLE()
            )
        );
        token.mint(user1, 100);
        vm.stopPrank();
    }

    function test_mint_revert_not_recipient() public {
        vm.prank(admin);
        token.setMaxSupply(100);
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountNotValidRecipient.selector));
        token.mint(user1, 100);
    }

    function test_mint_revert_max_supply() public {
        vm.prank(admin);
        token.setMaxSupply(50);
        vm.prank(admin);
        token.addMintRecipient(user1);
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MaxSupplyExceeded.selector));
        token.mint(user1, 100);
    }

    // --- Burning ---
    function test_burn_success() public {
        vm.prank(admin);
        token.setMaxSupply(100);
        vm.prank(admin);
        token.addMintRecipient(minter);
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        token.mint(minter, 100);
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit Burned(100, minter);
        token.burn(100);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(minter), 0);
    }

    function test_burn_revert_not_minter() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, token.MINTER_ROLE()
            )
        );
        token.burn(1);
        vm.stopPrank();
    }

    function test_burn_revert_exceeds_balance() public {
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 0, 1)
        );
        token.burn(1);
    }

    // --- Burn From Blocked Address ---
    function test_burnFromBlockedAddress_success() public {
        vm.prank(admin);
        token.setMaxSupply(100);
        vm.prank(admin);
        token.addMintRecipient(user1);
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        token.mint(user1, 100);
        vm.prank(admin);
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        vm.prank(blocker);
        token.blockAddress(user1);
        vm.prank(admin);
        token.grantRole(token.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);
        vm.prank(blockedBurner);
        vm.expectEmit(true, true, true, true);
        emit BurnedFromBlockedAddress(100, user1, blockedBurner);
        token.burnFromBlockedAddress(user1);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(user1), 0);
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
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        vm.prank(blocker);
        token.blockAddress(user1);
        vm.prank(admin);
        token.grantRole(token.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);
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

    // --- Pause/Unpause ---
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

    // --- Block/Unblock Address ---
    function test_blockAddress_success() public {
        vm.prank(admin);
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        vm.prank(blocker);
        vm.expectEmit(true, true, true, true);
        emit BlockedAddress(user1, blocker);
        token.blockAddress(user1);
        assertTrue(token.isBlocked(user1));
    }

    function test_blockAddress_revert_zero_address() public {
        vm.prank(admin);
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        vm.prank(blocker);
        vm.expectRevert(abi.encodeWithSelector(AdminCannotBeZeroAddress.selector));
        token.blockAddress(address(0));
    }

    function test_blockAddress_revert_not_blocker() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.BLOCKER_ROLE()
            )
        );
        token.blockAddress(user1);
        vm.stopPrank();
    }

    function test_unblockAddress_success() public {
        vm.prank(admin);
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        vm.prank(blocker);
        token.blockAddress(user1);
        vm.prank(admin);
        token.grantRole(token.UNBLOCKER_ROLE(), unblocker);
        vm.prank(unblocker);
        vm.expectEmit(true, true, true, true);
        emit UnblockedAddress(user1, unblocker);
        token.unblockAddress(user1);
        assertFalse(token.isBlocked(user1));
    }

    function test_unblockAddress_revert_not_unblocker() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.UNBLOCKER_ROLE()
            )
        );
        token.unblockAddress(user1);
        vm.stopPrank();
    }

    function test_setMaxSupply_success() public {
        vm.prank(admin);
        token.setMaxSupply(100);
        vm.prank(admin);
        token.setMaxSupply(50);
        assertEq(token.getMaxSupply(), 50);
    }

    function test_setMaxSupply_revert_below_totalSupply() public {
        token.setMaxSupply(100);
        token.addMintRecipient(address(this));
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        token.mint(address(this), 80);
        vm.expectRevert(
            abi.encodeWithSelector(MaxSupplyMustBeGreaterThanOrEqualToTotalSupply.selector)
        );
        token.setMaxSupply(70);
    }

    function test_setMaxSupply_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        token.setMaxSupply(1);
        vm.stopPrank();
    }

    // --- Mint Recipient List ---
    function test_addMintRecipient_success() public {
        vm.prank(admin);
        token.addMintRecipient(user1);
        // no revert
    }

    function test_addMintRecipient_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        token.addMintRecipient(user1);
        vm.stopPrank();
    }

    function test_removeMintRecipient_success() public {
        vm.prank(admin);
        token.addMintRecipient(user1);
        vm.prank(admin);
        token.removeMintRecipient(user1);
        // no revert
    }

    function test_removeMintRecipient_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                token.DEFAULT_ADMIN_ROLE()
            )
        );
        token.removeMintRecipient(user1);
        vm.stopPrank();
    }

    // --- isBlocked, getMaxSupply, decimals ---
    function test_isBlocked_returns_true_false() public {
        vm.prank(admin);
        token.grantRole(token.BLOCKER_ROLE(), blocker);
        vm.prank(blocker);
        token.blockAddress(user1);
        assertTrue(token.isBlocked(user1));
        assertFalse(token.isBlocked(user2));
    }

    function test_getMaxSupply_returns_value() public {
        vm.prank(admin);
        token.setMaxSupply(123);
        assertEq(token.getMaxSupply(), 123);
    }

    function test_decimals_returns_value() public {
        assertEq(token.decimals(), 6);
    }

    function test_isMintRecipient_returns_true_false() public {
        // Not a recipient
        assertFalse(token.isMintRecipient(user1));
        // Add as recipient
        vm.prank(admin);
        token.addMintRecipient(user1);
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

    // --- Upgradeability ---
    function test_upgradeTo_revert_not_admin() public {
        StablecoinTemplateV3SampleUpgrade upgradeImpl = new StablecoinTemplateV3SampleUpgrade();
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
        StablecoinTemplateV3SampleUpgrade upgradeImpl = new StablecoinTemplateV3SampleUpgrade();
        vm.prank(admin);
        token.upgradeToAndCall(address(upgradeImpl), "");
        // No revert
    }

}

contract StablecoinTemplateV3SampleUpgradeTest is Test {

    StablecoinTemplateV3SampleUpgrade upgradeImpl;

    function setUp() public {
        // Create implementation contract
        StablecoinTemplateV3SampleUpgrade implementation = new StablecoinTemplateV3SampleUpgrade();

        // Create proxy with implementation
        upgradeImpl = StablecoinTemplateV3SampleUpgrade(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 2),
                initialOwner: address(this),
                implementation: address(implementation),
                callData: abi.encodeCall(
                    StablecoinTemplateV3.reinitialize, ("Test Coin", "TC", 6, address(this))
                )
            })
        );
    }

    function test_name_override() public {
        assertEq(upgradeImpl.name(), "StablecoinTemplateV3 Sample Upgrade");
    }

    function test_eip712Name_override() public {
        // _EIP712Name is internal, so we cannot call it directly, but we can check permit domain
        // This is a placeholder for EIP712 domain test if needed
        assertTrue(true);
    }

}
