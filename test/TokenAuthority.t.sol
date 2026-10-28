// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockERC20BurnMint, MockERC20WrapUnwrap } from "./utils/MockERC20.sol";
import { MockStablecoinTemplateV2 } from "./utils/MockStablecoinTemplateV2.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { MintIntentRegistry } from "src/mintIntent/MintIntentRegistry.sol";
import { Approval, OperationState } from "src/mintIntent/MintIntentStorage.sol";
import { IMintIntent } from "src/mintIntent/interfaces/IMintIntent.sol";
import { IMintIntentErrors } from "src/mintIntent/interfaces/IMintIntentErrors.sol";
import {
    IBurnAndRemintStablecoin,
    IForceTransferStablecoin,
    IReserveWrappedStablecoin
} from "src/seize/interfaces/ISeizableStablecoin.sol";
import { ISeize } from "src/seize/interfaces/ISeize.sol";
import { ITokenAuthority } from "src/tokenAuthority/ITokenAuthority.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

import { AuthRegistry, IAuthRegistry } from "auth-registry/src/AuthRegistry.sol";

import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";
import {
    StablecoinTemplateV3ErrorsAndEvents
} from "src/v3/StablecoinTemplateV3ErrorsAndEvents.sol";

import { ITokenHandler } from "src/tokenAuthority/tokenHandler/ITokenHandler.sol";
import {
    ReserveLedgerBackedHandler
} from "src/tokenAuthority/tokenHandler/ReserveLedgerBackedHandler.sol";
import {
    ReserveLedgerWrappedHandler
} from "src/tokenAuthority/tokenHandler/ReserveLedgerWrappedHandler.sol";
import { SingleTokenHandler } from "src/tokenAuthority/tokenHandler/SingleTokenHandler.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract TokenAuthorityTest is Test {

    error InvalidInitialization();

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UNWRAPPER_ROLE = keccak256("UNWRAPPER_ROLE");
    bytes32 public constant BRIDGE_ECOSYSTEM_CONTRACT_ROLE =
        keccak256("BRIDGE_ECOSYSTEM_CONTRACT_ROLE");
    bytes32 public constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");
    bytes32 public constant STABLECOIN_PAUSER_ROLE = keccak256("STABLECOIN_PAUSER_ROLE");
    bytes32 public constant SEIZER_ROLE = keccak256("SEIZER_ROLE");
    bytes32 public constant FORCE_TRANSFER_ROLE = keccak256("FORCE_TRANSFER_ROLE");

    TokenAuthority tokenAuthority;
    MintIntentRegistry mintIntentRegistry;
    ReserveLedger reserveLedgerToken;
    StablecoinTemplateV3 wrappedStablecoin;
    StablecoinTemplateV3 backedStablecoin;
    AuthRegistry authRegistry;

    address bridgeAdmin;
    address tokenAuthorityAdmin;
    address tokenAuthorityPublisher;
    address reserveLedgerAdmin;
    address wrappedStablecoinAdmin;
    address backedStablecoinAdmin;
    address minter;
    address alice;
    address bob;
    address charles;
    address maliciousUser;

    SingleTokenHandler singleTokenHandler;
    ReserveLedgerBackedHandler reserveLedgerBackedHandler;
    ReserveLedgerWrappedHandler reserveLedgerWrappedHandler;

    // Seize fixtures, populated by _setUpSeize
    MockStablecoinTemplateV2 v2Stablecoin;
    address v2StablecoinAdmin;
    address seizer;
    address seizureWallet;
    address frozenHolder;
    uint64 seizureWalletListId;

    function setUp() public {
        bridgeAdmin = makeAddr("bridgeAdmin");
        tokenAuthorityAdmin = makeAddr("tokenAuthorityAdmin");
        tokenAuthorityPublisher = makeAddr("tokenAuthorityPublisher");
        reserveLedgerAdmin = makeAddr("reserveLedgerAdmin");
        wrappedStablecoinAdmin = makeAddr("wrappedStablecoinAdmin");
        backedStablecoinAdmin = makeAddr("backedStablecoinAdmin");
        minter = makeAddr("minter");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charles = makeAddr("charles");
        maliciousUser = makeAddr("maliciousUser");

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy auth registry and setup transfer/mint recip policies for RL/Stablecoin and parent
        ////////////////////////////////////////////////////////////////////////////////////////////
        authRegistry = new AuthRegistry();
        uint64 parentMintRecipientPolicyId =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.WHITELIST);
        uint64 parentBlocklistPolicyId =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.BLACKLIST);

        uint64 reserveLedgerMintRecipientPolicyId = authRegistry.createPolicy(
            reserveLedgerAdmin, IAuthRegistry.PolicyType.WHITELIST, parentMintRecipientPolicyId
        );
        uint64 reserveLedgerBlocklistPolicyId = authRegistry.createPolicy(
            reserveLedgerAdmin, IAuthRegistry.PolicyType.BLACKLIST, parentBlocklistPolicyId
        );

        uint64 wrappedStablecoinMintRecipientPolicyId = authRegistry.createPolicy(
            wrappedStablecoinAdmin, IAuthRegistry.PolicyType.WHITELIST, parentMintRecipientPolicyId
        );
        uint64 wrappedStablecoinBlocklistPolicyId = authRegistry.createPolicy(
            wrappedStablecoinAdmin, IAuthRegistry.PolicyType.BLACKLIST, parentBlocklistPolicyId
        );

        uint64 backedStablecoinMintRecipientPolicyId = authRegistry.createPolicy(
            backedStablecoinAdmin, IAuthRegistry.PolicyType.WHITELIST, parentMintRecipientPolicyId
        );
        uint64 backedStablecoinBlocklistPolicyId = authRegistry.createPolicy(
            backedStablecoinAdmin, IAuthRegistry.PolicyType.BLACKLIST, parentBlocklistPolicyId
        );

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy ReserveLedger
        ////////////////////////////////////////////////////////////////////////////////////////////
        ReserveLedger reserveLedgerImpl = new ReserveLedger(address(authRegistry));
        reserveLedgerToken = ReserveLedger(
            address(
                new ERC1967Proxy(
                    address(reserveLedgerImpl),
                    abi.encodeCall(
                        StablecoinTemplateV3Base.initialize,
                        (
                            "Reserve Ledger",
                            "RL",
                            6,
                            reserveLedgerAdmin,
                            reserveLedgerBlocklistPolicyId,
                            reserveLedgerMintRecipientPolicyId
                        )
                    )
                )
            )
        );

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy Wrapped and Backed Stablecoin
        ////////////////////////////////////////////////////////////////////////////////////////////
        StablecoinTemplateV3 stablecoinImpl =
            new StablecoinTemplateV3(address(reserveLedgerToken), address(authRegistry));
        wrappedStablecoin = StablecoinTemplateV3(
            address(
                new ERC1967Proxy(
                    address(stablecoinImpl),
                    abi.encodeCall(
                        StablecoinTemplateV3Base.initialize,
                        (
                            "WrappedStablecoin",
                            "WSC",
                            6,
                            wrappedStablecoinAdmin,
                            wrappedStablecoinBlocklistPolicyId,
                            wrappedStablecoinMintRecipientPolicyId
                        )
                    )
                )
            )
        );

        backedStablecoin = StablecoinTemplateV3(
            address(
                new ERC1967Proxy(
                    address(stablecoinImpl),
                    abi.encodeCall(
                        StablecoinTemplateV3Base.initialize,
                        (
                            "BackedStablecoin",
                            "BSC",
                            6,
                            backedStablecoinAdmin,
                            backedStablecoinBlocklistPolicyId,
                            backedStablecoinMintRecipientPolicyId
                        )
                    )
                )
            )
        );

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy TokenAuthority
        ////////////////////////////////////////////////////////////////////////////////////////////
        mintIntentRegistry = _deployMintIntentRegistry(tokenAuthorityAdmin);

        tokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        tokenAuthority.initialize(
            tokenAuthorityAdmin, tokenAuthorityPublisher, address(mintIntentRegistry)
        );

        // Authorize the TokenAuthority to publish and consume intents in the shared registry
        bytes32 controllerRole = mintIntentRegistry.CONTROLLER_ROLE();
        vm.prank(tokenAuthorityAdmin);
        mintIntentRegistry.grantRole(controllerRole, address(tokenAuthority));

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy Token Handlers
        ////////////////////////////////////////////////////////////////////////////////////////////
        singleTokenHandler = new SingleTokenHandler(address(tokenAuthority));
        reserveLedgerBackedHandler = new ReserveLedgerBackedHandler(address(tokenAuthority));
        reserveLedgerWrappedHandler = new ReserveLedgerWrappedHandler(address(tokenAuthority));

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Setup Permissions - GrantRoles, add to mint recipients, add to blocklist, mint
        // allowances/ lmits
        // //////////////////////////////////////////////////////////////////////////////////////////

        // Parent Policies
        vm.startPrank(bridgeAdmin);
        authRegistry.modifyPolicyWhitelist(
            parentMintRecipientPolicyId, address(reserveLedgerBackedHandler), true
        );
        authRegistry.modifyPolicyWhitelist(
            parentMintRecipientPolicyId, address(reserveLedgerWrappedHandler), true
        );
        authRegistry.modifyPolicyBlacklist(parentBlocklistPolicyId, maliciousUser, true);
        vm.stopPrank();

        // Reserve Ledger
        vm.startPrank(reserveLedgerAdmin);
        reserveLedgerToken.grantRole(MINTER_ROLE, address(singleTokenHandler));
        reserveLedgerToken.grantRole(MINTER_ROLE, address(reserveLedgerBackedHandler));
        reserveLedgerToken.grantRole(MINTER_ROLE, address(reserveLedgerWrappedHandler));
        reserveLedgerToken.setMaxSupply(1_000_000_000e6);
        authRegistry.modifyPolicyWhitelist(reserveLedgerMintRecipientPolicyId, alice, true);
        vm.stopPrank();

        // Wrapped Stablecoin
        vm.startPrank(wrappedStablecoinAdmin);
        wrappedStablecoin.grantRole(MINTER_ROLE, address(reserveLedgerBackedHandler));
        wrappedStablecoin.grantRole(MINTER_ROLE, address(reserveLedgerWrappedHandler));
        wrappedStablecoin.setMaxSupply(1_000_000_000e6);
        authRegistry.modifyPolicyWhitelist(wrappedStablecoinMintRecipientPolicyId, bob, true);
        vm.stopPrank();

        // Backed Stablecoin
        vm.startPrank(backedStablecoinAdmin);
        backedStablecoin.grantRole(MINTER_ROLE, address(reserveLedgerBackedHandler));
        backedStablecoin.grantRole(MINTER_ROLE, address(reserveLedgerWrappedHandler));
        backedStablecoin.setMaxSupply(1_000_000_000e6);
        authRegistry.modifyPolicyWhitelist(backedStablecoinMintRecipientPolicyId, charles, true);
        vm.stopPrank();

        // TokenAuthority
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(MINT_RATE_LIMIT_SETTER_ROLE, tokenAuthorityAdmin);
        tokenAuthority.grantRole(BURNER_ROLE, tokenAuthorityAdmin);
        tokenAuthority.grantRole(UNWRAPPER_ROLE, tokenAuthorityAdmin);
        tokenAuthority.grantRole(BRIDGE_ECOSYSTEM_CONTRACT_ROLE, tokenAuthorityAdmin);
        tokenAuthority.grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, tokenAuthorityAdmin);
        tokenAuthority.grantRole(STABLECOIN_PAUSER_ROLE, tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), minter, 1000e6);
        tokenAuthority.setTxnMintLimit(address(wrappedStablecoin), 1_000_000e6);
        tokenAuthority.setMinterAllowance(address(backedStablecoin), minter, 1000e6);
        tokenAuthority.setTxnMintLimit(address(backedStablecoin), 1_000_000e6);
        tokenAuthority.setMinterAllowance(address(reserveLedgerToken), minter, 250e6);
        tokenAuthority.setTxnMintLimit(address(reserveLedgerToken), 1_000_000e6);
        vm.stopPrank();

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Configure Token Handlers
        ////////////////////////////////////////////////////////////////////////////////////////////
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.registerStablecoin(
            address(reserveLedgerToken), address(singleTokenHandler), 1_000_000e6
        );
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin), address(reserveLedgerWrappedHandler), 1_000_000e6
        );
        tokenAuthority.registerStablecoin(
            address(backedStablecoin), address(reserveLedgerBackedHandler), 1_000_000e6
        );
        vm.stopPrank();
    }

    function _deployMintIntentRegistry(address registryAdmin)
        internal
        returns (MintIntentRegistry)
    {
        MintIntentRegistry registryImplementation = new MintIntentRegistry(false);
        return MintIntentRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation),
                    abi.encodeCall(MintIntentRegistry.initialize, (registryAdmin))
                )
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test minting functionality
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_mintReserveLedgerTokens() public {
        vm.prank(minter);
        vm.expectEmit(true, true, false, true, address(singleTokenHandler));
        emit ITokenHandler.Minted(address(reserveLedgerToken), alice, 100e6);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        assertEq(reserveLedgerToken.balanceOf(alice), 100e6, "rl alice bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter),
            150e6,
            "rl minter allowance"
        );
    }

    function test_mintStablecoinsWrapped() public {
        vm.prank(minter);
        vm.expectEmit(true, true, false, true, address(reserveLedgerWrappedHandler));
        emit ITokenHandler.Minted(address(wrappedStablecoin), bob, 100e6);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        assertEq(
            reserveLedgerToken.balanceOf(address(wrappedStablecoin)),
            100e6,
            "rl wrappedStablecoin bal"
        );
        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "rl wrappedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(wrappedStablecoin.totalSupply(), 100e6, "wrappedStablecoin total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter),
            900e6,
            "wrappedStablecoin minter allowance"
        );
    }

    function test_mintStablecoinsBacked() public {
        vm.prank(minter);
        vm.expectEmit(true, true, false, true, address(reserveLedgerBackedHandler));
        emit ITokenHandler.Minted(address(backedStablecoin), charles, 100e6);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        assertEq(
            reserveLedgerToken.balanceOf(address(reserveStore)), 100e6, "rl backedStablecoin bal"
        );
        assertEq(backedStablecoin.balanceOf(charles), 100e6, "rl backedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 100e6, "backedStablecoin total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(backedStablecoin), minter),
            900e6,
            "backedStablecoin minter allowance"
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test burning functionality
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_burnReserveLedgerTokens() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);

        vm.expectEmit(true, false, false, true, address(singleTokenHandler));
        emit ITokenHandler.Burned(address(reserveLedgerToken), 100e6);
        tokenAuthority.burn(address(reserveLedgerToken), 100e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(alice), 0, "rl alice bal");
        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 0, "rl admin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter),
            150e6,
            "rl minter allowance"
        );
    }

    function test_burnStablecoinsWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        vm.prank(bob);
        wrappedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        wrappedStablecoin.approve(address(tokenAuthority), 100e6);

        vm.expectEmit(true, false, false, true, address(reserveLedgerWrappedHandler));
        emit ITokenHandler.Burned(address(wrappedStablecoin), 100e6);
        tokenAuthority.burn(address(wrappedStablecoin), 100e6);
        vm.stopPrank();

        assertEq(
            reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 0, "rl wrappedStablecoin bal"
        );
        assertEq(wrappedStablecoin.balanceOf(bob), 0, "rl wrappedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
        assertEq(wrappedStablecoin.totalSupply(), 0, "wrappedStablecoin total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter),
            900e6,
            "wrappedStablecoin minter allowance"
        );
    }

    function test_burnStablecoinsBacked() public {
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        vm.prank(charles);
        backedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        backedStablecoin.approve(address(tokenAuthority), 100e6);

        vm.expectEmit(true, false, false, true, address(reserveLedgerBackedHandler));
        emit ITokenHandler.Burned(address(backedStablecoin), 100e6);
        tokenAuthority.burn(address(backedStablecoin), 100e6);
        vm.stopPrank();

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), 0, "rl backedStablecoin bal");
        assertEq(backedStablecoin.balanceOf(charles), 0, "rl backedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 0, "backedStablecoin total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(backedStablecoin), minter),
            900e6,
            "backedStablecoin minter allowance"
        );
    }

    function test_burnWithOperationId_consumesUnusedOperationId() public {
        uint256 operationId = 1;

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);
        tokenAuthority.burnWithOperationId(address(reserveLedgerToken), 100e6, operationId);

        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(address(reserveLedgerToken), 1, operationId);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 0, "rl admin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
    }

    function test_burnWithOperationId_revertWhenOperationIdReservedByMintApproval() public {
        uint256 operationId = 2;
        bytes32 holdId = keccak256("reserved-mint-approval");

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.publishApproval(
            IMintIntent.ApprovalParams({
                operationId: operationId,
                holdId: holdId,
                amount: 100e6,
                recipient: bob,
                stablecoin: address(wrappedStablecoin)
            }),
            uint64(block.timestamp + 1 days)
        );

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(address(wrappedStablecoin), 100e6, operationId);
    }

    function test_burnWithOperationId_revertWhenOperationIdConsumedByMintApproval() public {
        uint256 operationId = 6;
        bytes32 holdId = keccak256("consumed-mint-approval");
        IMintIntent.ApprovalParams memory params = IMintIntent.ApprovalParams({
            operationId: operationId,
            holdId: holdId,
            amount: 100e6,
            recipient: bob,
            stablecoin: address(wrappedStablecoin)
        });

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        Approval memory publishedApproval = tokenAuthority.getApproval(holdId);
        assertEq(publishedApproval.operationId, operationId, "approval operation id");

        vm.prank(minter);
        tokenAuthority.mintWithApproval(params);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(address(wrappedStablecoin), 100e6, operationId);
    }

    function test_publishApproval_revertWhenOperationIdConsumedByBurn() public {
        uint256 operationId = 3;

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);
        tokenAuthority.burnWithOperationId(address(reserveLedgerToken), 100e6, operationId);
        vm.stopPrank();

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        tokenAuthority.publishApproval(
            IMintIntent.ApprovalParams({
                operationId: operationId,
                holdId: keccak256("burn-consumed-operation"),
                amount: 100e6,
                recipient: bob,
                stablecoin: address(wrappedStablecoin)
            }),
            uint64(block.timestamp + 1 days)
        );
    }

    function test_revokeOperationId_blocksBurnAndApproval() public {
        uint256 operationId = 4;

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.revokeOperationId(operationId);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(address(reserveLedgerToken), 100e6, operationId);

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        tokenAuthority.publishApproval(
            IMintIntent.ApprovalParams({
                operationId: operationId,
                holdId: keccak256("revoked-operation"),
                amount: 100e6,
                recipient: bob,
                stablecoin: address(wrappedStablecoin)
            }),
            uint64(block.timestamp + 1 days)
        );
    }

    function test_revokeOperationId_revokesReservedMintApproval() public {
        uint256 operationId = 5;
        bytes32 holdId = keccak256("revoke-reserved-operation");
        IMintIntent.ApprovalParams memory params = IMintIntent.ApprovalParams({
            operationId: operationId,
            holdId: holdId,
            amount: 100e6,
            recipient: bob,
            stablecoin: address(wrappedStablecoin)
        });

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        Approval memory publishedApproval = tokenAuthority.getApproval(holdId);
        assertEq(publishedApproval.operationId, operationId, "approval operation id");

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.revokeOperationId(operationId);

        Approval memory approval = tokenAuthority.getApproval(holdId);
        assertEq(approval.flags, 2, "approval revoked");

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.InvalidApproval.selector, holdId, uint256(2))
        );
        tokenAuthority.mintWithApproval(params);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(address(wrappedStablecoin), 100e6, operationId);
    }

    function test_revokeApproval_revokesOperationId() public {
        uint256 operationId = 7;
        bytes32 holdId = keccak256("revoke-approval-operation");

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.publishApproval(
            IMintIntent.ApprovalParams({
                operationId: operationId,
                holdId: holdId,
                amount: 100e6,
                recipient: bob,
                stablecoin: address(wrappedStablecoin)
            }),
            uint64(block.timestamp + 1 days)
        );

        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.revokeApproval(holdId);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(address(wrappedStablecoin), 100e6, operationId);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test mint intent functionality
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_initialize_grantsPublisherRole() public view {
        assertTrue(tokenAuthority.hasRole(tokenAuthority.PUBLISHER_ROLE(), tokenAuthorityPublisher));
    }

    function test_publishRevokeExtend_revertWhenNotPublisher() public {
        IMintIntent.ApprovalParams memory params = _approvalParams(10, keccak256("not-publisher"));

        vm.startPrank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                tokenAuthority.PUBLISHER_ROLE()
            )
        );
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                tokenAuthority.PUBLISHER_ROLE()
            )
        );
        tokenAuthority.revokeApproval(params.holdId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                tokenAuthority.PUBLISHER_ROLE()
            )
        );
        tokenAuthority.revokeOperationId(params.operationId);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                tokenAuthority.PUBLISHER_ROLE()
            )
        );
        tokenAuthority.extendApproval(params.holdId, uint64(block.timestamp + 2 days));
        vm.stopPrank();
    }

    function test_publishApproval_storesFieldsAndEmits() public {
        uint256 operationId = 11;
        bytes32 holdId = keccak256("publish-stores-fields");
        uint64 expiry = uint64(block.timestamp + 1 days);
        IMintIntent.ApprovalParams memory params = _approvalParams(operationId, holdId);

        vm.prank(tokenAuthorityPublisher);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit IMintIntent.ApprovalPublished(
            tokenAuthorityPublisher,
            operationId,
            holdId,
            address(wrappedStablecoin),
            bob,
            100e6,
            expiry
        );
        tokenAuthority.publishApproval(params, expiry);

        Approval memory approval = tokenAuthority.getApproval(holdId);
        assertEq(approval.amount, params.amount, "approval amount");
        assertEq(approval.recipient, params.recipient, "approval recipient");
        assertEq(approval.stablecoin, params.stablecoin, "approval stablecoin");
        assertEq(approval.expiry, expiry, "approval expiry");
        assertEq(approval.flags, 0, "approval flags");
        assertEq(approval.operationId, operationId, "approval operation id");
    }

    function test_publishApproval_rejectsInvalidInputsAndDuplicates() public {
        vm.startPrank(tokenAuthorityPublisher);

        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.publishApproval(
            _approvalParams(0, keccak256("zero-operation")), uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(IMintIntentErrors.InvalidHoldId.selector);
        tokenAuthority.publishApproval(
            _approvalParams(12, bytes32(0)), uint64(block.timestamp + 1 days)
        );

        IMintIntent.ApprovalParams memory params = _approvalParams(13, keccak256("invalid-publish"));

        params.amount = 0;
        vm.expectRevert(IMintIntentErrors.InvalidAmount.selector);
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        params = _approvalParams(14, keccak256("zero-stablecoin"));
        params.stablecoin = address(0);
        vm.expectRevert(IMintIntentErrors.InvalidStablecoin.selector);
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        params = _approvalParams(15, keccak256("zero-recipient"));
        params.recipient = address(0);
        vm.expectRevert(IMintIntentErrors.InvalidRecipient.selector);
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        vm.expectRevert(IMintIntentErrors.InvalidExpiry.selector);
        tokenAuthority.publishApproval(
            _approvalParams(16, keccak256("expired-expiry")), uint64(block.timestamp)
        );

        params = _approvalParams(17, keccak256("duplicate-original"));
        tokenAuthority.publishApproval(params, uint64(block.timestamp + 1 days));

        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.ApprovalExistsForOperationId.selector, 17)
        );
        tokenAuthority.publishApproval(
            _approvalParams(17, keccak256("duplicate-operation")), uint64(block.timestamp + 1 days)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForHoldId.selector, params.holdId
            )
        );
        tokenAuthority.publishApproval(
            _approvalParams(18, params.holdId), uint64(block.timestamp + 1 days)
        );

        vm.stopPrank();
    }

    function test_extendApproval_updatesExpiryAndEmits() public {
        uint256 operationId = 19;
        bytes32 holdId = keccak256("extend-success");
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint64 newExpiry = uint64(block.timestamp + 2 days);
        IMintIntent.ApprovalParams memory params = _approvalParams(operationId, holdId);
        _publishApproval(params, expiry);

        vm.prank(tokenAuthorityPublisher);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit IMintIntent.ApprovalExtended(tokenAuthorityPublisher, holdId, operationId, newExpiry);
        tokenAuthority.extendApproval(holdId, newExpiry);

        Approval memory approval = tokenAuthority.getApproval(holdId);
        assertEq(approval.expiry, newExpiry, "approval expiry");
        assertEq(approval.operationId, operationId, "approval operation id");
    }

    function test_extendApproval_rejectsSameOlderRevokedConsumedAndNonexistent() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        IMintIntent.ApprovalParams memory params = _approvalParams(20, keccak256("extend-invalid"));
        _publishApproval(params, expiry);

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExpiryNotExtended.selector, params.holdId, expiry, expiry
            )
        );
        tokenAuthority.extendApproval(params.holdId, expiry);

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExpiryNotExtended.selector,
                params.holdId,
                expiry - 1,
                expiry
            )
        );
        tokenAuthority.extendApproval(params.holdId, expiry - 1);

        IMintIntent.ApprovalParams memory revoked = _approvalParams(21, keccak256("extend-revoked"));
        _publishApproval(revoked, expiry);
        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.revokeApproval(revoked.holdId);

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApproval.selector, revoked.holdId, uint256(2)
            )
        );
        tokenAuthority.extendApproval(revoked.holdId, expiry + 1);

        IMintIntent.ApprovalParams memory consumed =
            _approvalParams(22, keccak256("extend-consumed"));
        _publishApproval(consumed, expiry);
        vm.prank(minter);
        tokenAuthority.mintWithApproval(consumed);

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApproval.selector, consumed.holdId, uint256(1)
            )
        );
        tokenAuthority.extendApproval(consumed.holdId, expiry + 1);

        bytes32 missingHoldId = keccak256("extend-missing");
        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalNotExistsForHoldId.selector, missingHoldId
            )
        );
        tokenAuthority.extendApproval(missingHoldId, expiry + 1);
    }

    function test_mintWithApproval_consumesApprovalAndRejectsReuse() public {
        uint256 operationId = 23;
        bytes32 holdId = keccak256("mint-with-approval");
        IMintIntent.ApprovalParams memory params = _approvalParams(operationId, holdId);
        _publishApproval(params, uint64(block.timestamp + 1 days));

        vm.prank(minter);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit IMintIntent.ApprovalConsumed(minter, operationId, holdId);
        tokenAuthority.mintWithApproval(params);

        Approval memory approval = tokenAuthority.getApproval(holdId);
        assertEq(approval.flags, 1, "approval consumed");
        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "recipient balance");
        assertEq(
            tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter),
            900e6,
            "minter allowance"
        );

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.InvalidApproval.selector, holdId, uint256(1))
        );
        tokenAuthority.mintWithApproval(params);

        vm.prank(tokenAuthorityPublisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        tokenAuthority.publishApproval(
            _approvalParams(operationId, keccak256("consumed-operation-republish")),
            uint64(block.timestamp + 1 days)
        );
    }

    function test_mintWithApproval_limitFailuresDoNotConsumeApproval() public {
        IMintIntent.ApprovalParams memory allowanceParams =
            _approvalParams(30, keccak256("approval-allowance-limit"));
        _publishApproval(allowanceParams, uint64(block.timestamp + 1 days));

        vm.prank(maliciousUser);
        vm.expectRevert(ITokenAuthority.MinterAllowanceExceeded.selector);
        tokenAuthority.mintWithApproval(allowanceParams);

        Approval memory approval = tokenAuthority.getApproval(allowanceParams.holdId);
        assertEq(approval.flags, 0, "arbitrary caller failure should not consume approval");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), minter, 99e6);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MinterAllowanceExceeded.selector);
        tokenAuthority.mintWithApproval(allowanceParams);

        approval = tokenAuthority.getApproval(allowanceParams.holdId);
        assertEq(approval.flags, 0, "allowance failure should not consume approval");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), minter, 100e6);

        vm.prank(minter);
        tokenAuthority.mintWithApproval(allowanceParams);

        IMintIntent.ApprovalParams memory txnLimitParams =
            _approvalParams(31, keccak256("approval-txn-limit"));
        _publishApproval(txnLimitParams, uint64(block.timestamp + 1 days));

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), minter, 100e6);
        tokenAuthority.setTxnMintLimit(address(wrappedStablecoin), 99e6);
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintTxnLimitExceeded.selector);
        tokenAuthority.mintWithApproval(txnLimitParams);

        approval = tokenAuthority.getApproval(txnLimitParams.holdId);
        assertEq(approval.flags, 0, "txn limit failure should not consume approval");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setTxnMintLimit(address(wrappedStablecoin), 100e6);

        vm.prank(minter);
        tokenAuthority.mintWithApproval(txnLimitParams);
    }

    function test_mintWithApproval_invalidParamsReportExpectedBooleans() public {
        IMintIntent.ApprovalParams memory params = _approvalParams(24, keccak256("invalid-params"));
        _publishApproval(params, uint64(block.timestamp + 1 days));

        IMintIntent.ApprovalParams memory invalid = params;
        invalid.holdId = keccak256("wrong-hold");
        vm.prank(minter);
        _expectInvalidApprovalParams(false, true, true, true, true, true);
        tokenAuthority.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.holdId = bytes32(0);
        vm.prank(minter);
        _expectInvalidApprovalParams(true, true, true, true, true, true);
        tokenAuthority.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.operationId = 25;
        vm.prank(minter);
        _expectInvalidApprovalParams(false, true, false, false, false, false);
        tokenAuthority.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.amount = 99e6;
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, true, false, false, false);
        tokenAuthority.mintWithApproval(invalid);

        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.recipient = alice;
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, false, true, false, false);
        tokenAuthority.mintWithApproval(invalid);

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(backedStablecoin), minter, 100e6);
        invalid = _approvalParams(24, keccak256("invalid-params"));
        invalid.stablecoin = address(backedStablecoin);
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, false, false, true, false);
        tokenAuthority.mintWithApproval(invalid);

        IMintIntent.ApprovalParams memory expired =
            _approvalParams(26, keccak256("expired-approval"));
        _publishApproval(expired, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(minter);
        _expectInvalidApprovalParams(false, false, false, false, false, true);
        tokenAuthority.mintWithApproval(expired);
    }

    /// @dev The error params are deliberately flat rather than wrapped in a struct: off-chain
    /// clients that stringify a decoded tuple render it as an opaque object instead of the
    /// individual failures. A struct of six bools is a static tuple, so re-nesting them would
    /// encode to the same bytes and only change the selector -- hence the selector assertion
    /// below is what catches a regression, and the decode confirms the bools stay in order.
    function test_mintWithApproval_invalidParamsRevertDataIsFlat() public {
        IMintIntent.ApprovalParams memory params =
            _approvalParams(28, keccak256("flat-revert-data"));
        _publishApproval(params, uint64(block.timestamp + 1 days));

        IMintIntent.ApprovalParams memory invalid = params;
        invalid.amount = 99e6;

        bytes memory callData = abi.encodeCall(TokenAuthority.mintWithApproval, (invalid));

        vm.prank(minter);
        (bool success, bytes memory revertData) = address(tokenAuthority).call(callData);

        assertFalse(success, "call should revert");
        assertEq(revertData.length, 4 + 6 * 32, "selector plus six words");
        assertEq(
            bytes4(revertData),
            IMintIntentErrors.InvalidApprovalParams.selector,
            "InvalidApprovalParams selector"
        );
        // Pinned so a struct-wrapped signature -- which encodes identically -- is caught here.
        assertEq(
            bytes4(revertData), bytes4(0xf474cfad), "flat InvalidApprovalParams(bool x6) selector"
        );

        bytes memory args = new bytes(revertData.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = revertData[i + 4];
        }

        (
            bool invalidHoldId,
            bool invalidOperationId,
            bool invalidAmount,
            bool invalidRecipient,
            bool stablecoinIsWrong,
            bool invalidExpiry
        ) = abi.decode(args, (bool, bool, bool, bool, bool, bool));

        assertFalse(invalidHoldId, "hold ID valid");
        assertFalse(invalidOperationId, "operation ID valid");
        assertTrue(invalidAmount, "amount mismatch reported");
        assertFalse(invalidRecipient, "recipient valid");
        assertFalse(stablecoinIsWrong, "stablecoin valid");
        assertFalse(invalidExpiry, "expiry valid");
    }

    function test_revokeApprovalAndOperationId_emitFieldsAndBlockReuse() public {
        IMintIntent.ApprovalParams memory revokedApproval =
            _approvalParams(27, keccak256("revoke-approval-fields"));
        _publishApproval(revokedApproval, uint64(block.timestamp + 1 days));

        vm.prank(tokenAuthorityPublisher);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit IMintIntent.ApprovalRevoked(
            tokenAuthorityPublisher, revokedApproval.holdId, revokedApproval.operationId
        );
        tokenAuthority.revokeApproval(revokedApproval.holdId);

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApproval.selector, revokedApproval.holdId, uint256(2)
            )
        );
        tokenAuthority.mintWithApproval(revokedApproval);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(
            address(wrappedStablecoin), 100e6, revokedApproval.operationId
        );

        IMintIntent.ApprovalParams memory revokedOperation =
            _approvalParams(28, keccak256("revoke-operation-fields"));
        _publishApproval(revokedOperation, uint64(block.timestamp + 1 days));

        vm.startPrank(tokenAuthorityPublisher);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit IMintIntent.ApprovalRevoked(
            tokenAuthorityPublisher, revokedOperation.holdId, revokedOperation.operationId
        );
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit IMintIntent.OperationIdRevoked(
            tokenAuthorityPublisher, revokedOperation.operationId, revokedOperation.holdId
        );
        tokenAuthority.revokeOperationId(revokedOperation.operationId);
        vm.stopPrank();

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApproval.selector, revokedOperation.holdId, uint256(2)
            )
        );
        tokenAuthority.mintWithApproval(revokedOperation);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        tokenAuthority.burnWithOperationId(
            address(wrappedStablecoin), 100e6, revokedOperation.operationId
        );
    }

    function test_setMintIntentVersion_requiredGatesPlainMintButAllowsApprovalMint() public {
        IMintIntent.ApprovalParams memory params =
            _approvalParams(29, keccak256("required-version"));
        _publishApproval(params, uint64(block.timestamp + 1 days));

        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                DEFAULT_ADMIN_ROLE
            )
        );
        tokenAuthority.setMintIntentVersion(ITokenAuthority.MintIntentVersion.Required);

        vm.prank(tokenAuthorityAdmin);
        vm.expectEmit(true, false, false, true, address(tokenAuthority));
        emit ITokenAuthority.MintIntentVersionSet(
            tokenAuthorityAdmin, ITokenAuthority.MintIntentVersion.Required
        );
        tokenAuthority.setMintIntentVersion(ITokenAuthority.MintIntentVersion.Required);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintIntentRequired.selector);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.mintBridgeEcosystem(address(reserveLedgerToken), alice, 1);

        vm.prank(minter);
        tokenAuthority.mintWithApproval(params);

        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "approval mint balance");
        assertEq(reserveLedgerToken.balanceOf(alice), 1, "bridge ecosystem mint balance");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test wrapping functionality
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_wrapIntoSingle_revert() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.startPrank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);
        vm.expectRevert(SingleTokenHandler.NotSupported.selector);
        tokenAuthority.wrap(address(reserveLedgerToken), bob, 50e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(alice), 100e6, "rl alice bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter),
            150e6,
            "rl minter allowance"
        );
    }

    function test_wrapIntoWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.startPrank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);

        vm.expectEmit(true, true, false, true, address(reserveLedgerWrappedHandler));
        emit ITokenHandler.Wrapped(address(wrappedStablecoin), bob, 50e6);
        tokenAuthority.wrap(address(wrappedStablecoin), bob, 50e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(alice), 50e6, "rl alice bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter),
            150e6,
            "rl minter allowance"
        );

        assertEq(wrappedStablecoin.balanceOf(bob), 50e6, "wrappedStablecoin bob bal");
        assertEq(
            reserveLedgerToken.balanceOf(address(wrappedStablecoin)),
            50e6,
            "rl wrappedStablecoin bal"
        );
        assertEq(wrappedStablecoin.totalSupply(), 50e6, "wrappedStablecoin total supply");
    }

    function test_wrapIntoBacked() public {
        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));
        assertEq(reserveStore, address(0), "reserve store shouldnt be set yet");

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.startPrank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);

        vm.expectEmit(true, true, false, true, address(reserveLedgerBackedHandler));
        emit ITokenHandler.Wrapped(address(backedStablecoin), charles, 50e6);
        tokenAuthority.wrap(address(backedStablecoin), charles, 50e6);
        vm.stopPrank();

        reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        assertEq(reserveLedgerToken.balanceOf(alice), 50e6, "rl alice bal");
        assertEq(reserveLedgerToken.balanceOf(reserveStore), 50e6, "rl reserve store bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter),
            150e6,
            "rl minter allowance"
        );

        assertEq(backedStablecoin.balanceOf(charles), 50e6, "backedStablecoin bob bal");
        assertEq(backedStablecoin.totalSupply(), 50e6, "backedStablecoin total supply");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test unwrapping functionality
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_unwrapReserveLedgerTokens() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.transfer(tokenAuthorityAdmin, 50e6);

        vm.startPrank(tokenAuthorityAdmin);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);
        vm.expectRevert(SingleTokenHandler.NotSupported.selector);
        tokenAuthority.unwrap(address(reserveLedgerToken), 50e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(alice), 50e6, "rl alice bal");
        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 50e6, "rl token auth admin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter),
            150e6,
            "rl minter allowance"
        );
    }

    function test_unwrapStablecoinsWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        vm.prank(bob);
        wrappedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        wrappedStablecoin.approve(address(tokenAuthority), 100e6);

        vm.expectEmit(true, true, false, true, address(reserveLedgerWrappedHandler));
        emit ITokenHandler.Unwrapped(address(wrappedStablecoin), tokenAuthorityAdmin, 100e6);
        tokenAuthority.unwrap(address(wrappedStablecoin), 100e6);
        vm.stopPrank();

        assertEq(
            reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 0, "rl wrappedStablecoin bal"
        );
        assertEq(wrappedStablecoin.balanceOf(bob), 0, "bob rl wrappedStablecoin bal");
        assertEq(
            wrappedStablecoin.balanceOf(tokenAuthorityAdmin),
            0,
            "token auth admin rl wrappedStablecoin bal"
        );
        assertEq(
            reserveLedgerToken.balanceOf(tokenAuthorityAdmin),
            100e6,
            "token auth admin wrappedStablecoin bal"
        );
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(wrappedStablecoin.totalSupply(), 0, "wrappedStablecoin total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter),
            900e6,
            "wrappedStablecoin minter allowance"
        );
    }

    function test_unwrapStablecoinsBacked() public {
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        vm.prank(charles);
        backedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        backedStablecoin.approve(address(tokenAuthority), 100e6);

        vm.expectEmit(true, true, false, true, address(reserveLedgerBackedHandler));
        emit ITokenHandler.Unwrapped(address(backedStablecoin), tokenAuthorityAdmin, 100e6);
        tokenAuthority.unwrap(address(backedStablecoin), 100e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), 0, "rl backedStablecoin bal");
        assertEq(backedStablecoin.balanceOf(charles), 0, "rl backedStablecoin bal");
        assertEq(reserveLedgerToken.balanceOf(charles), 0, "rl charles bal");
        assertEq(
            reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 100e6, "rl token auth admin bal"
        );
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 0, "backedStablecoin total supply");
        assertEq(
            tokenAuthority.getMinterAllowance(address(backedStablecoin), minter),
            900e6,
            "backedStablecoin minter allowance"
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test intiailizer
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_tokenAuthorityInitialize() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        newTokenAuthority.initialize(
            bridgeAdmin, tokenAuthorityPublisher, address(mintIntentRegistry)
        );
        bool adminHasRole = newTokenAuthority.hasRole(DEFAULT_ADMIN_ROLE, bridgeAdmin);

        assert(adminHasRole);
        assertEq(address(newTokenAuthority.mintIntentRegistry()), address(mintIntentRegistry));
    }

    function test_tokenAuthorityInitialize_revertWhenDisabled() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), true);
        vm.expectRevert(InvalidInitialization.selector);
        newTokenAuthority.initialize(
            bridgeAdmin, tokenAuthorityPublisher, address(mintIntentRegistry)
        );
    }

    function test_tokenAuthorityInitialize_revertWhenRegistryIsZero() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        vm.expectRevert(IMintIntentErrors.InvalidRegistry.selector);
        newTokenAuthority.initialize(bridgeAdmin, tokenAuthorityPublisher, address(0));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test mint error cases
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_mint_revertWhenAmountIsZero() public {
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.AmountCannotBeZero.selector);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 0);
    }

    function test_mint_revertWhenMinterAllowanceExceeded() public {
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MinterAllowanceExceeded.selector);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 500e6); // allowance is 250e6
    }

    function test_mint_revertWhenMintTxnLimitExceeded() public {
        // Set a low txn limit
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setTxnMintLimit(address(reserveLedgerToken), 50e6);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintTxnLimitExceeded.selector);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);
    }

    function test_mint_revertWhenTokenHandlerNotSet() public {
        address randomToken = makeAddr("randomToken");
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(randomToken, minter, 1000e6);
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setTxnMintLimit(randomToken, 1000e6);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.TokenHandlerNotSet.selector);
        tokenAuthority.mint(randomToken, alice, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test mintBridgeEcosystem
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_mintBridgeEcosystem() public {
        vm.prank(tokenAuthorityAdmin);
        vm.expectEmit(true, true, false, true, address(reserveLedgerWrappedHandler));
        emit ITokenHandler.Minted(address(wrappedStablecoin), bob, 100e6);
        tokenAuthority.mintBridgeEcosystem(address(wrappedStablecoin), bob, 100e6);

        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "bob wrappedStablecoin bal");
        assertEq(
            reserveLedgerToken.balanceOf(address(wrappedStablecoin)),
            100e6,
            "rl wrappedStablecoin bal"
        );
    }

    function test_mintBridgeEcosystem_revertWhenNotBridgeEcosystemRole() public {
        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                BRIDGE_ECOSYSTEM_CONTRACT_ROLE
            )
        );
        tokenAuthority.mintBridgeEcosystem(address(wrappedStablecoin), bob, 100e6);
    }

    function test_mintBridgeEcosystem_revertWhenTokenHandlerNotSet() public {
        address randomToken = makeAddr("randomToken");

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.TokenHandlerNotSet.selector);
        tokenAuthority.mintBridgeEcosystem(randomToken, bob, 100e6);
    }

    function test_mintBridgeEcosystem_revertWhenAmountExceedsAbsoluteMax() public {
        uint256 exceedsMax = 1_000_000_001 * 1e6;

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.AmountExceedsAbsoluteMax.selector);
        tokenAuthority.mintBridgeEcosystem(address(wrappedStablecoin), bob, exceedsMax);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test burn error cases
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_burn_revertWhenNotBurnerRole() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, BURNER_ROLE
            )
        );
        tokenAuthority.burn(address(reserveLedgerToken), 100e6);
    }

    /// @dev burnWithOperationId is the only external path into consumeUnusedOperationId, which
    /// retires an operation ID for every controller sharing the registry. Asserts the role gate
    /// holds and that a rejected call leaves the ID claimable.
    function test_burnWithOperationId_revertWhenNotBurnerRole() public {
        uint256 operationId = 4242;

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, BURNER_ROLE
            )
        );
        tokenAuthority.burnWithOperationId(address(reserveLedgerToken), 100e6, operationId);

        assertEq(
            uint256(mintIntentRegistry.getOperationState(operationId)),
            uint256(OperationState.UNUSED),
            "a rejected burn must not retire the operation ID"
        );
    }

    function test_burn_revertWhenTokenHandlerNotSet() public {
        address randomToken = makeAddr("randomToken");

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.TokenHandlerNotSet.selector);
        tokenAuthority.burn(randomToken, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test unwrap error cases
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_unwrap_revertWhenNotUnwrapperRole() public {
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        vm.prank(bob);
        wrappedStablecoin.approve(address(tokenAuthority), 100e6);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, bob, UNWRAPPER_ROLE
            )
        );
        tokenAuthority.unwrap(address(wrappedStablecoin), 100e6);
    }

    function test_unwrap_revertWhenTokenHandlerNotSet() public {
        address randomToken = makeAddr("randomToken");

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.TokenHandlerNotSet.selector);
        tokenAuthority.unwrap(randomToken, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test wrap error cases
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_wrap_revertWhenAmountIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ITokenAuthority.AmountCannotBeZero.selector);
        tokenAuthority.wrap(address(wrappedStablecoin), bob, 0);
    }

    function test_wrap_revertWhenTokenHandlerNotSet() public {
        address randomToken = makeAddr("randomToken");

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);

        vm.prank(alice);
        vm.expectRevert(ITokenAuthority.TokenHandlerNotSet.selector);
        tokenAuthority.wrap(randomToken, bob, 50e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test setTxnMintLimit
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_setTxnMintLimit() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setTxnMintLimit(address(wrappedStablecoin), 500e6);

        assertEq(tokenAuthority.getStablecoinTxnMintLimit(address(wrappedStablecoin)), 500e6);
    }

    function test_setTxnMintLimit_revertWhenNotMintRateLimitSetterRole() public {
        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                MINT_RATE_LIMIT_SETTER_ROLE
            )
        );
        tokenAuthority.setTxnMintLimit(address(wrappedStablecoin), 500e6);
    }

    function test_setTxnMintLimit_revertWhenAmountExceedsAbsoluteMax() public {
        uint256 exceedsMax = 1_000_000_000 * 1e6 + 1; // exactly at absolute max, should fail

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.AmountExceedsAbsoluteMax.selector);
        tokenAuthority.setTxnMintLimit(address(wrappedStablecoin), exceedsMax);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test setMinterAllowance
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_setMinterAllowance() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), alice, 500e6);

        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), alice), 500e6);
    }

    function test_setMinterAllowance_revertWhenNotMintRateLimitSetterRole() public {
        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                MINT_RATE_LIMIT_SETTER_ROLE
            )
        );
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), alice, 500e6);
    }

    function test_setMinterAllowance_revertWhenAmountExceedsAbsoluteMax() public {
        uint256 exceedsMax = 1_000_000_000 * 1e6 + 1; // exactly at absolute max, should fail

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.AmountExceedsAbsoluteMax.selector);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), alice, exceedsMax);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test setTokenHandler
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_setTokenHandler() public {
        address newHandler = address(new SingleTokenHandler(address(tokenAuthority)));

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setTokenHandler(address(wrappedStablecoin), newHandler);

        assertEq(tokenAuthority.getTokenHandler(address(wrappedStablecoin)), newHandler);
    }

    function test_setTokenHandler_revertWhenTokenHandlerIsInvalid() public {
        address newHandler = makeAddr("newHandler");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.InvalidTokenHandler.selector);
        tokenAuthority.setTokenHandler(address(wrappedStablecoin), newHandler);
    }

    function test_setTokenHandler_revertWhenNotPaused() public {
        address newHandler = address(new SingleTokenHandler(address(tokenAuthority)));

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinNotPaused.selector);
        tokenAuthority.setTokenHandler(address(wrappedStablecoin), newHandler);
    }

    function test_setTokenHandler_revertWhenNotTokenAuthorityHandlerSetterRole() public {
        address newHandler = makeAddr("newHandler");

        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                TOKEN_AUTHORITY_HANDLER_SETTER_ROLE
            )
        );
        tokenAuthority.setTokenHandler(address(wrappedStablecoin), newHandler);
    }

    function test_setTokenHandler_revertWhenStablecoinNotRegistered() public {
        address unregisteredStablecoin = makeAddr("unregisteredStablecoin");
        address newHandler = address(new SingleTokenHandler(address(tokenAuthority)));

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(unregisteredStablecoin, true);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinNotRegistered.selector);
        tokenAuthority.setTokenHandler(unregisteredStablecoin, newHandler);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test setStablecoinPaused
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_stablecoinPauser_role_constant() public view {
        assertEq(tokenAuthority.STABLECOIN_PAUSER_ROLE(), keccak256("STABLECOIN_PAUSER_ROLE"));
    }

    function test_stablecoinIsPaused_defaults_false() public view {
        assertFalse(tokenAuthority.stablecoinIsPaused(address(wrappedStablecoin)));
    }

    function test_setStablecoinPaused_revertWhenNotPauser() public {
        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                STABLECOIN_PAUSER_ROLE
            )
        );
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);
    }

    function test_setStablecoinPaused_pauses_and_emits() public {
        vm.prank(tokenAuthorityAdmin);
        vm.expectEmit(true, true, false, true, address(tokenAuthority));
        emit ITokenAuthority.StablecoinPauseSet(
            tokenAuthorityAdmin, address(wrappedStablecoin), true
        );
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        assertTrue(tokenAuthority.stablecoinIsPaused(address(wrappedStablecoin)));
    }

    function test_setStablecoinPaused_unpauses_and_emits() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(tokenAuthorityAdmin);
        vm.expectEmit(true, true, false, true, address(tokenAuthority));
        emit ITokenAuthority.StablecoinPauseSet(
            tokenAuthorityAdmin, address(wrappedStablecoin), false
        );
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), false);

        assertFalse(tokenAuthority.stablecoinIsPaused(address(wrappedStablecoin)));
    }

    function test_setStablecoinPaused_noop_whenAlreadyPaused() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.recordLogs();
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertTrue(tokenAuthority.stablecoinIsPaused(address(wrappedStablecoin)));
    }

    function test_mint_revertWhenPaused() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.StablecoinPaused.selector);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);
    }

    function test_burn_revertWhenPaused() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinPaused.selector);
        tokenAuthority.burn(address(wrappedStablecoin), 100e6);
    }

    function test_wrap_revertWhenPaused() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(alice);
        vm.expectRevert(ITokenAuthority.StablecoinPaused.selector);
        tokenAuthority.wrap(address(wrappedStablecoin), bob, 100e6);
    }

    function test_unwrap_revertWhenPaused() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinPaused.selector);
        tokenAuthority.unwrap(address(wrappedStablecoin), 100e6);
    }

    function test_mint_succeedsAfterUnpause() public {
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), false);
        vm.stopPrank();

        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        assertEq(wrappedStablecoin.balanceOf(bob), 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test registerStablecoin
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_registerStablecoin() public {
        address newStablecoin = makeAddr("newStablecoin");

        vm.mockCall(
            address(reserveLedgerToken),
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.mockCall(
            newStablecoin,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.prank(tokenAuthorityAdmin);
        vm.expectEmit(true, true, false, true, address(tokenAuthority));
        emit ITokenAuthority.StablecoinRegistered(
            tokenAuthorityAdmin, newStablecoin, address(reserveLedgerWrappedHandler), 1_000_000e6
        );
        tokenAuthority.registerStablecoin(
            newStablecoin, address(reserveLedgerWrappedHandler), 1_000_000e6
        );

        assertEq(tokenAuthority.getStablecoinTxnMintLimit(newStablecoin), 1_000_000e6);
    }

    function test_registerStablecoin_revertWhenNotDefaultAdmin() public {
        address handlerSetter = makeAddr("handlerSetter");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, handlerSetter);

        vm.prank(handlerSetter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                handlerSetter,
                DEFAULT_ADMIN_ROLE
            )
        );
        tokenAuthority.registerStablecoin(
            makeAddr("newStablecoin"), address(reserveLedgerWrappedHandler), 1_000_000e6
        );
    }

    function test_registerStablecoin_revertWhenPrecisionMismatch() public {
        address newStablecoin = makeAddr("precisionMismatchStablecoin");

        vm.mockCall(
            address(reserveLedgerToken),
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.mockCall(
            newStablecoin,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(18))
        );

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenAuthority.PrecisionMismatch.selector, uint256(6), 18)
        );
        tokenAuthority.registerStablecoin(
            newStablecoin, address(reserveLedgerWrappedHandler), 1_000_000e6
        );
    }

    function test_registerStablecoin_revertWhenStablecoinAlreadyRegistered() public {
        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinAlreadyRegistered.selector);
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin), address(reserveLedgerWrappedHandler), 1_000_000e6
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test getters
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_getStablecoinTxnMintLimit() public view {
        assertEq(tokenAuthority.getStablecoinTxnMintLimit(address(wrappedStablecoin)), 1_000_000e6);
    }

    function test_getTokenHandler() public view {
        assertEq(
            tokenAuthority.getTokenHandler(address(wrappedStablecoin)),
            address(reserveLedgerWrappedHandler)
        );
        assertEq(
            tokenAuthority.getTokenHandler(address(backedStablecoin)),
            address(reserveLedgerBackedHandler)
        );
        assertEq(
            tokenAuthority.getTokenHandler(address(reserveLedgerToken)), address(singleTokenHandler)
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test SingleTokenHandler onlyTokenAuthority modifier
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_singleTokenHandler_mint_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        singleTokenHandler.mint(address(reserveLedgerToken), alice, 100e6);
    }

    function test_singleTokenHandler_burn_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        singleTokenHandler.burn(address(reserveLedgerToken), 100e6);
    }

    function test_singleTokenHandler_wrap_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        singleTokenHandler.wrap(address(reserveLedgerToken), alice, 100e6);
    }

    function test_singleTokenHandler_unwrap_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        singleTokenHandler.unwrap(address(reserveLedgerToken), alice, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test ReserveLedgerWrappedHandler onlyTokenAuthority modifier
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_reserveLedgerWrappedHandler_mint_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerWrappedHandler.mint(address(wrappedStablecoin), bob, 100e6);
    }

    function test_reserveLedgerWrappedHandler_burn_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerWrappedHandler.burn(address(wrappedStablecoin), 100e6);
    }

    function test_reserveLedgerWrappedHandler_wrap_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerWrappedHandler.wrap(address(wrappedStablecoin), bob, 100e6);
    }

    function test_reserveLedgerWrappedHandler_unwrap_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerWrappedHandler.unwrap(address(wrappedStablecoin), bob, 100e6);
    }

    function test_reserveLedgerWrappedHandler_mint_revertWhenPrecisionMismatch() public {
        address precisionMismatchStablecoin = makeAddr("precisionMismatchWrappedStablecoin");

        vm.mockCall(
            precisionMismatchStablecoin,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(18))
        );

        vm.prank(address(tokenAuthority));
        vm.expectRevert(
            abi.encodeWithSelector(ITokenHandler.PrecisionMismatch.selector, uint256(6), 18)
        );
        reserveLedgerWrappedHandler.mint(precisionMismatchStablecoin, bob, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test ReserveLedgerBackedHandler onlyTokenAuthority modifier
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_reserveLedgerBackedHandler_mint_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerBackedHandler.mint(address(backedStablecoin), charles, 100e6);
    }

    function test_reserveLedgerBackedHandler_burn_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerBackedHandler.burn(address(backedStablecoin), 100e6);
    }

    function test_reserveLedgerBackedHandler_wrap_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerBackedHandler.wrap(address(backedStablecoin), charles, 100e6);
    }

    function test_reserveLedgerBackedHandler_unwrap_revertWhenNotTokenAuthority() public {
        vm.prank(maliciousUser);
        vm.expectRevert(ITokenHandler.OnlyTokenAuthority.selector);
        reserveLedgerBackedHandler.unwrap(address(backedStablecoin), charles, 100e6);
    }

    function test_reserveLedgerBackedHandler_mint_revertWhenPrecisionMismatch() public {
        address precisionMismatchStablecoin = makeAddr("precisionMismatchBackedStablecoin");

        vm.mockCall(
            precisionMismatchStablecoin,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(18))
        );

        vm.prank(address(tokenAuthority));
        vm.expectRevert(
            abi.encodeWithSelector(ITokenHandler.PrecisionMismatch.selector, uint256(6), 18)
        );
        reserveLedgerBackedHandler.mint(precisionMismatchStablecoin, charles, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test ReserveLedgerBackedHandler ReserveStoreNotFound error
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_reserveLedgerBackedHandler_burn_revertWhenReserveStoreNotFound() public {
        // Call the handler directly from tokenAuthority address to test ReserveStoreNotFound
        // Use a random stablecoin address that has no reserve store
        address randomStablecoin = makeAddr("randomStablecoin");

        vm.mockCall(
            address(reserveLedgerToken),
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.mockCall(
            randomStablecoin,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.prank(address(tokenAuthority));
        vm.expectRevert(ReserveLedgerBackedHandler.ReserveStoreNotFound.selector);
        reserveLedgerBackedHandler.burn(randomStablecoin, 100e6);
    }

    function test_reserveLedgerBackedHandler_unwrap_revertWhenReserveStoreNotFound() public {
        // Call the handler directly from tokenAuthority address to test ReserveStoreNotFound
        // Use a random stablecoin address that has no reserve store
        address randomStablecoin = makeAddr("randomStablecoin");

        vm.mockCall(
            address(reserveLedgerToken),
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.mockCall(
            randomStablecoin,
            abi.encodeWithSelector(IERC20Metadata.decimals.selector),
            abi.encode(uint256(6))
        );

        vm.prank(address(tokenAuthority));
        vm.expectRevert(ReserveLedgerBackedHandler.ReserveStoreNotFound.selector);
        reserveLedgerBackedHandler.unwrap(randomStablecoin, alice, 100e6);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test ReserveLedgerBackedHandler existing reserveStore branch
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_mintStablecoinsBacked_existingReserveStore() public {
        // First mint creates the reserve store
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));
        assertNotEq(reserveStore, address(0), "reserve store should be set");

        // Second mint should use existing reserve store
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 50e6);

        // Verify reserve store is still the same
        assertEq(
            reserveLedgerBackedHandler.reserveStores(address(backedStablecoin)),
            reserveStore,
            "reserve store should not change"
        );

        assertEq(reserveLedgerToken.balanceOf(reserveStore), 150e6, "rl reserve store bal");
        assertEq(backedStablecoin.balanceOf(charles), 150e6, "charles backed stablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 150e6, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 150e6, "backed stablecoin total supply");
    }

    function test_wrapIntoBacked_existingReserveStore() public {
        // First mint to create the reserve store
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));
        assertNotEq(reserveStore, address(0), "reserve store should be set");

        // Now mint some reserve ledger tokens to alice for wrapping
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 50e6);

        // Wrap should use existing reserve store
        vm.startPrank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);
        tokenAuthority.wrap(address(backedStablecoin), charles, 50e6);
        vm.stopPrank();

        // Verify reserve store is still the same
        assertEq(
            reserveLedgerBackedHandler.reserveStores(address(backedStablecoin)),
            reserveStore,
            "reserve store should not change"
        );

        assertEq(reserveLedgerToken.balanceOf(reserveStore), 150e6, "rl reserve store bal");
        assertEq(backedStablecoin.balanceOf(charles), 150e6, "charles backed stablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 150e6, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 150e6, "backed stablecoin total supply");
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
            recipient: bob,
            stablecoin: address(wrappedStablecoin)
        });
    }

    function _publishApproval(IMintIntent.ApprovalParams memory params, uint64 expiry) internal {
        vm.prank(tokenAuthorityPublisher);
        tokenAuthority.publishApproval(params, expiry);
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
                IMintIntentErrors.InvalidApprovalParams.selector,
                invalidHoldId,
                invalidOperationId,
                invalidAmount,
                invalidRecipient,
                stablecoinIsWrong,
                invalidExpiry
            )
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Seize
    //////////////////////////////////////////////////////////////////////////*/

    uint256 constant SEIZE_HOLDER_BALANCE = 1000e6;

    /// @dev Freezes `frozenHolder` holding SEIZE_HOLDER_BALANCE on both the V3 wrapped stablecoin
    /// (force transfer) and a V2 stablecoin behind the backed handler (burn and re-mint), with
    /// every role and list entry monorail's setup grants.
    function _setUpSeize() internal {
        seizer = makeAddr("seizer");
        seizureWallet = makeAddr("seizureWallet");
        frozenHolder = makeAddr("frozenHolder");
        v2StablecoinAdmin = makeAddr("v2StablecoinAdmin");

        vm.startPrank(bridgeAdmin);
        seizureWalletListId =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.WHITELIST);
        authRegistry.modifyPolicyWhitelist(seizureWalletListId, seizureWallet, true);
        vm.stopPrank();

        // V3: the TokenAuthority holds FORCE_TRANSFER_ROLE; the holder is funded through the
        // wrapped handler so its reserve backing sits inside the coin.
        vm.startPrank(wrappedStablecoinAdmin);
        wrappedStablecoin.grantRole(FORCE_TRANSFER_ROLE, address(tokenAuthority));
        authRegistry.modifyPolicyWhitelist(
            wrappedStablecoin.getMintRecipientPolicyId(), frozenHolder, true
        );
        vm.stopPrank();
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), frozenHolder, SEIZE_HOLDER_BALANCE);
        uint64 wrappedTransferPolicyId = wrappedStablecoin.getTransferPolicyId();
        vm.prank(wrappedStablecoinAdmin);
        authRegistry.modifyPolicyBlacklist(wrappedTransferPolicyId, frozenHolder, true);

        // V2: registered behind the backed handler like the live V2 coins, so issuance puts
        // reserve ledger tokens in a reserve store. The TokenAuthority gets the six V2 roles and
        // both mint-recipient entries from monorail's prepare step.
        v2Stablecoin = new MockStablecoinTemplateV2("V2 Stablecoin", "V2SC", 6, v2StablecoinAdmin);
        vm.startPrank(v2StablecoinAdmin);
        v2Stablecoin.increaseMaxSupply(1_000_000_000e6);
        v2Stablecoin.grantRole(MINTER_ROLE, address(reserveLedgerBackedHandler));
        v2Stablecoin.grantRole(v2Stablecoin.BLOCKER_ROLE(), v2StablecoinAdmin);
        v2Stablecoin.grantRole(v2Stablecoin.UNBLOCKER_ROLE(), v2StablecoinAdmin);
        v2Stablecoin.grantRole(v2Stablecoin.PAUSER_ROLE(), v2StablecoinAdmin);
        v2Stablecoin.addMintRecipient(frozenHolder);
        v2Stablecoin.grantRole(v2Stablecoin.BLOCKED_ADDRESS_BURNER_ROLE(), address(tokenAuthority));
        v2Stablecoin.grantRole(MINTER_ROLE, address(tokenAuthority));
        v2Stablecoin.grantRole(v2Stablecoin.UNBLOCKER_ROLE(), address(tokenAuthority));
        v2Stablecoin.grantRole(v2Stablecoin.BLOCKER_ROLE(), address(tokenAuthority));
        v2Stablecoin.grantRole(v2Stablecoin.PAUSER_ROLE(), address(tokenAuthority));
        v2Stablecoin.grantRole(v2Stablecoin.UNPAUSER_ROLE(), address(tokenAuthority));
        v2Stablecoin.addMintRecipient(seizureWallet);
        v2Stablecoin.addMintRecipient(address(tokenAuthority));
        vm.stopPrank();

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.registerStablecoin(
            address(v2Stablecoin), address(reserveLedgerBackedHandler), 1_000_000e6
        );
        tokenAuthority.setMinterAllowance(address(v2Stablecoin), minter, SEIZE_HOLDER_BALANCE);
        vm.stopPrank();
        vm.prank(minter);
        tokenAuthority.mint(address(v2Stablecoin), frozenHolder, SEIZE_HOLDER_BALANCE);
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.blockAddress(frozenHolder);

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(SEIZER_ROLE, seizer);
        tokenAuthority.setSeizeConfig(
            address(wrappedStablecoin),
            ITokenAuthority.SeizeMode.ForceTransfer,
            address(authRegistry),
            seizureWalletListId
        );
        tokenAuthority.setSeizeConfig(
            address(v2Stablecoin),
            ITokenAuthority.SeizeMode.BurnAndRemint,
            address(authRegistry),
            seizureWalletListId
        );
        vm.stopPrank();
    }

    function _v2ReserveStore() internal view returns (address) {
        return reserveLedgerBackedHandler.reserveStores(address(v2Stablecoin));
    }

    /// @dev Both coins were issued 1000e6 each, so the reserve ledger backs 2000e6 in total.
    function _assertReserveBackingUnchanged() internal view {
        assertEq(reserveLedgerToken.totalSupply(), 2000e6, "rl total supply");
        assertEq(
            reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 1000e6, "rl inside v3 coin"
        );
        assertEq(reserveLedgerToken.balanceOf(_v2ReserveStore()), 1000e6, "rl in v2 reserve store");
    }

    function test_seizerRole_constant() public view {
        // Frozen literal: monorail grants and enumerates this role ID.
        assertEq(
            tokenAuthority.SEIZER_ROLE(),
            0xe770a2b882b0a3a025be15ffce2d5d54f5d719264e701933268dd62f79db677f
        );
        assertEq(tokenAuthority.SEIZER_ROLE(), SEIZER_ROLE);
    }

    function test_seize_seizerRoleIsEnumerable() public {
        _setUpSeize();

        assertEq(tokenAuthority.getRoleMemberCount(SEIZER_ROLE), 1);
        assertEq(tokenAuthority.getRoleMember(SEIZER_ROLE, 0), seizer);
    }

    function test_seize_forceTransfer_movesPartOfFrozenBalance() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(wrappedStablecoin));
        emit StablecoinTemplateV3ErrorsAndEvents.ForceTransferred(
            600e6, frozenHolder, seizureWallet, address(tokenAuthority)
        );
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ISeize.Seized(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6, seizer);
        vm.prank(seizer);
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(wrappedStablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(wrappedStablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertEq(wrappedStablecoin.balanceOf(address(tokenAuthority)), 0, "token authority");
        assertEq(wrappedStablecoin.totalSupply(), 1000e6, "supply");
        assertTrue(wrappedStablecoin.isBlocked(frozenHolder));
        _assertReserveBackingUnchanged();
    }

    function test_seize_forceTransfer_movesWholeFrozenBalance() public {
        _setUpSeize();

        vm.prank(seizer);
        tokenAuthority.seize(
            address(wrappedStablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE
        );

        assertEq(wrappedStablecoin.balanceOf(frozenHolder), 0, "holder");
        assertEq(wrappedStablecoin.balanceOf(seizureWallet), 1000e6, "seizure wallet");
        assertEq(wrappedStablecoin.totalSupply(), 1000e6, "supply");
        _assertReserveBackingUnchanged();
    }

    function test_seize_forceTransfer_pausedCoinStaysPausedWithoutUnpausing() public {
        _setUpSeize();
        vm.startPrank(wrappedStablecoinAdmin);
        wrappedStablecoin.grantRole(wrappedStablecoin.PAUSER_ROLE(), wrappedStablecoinAdmin);
        wrappedStablecoin.pause();
        vm.stopPrank();

        // The V3 coin bypasses its own pause, so the TokenAuthority needs no unpause role on it.
        vm.expectCall(
            address(wrappedStablecoin),
            abi.encodeWithSelector(wrappedStablecoin.unpause.selector),
            0
        );
        vm.prank(seizer);
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);

        assertTrue(wrappedStablecoin.paused());
        assertEq(wrappedStablecoin.balanceOf(seizureWallet), 600e6);
    }

    function test_seize_burnAndRemint_partialSeizeReturnsRemainderToHolder() public {
        _setUpSeize();
        address reserveStore = _v2ReserveStore();

        // The exact on-chain sequence: whole-balance burn, seized mint, remainder mint to self,
        // unblock, transfer back, re-block, then Seized.
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit MockStablecoinTemplateV2.BurnedFromBlockedAddress(
            1000e6, frozenHolder, address(tokenAuthority)
        );
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit MockStablecoinTemplateV2.Minted(600e6, seizureWallet, address(tokenAuthority));
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit MockStablecoinTemplateV2.Minted(
            400e6, address(tokenAuthority), address(tokenAuthority)
        );
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit MockStablecoinTemplateV2.UnblockedAddress(frozenHolder, address(tokenAuthority));
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IERC20.Transfer(address(tokenAuthority), frozenHolder, 400e6);
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit MockStablecoinTemplateV2.BlockedAddress(frozenHolder, address(tokenAuthority));
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ISeize.Seized(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6, seizer);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(v2Stablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertEq(v2Stablecoin.balanceOf(address(tokenAuthority)), 0, "token authority");
        assertEq(v2Stablecoin.totalSupply(), 1000e6, "supply");
        assertTrue(v2Stablecoin.isBlocked(frozenHolder), "holder re-blocked");
        assertEq(reserveLedgerBackedHandler.reserveStores(address(v2Stablecoin)), reserveStore);
        _assertReserveBackingUnchanged();
    }

    function test_seize_burnAndRemint_wholeBalanceSkipsRemainderPath() public {
        _setUpSeize();

        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeWithSelector(IBurnAndRemintStablecoin.unblockAddress.selector),
            0
        );
        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeWithSelector(IBurnAndRemintStablecoin.blockAddress.selector),
            0
        );
        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeCall(IBurnAndRemintStablecoin.mint, (seizureWallet, SEIZE_HOLDER_BALANCE)),
            1
        );
        vm.expectCall(address(v2Stablecoin), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.prank(seizer);
        tokenAuthority.seize(
            address(v2Stablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE
        );

        assertEq(v2Stablecoin.balanceOf(frozenHolder), 0, "holder");
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 1000e6, "seizure wallet");
        assertEq(v2Stablecoin.totalSupply(), 1000e6, "supply");
        assertTrue(v2Stablecoin.isBlocked(frozenHolder));
        _assertReserveBackingUnchanged();
    }

    function test_seize_burnAndRemint_pausedCoinEndsPaused() public {
        _setUpSeize();
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.pause();

        vm.expectCall(
            address(v2Stablecoin), abi.encodeCall(IBurnAndRemintStablecoin.unpause, ()), 1
        );
        vm.expectCall(address(v2Stablecoin), abi.encodeCall(IBurnAndRemintStablecoin.pause, ()), 1);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertTrue(v2Stablecoin.paused(), "re-paused");
        assertEq(v2Stablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertTrue(v2Stablecoin.isBlocked(frozenHolder));
    }

    function test_seize_burnAndRemint_unpausedCoinIsNeverPaused() public {
        _setUpSeize();

        vm.expectCall(
            address(v2Stablecoin), abi.encodeCall(IBurnAndRemintStablecoin.unpause, ()), 0
        );
        vm.expectCall(address(v2Stablecoin), abi.encodeCall(IBurnAndRemintStablecoin.pause, ()), 0);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertFalse(v2Stablecoin.paused());
    }

    function test_seize_burnAndRemint_doesNotSweepStrayTokenAuthorityBalance() public {
        _setUpSeize();
        // A minter sends coins to the TokenAuthority's address outside any seize.
        vm.startPrank(v2StablecoinAdmin);
        v2Stablecoin.grantRole(MINTER_ROLE, v2StablecoinAdmin);
        v2Stablecoin.mint(address(tokenAuthority), 50e6);
        vm.stopPrank();

        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 400e6);

        assertEq(v2Stablecoin.balanceOf(address(tokenAuthority)), 50e6, "stray balance untouched");
        assertEq(v2Stablecoin.balanceOf(frozenHolder), 0, "holder");
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 1000e6, "seizure wallet");
        assertEq(v2Stablecoin.totalSupply(), 1050e6, "supply");
    }

    function test_seize_burnAndRemint_unblocksOnlyHolder() public {
        _setUpSeize();
        address otherFrozenHolder = makeAddr("otherFrozenHolder");
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.blockAddress(otherFrozenHolder);

        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeCall(IBurnAndRemintStablecoin.unblockAddress, (frozenHolder)),
            1
        );
        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeCall(IBurnAndRemintStablecoin.unblockAddress, (otherFrozenHolder)),
            0
        );
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertTrue(v2Stablecoin.isBlocked(frozenHolder));
        assertTrue(v2Stablecoin.isBlocked(otherFrozenHolder));
    }

    function test_seize_ignoresTokenAuthorityStablecoinPause() public {
        _setUpSeize();
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);
        tokenAuthority.setStablecoinPaused(address(v2Stablecoin), true);
        vm.stopPrank();

        vm.startPrank(seizer);
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.stopPrank();

        assertEq(wrappedStablecoin.balanceOf(seizureWallet), 600e6);
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 600e6);
        assertTrue(tokenAuthority.stablecoinIsPaused(address(wrappedStablecoin)));
        assertTrue(tokenAuthority.stablecoinIsPaused(address(v2Stablecoin)));
    }

    function test_seize_revertWhenCallerLacksSeizerRole() public {
        _setUpSeize();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, SEIZER_ROLE
            )
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenStablecoinNotConfigured() public {
        _setUpSeize();

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(backedStablecoin))
        );
        tokenAuthority.seize(address(backedStablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenDestinationNotSeizureWallet() public {
        _setUpSeize();

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.DestinationNotSeizureWallet.selector, bob));
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, bob, 600e6);
    }

    function test_seize_revertWhenDestinationRemovedFromList() public {
        _setUpSeize();
        vm.prank(bridgeAdmin);
        authRegistry.modifyPolicyWhitelist(seizureWalletListId, seizureWallet, false);

        vm.startPrank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.DestinationNotSeizureWallet.selector, seizureWallet)
        );
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.DestinationNotSeizureWallet.selector, seizureWallet)
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.stopPrank();
    }

    function test_seize_revertWhenHolderNotBlocked() public {
        _setUpSeize();
        uint64 wrappedTransferPolicyId = wrappedStablecoin.getTransferPolicyId();
        vm.prank(wrappedStablecoinAdmin);
        authRegistry.modifyPolicyBlacklist(wrappedTransferPolicyId, frozenHolder, false);
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.unblockAddress(frozenHolder);

        vm.startPrank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.HolderNotBlocked.selector, frozenHolder));
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);
        vm.expectRevert(abi.encodeWithSelector(ISeize.HolderNotBlocked.selector, frozenHolder));
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.stopPrank();
    }

    function test_seize_revertWhenAmountIsZeroOrAboveBalance() public {
        _setUpSeize();

        vm.startPrank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeAmount.selector, 0, SEIZE_HOLDER_BALANCE)
        );
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISeize.InvalidSeizeAmount.selector, SEIZE_HOLDER_BALANCE + 1, SEIZE_HOLDER_BALANCE
            )
        );
        tokenAuthority.seize(
            address(wrappedStablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE + 1
        );
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeAmount.selector, 0, SEIZE_HOLDER_BALANCE)
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISeize.InvalidSeizeAmount.selector, SEIZE_HOLDER_BALANCE + 1, SEIZE_HOLDER_BALANCE
            )
        );
        tokenAuthority.seize(
            address(v2Stablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE + 1
        );
        vm.stopPrank();
    }

    function test_seize_revertWhenHolderHasNoBalance() public {
        _setUpSeize();
        address emptyFrozenHolder = makeAddr("emptyFrozenHolder");
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.blockAddress(emptyFrozenHolder);

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.InvalidSeizeAmount.selector, 1, 0));
        tokenAuthority.seize(address(v2Stablecoin), emptyFrozenHolder, seizureWallet, 1);
    }

    function test_seize_revertWhenDestinationIsHolderOrTokenAuthority() public {
        _setUpSeize();

        vm.startPrank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeDestination.selector, frozenHolder)
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, frozenHolder, 600e6);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeDestination.selector, address(tokenAuthority))
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, address(tokenAuthority), 600e6);
        vm.stopPrank();
    }

    function test_seize_revertWhenHolderLeftUnblocked() public {
        _setUpSeize();
        // A coin whose re-block silently does nothing must not leave the holder free.
        vm.mockCall(
            address(v2Stablecoin),
            abi.encodeWithSelector(IBurnAndRemintStablecoin.blockAddress.selector),
            ""
        );

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.HolderNotBlocked.selector, frozenHolder));
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenPauseNotRestored() public {
        _setUpSeize();
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.pause();
        vm.mockCall(address(v2Stablecoin), abi.encodeCall(IBurnAndRemintStablecoin.pause, ()), "");

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.PauseStateNotRestored.selector, true));
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenCoinDoesNotMoveCoins() public {
        _setUpSeize();
        vm.mockCall(
            address(wrappedStablecoin),
            abi.encodeWithSelector(StablecoinTemplateV3.forceTransfer.selector),
            ""
        );

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISeize.SeizeBalanceMismatch.selector, frozenHolder, 400e6, SEIZE_HOLDER_BALANCE
            )
        );
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_issuancePathsNeverUseSeizeRoles() public {
        _setUpSeize();
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(v2Stablecoin), minter, 100e6);
        tokenAuthority.setMinterAllowance(address(wrappedStablecoin), minter, 100e6);
        vm.stopPrank();
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.addMintRecipient(alice);

        bytes4[6] memory seizeOnlySelectors = [
            IBurnAndRemintStablecoin.pause.selector,
            IBurnAndRemintStablecoin.unpause.selector,
            IBurnAndRemintStablecoin.blockAddress.selector,
            IBurnAndRemintStablecoin.unblockAddress.selector,
            IBurnAndRemintStablecoin.burnFromBlockedAddress.selector,
            IERC20.transfer.selector
        ];
        for (uint256 i = 0; i < seizeOnlySelectors.length; i++) {
            vm.expectCall(address(v2Stablecoin), abi.encodeWithSelector(seizeOnlySelectors[i]), 0);
        }
        vm.expectCall(
            address(wrappedStablecoin),
            abi.encodeWithSelector(StablecoinTemplateV3.forceTransfer.selector),
            0
        );

        // V2 issuance still goes through the handler, never the TokenAuthority's direct mint.
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit MockStablecoinTemplateV2.Minted(100e6, alice, address(reserveLedgerBackedHandler));
        vm.prank(minter);
        tokenAuthority.mint(address(v2Stablecoin), alice, 100e6);
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);
    }

    function test_seize_doesNotTouchMintLimits() public {
        _setUpSeize();
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setMinterAllowance(address(v2Stablecoin), minter, 500e6);

        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(tokenAuthority.getMinterAllowance(address(v2Stablecoin), minter), 500e6);
        assertEq(tokenAuthority.getStablecoinTxnMintLimit(address(v2Stablecoin)), 1_000_000e6);
        assertEq(tokenAuthority.getMinterAllowance(address(v2Stablecoin), seizer), 0);
        assertEq(
            tokenAuthority.getMinterAllowance(address(v2Stablecoin), address(tokenAuthority)), 0
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Seize Settings
    //////////////////////////////////////////////////////////////////////////*/

    function test_setSeizeConfig_storesAndEmits() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ITokenAuthority.SeizeConfigSet(
            tokenAuthorityAdmin,
            address(backedStablecoin),
            ITokenAuthority.SeizeMode.ForceTransfer,
            address(authRegistry),
            seizureWalletListId
        );
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeConfig(
            address(backedStablecoin),
            ITokenAuthority.SeizeMode.ForceTransfer,
            address(authRegistry),
            seizureWalletListId
        );

        ITokenAuthority.SeizeConfig memory seizeConfig =
            tokenAuthority.getSeizeConfig(address(backedStablecoin));
        assertEq(uint8(seizeConfig.mode), uint8(ITokenAuthority.SeizeMode.ForceTransfer));
        assertEq(seizeConfig.seizureWalletRegistry, address(authRegistry));
        assertEq(seizeConfig.seizureWalletListId, seizureWalletListId);
    }

    function test_setSeizeConfig_noneClearsSettings() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ITokenAuthority.SeizeConfigSet(
            tokenAuthorityAdmin,
            address(v2Stablecoin),
            ITokenAuthority.SeizeMode.None,
            address(0),
            0
        );
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeConfig(
            address(v2Stablecoin), ITokenAuthority.SeizeMode.None, address(0), 0
        );

        ITokenAuthority.SeizeConfig memory seizeConfig =
            tokenAuthority.getSeizeConfig(address(v2Stablecoin));
        assertEq(uint8(seizeConfig.mode), uint8(ITokenAuthority.SeizeMode.None));
        assertEq(seizeConfig.seizureWalletRegistry, address(0));
        assertEq(seizeConfig.seizureWalletListId, 0);

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(v2Stablecoin))
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_setSeizeConfig_revertWhenModeDoesNotMatchStablecoin() public {
        _setUpSeize();

        // V2 has no forceTransfer; V3 holds its own backing and has no storage blocklist; the
        // reserve ledger supports neither; an address without code answers nothing.
        address[5] memory stablecoins = [
            address(v2Stablecoin),
            address(wrappedStablecoin),
            address(reserveLedgerToken),
            address(reserveLedgerToken),
            alice
        ];
        ITokenAuthority.SeizeMode[5] memory modes = [
            ITokenAuthority.SeizeMode.ForceTransfer,
            ITokenAuthority.SeizeMode.BurnAndRemint,
            ITokenAuthority.SeizeMode.ForceTransfer,
            ITokenAuthority.SeizeMode.BurnAndRemint,
            ITokenAuthority.SeizeMode.BurnAndRemint
        ];

        vm.startPrank(tokenAuthorityAdmin);
        for (uint256 i = 0; i < stablecoins.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ITokenAuthority.SeizeModeMismatch.selector, stablecoins[i], modes[i]
                )
            );
            tokenAuthority.setSeizeConfig(
                stablecoins[i], modes[i], address(authRegistry), seizureWalletListId
            );
        }
        vm.stopPrank();
    }

    function test_setSeizeConfig_revertWhenV3NotYetUpgradedWithForceTransfer() public {
        _setUpSeize();
        // A V3 coin reports FORCE_TRANSFER_ROLE only once it runs the forceTransfer upgrade, so
        // configure_ta_seize must wait for it. Simulated by making the role getter absent.
        vm.mockCallRevert(
            address(backedStablecoin),
            abi.encodeCall(IForceTransferStablecoin.FORCE_TRANSFER_ROLE, ()),
            ""
        );

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenAuthority.SeizeModeMismatch.selector,
                address(backedStablecoin),
                ITokenAuthority.SeizeMode.ForceTransfer
            )
        );
        tokenAuthority.setSeizeConfig(
            address(backedStablecoin),
            ITokenAuthority.SeizeMode.ForceTransfer,
            address(authRegistry),
            seizureWalletListId
        );
    }

    function test_seize_revertWhenBurnReleasesReserveBacking() public {
        _setUpSeize();
        // The misconfiguration the mode check exists for: a V3 coin set to BurnAndRemint while the
        // TokenAuthority holds V3 burner and minter roles. V3's burnFromBlockedAddress pays the
        // backing to the caller, so a whole-balance seize would pass every stablecoin-level check
        // and leave 1000e6 re-minted coins unbacked. The mode check is mocked past to prove the
        // reserve post-condition catches it on its own.
        vm.startPrank(wrappedStablecoinAdmin);
        wrappedStablecoin.grantRole(
            wrappedStablecoin.BLOCKED_ADDRESS_BURNER_ROLE(), address(tokenAuthority)
        );
        wrappedStablecoin.grantRole(MINTER_ROLE, address(tokenAuthority));
        authRegistry.modifyPolicyWhitelist(
            wrappedStablecoin.getMintRecipientPolicyId(), seizureWallet, true
        );
        vm.stopPrank();
        vm.mockCall(
            address(wrappedStablecoin),
            abi.encodeCall(IBurnAndRemintStablecoin.UNBLOCKER_ROLE, ()),
            abi.encode(keccak256("UNBLOCKER_ROLE"))
        );
        vm.mockCallRevert(
            address(wrappedStablecoin),
            abi.encodeCall(IReserveWrappedStablecoin.RESERVE_LEDGER_ADDRESS, ()),
            ""
        );
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeConfig(
            address(wrappedStablecoin),
            ITokenAuthority.SeizeMode.BurnAndRemint,
            address(authRegistry),
            seizureWalletListId
        );
        vm.clearMockedCalls();

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenAuthority.SeizeReserveBalanceChanged.selector,
                address(wrappedStablecoin),
                SEIZE_HOLDER_BALANCE,
                0
            )
        );
        tokenAuthority.seize(
            address(wrappedStablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE
        );
    }

    function test_setSeizeConfig_revertWhenNoneHasLeftoverArguments() public {
        _setUpSeize();

        vm.startPrank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.InvalidSeizeConfig.selector);
        tokenAuthority.setSeizeConfig(
            address(v2Stablecoin), ITokenAuthority.SeizeMode.None, address(authRegistry), 0
        );
        vm.expectRevert(ITokenAuthority.InvalidSeizeConfig.selector);
        tokenAuthority.setSeizeConfig(
            address(v2Stablecoin), ITokenAuthority.SeizeMode.None, address(0), seizureWalletListId
        );
        vm.stopPrank();
    }

    function test_setSeizeConfig_revertWhenNotAdmin() public {
        _setUpSeize();

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, seizer, DEFAULT_ADMIN_ROLE
            )
        );
        tokenAuthority.setSeizeConfig(
            address(v2Stablecoin),
            ITokenAuthority.SeizeMode.BurnAndRemint,
            address(authRegistry),
            seizureWalletListId
        );
    }

    function test_setSeizeConfig_revertWhenStablecoinIsZero() public {
        _setUpSeize();

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.setSeizeConfig(
            address(0),
            ITokenAuthority.SeizeMode.BurnAndRemint,
            address(authRegistry),
            seizureWalletListId
        );
    }

    function test_setSeizeConfig_revertWhenListUnusable() public {
        _setUpSeize();
        vm.startPrank(bridgeAdmin);
        uint64 blacklistId =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.BLACKLIST);
        uint64 listContainingTokenAuthority =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.WHITELIST);
        authRegistry.modifyPolicyWhitelist(
            listContainingTokenAuthority, address(tokenAuthority), true
        );
        vm.stopPrank();

        // Zero registry, the two built-in policies, a blacklist (authorizes everyone unlisted),
        // and a whitelist that names the TokenAuthority itself.
        address[5] memory registries = [
            address(0),
            address(authRegistry),
            address(authRegistry),
            address(authRegistry),
            address(authRegistry)
        ];
        uint64[5] memory listIds =
            [seizureWalletListId, 0, 1, blacklistId, listContainingTokenAuthority];

        vm.startPrank(tokenAuthorityAdmin);
        for (uint256 i = 0; i < registries.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISeize.InvalidSeizureWalletList.selector, registries[i], listIds[i]
                )
            );
            tokenAuthority.setSeizeConfig(
                address(v2Stablecoin),
                ITokenAuthority.SeizeMode.BurnAndRemint,
                registries[i],
                listIds[i]
            );
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Storage Layout
    //////////////////////////////////////////////////////////////////////////*/

    function test_seizeConfigs_storageSlotIsAppendedAfterMintIntentRegistry() public {
        _setUpSeize();

        // seizeConfigs is slot 6: minterAllowances 0, mintTxnLimits 1, tokenHandlers 2,
        // mintIntentVersion 3, stablecoinIsPaused 4, mintIntentRegistry 5. The struct packs
        // mode (1 byte), registry (20 bytes), and list ID (8 bytes) into one word.
        bytes32 seizeConfigSlot = keccak256(abi.encode(address(v2Stablecoin), uint256(6)));
        uint256 expectedWord = uint256(uint8(ITokenAuthority.SeizeMode.BurnAndRemint))
            | (uint256(uint160(address(authRegistry))) << 8) | (uint256(seizureWalletListId) << 168);
        assertEq(uint256(vm.load(address(tokenAuthority), seizeConfigSlot)), expectedWord);
        assertEq(
            address(uint160(uint256(vm.load(address(tokenAuthority), bytes32(uint256(5)))))),
            address(mintIntentRegistry),
            "mintIntentRegistry still slot 5"
        );
    }

}
