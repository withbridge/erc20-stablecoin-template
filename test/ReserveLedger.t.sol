// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import {
    DeterministicProxyFactoryFixture
} from "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";
import { Test } from "forge-std/Test.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";

import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";
import {
    StablecoinTemplateV3ErrorsAndEvents
} from "src/v3/StablecoinTemplateV3ErrorsAndEvents.sol";

contract ReserveLedgerTest is Test, StablecoinTemplateV3ErrorsAndEvents {

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

        address reserveLedgerImplementation = address(new ReserveLedger(address(authRegistry)));
        reserveLedger = ReserveLedger(
            DeterministicProxyFactoryFixture.deterministicProxyOZ({
                initialProxySalt: PermissionedSalt.createPermissionedSalt(address(this), 4),
                initialOwner: address(this),
                implementation: reserveLedgerImplementation,
                callData: abi.encodeCall(
                    StablecoinTemplateV3Base.reinitialize, ("Test Reserve", "TR", 6, address(this))
                )
            })
        );

        // set up access roles
        reserveLedger.grantRole(reserveLedger.MINTER_ROLE(), minter);
        reserveLedger.grantRole(reserveLedger.UNWRAPPER_ROLE(), minter);
        reserveLedger.grantRole(reserveLedger.PAUSER_ROLE(), pauser);
        reserveLedger.grantRole(reserveLedger.UNPAUSER_ROLE(), unpauser);
        reserveLedger.grantRole(reserveLedger.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);

        // set up transfer policy
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit TransferPolicyIdSet(admin, transferPolicyId);
        reserveLedger.setTransferPolicyId(transferPolicyId);

        assertEq(reserveLedger.getTransferPolicyId(), transferPolicyId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Deployment Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize() public {
        address reserveLedgerImplementation = address(new ReserveLedger(address(authRegistry)));
        bytes memory callData =
            abi.encodeCall(StablecoinTemplateV3Base.initialize, ("Test Reserve", "TR", 6, admin));

        ERC1967Proxy proxy = new ERC1967Proxy(reserveLedgerImplementation, callData);

        ReserveLedger reserveToken = ReserveLedger(address(proxy));
        assertTrue(reserveToken.hasRole(reserveToken.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(reserveToken.name(), "Test Reserve");
        assertEq(reserveToken.symbol(), "TR");
        assertEq(reserveToken.decimals(), 6);
        assertEq(reserveToken.getMaxSupply(), 0);
        assertEq(reserveToken.owner(), admin);

        reserveToken.reinitialize("New Reserve", "NR", 8, minter);
        assertTrue(reserveToken.hasRole(reserveToken.DEFAULT_ADMIN_ROLE(), minter));
        assertEq(reserveToken.name(), "New Reserve");
        assertEq(reserveToken.symbol(), "NR");
        assertEq(reserveToken.decimals(), 8);
        assertEq(reserveToken.getMaxSupply(), 0);
        assertEq(reserveToken.owner(), minter);
    }

    function test_initialize_sets_admin() public view {
        assertTrue(reserveLedger.hasRole(reserveLedger.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_initialize_reverts_zero_admin() public {
        // Create a new implementation contract
        ReserveLedger implementation = new ReserveLedger(address(authRegistry));

        // Create a proxy with the implementation but without initialization
        ReserveLedger proxy = ReserveLedger(
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
        proxy.reinitialize("Test Reserve", "TR", 6, address(0));
    }

    function test_reinitialize_revert_not_owner() public {
        // Create a new proxy to test reinitialize
        address implementation = address(new ReserveLedger(address(authRegistry)));
        ReserveLedger proxy = ReserveLedger(
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
        proxy.reinitialize("New Reserve", "NR", 6, user1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Minting Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        reserveLedger.addMintRecipient(user1);
        vm.stopPrank();

        vm.startPrank(minter);
        vm.expectEmit(true, true, true, true);
        emit Minted(100, user1, minter);
        reserveLedger.mint(user1, 100);
        assertEq(reserveLedger.totalSupply(), 100);
        assertEq(reserveLedger.balanceOf(user1), 100);
        vm.stopPrank();
    }

    function test_mint_revert_not_minter() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        reserveLedger.addMintRecipient(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.MINTER_ROLE()
            )
        );
        reserveLedger.mint(user1, 100);
        vm.stopPrank();
    }

    function test_mint_revert_not_recipient() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(AccountNotValidRecipient.selector));
        reserveLedger.mint(user1, 100);
    }

    function test_mint_revert_max_supply() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(50);
        reserveLedger.addMintRecipient(user1);
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MaxSupplyExceeded.selector));
        reserveLedger.mint(user1, 100);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Burning Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_burn_success() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        reserveLedger.addMintRecipient(minter);
        vm.stopPrank();

        vm.startPrank(minter);
        reserveLedger.mint(minter, 100);
        vm.expectEmit(true, true, true, true);
        emit Burned(100, minter);
        reserveLedger.burn(100);
        assertEq(reserveLedger.totalSupply(), 0);
        assertEq(reserveLedger.balanceOf(minter), 0);
        vm.stopPrank();
    }

    function test_burn_revert_not_minter() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.MINTER_ROLE()
            )
        );
        reserveLedger.burn(100);
        vm.stopPrank();
    }

    function test_burn_revert_exceeds_balance() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 0, 1)
        );
        reserveLedger.burn(1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Burn From Blocked Address Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_burnFromBlockedAddress_success() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        reserveLedger.addMintRecipient(user1);
        vm.stopPrank();

        vm.startPrank(minter);
        reserveLedger.mint(user1, 100);
        vm.stopPrank();

        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);

        vm.prank(blockedBurner);
        vm.expectEmit(true, true, true, true);
        emit BurnedFromBlockedAddress(100, user1, blockedBurner);
        reserveLedger.burnFromBlockedAddress(user1);
        assertEq(reserveLedger.totalSupply(), 0);
        assertEq(reserveLedger.balanceOf(user1), 0);
    }

    function test_burnFromBlockedAddress_revert_not_blocked() public {
        vm.prank(blockedBurner);
        vm.expectRevert(abi.encodeWithSelector(AddressIsNotBlocked.selector));
        reserveLedger.burnFromBlockedAddress(user1);
    }

    function test_burnFromBlockedAddress_revert_no_balance() public {
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        vm.prank(blockedBurner);
        vm.expectRevert(abi.encodeWithSelector(NoBalanceToBurn.selector));
        reserveLedger.burnFromBlockedAddress(user1);
    }

    function test_burnFromBlockedAddress_revert_not_burner() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.BLOCKED_ADDRESS_BURNER_ROLE()
            )
        );
        reserveLedger.burnFromBlockedAddress(user1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Pausability Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_pause_unpause_success() public {
        vm.prank(pauser);
        reserveLedger.pause();
        assertTrue(reserveLedger.paused());
        vm.prank(unpauser);
        reserveLedger.unpause();
        assertFalse(reserveLedger.paused());
    }

    function test_pause_revert_not_pauser() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.PAUSER_ROLE()
            )
        );
        reserveLedger.pause();
        vm.stopPrank();
    }

    function test_unpause_revert_not_unpauser() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.UNPAUSER_ROLE()
            )
        );
        reserveLedger.unpause();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Blocking/Unblocking Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_blockAddress_success() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        reserveLedger.addMintRecipient(user1);
        vm.stopPrank();

        vm.prank(minter);
        reserveLedger.mint(user1, 100);

        vm.prank(user1);
        assertTrue(reserveLedger.transfer(user2, 50));

        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        assertTrue(reserveLedger.isBlocked(user1));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(AddressBlocked.selector));
        assertFalse(reserveLedger.transfer(user2, 100));
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
        assertTrue(reserveLedger.isBlocked(user1));
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, false);
        assertFalse(reserveLedger.isBlocked(user1));
    }

    function test_unblockAddress_revert_not_unblocker() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAuthRegistry.Unauthorized.selector));
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, false);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Max Supply Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_setMaxSupply_success() public {
        vm.prank(admin);
        reserveLedger.setMaxSupply(50);
        assertEq(reserveLedger.getMaxSupply(), 50);
    }

    function test_setMaxSupply_revert_below_totalSupply() public {
        vm.startPrank(admin);
        reserveLedger.setMaxSupply(100);
        reserveLedger.addMintRecipient(minter);
        reserveLedger.addMintRecipient(address(this));
        vm.stopPrank();

        vm.prank(minter);
        reserveLedger.mint(address(this), 100);

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(MaxSupplyMustBeGreaterThanOrEqualToTotalSupply.selector)
        );
        reserveLedger.setMaxSupply(70);
        vm.stopPrank();
    }

    function test_setMaxSupply_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.DEFAULT_ADMIN_ROLE()
            )
        );
        reserveLedger.setMaxSupply(1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Mint Recipient List Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_addMintRecipient_success() public {
        vm.prank(admin);
        reserveLedger.addMintRecipient(user1);
    }

    function test_addMintRecipient_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.DEFAULT_ADMIN_ROLE()
            )
        );
        reserveLedger.addMintRecipient(user1);
        vm.stopPrank();
    }

    function test_removeMintRecipient_success() public {
        vm.prank(admin);
        reserveLedger.addMintRecipient(user1);
        vm.prank(admin);
        reserveLedger.removeMintRecipient(user1);
        // no revert
    }

    function test_removeMintRecipient_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.DEFAULT_ADMIN_ROLE()
            )
        );
        reserveLedger.removeMintRecipient(user1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                      isBlocked, getMaxSupply, decimals Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_isBlocked_returns_true_false() public {
        vm.prank(admin);
        authRegistry.modifyPolicyBlacklist(transferPolicyId, user1, true);
        assertTrue(reserveLedger.isBlocked(user1));
        assertFalse(reserveLedger.isBlocked(user2));
    }

    function test_getMaxSupply_returns_value() public {
        vm.prank(admin);
        reserveLedger.setMaxSupply(123);
        assertEq(reserveLedger.getMaxSupply(), 123);
    }

    function test_decimals_returns_value() public view {
        assertEq(reserveLedger.decimals(), 6);
    }

    function test_isMintRecipient_returns_true_false() public {
        // Not a recipient
        assertFalse(reserveLedger.isMintRecipient(user1));
        // Add as recipient
        vm.prank(admin);
        reserveLedger.addMintRecipient(user1);
        assertTrue(reserveLedger.isMintRecipient(user1));
    }

    function test_revokeRole_non_admin_role() public {
        // Grant and then revoke MINTER_ROLE
        vm.prank(admin);
        reserveLedger.grantRole(reserveLedger.MINTER_ROLE(), minter);
        assertTrue(reserveLedger.hasRole(reserveLedger.MINTER_ROLE(), minter));
        vm.prank(admin);
        reserveLedger.revokeRole(reserveLedger.MINTER_ROLE(), minter);
        assertFalse(reserveLedger.hasRole(reserveLedger.MINTER_ROLE(), minter));
    }

    function test_revokeRole_admin_role_multiple_admins() public {
        // Add a second admin
        address admin2 = makeAddr("admin2");
        vm.prank(admin);
        reserveLedger.grantRole(reserveLedger.DEFAULT_ADMIN_ROLE(), admin2);
        assertTrue(reserveLedger.hasRole(reserveLedger.DEFAULT_ADMIN_ROLE(), admin2));
        // Revoke admin2
        vm.prank(admin);
        reserveLedger.revokeRole(reserveLedger.DEFAULT_ADMIN_ROLE(), admin2);
        assertFalse(reserveLedger.hasRole(reserveLedger.DEFAULT_ADMIN_ROLE(), admin2));
    }

    function test_revokeRole_admin_role_reverts_on_last_admin() public {
        // Only one admin (the test contract)
        assertEq(reserveLedger.getRoleMemberCount(reserveLedger.DEFAULT_ADMIN_ROLE()), 1);

        // Get the role value BEFORE expectRevert
        bytes32 adminRole = reserveLedger.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(CannotRevokeLastAdminRole.selector));
        reserveLedger.revokeRole(adminRole, admin);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Access Control Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_grantRole_admin_reverts_zero_address() public {
        bytes32 role = reserveLedger.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AdminCannotBeZeroAddress.selector));
        reserveLedger.grantRole(role, address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Upgrade Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_upgradeTo_revert_not_admin() public {
        address upgradeImpl = address(new ReserveLedger(address(authRegistry)));
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                reserveLedger.DEFAULT_ADMIN_ROLE()
            )
        );
        reserveLedger.upgradeToAndCall(upgradeImpl, "");
        vm.stopPrank();
    }

    function test_upgradeTo_success() public {
        address upgradeImpl = address(new ReserveLedger(address(authRegistry)));
        vm.prank(admin);
        reserveLedger.upgradeToAndCall(upgradeImpl, "");
        // No revert
    }

}
