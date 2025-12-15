// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { ITIP20Controller } from "src/v3/tempo/interfaces/ITIP20Controller.sol";
import { TIP20Controller } from "src/v3/tempo/TIP20Controller.sol";
import { ReserveStore } from "src/v3/tempo/ReserveStore.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";

contract TIP20ControllerTest is Test {

    TIP20Controller controller;
    ReserveStore reserveStore;

    ITIP20 reserveLedgerToken;
    ITIP20 stablecoin;

    address admin;
    address minter;
    address user1;
    address user2;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Use TIP20 tokens from Tempo's precompiles
        reserveLedgerToken = StdTokens.PATH_USD;
        stablecoin = StdTokens.ALPHA_USD;

        // Deploy TIP20Controller implementation
        TIP20Controller implementation = new TIP20Controller(address(reserveLedgerToken), false);

        // Deploy proxy
        bytes memory initData = abi.encodeCall(TIP20Controller.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        controller = TIP20Controller(address(proxy));

        // Grant MINT_RATE_LIMIT_SETTER_ROLE to admin
        controller.grantRole(controller.MINT_RATE_LIMIT_SETTER_ROLE(), admin);

        // Deploy ReserveStore for stablecoin
        reserveStore = new ReserveStore(
            address(reserveLedgerToken),
            address(controller),
            address(stablecoin)
        );

        // Set reserve store in controller
        controller.setReserveStore(address(stablecoin), address(reserveStore));

        // Grant controller the ISSUER_ROLE on stablecoin so it can mint/burn
        vm.prank(address(0)); // System address for granting roles
        ITIP20RolesAuth(address(stablecoin)).grantRole(stablecoin.ISSUER_ROLE(), address(controller));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Initialization Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_failsWhenDisabled() public {
        TIP20Controller newController = new TIP20Controller(address(reserveLedgerToken), true);

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        newController.initialize(admin);
    }

    function test_initialize_sets_admin() public view {
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_immutable_reserve_ledger_token() public view {
        assertEq(controller.RESERVE_LEDGER_TOKEN(), address(reserveLedgerToken));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Mint Rate Limit Setter Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_setTxnMintLimit_success() public {
        uint256 txnLimit = 100;

        vm.prank(admin);
        controller.setTxnMintLimit(address(stablecoin), txnLimit);

        uint256 returnedTxnLimit = controller.getStablecoinTxnMintLimit(address(stablecoin));
        assertEq(returnedTxnLimit, txnLimit);
    }

    function test_setTxnMintLimit_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.MINT_RATE_LIMIT_SETTER_ROLE()
            )
        );
        controller.setTxnMintLimit(address(stablecoin), 100);
        vm.stopPrank();
    }

    function test_setMinterAllowance_success() public {
        uint256 allowance = 500;

        vm.prank(admin);
        controller.setMinterAllowance(address(stablecoin), minter, allowance);

        uint256 returnedAllowance = controller.getMinterAllowance(address(stablecoin), minter);
        assertEq(returnedAllowance, allowance);
    }

    function test_setMinterAllowance_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.MINT_RATE_LIMIT_SETTER_ROLE()
            )
        );
        controller.setMinterAllowance(address(stablecoin), minter, 500);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Reserve Store Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_setReserveStore_success() public view {
        assertEq(controller.getReserveStore(address(stablecoin)), address(reserveStore));
    }

    function test_setReserveStore_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.DEFAULT_ADMIN_ROLE()
            )
        );
        controller.setReserveStore(address(stablecoin), address(reserveStore));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Mint Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        uint256 mintAmount = 50e6; // 50 tokens with 6 decimals

        // Setup limits and allowances
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 100e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        vm.stopPrank();

        // Give minter some reserve tokens and approve controller
        deal(address(reserveLedgerToken), minter, mintAmount);
        vm.prank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);

        // Mint
        vm.prank(minter);
        controller.mint(address(stablecoin), user1, mintAmount);

        // Verify token was minted
        assertEq(stablecoin.balanceOf(user1), mintAmount);

        // Verify reserve tokens moved to ReserveStore
        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), mintAmount);

        // Verify allowance was decremented
        uint256 remainingAllowance = controller.getMinterAllowance(address(stablecoin), minter);
        assertEq(remainingAllowance, 500e6 - mintAmount);
    }

    function test_mint_cannot_be_zero() public {
        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.AmountCannotBeZero.selector);
        controller.mint(address(stablecoin), user1, 0);
    }

    function test_mint_revert_txn_limit_exceeded() public {
        uint256 mintAmount = 100e6;

        // Setup limits where txn limit is less than mint amount
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 50e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        vm.stopPrank();

        // Attempt to mint
        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.MintTxnLimitExceeded.selector);
        controller.mint(address(stablecoin), user1, mintAmount);
    }

    function test_mint_revert_minter_allowance_exceeded() public {
        uint256 mintAmount = 100e6;

        // Setup limits where minter allowance is less than mint amount
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 1000e6);
        controller.setMinterAllowance(address(stablecoin), minter, 50e6);
        vm.stopPrank();

        // Attempt to mint
        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.MinterAllowanceExceeded.selector);
        controller.mint(address(stablecoin), user1, mintAmount);
    }

    function test_mint_revert_reserve_store_not_configured() public {
        ITIP20 unconfiguredToken = StdTokens.BETA_USD;

        vm.startPrank(admin);
        controller.setTxnMintLimit(address(unconfiguredToken), 1000e6);
        controller.setMinterAllowance(address(unconfiguredToken), minter, 500e6);
        vm.stopPrank();

        deal(address(reserveLedgerToken), minter, 100e6);
        vm.prank(minter);
        reserveLedgerToken.approve(address(controller), 100e6);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.ReserveStoreNotConfigured.selector);
        controller.mint(address(unconfiguredToken), user1, 50e6);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Mint Reserve Ledger Token Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_reserve_ledger_token_directly() public {
        uint256 mintAmount = 50e6;

        // Setup limits and allowances for reserve ledger token
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(reserveLedgerToken), 100e6);
        controller.setMinterAllowance(address(reserveLedgerToken), minter, 500e6);
        vm.stopPrank();

        // Give minter some reserve tokens
        deal(address(reserveLedgerToken), minter, mintAmount);
        vm.prank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);

        // Mint reserve ledger tokens directly (transfer, not mint)
        vm.prank(minter);
        controller.mint(address(reserveLedgerToken), user1, mintAmount);

        // Verify tokens were transferred to user1
        assertEq(reserveLedgerToken.balanceOf(user1), mintAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Bridge Ecosystem Contract Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mintBridgeEcosystem_bypasses_limits() public {
        address bridgeContract = makeAddr("bridge");
        uint256 mintAmount = 1000e6;

        // Enable bridge contract
        vm.prank(admin);
        controller.grantRole(controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE(), bridgeContract);

        // Give bridge some reserve tokens
        deal(address(reserveLedgerToken), bridgeContract, mintAmount);
        vm.prank(bridgeContract);
        reserveLedgerToken.approve(address(controller), mintAmount);

        // Bridge contract should be able to mint without limits
        vm.prank(bridgeContract);
        controller.mintBridgeEcosystem(address(stablecoin), user1, mintAmount);

        // Verify tokens were minted
        assertEq(stablecoin.balanceOf(user1), mintAmount);
    }

    function test_mintBridgeEcosystem_revert_not_bridge() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE()
            )
        );
        controller.mintBridgeEcosystem(address(stablecoin), user2, 100e6);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Burn Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_burn_stablecoin_success() public {
        uint256 mintAmount = 100e6;
        uint256 burnAmount = 30e6;

        // Setup and mint first
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 200e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        controller.grantRole(controller.BURNER_ROLE(), minter);
        vm.stopPrank();

        // Mint stablecoins
        deal(address(reserveLedgerToken), minter, mintAmount);
        vm.startPrank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);
        controller.mint(address(stablecoin), minter, mintAmount);

        // Approve controller to burn stablecoins
        stablecoin.approve(address(controller), burnAmount);
        vm.stopPrank();

        uint256 reserveStoreBefore = reserveLedgerToken.balanceOf(address(reserveStore));

        // Burn
        vm.prank(minter);
        controller.burn(address(stablecoin), burnAmount);

        // Verify stablecoin was burned
        assertEq(stablecoin.balanceOf(minter), mintAmount - burnAmount);

        // Verify reserve tokens were also burned (removed from reserve store)
        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), reserveStoreBefore - burnAmount);
    }

    function test_burn_revert_not_burner() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.BURNER_ROLE()
            )
        );
        controller.burn(address(stablecoin), 30e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Unwrap Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_unwrap_success() public {
        uint256 mintAmount = 100e6;
        uint256 unwrapAmount = 30e6;

        // Setup: mint some stablecoins first
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 200e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        controller.grantRole(controller.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        // Mint stablecoins to minter
        deal(address(reserveLedgerToken), minter, mintAmount);
        vm.startPrank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);
        controller.mint(address(stablecoin), minter, mintAmount);

        // Approve controller to take stablecoins
        stablecoin.approve(address(controller), unwrapAmount);
        vm.stopPrank();

        // Unwrap
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit ITIP20Controller.Unwrap(minter, address(stablecoin), unwrapAmount);
        controller.unwrap(address(stablecoin), unwrapAmount);

        // Verify stablecoins were burned
        assertEq(stablecoin.balanceOf(minter), mintAmount - unwrapAmount);

        // Verify reserve tokens were transferred to minter
        assertEq(reserveLedgerToken.balanceOf(minter), unwrapAmount);
    }

    function test_unwrap_revert_not_unwrapper() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.UNWRAPPER_ROLE()
            )
        );
        controller.unwrap(address(stablecoin), 30e6);
        vm.stopPrank();
    }

    function test_unwrap_revert_reserve_store_not_configured() public {
        ITIP20 unconfiguredToken = StdTokens.BETA_USD;

        vm.prank(admin);
        controller.grantRole(controller.UNWRAPPER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.ReserveStoreNotConfigured.selector);
        controller.unwrap(address(unconfiguredToken), 30e6);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Wrap Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_wrap_success() public {
        uint256 wrapAmount = 100e6;

        // Give user1 some reserve tokens
        deal(address(reserveLedgerToken), user1, wrapAmount);

        // User1 approves controller
        vm.prank(user1);
        reserveLedgerToken.approve(address(controller), wrapAmount);

        // Wrap tokens for user2
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit ITIP20Controller.Wrap(user1, address(stablecoin), user2, wrapAmount);
        controller.wrap(address(stablecoin), user2, wrapAmount);

        // Verify user2 received stablecoins
        assertEq(stablecoin.balanceOf(user2), wrapAmount);

        // Verify reserve tokens moved to ReserveStore
        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), wrapAmount);

        // Verify user1's reserve tokens were transferred
        assertEq(reserveLedgerToken.balanceOf(user1), 0);
    }

    function test_wrap_zero_amount_reverts() public {
        vm.prank(user1);
        vm.expectRevert(ITIP20Controller.AmountCannotBeZero.selector);
        controller.wrap(address(stablecoin), user2, 0);
    }

    function test_wrap_revert_reserve_store_not_configured() public {
        ITIP20 unconfiguredToken = StdTokens.BETA_USD;
        uint256 wrapAmount = 100e6;

        deal(address(reserveLedgerToken), user1, wrapAmount);
        vm.prank(user1);
        reserveLedgerToken.approve(address(controller), wrapAmount);

        vm.prank(user1);
        vm.expectRevert(ITIP20Controller.ReserveStoreNotConfigured.selector);
        controller.wrap(address(unconfiguredToken), user2, wrapAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Getter Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_getMinterAllowance_returns_zero_by_default() public view {
        uint256 allowance = controller.getMinterAllowance(address(stablecoin), minter);
        assertEq(allowance, 0);
    }

    function test_getStablecoinTxnMintLimit_returns_zero_by_default() public view {
        uint256 txnLimit = controller.getStablecoinTxnMintLimit(address(stablecoin));
        assertEq(txnLimit, 0);
    }

    function test_getReserveStore_returns_zero_for_unconfigured() public {
        address randomAddr = makeAddr("random");
        address store = controller.getReserveStore(randomAddr);
        assertEq(store, address(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Role Management Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_role_constants() public view {
        bytes32 mintRateLimitSetterRole = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
        bytes32 burnerRole = keccak256("BURNER_ROLE");
        bytes32 unwrapperRole = keccak256("UNWRAPPER_ROLE");
        bytes32 bridgeRole = keccak256("BRIDGE_ECOSYSTEM_CONTRACT_ROLE");

        assertEq(controller.MINT_RATE_LIMIT_SETTER_ROLE(), mintRateLimitSetterRole);
        assertEq(controller.BURNER_ROLE(), burnerRole);
        assertEq(controller.UNWRAPPER_ROLE(), unwrapperRole);
        assertEq(controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE(), bridgeRole);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Upgrade Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_revert_not_admin() public {
        address newImplementation = address(new TIP20Controller(address(reserveLedgerToken), false));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.DEFAULT_ADMIN_ROLE()
            )
        );
        controller.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function test_authorizeUpgrade_success() public {
        address newImplementation = address(new TIP20Controller(address(reserveLedgerToken), false));

        vm.prank(admin);
        controller.upgradeToAndCall(newImplementation, "");
        // No revert - upgrade successful
    }

}
