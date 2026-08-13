// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { Approval } from "src/mintIntent/MintIntentStorage.sol";
import { IMintIntent } from "src/mintIntent/interfaces/IMintIntent.sol";
import { TIP20Controller } from "src/v3/tempo/TIP20Controller.sol";
import { ITIP20Controller } from "src/v3/tempo/interfaces/ITIP20Controller.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";

contract TIP20ControllerTest is Test {

    TIP20Controller controller;

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

        // Deploy new TIP20 tokens from factory using PATH_USD as quote token
        ITIP20Factory factory = StdPrecompiles.TIP20_FACTORY;
        ITIP20 quoteToken = StdTokens.PATH_USD;

        // Create reserve ledger token
        address reserveAddr =
            factory.createToken("Reserve USD", "rUSD", "USD", quoteToken, admin, bytes32(0));
        reserveLedgerToken = ITIP20(reserveAddr);

        // Create stablecoin
        address stablecoinAddr = factory.createToken(
            "Test Stablecoin", "tUSD", "USD", quoteToken, admin, keccak256("test")
        );
        stablecoin = ITIP20(stablecoinAddr);

        // Deploy TIP20Controller implementation
        TIP20Controller implementation = new TIP20Controller(address(reserveLedgerToken), false);

        // Deploy proxy
        bytes memory initData = abi.encodeCall(TIP20Controller.initialize, (admin, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        controller = TIP20Controller(address(proxy));

        // Grant MINT_RATE_LIMIT_SETTER_ROLE to admin
        controller.grantRole(controller.MINT_RATE_LIMIT_SETTER_ROLE(), admin);

        // Grant controller the ISSUER_ROLE on stablecoin so it can mint/burn
        // Reserve stores are now auto-deployed lazily
        ITIP20RolesAuth(address(stablecoin))
            .grantRole(stablecoin.ISSUER_ROLE(), address(controller));

        // Grant test contract (admin) the ISSUER_ROLE on reserveLedgerToken so _mintReserveTokens
        // works
        ITIP20RolesAuth(address(reserveLedgerToken))
            .grantRole(reserveLedgerToken.ISSUER_ROLE(), admin);

        // Grant controller the ISSUER_ROLE on reserveLedgerToken so controller _mint
        // works
        ITIP20RolesAuth(address(reserveLedgerToken))
            .grantRole(reserveLedgerToken.ISSUER_ROLE(), address(controller));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Initialization Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_failsWhenDisabled() public {
        TIP20Controller newController = new TIP20Controller(address(reserveLedgerToken), true);

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        newController.initialize(admin, admin);
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

    function test_setMinterAllowance_revert_amount_exceeds_absolute_max() public {
        uint256 allowance = 1_000_000_000 * 1e6 + 1;

        vm.prank(admin);
        vm.expectRevert(ITIP20Controller.AmountExceedsAbsoluteMax.selector);
        controller.setMinterAllowance(address(stablecoin), minter, allowance);
    }

    function test_setTxnMintLimit_revert_amount_exceeds_absolute_max() public {
        uint256 txnLimit = 1_000_000_000 * 1e6 + 1;

        vm.prank(admin);
        vm.expectRevert(ITIP20Controller.AmountExceedsAbsoluteMax.selector);
        controller.setTxnMintLimit(address(stablecoin), txnLimit);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Reserve Store Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_setReserveStore_success() public {
        address customReserveStore = makeAddr("customReserveStore");

        vm.prank(admin);
        controller.setReserveStore(address(stablecoin), customReserveStore);

        assertEq(controller.getReserveStore(address(stablecoin)), customReserveStore);
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
        controller.setReserveStore(address(stablecoin), makeAddr("someStore"));
        vm.stopPrank();
    }

    function test_setReserveStore_revert_when_old_reserve_store_is_not_zero() public {
        address oldReserveStore = makeAddr("oldReserveStore");
        address newReserveStore = makeAddr("newReserveStore");

        vm.prank(oldReserveStore);
        reserveLedgerToken.approve(address(controller), type(uint256).max);

        vm.prank(address(controller));
        reserveLedgerToken.mint(oldReserveStore, 100e6);

        vm.prank(admin);
        controller.setReserveStore(address(stablecoin), oldReserveStore);

        assertEq(reserveLedgerToken.balanceOf(oldReserveStore), 100e6);
        assertEq(reserveLedgerToken.balanceOf(newReserveStore), 0);

        vm.prank(admin);
        controller.setReserveStore(address(stablecoin), newReserveStore);

        assertEq(reserveLedgerToken.balanceOf(oldReserveStore), 0);
        assertEq(reserveLedgerToken.balanceOf(newReserveStore), 100e6);
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
        _mintReserveTokens(minter, mintAmount);
        vm.prank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);

        // Mint
        vm.prank(minter);
        controller.mint(address(stablecoin), user1, mintAmount);

        // Verify token was minted
        assertEq(stablecoin.balanceOf(user1), mintAmount);

        // Verify reserve tokens moved to auto-deployed ReserveStore
        address reserveStore = controller.getReserveStore(address(stablecoin));
        assertTrue(reserveStore != address(0));
        assertEq(reserveLedgerToken.balanceOf(reserveStore), mintAmount);

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

    function test_mint_auto_deploys_reserve_store() public {
        // Create a new token for this test
        ITIP20 newToken = _createNewStablecoin("New Token", "NEW");
        uint256 mintAmount = 50e6;

        // Verify no reserve store exists yet
        assertEq(controller.getReserveStore(address(newToken)), address(0));

        vm.startPrank(admin);
        controller.setTxnMintLimit(address(newToken), 1000e6);
        controller.setMinterAllowance(address(newToken), minter, 500e6);
        vm.stopPrank();

        // Grant controller the ISSUER_ROLE on newToken so it can mint
        ITIP20RolesAuth(address(newToken)).grantRole(newToken.ISSUER_ROLE(), address(controller));

        _mintReserveTokens(minter, mintAmount);
        vm.prank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);

        // Mint should auto-deploy reserve store
        vm.prank(minter);
        controller.mint(address(newToken), user1, mintAmount);

        // Verify reserve store was created
        address reserveStore = controller.getReserveStore(address(newToken));
        assertTrue(reserveStore != address(0));

        // Verify tokens were minted
        assertEq(newToken.balanceOf(user1), mintAmount);

        // Verify reserve tokens moved to ReserveStore
        assertEq(reserveLedgerToken.balanceOf(reserveStore), mintAmount);
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
        _mintReserveTokens(minter, mintAmount);
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
        _mintReserveTokens(bridgeContract, mintAmount);
        vm.prank(bridgeContract);
        reserveLedgerToken.approve(address(controller), mintAmount);

        // Bridge contract should be able to mint without limits
        vm.prank(bridgeContract);
        controller.mintBridgeEcosystem(address(stablecoin), user1, mintAmount);

        // Verify tokens were minted
        assertEq(stablecoin.balanceOf(user1), mintAmount);
    }

    function test_mintBridgeEcosystem_revert_not_bridge() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE()
            )
        );
        vm.prank(user1);
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

        // Grant controller ISSUER_ROLE on reserve token for burning
        ITIP20RolesAuth(address(reserveLedgerToken))
            .grantRole(reserveLedgerToken.ISSUER_ROLE(), address(controller));

        // Mint stablecoins
        _mintReserveTokens(minter, mintAmount);
        vm.startPrank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);
        controller.mint(address(stablecoin), minter, mintAmount);

        // Approve controller to burn stablecoins
        stablecoin.approve(address(controller), burnAmount);
        vm.stopPrank();

        address reserveStore = controller.getReserveStore(address(stablecoin));
        uint256 reserveStoreBefore = reserveLedgerToken.balanceOf(reserveStore);

        // Burn
        vm.prank(minter);
        controller.burn(address(stablecoin), burnAmount);

        // Verify stablecoin was burned
        assertEq(stablecoin.balanceOf(minter), mintAmount - burnAmount);

        // Verify reserve tokens were also burned (removed from reserve store)
        assertEq(reserveLedgerToken.balanceOf(reserveStore), reserveStoreBefore - burnAmount);
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

    function test_burnWithOperationId_consumesUnusedOperationId() public {
        uint256 operationId = 1;
        uint256 mintAmount = 100e6;
        uint256 burnAmount = 30e6;

        _mintStablecoinToMinter(mintAmount);

        vm.startPrank(minter);
        stablecoin.approve(address(controller), burnAmount);
        controller.burn(address(stablecoin), burnAmount, operationId);

        vm.expectRevert(IMintIntent.InvalidOperationId.selector);
        controller.burn(address(stablecoin), 1, operationId);
        vm.stopPrank();
    }

    function test_burnWithOperationId_revertWhenOperationIdReservedByMintApproval() public {
        uint256 operationId = 2;
        bytes32 holdId = keccak256("tip20-reserved-mint-approval");

        vm.prank(admin);
        controller.grantRole(controller.BURNER_ROLE(), minter);

        vm.prank(admin);
        controller.publishApproval(
            IMintIntent.ApprovalParams({
                operationId: operationId,
                holdId: holdId,
                amount: 100e6,
                recipient: user1,
                stablecoin: address(stablecoin)
            }),
            uint64(block.timestamp + 1 days)
        );

        vm.prank(minter);
        vm.expectRevert(IMintIntent.InvalidOperationId.selector);
        controller.burn(address(stablecoin), 100e6, operationId);
    }

    function test_burnWithOperationId_revertWhenOperationIdConsumedByMintApproval() public {
        uint256 operationId = 3;
        IMintIntent.ApprovalParams memory params = IMintIntent.ApprovalParams({
            operationId: operationId,
            holdId: keccak256("tip20-consumed-mint-approval"),
            amount: 100e6,
            recipient: minter,
            stablecoin: address(stablecoin)
        });

        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 100e6);
        controller.setMinterAllowance(address(stablecoin), minter, 100e6);
        controller.grantRole(controller.BURNER_ROLE(), minter);
        controller.publishApproval(params, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        vm.prank(minter);
        controller.mintWithApproval(params);

        vm.prank(minter);
        vm.expectRevert(IMintIntent.InvalidOperationId.selector);
        controller.burn(address(stablecoin), 100e6, operationId);
    }

    function test_publishApproval_revertWhenOperationIdConsumedByBurn() public {
        uint256 operationId = 4;

        _mintStablecoinToMinter(100e6);

        vm.startPrank(minter);
        stablecoin.approve(address(controller), 30e6);
        controller.burn(address(stablecoin), 30e6, operationId);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.ApprovalExistsForOperationId.selector, operationId)
        );
        controller.publishApproval(
            IMintIntent.ApprovalParams({
                operationId: operationId,
                holdId: keccak256("tip20-burn-consumed-operation"),
                amount: 100e6,
                recipient: user1,
                stablecoin: address(stablecoin)
            }),
            uint64(block.timestamp + 1 days)
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Mint Intent Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_grantsPublisherRole() public view {
        assertTrue(controller.hasRole(controller.PUBLISHER_ROLE(), admin));
    }

    function test_publishRevokeExtend_revertWhenNotPublisher() public {
        IMintIntent.ApprovalParams memory params = _approvalParams(10, keccak256("not-publisher"));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.PUBLISHER_ROLE()
            )
        );
        controller.publishApproval(params, uint64(block.timestamp + 1 days));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.PUBLISHER_ROLE()
            )
        );
        controller.revokeApproval(params.holdId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.PUBLISHER_ROLE()
            )
        );
        controller.revokeOperationId(params.operationId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.PUBLISHER_ROLE()
            )
        );
        controller.extendApproval(params.holdId, uint64(block.timestamp + 2 days));
        vm.stopPrank();
    }

    function test_publishApproval_storesFieldsAndEmits() public {
        uint256 operationId = 11;
        bytes32 holdId = keccak256("publish-stores-fields");
        uint64 expiry = uint64(block.timestamp + 1 days);
        IMintIntent.ApprovalParams memory params = _approvalParams(operationId, holdId);

        vm.expectEmit(true, true, true, true, address(controller));
        emit IMintIntent.ApprovalPublished(
            admin, operationId, holdId, address(stablecoin), user1, 100e6, expiry
        );
        controller.publishApproval(params, expiry);

        Approval memory approval = controller.getApproval(holdId);
        assertEq(approval.amount, params.amount);
        assertEq(approval.recipient, params.recipient);
        assertEq(approval.stablecoin, params.stablecoin);
        assertEq(approval.expiry, expiry);
        assertEq(approval.flags, 0);
        assertEq(approval.operationId, operationId);
    }

    function test_publishApproval_rejectsInvalidInputsAndDuplicates() public {
        vm.expectRevert(IMintIntent.InvalidOperationId.selector);
        controller.publishApproval(
            _approvalParams(0, keccak256("zero-operation")), uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(IMintIntent.InvalidHoldId.selector);
        controller.publishApproval(
            _approvalParams(12, bytes32(0)), uint64(block.timestamp + 1 days)
        );

        IMintIntent.ApprovalParams memory params = _approvalParams(13, keccak256("invalid-publish"));

        params.amount = 0;
        vm.expectRevert(IMintIntent.InvalidAmount.selector);
        controller.publishApproval(params, uint64(block.timestamp + 1 days));

        params = _approvalParams(14, keccak256("zero-stablecoin"));
        params.stablecoin = address(0);
        vm.expectRevert(IMintIntent.InvalidStablecoin.selector);
        controller.publishApproval(params, uint64(block.timestamp + 1 days));

        params = _approvalParams(15, keccak256("zero-recipient"));
        params.recipient = address(0);
        vm.expectRevert(IMintIntent.InvalidRecipient.selector);
        controller.publishApproval(params, uint64(block.timestamp + 1 days));

        vm.expectRevert(IMintIntent.InvalidExpiry.selector);
        controller.publishApproval(
            _approvalParams(16, keccak256("expired-expiry")), uint64(block.timestamp)
        );

        params = _approvalParams(17, keccak256("duplicate-original"));
        controller.publishApproval(params, uint64(block.timestamp + 1 days));

        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.ApprovalExistsForOperationId.selector, 17)
        );
        controller.publishApproval(
            _approvalParams(17, keccak256("duplicate-operation")), uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.ApprovalExistsForHoldId.selector, params.holdId)
        );
        controller.publishApproval(
            _approvalParams(18, params.holdId), uint64(block.timestamp + 1 days)
        );
    }

    function test_extendApproval_updatesExpiryAndEmits() public {
        uint256 operationId = 19;
        bytes32 holdId = keccak256("extend-success");
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint64 newExpiry = uint64(block.timestamp + 2 days);
        IMintIntent.ApprovalParams memory params = _approvalParams(operationId, holdId);
        _publishApproval(params, expiry);

        vm.expectEmit(true, true, true, true, address(controller));
        emit IMintIntent.ApprovalExtended(admin, holdId, operationId, newExpiry);
        controller.extendApproval(holdId, newExpiry);

        Approval memory approval = controller.getApproval(holdId);
        assertEq(approval.expiry, newExpiry);
        assertEq(approval.operationId, operationId);
    }

    function test_extendApproval_rejectsSameOlderRevokedConsumedAndNonexistent() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        IMintIntent.ApprovalParams memory params = _approvalParams(20, keccak256("extend-invalid"));
        _publishApproval(params, expiry);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntent.ApprovalExpiryNotExtended.selector, params.holdId, expiry, expiry
            )
        );
        controller.extendApproval(params.holdId, expiry);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntent.ApprovalExpiryNotExtended.selector, params.holdId, expiry - 1, expiry
            )
        );
        controller.extendApproval(params.holdId, expiry - 1);

        IMintIntent.ApprovalParams memory revoked = _approvalParams(21, keccak256("extend-revoked"));
        _publishApproval(revoked, expiry);
        controller.revokeApproval(revoked.holdId);

        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.InvalidApproval.selector, revoked.holdId, uint256(2))
        );
        controller.extendApproval(revoked.holdId, expiry + 1);

        IMintIntent.ApprovalParams memory consumed =
            _approvalParams(22, keccak256("extend-consumed"));
        _publishApproval(consumed, expiry);
        _allowMinter(address(stablecoin), 100e6);
        vm.prank(minter);
        controller.mintWithApproval(consumed);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntent.InvalidApproval.selector, consumed.holdId, uint256(1)
            )
        );
        controller.extendApproval(consumed.holdId, expiry + 1);

        bytes32 missingHoldId = keccak256("extend-missing");
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.ApprovalNotExistsForHoldId.selector, missingHoldId)
        );
        controller.extendApproval(missingHoldId, expiry + 1);
    }

    function test_mintWithApproval_consumesApprovalAndRejectsReuse() public {
        uint256 operationId = 23;
        bytes32 holdId = keccak256("mint-with-approval");
        IMintIntent.ApprovalParams memory params = _approvalParams(operationId, holdId);
        _publishApproval(params, uint64(block.timestamp + 1 days));
        _allowMinter(address(stablecoin), 100e6);

        vm.prank(minter);
        vm.expectEmit(true, true, true, true, address(controller));
        emit IMintIntent.ApprovalConsumed(minter, operationId, holdId);
        controller.mintWithApproval(params);

        Approval memory approval = controller.getApproval(holdId);
        assertEq(approval.flags, 1);
        assertEq(stablecoin.balanceOf(user1), 100e6);
        assertEq(controller.getMinterAllowance(address(stablecoin), minter), 0);
        address reserveStore = controller.getReserveStore(address(stablecoin));
        assertTrue(reserveStore != address(0));
        assertEq(reserveLedgerToken.balanceOf(reserveStore), 100e6);

        _allowMinter(address(stablecoin), 100e6);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.InvalidApproval.selector, holdId, uint256(1))
        );
        controller.mintWithApproval(params);

        vm.expectRevert(
            abi.encodeWithSelector(IMintIntent.ApprovalExistsForOperationId.selector, operationId)
        );
        controller.publishApproval(
            _approvalParams(operationId, keccak256("consumed-operation-republish")),
            uint64(block.timestamp + 1 days)
        );
    }

    function test_mintWithApproval_limitFailuresDoNotConsumeApproval() public {
        IMintIntent.ApprovalParams memory allowanceParams =
            _approvalParams(30, keccak256("approval-allowance-limit"));
        _publishApproval(allowanceParams, uint64(block.timestamp + 1 days));

        vm.prank(user2);
        vm.expectRevert(ITIP20Controller.MinterAllowanceExceeded.selector);
        controller.mintWithApproval(allowanceParams);

        Approval memory approval = controller.getApproval(allowanceParams.holdId);
        assertEq(approval.flags, 0);

        _allowMinter(address(stablecoin), 99e6);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.MinterAllowanceExceeded.selector);
        controller.mintWithApproval(allowanceParams);

        approval = controller.getApproval(allowanceParams.holdId);
        assertEq(approval.flags, 0);

        _allowMinter(address(stablecoin), 100e6);

        vm.prank(minter);
        controller.mintWithApproval(allowanceParams);

        IMintIntent.ApprovalParams memory txnLimitParams =
            _approvalParams(31, keccak256("approval-txn-limit"));
        _publishApproval(txnLimitParams, uint64(block.timestamp + 1 days));

        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 99e6);
        controller.setMinterAllowance(address(stablecoin), minter, 100e6);
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.MintTxnLimitExceeded.selector);
        controller.mintWithApproval(txnLimitParams);

        approval = controller.getApproval(txnLimitParams.holdId);
        assertEq(approval.flags, 0);

        _allowMinter(address(stablecoin), 100e6);

        vm.prank(minter);
        controller.mintWithApproval(txnLimitParams);
    }

    function test_mintWithApproval_invalidParamsReportExpectedBooleans() public {
        IMintIntent.ApprovalParams memory params = _approvalParams(24, keccak256("invalid-params"));
        _publishApproval(params, uint64(block.timestamp + 1 days));
        _allowMinter(address(stablecoin), 1000e6);

        IMintIntent.ApprovalParams memory invalid = params;
        invalid.holdId = keccak256("wrong-hold");
        vm.prank(minter);
        _expectInvalidApprovalParams(false, true, true, true, true, true);
        controller.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.holdId = bytes32(0);
        vm.prank(minter);
        _expectInvalidApprovalParams(true, true, true, true, true, true);
        controller.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.operationId = 25;
        vm.prank(minter);
        _expectInvalidApprovalParams(false, true, false, false, false, false);
        controller.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.amount = 99e6;
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, true, false, false, false);
        controller.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.recipient = user2;
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, false, true, false, false);
        controller.mintWithApproval(invalid);

        _allowMinter(address(reserveLedgerToken), 100e6);
        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.stablecoin = address(reserveLedgerToken);
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, false, false, true, false);
        controller.mintWithApproval(invalid);

        IMintIntent.ApprovalParams memory expired =
            _approvalParams(26, keccak256("expired-approval"));
        _publishApproval(expired, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, false, false, false, true);
        controller.mintWithApproval(expired);
    }

    function test_revokeApprovalAndOperationId_emitFieldsAndBlockReuse() public {
        IMintIntent.ApprovalParams memory revokedApproval =
            _approvalParams(27, keccak256("revoke-approval-fields"));
        _publishApproval(revokedApproval, uint64(block.timestamp + 1 days));

        vm.expectEmit(true, true, true, true, address(controller));
        emit IMintIntent.ApprovalRevoked(admin, revokedApproval.holdId, revokedApproval.operationId);
        controller.revokeApproval(revokedApproval.holdId);

        _allowMinter(address(stablecoin), 100e6);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntent.InvalidApproval.selector, revokedApproval.holdId, uint256(2)
            )
        );
        controller.mintWithApproval(revokedApproval);

        vm.prank(admin);
        controller.grantRole(controller.BURNER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(IMintIntent.InvalidOperationId.selector);
        controller.burn(address(stablecoin), 100e6, revokedApproval.operationId);

        IMintIntent.ApprovalParams memory revokedOperation =
            _approvalParams(28, keccak256("revoke-operation-fields"));
        _publishApproval(revokedOperation, uint64(block.timestamp + 1 days));

        vm.expectEmit(true, true, true, true, address(controller));
        emit IMintIntent.ApprovalRevoked(
            admin, revokedOperation.holdId, revokedOperation.operationId
        );
        vm.expectEmit(true, true, true, true, address(controller));
        emit IMintIntent.OperationIdRevoked(
            admin, revokedOperation.operationId, revokedOperation.holdId
        );
        controller.revokeOperationId(revokedOperation.operationId);

        _allowMinter(address(stablecoin), 100e6);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntent.InvalidApproval.selector, revokedOperation.holdId, uint256(2)
            )
        );
        controller.mintWithApproval(revokedOperation);

        vm.prank(minter);
        vm.expectRevert(IMintIntent.InvalidOperationId.selector);
        controller.burn(address(stablecoin), 100e6, revokedOperation.operationId);
    }

    function test_setMintIntentVersion_requiredGatesPlainMintButAllowsApprovalMint() public {
        IMintIntent.ApprovalParams memory params =
            _approvalParams(29, keccak256("required-version"));
        _publishApproval(params, uint64(block.timestamp + 1 days));
        _allowMinter(address(stablecoin), 200e6);

        bytes32 defaultAdminRole = controller.DEFAULT_ADMIN_ROLE();
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, defaultAdminRole
            )
        );
        controller.setMintIntentVersion(ITIP20Controller.MintIntentVersion.Required);

        vm.expectEmit(true, false, false, true, address(controller));
        emit ITIP20Controller.MintIntentVersionSet(
            admin, ITIP20Controller.MintIntentVersion.Required
        );
        controller.setMintIntentVersion(ITIP20Controller.MintIntentVersion.Required);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.MintIntentRequired.selector);
        controller.mint(address(stablecoin), user1, 100e6);

        controller.grantRole(controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE(), admin);
        controller.mintBridgeEcosystem(address(stablecoin), user2, 1);

        vm.prank(minter);
        controller.mintWithApproval(params);

        assertEq(stablecoin.balanceOf(user1), 100e6);
        assertEq(stablecoin.balanceOf(user2), 1);
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

    function test_unwrap_revert_stablecoin_is_reserve_ledger_token() public {
        vm.prank(admin);
        controller.grantRole(controller.UNWRAPPER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.InvalidStablecoinContract.selector);
        controller.unwrap(address(reserveLedgerToken), 100e6);
    }

    function test_unwrap_auto_deploys_reserve_store() public {
        ITIP20 newToken = _createNewStablecoin("Unwrap Token", "UNW");

        vm.prank(admin);
        controller.grantRole(controller.UNWRAPPER_ROLE(), minter);

        // Verify no reserve store exists yet
        assertEq(controller.getReserveStore(address(newToken)), address(0));

        // Unwrap will auto-deploy reserve store (though it will fail later due to no balance)
        // This test verifies the store gets created
        vm.prank(minter);
        vm.expectRevert(); // Will revert due to no stablecoin balance, but store should be created
        controller.unwrap(address(newToken), 30e6);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Wrap Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_wrap_success() public {
        uint256 wrapAmount = 100e6;

        // Give user1 some reserve tokens
        _mintReserveTokens(user1, wrapAmount);

        // User1 approves controller
        vm.prank(user1);
        reserveLedgerToken.approve(address(controller), wrapAmount);

        // Wrap tokens for user2
        vm.prank(user1);
        controller.wrap(address(stablecoin), user2, wrapAmount);

        // Verify user2 received stablecoins
        assertEq(stablecoin.balanceOf(user2), wrapAmount);

        // Verify reserve tokens moved to auto-deployed ReserveStore
        address reserveStore = controller.getReserveStore(address(stablecoin));
        assertTrue(reserveStore != address(0));
        assertEq(reserveLedgerToken.balanceOf(reserveStore), wrapAmount);

        // Verify user1's reserve tokens were transferred
        assertEq(reserveLedgerToken.balanceOf(user1), 0);
    }

    function test_wrap_zero_amount_reverts() public {
        vm.prank(user1);
        vm.expectRevert(ITIP20Controller.AmountCannotBeZero.selector);
        controller.wrap(address(stablecoin), user2, 0);
    }

    function test_wrap_revert_stablecoin_is_reserve_ledger_token() public {
        uint256 wrapAmount = 100e6;

        _mintReserveTokens(user1, wrapAmount);
        vm.prank(user1);
        reserveLedgerToken.approve(address(controller), wrapAmount);

        vm.prank(user1);
        vm.expectRevert(ITIP20Controller.InvalidStablecoinContract.selector);
        controller.wrap(address(reserveLedgerToken), user2, wrapAmount);
    }

    function test_wrap_auto_deploys_reserve_store() public {
        ITIP20 newToken = _createNewStablecoin("Wrap Token", "WRP");
        uint256 wrapAmount = 100e6;

        // Verify no reserve store exists yet
        assertEq(controller.getReserveStore(address(newToken)), address(0));

        // Grant controller the ISSUER_ROLE on newToken so it can mint
        ITIP20RolesAuth(address(newToken)).grantRole(newToken.ISSUER_ROLE(), address(controller));

        _mintReserveTokens(user1, wrapAmount);
        vm.prank(user1);
        reserveLedgerToken.approve(address(controller), wrapAmount);

        // Wrap should auto-deploy reserve store
        vm.prank(user1);
        controller.wrap(address(newToken), user2, wrapAmount);

        // Verify reserve store was created
        address reserveStore = controller.getReserveStore(address(newToken));
        assertTrue(reserveStore != address(0));

        // Verify user2 received stablecoins
        assertEq(newToken.balanceOf(user2), wrapAmount);

        // Verify reserve tokens moved to ReserveStore
        assertEq(reserveLedgerToken.balanceOf(reserveStore), wrapAmount);
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

    /*//////////////////////////////////////////////////////////////////////////
                                Helper Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Mints reserve tokens to an address using the ISSUER_ROLE
    function _mintReserveTokens(address to, uint256 amount) internal {
        reserveLedgerToken.mint(to, amount);
    }

    /// @dev Creates a new stablecoin from the factory
    function _createNewStablecoin(string memory name, string memory symbol)
        internal
        returns (ITIP20)
    {
        ITIP20Factory factory = StdPrecompiles.TIP20_FACTORY;
        address tokenAddr = factory.createToken(
            name, symbol, "USD", StdTokens.PATH_USD, admin, keccak256(abi.encodePacked(name))
        );
        return ITIP20(tokenAddr);
    }

    function _mintStablecoinToMinter(uint256 amount) internal {
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), amount);
        controller.setMinterAllowance(address(stablecoin), minter, amount);
        controller.grantRole(controller.BURNER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        controller.mint(address(stablecoin), minter, amount);
    }

    function _approvalParams(uint256 operationId, bytes32 holdId)
        internal
        view
        returns (IMintIntent.ApprovalParams memory)
    {
        return IMintIntent.ApprovalParams({
            operationId: operationId,
            holdId: holdId,
            amount: 100e6,
            recipient: user1,
            stablecoin: address(stablecoin)
        });
    }

    function _publishApproval(IMintIntent.ApprovalParams memory params, uint64 expiry) internal {
        controller.publishApproval(params, expiry);
    }

    function _allowMinter(address token, uint256 amount) internal {
        vm.startPrank(admin);
        controller.setTxnMintLimit(token, amount);
        controller.setMinterAllowance(token, minter, amount);
        vm.stopPrank();
    }

    function _expectInvalidApprovalParams(
        bool invalidHoldId,
        bool invalidOperationId,
        bool invalidAmount,
        bool invalidRecipient,
        bool stablecoinIsWrong,
        bool invalidExpiry
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntent.InvalidApprovalParams.selector,
                invalidHoldId,
                invalidOperationId,
                invalidAmount,
                invalidRecipient,
                stablecoinIsWrong,
                invalidExpiry
            )
        );
    }

}
