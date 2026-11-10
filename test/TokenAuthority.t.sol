// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockERC20BurnMint, MockERC20WrapUnwrap } from "./utils/MockERC20.sol";
import { MockStablecoinTemplateV2 } from "./utils/MockStablecoinTemplateV2.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { IdempotencyKeyRegistry } from "src/idempotency/IdempotencyKeyRegistry.sol";
import { IIdempotencyKeyErrors } from "src/idempotency/interfaces/IIdempotencyKeyErrors.sol";
import { IIdempotencyKeys } from "src/idempotency/interfaces/IIdempotencyKeys.sol";
import { ISeize } from "src/seize/interfaces/ISeize.sol";
import { ITokenAuthority } from "src/tokenAuthority/ITokenAuthority.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import {
    BurnAndRemintSeizeHandler
} from "src/tokenAuthority/seizeHandler/BurnAndRemintSeizeHandler.sol";
import {
    ForceTransferSeizeHandler
} from "src/tokenAuthority/seizeHandler/ForceTransferSeizeHandler.sol";
import { ISeizeHandler } from "src/tokenAuthority/seizeHandler/ISeizeHandler.sol";
import { SeizeHandler } from "src/tokenAuthority/seizeHandler/SeizeHandler.sol";
import { IStablecoinTemplateV2 } from "src/utils/IStablecoinTemplateV2.sol";

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
    IdempotencyKeyRegistry idempotencyKeyRegistry;
    ReserveLedger reserveLedgerToken;
    StablecoinTemplateV3 wrappedStablecoin;
    StablecoinTemplateV3 backedStablecoin;
    AuthRegistry authRegistry;

    address bridgeAdmin;
    address tokenAuthorityAdmin;
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
    ForceTransferSeizeHandler forceTransferSeizeHandler;
    BurnAndRemintSeizeHandler burnAndRemintSeizeHandler;
    MockStablecoinTemplateV2 v2Stablecoin;
    address v2StablecoinAdmin;
    address seizer;
    address seizureWallet;
    address frozenHolder;
    uint64 seizureWalletPolicyId;

    function setUp() public {
        bridgeAdmin = makeAddr("bridgeAdmin");
        tokenAuthorityAdmin = makeAddr("tokenAuthorityAdmin");
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
        idempotencyKeyRegistry = _deployIdempotencyKeyRegistry(tokenAuthorityAdmin);

        tokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        tokenAuthority.initialize(tokenAuthorityAdmin, address(idempotencyKeyRegistry));

        // Authorize the TokenAuthority to use keys in the shared registry
        bytes32 controllerRole = idempotencyKeyRegistry.CONTROLLER_ROLE();
        vm.prank(tokenAuthorityAdmin);
        idempotencyKeyRegistry.grantRole(controllerRole, address(tokenAuthority));

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
            address(reserveLedgerToken), address(singleTokenHandler), address(0), 1_000_000e6
        );
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin),
            address(reserveLedgerWrappedHandler),
            address(0),
            1_000_000e6
        );
        tokenAuthority.registerStablecoin(
            address(backedStablecoin), address(reserveLedgerBackedHandler), address(0), 1_000_000e6
        );
        vm.stopPrank();
    }

    function _deployIdempotencyKeyRegistry(address registryAdmin)
        internal
        returns (IdempotencyKeyRegistry)
    {
        IdempotencyKeyRegistry registryImplementation = new IdempotencyKeyRegistry(false);
        return IdempotencyKeyRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation),
                    abi.encodeCall(IdempotencyKeyRegistry.initialize, (registryAdmin))
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

    function test_burn_withKeys_consumesKeys() public {
        bytes32 key = keccak256("burn-key");

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.prank(alice);
        reserveLedgerToken.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);
        tokenAuthority.burn(address(reserveLedgerToken), 100e6, _keys(key));

        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        tokenAuthority.burn(address(reserveLedgerToken), 1, _keys(key));
        vm.stopPrank();

        assertFalse(idempotencyKeyRegistry.isFree(key));
        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 0, "rl admin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
    }

    function test_mint_withKeys_consumesKeysAndRejectsReuse() public {
        bytes32 key = keccak256("mint-key");
        bytes32 hold = keccak256("hold-key");

        vm.prank(minter);
        vm.expectEmit(true, true, false, false, address(tokenAuthority));
        emit IIdempotencyKeys.KeyUsed(minter, key);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6, _keys(key, hold));

        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "bob wrappedStablecoin bal");
        assertFalse(idempotencyKeyRegistry.isFree(key));
        assertFalse(idempotencyKeyRegistry.isFree(hold));

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6, _keys(key));
    }

    function test_mint_withKeys_limitFailureDoesNotConsumeKeys() public {
        bytes32 key = keccak256("limit-key");

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MinterAllowanceExceeded.selector);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 1500e6, _keys(key));

        assertTrue(idempotencyKeyRegistry.isFree(key), "failed mint must not spend the key");
    }

    function test_mint_and_burn_shareKeyNamespace() public {
        bytes32 key = keccak256("shared-mint-burn");

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6, _keys(key));

        vm.prank(alice);
        reserveLedgerToken.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        reserveLedgerToken.approve(address(tokenAuthority), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        tokenAuthority.burn(address(reserveLedgerToken), 100e6, _keys(key));
        vm.stopPrank();
    }

    function test_mint_revertWhenKeyRetiredByAnotherController() public {
        bytes32 key = keccak256("retire");
        address otherController = makeAddr("otherController");
        bytes32 controllerRole = idempotencyKeyRegistry.CONTROLLER_ROLE();

        vm.prank(tokenAuthorityAdmin);
        idempotencyKeyRegistry.grantRole(controllerRole, otherController);

        vm.prank(otherController);
        idempotencyKeyRegistry.useKeys(_keys(key));

        assertFalse(idempotencyKeyRegistry.isFree(key));

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6, _keys(key));
    }

    function test_mint_withKeys_emptyAllowedWhenOptionalSkipsRegistry() public {
        bytes32 controllerRole = idempotencyKeyRegistry.CONTROLLER_ROLE();
        vm.prank(tokenAuthorityAdmin);
        idempotencyKeyRegistry.revokeRole(controllerRole, address(tokenAuthority));

        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6, new bytes32[](0));

        assertEq(wrappedStablecoin.balanceOf(bob), 100e6);
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 900e6);
    }

    function test_mint_withoutKeys_revertWhenRequired() public {
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setIdempotencyKeysVersion(ITokenAuthority.IdempotencyKeysVersion.Required);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.IdempotencyKeysRequired.selector);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        assertEq(wrappedStablecoin.balanceOf(bob), 0);
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 1000e6);
    }

    function test_burn_withKeys_revertWhenEmpty() public {
        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(IIdempotencyKeyErrors.InvalidIdempotencyKeys.selector);
        tokenAuthority.burn(address(reserveLedgerToken), 1, new bytes32[](0));
    }

    function test_setIdempotencyKeysVersion_requiredGatesEmptyKeyMint() public {
        vm.prank(maliciousUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                maliciousUser,
                DEFAULT_ADMIN_ROLE
            )
        );
        tokenAuthority.setIdempotencyKeysVersion(ITokenAuthority.IdempotencyKeysVersion.Required);

        vm.prank(tokenAuthorityAdmin);
        vm.expectEmit(true, false, false, true, address(tokenAuthority));
        emit ITokenAuthority.IdempotencyKeysVersionSet(
            tokenAuthorityAdmin, ITokenAuthority.IdempotencyKeysVersion.Required
        );
        tokenAuthority.setIdempotencyKeysVersion(ITokenAuthority.IdempotencyKeysVersion.Required);

        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.IdempotencyKeysRequired.selector);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6, new bytes32[](0));

        bytes32 key = keccak256("required-ok");
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6, _keys(key));

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.mintBridgeEcosystem(address(reserveLedgerToken), alice, 1);

        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "keyed mint balance");
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 900e6);
        assertEq(reserveLedgerToken.balanceOf(alice), 1, "bridge ecosystem mint balance");
        assertFalse(idempotencyKeyRegistry.isFree(key));
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
        newTokenAuthority.initialize(bridgeAdmin, address(idempotencyKeyRegistry));
        bool adminHasRole = newTokenAuthority.hasRole(DEFAULT_ADMIN_ROLE, bridgeAdmin);

        assert(adminHasRole);
        assertEq(
            address(newTokenAuthority.idempotencyKeyRegistry()), address(idempotencyKeyRegistry)
        );
    }

    function test_tokenAuthorityInitialize_revertWhenDisabled() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), true);
        vm.expectRevert(InvalidInitialization.selector);
        newTokenAuthority.initialize(bridgeAdmin, address(idempotencyKeyRegistry));
    }

    function test_tokenAuthorityInitialize_revertWhenRegistryIsZero() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        vm.expectRevert(IIdempotencyKeyErrors.InvalidRegistry.selector);
        newTokenAuthority.initialize(bridgeAdmin, address(0));
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
        tokenAuthority.mint(address(reserveLedgerToken), alice, 500e6); // allowance
        // is 250e6
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

    function test_burn_withKeys_revertWhenNotBurnerRole() public {
        bytes32 key = keccak256("burn-role");

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
        tokenAuthority.burn(address(reserveLedgerToken), 100e6, _keys(key));

        assertTrue(idempotencyKeyRegistry.isFree(key), "a rejected burn must not retire the key");
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

    function test_wrap_revertWhenRecipientIsZero() public {
        vm.prank(alice);
        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.wrap(address(wrappedStablecoin), address(0), 50e6);
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

    function test_setTokenHandler_revertWhenTokenHandlerIsZero() public {
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.setStablecoinPaused(address(wrappedStablecoin), true);

        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.setTokenHandler(address(wrappedStablecoin), address(0));
        vm.stopPrank();

        assertEq(
            tokenAuthority.getTokenHandler(address(wrappedStablecoin)),
            address(reserveLedgerWrappedHandler)
        );
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
        address handlerSetter = makeAddr("handlerSetter");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, handlerSetter);

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

        vm.prank(handlerSetter);
        vm.expectEmit(true, true, false, true, address(tokenAuthority));
        emit ITokenAuthority.StablecoinRegistered(
            handlerSetter, newStablecoin, address(reserveLedgerWrappedHandler), 1_000_000e6
        );
        tokenAuthority.registerStablecoin(
            newStablecoin, address(reserveLedgerWrappedHandler), address(0), 1_000_000e6
        );

        assertEq(tokenAuthority.getStablecoinTxnMintLimit(newStablecoin), 1_000_000e6);
        assertEq(tokenAuthority.getSeizeHandler(newStablecoin), address(0));
    }

    function test_registerStablecoin_revertWhenNotTokenAuthorityHandlerSetterRole() public {
        address adminOnly = makeAddr("adminOnly");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(DEFAULT_ADMIN_ROLE, adminOnly);

        vm.prank(adminOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                adminOnly,
                TOKEN_AUTHORITY_HANDLER_SETTER_ROLE
            )
        );
        tokenAuthority.registerStablecoin(
            makeAddr("newStablecoin"), address(reserveLedgerWrappedHandler), address(0), 1_000_000e6
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
            newStablecoin, address(reserveLedgerWrappedHandler), address(0), 1_000_000e6
        );
    }

    function test_registerStablecoin_revertWhenStablecoinAlreadyRegistered() public {
        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinAlreadyRegistered.selector);
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin),
            address(reserveLedgerWrappedHandler),
            address(0),
            1_000_000e6
        );
    }

    function test_registerStablecoin_revertWhenTokenHandlerIsZero() public {
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin), address(0), address(0), 1_000_000e6
        );
        vm.stopPrank();
    }

    function test_registerStablecoin_revertWhenAmountExceedsAbsoluteMax() public {
        uint256 exceedsMax = tokenAuthority.ABSOLUTE_MAX() + 1;

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.expectRevert(ITokenAuthority.AmountExceedsAbsoluteMax.selector);
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin), address(reserveLedgerWrappedHandler), address(0), exceedsMax
        );
        vm.stopPrank();
    }

    function test_registerStablecoin_revertWhenTokenHandlerIsInvalid() public {
        address invalidHandler = makeAddr("invalidHandler");

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.expectRevert(ITokenAuthority.InvalidTokenHandler.selector);
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin), invalidHandler, address(0), 1_000_000e6
        );
        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test unregisterStablecoin
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_unregisterStablecoin() public {
        address handlerSetter = makeAddr("handlerSetter");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, handlerSetter);

        vm.prank(handlerSetter);
        vm.expectEmit(true, true, false, false, address(tokenAuthority));
        emit ITokenAuthority.StablecoinUnregistered(handlerSetter, address(wrappedStablecoin));
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        assertEq(tokenAuthority.getTokenHandler(address(wrappedStablecoin)), address(0));
        assertEq(tokenAuthority.getStablecoinTxnMintLimit(address(wrappedStablecoin)), 0);
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 1000e6);
        assertEq(
            tokenAuthority.getTokenHandler(address(backedStablecoin)),
            address(reserveLedgerBackedHandler)
        );
        assertEq(tokenAuthority.getStablecoinTxnMintLimit(address(backedStablecoin)), 1_000_000e6);

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.TokenHandlerNotSet.selector);
        tokenAuthority.mintBridgeEcosystem(address(wrappedStablecoin), bob, 100e6);
    }

    function test_unregisterStablecoin_revertWhenNotTokenAuthorityHandlerSetterRole() public {
        address adminOnly = makeAddr("adminOnly");

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(DEFAULT_ADMIN_ROLE, adminOnly);

        vm.prank(adminOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                adminOnly,
                TOKEN_AUTHORITY_HANDLER_SETTER_ROLE
            )
        );
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));
    }

    function test_unregisterStablecoin_revertWhenStablecoinIsZero() public {
        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.unregisterStablecoin(address(0));
    }

    function test_unregisterStablecoin_revertWhenStablecoinNotRegistered() public {
        address unregisteredStablecoin = makeAddr("unregisteredStablecoin");

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinNotRegistered.selector);
        tokenAuthority.unregisterStablecoin(unregisteredStablecoin);
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

    function _keys(bytes32 a) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](1);
        keys[0] = a;
    }

    function _keys(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](2);
        keys[0] = a;
        keys[1] = b;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Seize
    //////////////////////////////////////////////////////////////////////////*/

    uint256 constant SEIZE_HOLDER_BALANCE = 1000e6;

    /// @dev Freezes `frozenHolder` holding SEIZE_HOLDER_BALANCE on both the V3 wrapped stablecoin
    /// (force transfer) and a V2 stablecoin behind the backed handler (burn and re-mint), with
    /// every role and list entry each seize handler needs.
    function _setUpSeize() internal {
        seizer = makeAddr("seizer");
        seizureWallet = makeAddr("seizureWallet");
        frozenHolder = makeAddr("frozenHolder");
        v2StablecoinAdmin = makeAddr("v2StablecoinAdmin");

        forceTransferSeizeHandler = new ForceTransferSeizeHandler(address(tokenAuthority));
        burnAndRemintSeizeHandler = new BurnAndRemintSeizeHandler(address(tokenAuthority));

        vm.startPrank(bridgeAdmin);
        seizureWalletPolicyId =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.WHITELIST);
        authRegistry.modifyPolicyWhitelist(seizureWalletPolicyId, seizureWallet, true);
        vm.stopPrank();

        // V3: the force-transfer seize handler holds FORCE_TRANSFER_ROLE; the holder is funded
        // through the wrapped token handler so its reserve backing sits inside the coin.
        vm.startPrank(wrappedStablecoinAdmin);
        wrappedStablecoin.grantRole(FORCE_TRANSFER_ROLE, address(forceTransferSeizeHandler));
        authRegistry.modifyPolicyWhitelist(
            wrappedStablecoin.getMintRecipientPolicyId(), frozenHolder, true
        );
        vm.stopPrank();
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), frozenHolder, SEIZE_HOLDER_BALANCE);
        uint64 wrappedTransferPolicyId = wrappedStablecoin.getTransferPolicyId();
        vm.prank(wrappedStablecoinAdmin);
        authRegistry.modifyPolicyBlacklist(wrappedTransferPolicyId, frozenHolder, true);

        // V2: registered behind the backed token handler like the live V2 coins, so issuance puts
        // reserve ledger tokens in a reserve store. The burn-and-re-mint seize handler gets the six
        // V2 roles and both mint-recipient entries.
        v2Stablecoin = new MockStablecoinTemplateV2("V2 Stablecoin", "V2SC", 6, v2StablecoinAdmin);
        address burnAndRemint = address(burnAndRemintSeizeHandler);
        vm.startPrank(v2StablecoinAdmin);
        v2Stablecoin.increaseMaxSupply(1_000_000_000e6);
        v2Stablecoin.grantRole(MINTER_ROLE, address(reserveLedgerBackedHandler));
        v2Stablecoin.grantRole(v2Stablecoin.BLOCKER_ROLE(), v2StablecoinAdmin);
        v2Stablecoin.grantRole(v2Stablecoin.UNBLOCKER_ROLE(), v2StablecoinAdmin);
        v2Stablecoin.grantRole(v2Stablecoin.PAUSER_ROLE(), v2StablecoinAdmin);
        v2Stablecoin.addMintRecipient(frozenHolder);
        v2Stablecoin.grantRole(v2Stablecoin.BLOCKED_ADDRESS_BURNER_ROLE(), burnAndRemint);
        v2Stablecoin.grantRole(MINTER_ROLE, burnAndRemint);
        v2Stablecoin.grantRole(v2Stablecoin.UNBLOCKER_ROLE(), burnAndRemint);
        v2Stablecoin.grantRole(v2Stablecoin.BLOCKER_ROLE(), burnAndRemint);
        v2Stablecoin.grantRole(v2Stablecoin.PAUSER_ROLE(), burnAndRemint);
        v2Stablecoin.grantRole(v2Stablecoin.UNPAUSER_ROLE(), burnAndRemint);
        v2Stablecoin.addMintRecipient(seizureWallet);
        v2Stablecoin.addMintRecipient(burnAndRemint);
        vm.stopPrank();

        // Registered with its seize handler in the same call, the way new stablecoins are.
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.registerStablecoin(
            address(v2Stablecoin), address(reserveLedgerBackedHandler), burnAndRemint, 1_000_000e6
        );
        tokenAuthority.setMinterAllowance(address(v2Stablecoin), minter, SEIZE_HOLDER_BALANCE);
        vm.stopPrank();
        vm.prank(minter);
        tokenAuthority.mint(address(v2Stablecoin), frozenHolder, SEIZE_HOLDER_BALANCE);
        vm.prank(v2StablecoinAdmin);
        v2Stablecoin.blockAddress(frozenHolder);

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(SEIZER_ROLE, seizer);
        // Each seize handler holds the list for its stablecoins; the TokenAuthority admin sets it.
        forceTransferSeizeHandler.setSeizureWalletPolicyId(seizureWalletPolicyId);
        burnAndRemintSeizeHandler.setSeizureWalletPolicyId(seizureWalletPolicyId);
        // Registered in setUp without one, like the stablecoins live before this upgrade.
        tokenAuthority.setSeizeHandler(
            address(wrappedStablecoin), address(forceTransferSeizeHandler)
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
        // Frozen literal: the role ID granted to each entity's Seize Authority vault.
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
            600e6, frozenHolder, seizureWallet, address(forceTransferSeizeHandler)
        );
        vm.expectEmit(true, true, true, true, address(forceTransferSeizeHandler));
        emit ISeizeHandler.Seized(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ISeize.Seized(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6, seizer);
        vm.prank(seizer);
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(wrappedStablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(wrappedStablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertEq(wrappedStablecoin.balanceOf(address(tokenAuthority)), 0, "token authority");
        assertEq(
            wrappedStablecoin.balanceOf(address(forceTransferSeizeHandler)), 0, "seize handler"
        );
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

        // The V3 coin bypasses its own pause, so the seize handler needs no unpause role on it.
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

    function test_seize_forceTransfer_revertOnStablecoinWithoutForceTransfer() public {
        _setUpSeize();
        // A V2 coin wrongly given the force-transfer seize handler has no forceTransfer, so the
        // seize reverts and nothing moves.
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeHandler(address(v2Stablecoin), address(forceTransferSeizeHandler));

        vm.prank(seizer);
        vm.expectRevert();
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(v2Stablecoin.balanceOf(frozenHolder), SEIZE_HOLDER_BALANCE);
    }

    function test_seize_burnAndRemint_partialSeizeReturnsRemainderToHolder() public {
        _setUpSeize();
        address reserveStore = _v2ReserveStore();
        address handler = address(burnAndRemintSeizeHandler);

        // The exact on-chain sequence: whole-balance burn, seized mint, remainder mint to the
        // handler, unblock, transfer back, re-block, then the handler and TokenAuthority events.
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IStablecoinTemplateV2.BurnedFromBlockedAddress(1000e6, frozenHolder, handler);
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IStablecoinTemplateV2.Minted(600e6, seizureWallet, handler);
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IStablecoinTemplateV2.Minted(400e6, handler, handler);
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IStablecoinTemplateV2.UnblockedAddress(frozenHolder, handler);
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IERC20.Transfer(handler, frozenHolder, 400e6);
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IStablecoinTemplateV2.BlockedAddress(frozenHolder, handler);
        vm.expectEmit(true, true, true, true, handler);
        emit ISeizeHandler.Seized(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ISeize.Seized(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6, seizer);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(v2Stablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertEq(v2Stablecoin.balanceOf(handler), 0, "seize handler");
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
            abi.encodeWithSelector(IStablecoinTemplateV2.unblockAddress.selector),
            0
        );
        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeWithSelector(IStablecoinTemplateV2.blockAddress.selector),
            0
        );
        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeCall(IStablecoinTemplateV2.mint, (seizureWallet, SEIZE_HOLDER_BALANCE)),
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

        vm.expectCall(address(v2Stablecoin), abi.encodeCall(IStablecoinTemplateV2.unpause, ()), 1);
        vm.expectCall(address(v2Stablecoin), abi.encodeCall(IStablecoinTemplateV2.pause, ()), 1);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertTrue(v2Stablecoin.paused(), "re-paused");
        assertEq(v2Stablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertTrue(v2Stablecoin.isBlocked(frozenHolder));
    }

    function test_seize_burnAndRemint_unpausedCoinIsNeverPaused() public {
        _setUpSeize();

        vm.expectCall(address(v2Stablecoin), abi.encodeCall(IStablecoinTemplateV2.unpause, ()), 0);
        vm.expectCall(address(v2Stablecoin), abi.encodeCall(IStablecoinTemplateV2.pause, ()), 0);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertFalse(v2Stablecoin.paused());
    }

    function test_seize_burnAndRemint_doesNotSweepStraySeizeHandlerBalance() public {
        _setUpSeize();
        // A minter sends coins to the seize handler's address outside any seize.
        vm.startPrank(v2StablecoinAdmin);
        v2Stablecoin.grantRole(MINTER_ROLE, v2StablecoinAdmin);
        v2Stablecoin.mint(address(burnAndRemintSeizeHandler), 50e6);
        vm.stopPrank();

        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 400e6);

        assertEq(
            v2Stablecoin.balanceOf(address(burnAndRemintSeizeHandler)),
            50e6,
            "stray balance untouched"
        );
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
            abi.encodeCall(IStablecoinTemplateV2.unblockAddress, (frozenHolder)),
            1
        );
        vm.expectCall(
            address(v2Stablecoin),
            abi.encodeCall(IStablecoinTemplateV2.unblockAddress, (otherFrozenHolder)),
            0
        );
        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);

        assertTrue(v2Stablecoin.isBlocked(frozenHolder));
        assertTrue(v2Stablecoin.isBlocked(otherFrozenHolder));
    }

    function test_seize_burnAndRemint_revertWhenBurnReleasesReserveBacking() public {
        _setUpSeize();
        // A V3 coin wrongly given the burn-and-re-mint seize handler, with the handler holding V3
        // burner and minter roles. V3's burnFromBlockedAddress pays the backing to the caller, so
        // the handler would end up holding 1000e6 of reserve ledger tokens while 1000e6 re-minted
        // coins sat unbacked. The handler's own balance check refuses it.
        vm.startPrank(wrappedStablecoinAdmin);
        wrappedStablecoin.grantRole(
            wrappedStablecoin.BLOCKED_ADDRESS_BURNER_ROLE(), address(burnAndRemintSeizeHandler)
        );
        wrappedStablecoin.grantRole(MINTER_ROLE, address(burnAndRemintSeizeHandler));
        authRegistry.modifyPolicyWhitelist(
            wrappedStablecoin.getMintRecipientPolicyId(), seizureWallet, true
        );
        vm.stopPrank();
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeHandler(
            address(wrappedStablecoin), address(burnAndRemintSeizeHandler)
        );

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                BurnAndRemintSeizeHandler.SeizeHandlerBalanceChanged.selector,
                address(reserveLedgerToken),
                0,
                SEIZE_HOLDER_BALANCE
            )
        );
        tokenAuthority.seize(
            address(wrappedStablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE
        );
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
        authRegistry.modifyPolicyWhitelist(seizureWalletPolicyId, seizureWallet, false);

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

    function test_seize_revertWhenDestinationIsSeizeHandler() public {
        _setUpSeize();
        // Even if the handler were wrongly added to the list, coins sent to it would be stuck.
        vm.startPrank(bridgeAdmin);
        authRegistry.modifyPolicyWhitelist(
            seizureWalletPolicyId, address(forceTransferSeizeHandler), true
        );
        vm.stopPrank();

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISeize.InvalidSeizeDestination.selector, address(forceTransferSeizeHandler)
            )
        );
        tokenAuthority.seize(
            address(wrappedStablecoin), frozenHolder, address(forceTransferSeizeHandler), 600e6
        );
    }

    function test_seize_revertWhenCoinDoesNotMoveCoins() public {
        _setUpSeize();
        vm.mockCall(
            address(wrappedStablecoin),
            abi.encodeWithSelector(StablecoinTemplateV3.forceTransfer.selector),
            ""
        );

        // The Seizure Wallet received nothing, which is the one outcome every seize asserts.
        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeBalanceMismatch.selector, seizureWallet, 600e6, 0)
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
            IStablecoinTemplateV2.pause.selector,
            IStablecoinTemplateV2.unpause.selector,
            IStablecoinTemplateV2.blockAddress.selector,
            IStablecoinTemplateV2.unblockAddress.selector,
            IStablecoinTemplateV2.burnFromBlockedAddress.selector,
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
        vm.expectCall(
            address(burnAndRemintSeizeHandler),
            abi.encodeWithSelector(ISeizeHandler.seize.selector),
            0
        );
        vm.expectCall(
            address(forceTransferSeizeHandler),
            abi.encodeWithSelector(ISeizeHandler.seize.selector),
            0
        );

        // V2 issuance still goes through the token handler, never a seize handler.
        vm.expectEmit(true, true, true, true, address(v2Stablecoin));
        emit IStablecoinTemplateV2.Minted(100e6, alice, address(reserveLedgerBackedHandler));
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
            tokenAuthority.getMinterAllowance(
                address(v2Stablecoin), address(burnAndRemintSeizeHandler)
            ),
            0
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Seize Handlers
    //////////////////////////////////////////////////////////////////////////*/

    function test_seizeHandlers_revertWhenNotTokenAuthority() public {
        _setUpSeize();

        vm.startPrank(seizer);
        vm.expectRevert(ISeizeHandler.OnlyTokenAuthority.selector);
        forceTransferSeizeHandler.seize(
            address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6
        );
        vm.expectRevert(ISeizeHandler.OnlyTokenAuthority.selector);
        burnAndRemintSeizeHandler.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        vm.stopPrank();
    }

    function test_seizeHandlers_revertWhenTokenAuthorityIsZero() public {
        vm.expectRevert(ISeizeHandler.ZeroAddress.selector);
        new ForceTransferSeizeHandler(address(0));
    }

    function test_seizeHandlers_constructorState() public {
        _setUpSeize();

        assertEq(forceTransferSeizeHandler.TOKEN_AUTHORITY(), address(tokenAuthority));
        assertEq(burnAndRemintSeizeHandler.TOKEN_AUTHORITY(), address(tokenAuthority));
        assertEq(burnAndRemintSeizeHandler.RESERVE_LEDGER_TOKEN(), address(reserveLedgerToken));
        // Both read the registry from the TokenAuthority's reserve ledger, not from an argument.
        assertEq(address(forceTransferSeizeHandler.AUTH_REGISTRY()), address(authRegistry));
        assertEq(address(burnAndRemintSeizeHandler.AUTH_REGISTRY()), address(authRegistry));
        assertTrue(forceTransferSeizeHandler.supportsInterface(type(ISeizeHandler).interfaceId));
        assertTrue(burnAndRemintSeizeHandler.supportsInterface(type(ISeizeHandler).interfaceId));
        // A seize handler is not a token handler, and the reverse.
        assertFalse(forceTransferSeizeHandler.supportsInterface(type(ITokenHandler).interfaceId));
        assertFalse(singleTokenHandler.supportsInterface(type(ISeizeHandler).interfaceId));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Seize Settings
    //////////////////////////////////////////////////////////////////////////*/

    function test_registerStablecoin_setsSeizeHandler() public {
        _setUpSeize();
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.recordLogs();
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin),
            address(reserveLedgerWrappedHandler),
            address(forceTransferSeizeHandler),
            1_000_000e6
        );
        vm.stopPrank();

        assertEq(
            tokenAuthority.getSeizeHandler(address(wrappedStablecoin)),
            address(forceTransferSeizeHandler)
        );
        _assertSeizeHandlerSetNotLogged();
    }

    function test_registerStablecoin_revertWhenSeizeHandlerIsInvalid() public {
        _setUpSeize();
        address[2] memory invalidSeizeHandlers = _invalidSeizeHandlers();

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));
        for (uint256 i = 0; i < invalidSeizeHandlers.length; i++) {
            vm.expectRevert(ITokenAuthority.InvalidSeizeHandler.selector);
            tokenAuthority.registerStablecoin(
                address(wrappedStablecoin),
                address(reserveLedgerWrappedHandler),
                invalidSeizeHandlers[i],
                1_000_000e6
            );
        }
        vm.stopPrank();
    }

    function test_unregisterStablecoin_clearsSeizeHandler() public {
        _setUpSeize();

        vm.recordLogs();
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(v2Stablecoin));

        assertEq(tokenAuthority.getSeizeHandler(address(v2Stablecoin)), address(0));
        _assertSeizeHandlerSetNotLogged();
        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(v2Stablecoin))
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_unregisterStablecoin_reregisteringStartsWithoutSeizeHandler() public {
        _setUpSeize();
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin),
            address(reserveLedgerWrappedHandler),
            address(0),
            1_000_000e6
        );
        vm.stopPrank();

        assertEq(tokenAuthority.getSeizeHandler(address(wrappedStablecoin)), address(0));
    }

    function test_setSeizeHandler_storesAndEmits() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ITokenAuthority.SeizeHandlerSet(
            tokenAuthorityAdmin, address(backedStablecoin), address(forceTransferSeizeHandler)
        );
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeHandler(
            address(backedStablecoin), address(forceTransferSeizeHandler)
        );

        assertEq(
            tokenAuthority.getSeizeHandler(address(backedStablecoin)),
            address(forceTransferSeizeHandler)
        );
    }

    function test_setSeizeHandler_zeroClearsHandler() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(tokenAuthority));
        emit ITokenAuthority.SeizeHandlerSet(tokenAuthorityAdmin, address(v2Stablecoin), address(0));
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeHandler(address(v2Stablecoin), address(0));

        assertEq(tokenAuthority.getSeizeHandler(address(v2Stablecoin)), address(0));
        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(v2Stablecoin))
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_setSeizeHandler_revertWhenSeizeHandlerIsInvalid() public {
        _setUpSeize();
        address[2] memory invalidSeizeHandlers = _invalidSeizeHandlers();

        vm.startPrank(tokenAuthorityAdmin);
        for (uint256 i = 0; i < invalidSeizeHandlers.length; i++) {
            vm.expectRevert(ITokenAuthority.InvalidSeizeHandler.selector);
            tokenAuthority.setSeizeHandler(address(v2Stablecoin), invalidSeizeHandlers[i]);
        }
        vm.stopPrank();
    }

    function test_setSeizeHandler_revertWhenNotAdmin() public {
        _setUpSeize();

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, seizer, DEFAULT_ADMIN_ROLE
            )
        );
        tokenAuthority.setSeizeHandler(address(v2Stablecoin), address(burnAndRemintSeizeHandler));
    }

    function test_setSeizeHandler_revertWhenStablecoinIsZero() public {
        _setUpSeize();

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.setSeizeHandler(address(0), address(burnAndRemintSeizeHandler));
    }

    function test_setSeizeHandler_revertWhenStablecoinNotRegistered() public {
        _setUpSeize();

        vm.prank(tokenAuthorityAdmin);
        vm.expectRevert(ITokenAuthority.StablecoinNotRegistered.selector);
        tokenAuthority.setSeizeHandler(
            makeAddr("unregisteredStablecoin"), address(burnAndRemintSeizeHandler)
        );
    }

    function test_setSeizeHandler_worksWhileStablecoinIsNotPaused() public {
        _setUpSeize();
        // Unlike setTokenHandler, swapping the seize handler never touches issuance, so it needs
        // no issuance pause first.
        assertFalse(tokenAuthority.stablecoinIsPaused(address(v2Stablecoin)));

        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.setSeizeHandler(address(v2Stablecoin), address(burnAndRemintSeizeHandler));
    }

    function test_seizeHandlers_setSeizureWalletPolicyId_storesAndEmits() public {
        _setUpSeize();
        vm.prank(bridgeAdmin);
        uint64 otherPolicyId =
            authRegistry.createPolicy(bridgeAdmin, IAuthRegistry.PolicyType.WHITELIST);
        SeizeHandler[2] memory handlers = _seizeHandlers();

        for (uint256 i = 0; i < handlers.length; i++) {
            vm.expectEmit(true, true, true, true, address(handlers[i]));
            emit ISeizeHandler.SeizureWalletPolicyIdSet(tokenAuthorityAdmin, otherPolicyId);
            vm.prank(tokenAuthorityAdmin);
            handlers[i].setSeizureWalletPolicyId(otherPolicyId);

            assertEq(handlers[i].seizureWalletPolicyId(), otherPolicyId);
        }
    }

    function test_seizeHandlers_setSeizureWalletPolicyId_revertWhenNotTokenAuthorityAdmin() public {
        _setUpSeize();
        // The handler has no admin of its own: only the TokenAuthority's DEFAULT_ADMIN_ROLE counts.
        address handlerSetter = makeAddr("handlerSetter");
        vm.prank(tokenAuthorityAdmin);
        tokenAuthority.grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, handlerSetter);
        address[3] memory callers = [seizer, handlerSetter, address(tokenAuthority)];
        SeizeHandler[2] memory handlers = _seizeHandlers();

        for (uint256 i = 0; i < handlers.length; i++) {
            for (uint256 j = 0; j < callers.length; j++) {
                vm.prank(callers[j]);
                vm.expectRevert(ISeizeHandler.OnlyTokenAuthorityAdmin.selector);
                handlers[i].setSeizureWalletPolicyId(seizureWalletPolicyId);
            }
        }
    }

    function test_seizeHandlers_sharedListRemovalBlocksBothStablecoins() public {
        _setUpSeize();
        // Both handlers point at the entity's one list: removing the wallet blocks seizes on both.
        vm.prank(bridgeAdmin);
        authRegistry.modifyPolicyWhitelist(seizureWalletPolicyId, seizureWallet, false);

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

    function test_seizeHandlers_zeroDisablesSeizeForThatHandlersStablecoins() public {
        _setUpSeize();

        // Clearing the force-transfer handler's list disables seize for V3 coins only.
        vm.prank(tokenAuthorityAdmin);
        forceTransferSeizeHandler.setSeizureWalletPolicyId(0);

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(wrappedStablecoin))
        );
        tokenAuthority.seize(address(wrappedStablecoin), frozenHolder, seizureWallet, 600e6);

        vm.prank(seizer);
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 600e6);
        assertEq(v2Stablecoin.balanceOf(seizureWallet), 600e6, "V2 seize unaffected");

        // Clearing the other one disables the rest.
        vm.prank(tokenAuthorityAdmin);
        burnAndRemintSeizeHandler.setSeizureWalletPolicyId(0);

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(v2Stablecoin))
        );
        tokenAuthority.seize(address(v2Stablecoin), frozenHolder, seizureWallet, 100e6);
    }

    function test_seize_revertWhenSeizureWalletListUnusable() public {
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

        // The always-allow built-in, a blacklist (authorizes everyone unlisted), and a whitelist
        // naming the TokenAuthority itself. The setter accepts each; the seize handler refuses
        // them on every seize, on both handler types.
        uint64[3] memory policyIds = [uint64(1), blacklistId, listContainingTokenAuthority];
        address[2] memory stablecoins = [address(wrappedStablecoin), address(v2Stablecoin)];
        SeizeHandler[2] memory handlers = _seizeHandlers();

        for (uint256 i = 0; i < policyIds.length; i++) {
            vm.startPrank(tokenAuthorityAdmin);
            handlers[0].setSeizureWalletPolicyId(policyIds[i]);
            handlers[1].setSeizureWalletPolicyId(policyIds[i]);
            vm.stopPrank();

            for (uint256 j = 0; j < stablecoins.length; j++) {
                vm.prank(seizer);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        ISeize.InvalidSeizureWalletList.selector,
                        address(authRegistry),
                        policyIds[i]
                    )
                );
                tokenAuthority.seize(stablecoins[j], frozenHolder, seizureWallet, 600e6);
            }
        }
    }

    function _seizeHandlers() internal view returns (SeizeHandler[2] memory) {
        return [
            SeizeHandler(address(forceTransferSeizeHandler)),
            SeizeHandler(address(burnAndRemintSeizeHandler))
        ];
    }

    /// @dev Like the token handler, only the dedicated setter emits its event: registration and
    /// unregistration are covered by StablecoinRegistered and StablecoinUnregistered.
    function _assertSeizeHandlerSetNotLogged() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != ITokenAuthority.SeizeHandlerSet.selector,
                "SeizeHandlerSet emitted outside setSeizeHandler"
            );
        }
    }

    /// @dev An address without code and a token handler, neither of which reports
    /// {ISeizeHandler} through ERC165.
    function _invalidSeizeHandlers() internal view returns (address[2] memory) {
        return [alice, address(reserveLedgerBackedHandler)];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Storage Layout
    //////////////////////////////////////////////////////////////////////////*/

    function test_seizeState_storageSlotsAreAppended() public {
        _setUpSeize();

        // minterAllowances 0, mintTxnLimits 1, tokenHandlers 2, idempotencyKeysVersion 3,
        // stablecoinIsPaused 4, idempotencyKeyRegistry 5. Seize state is appended: seizeHandlers
        // is slot 6, the only new slot (the Seizure Wallet list lives in the seize handlers).
        uint256 seizeHandlerSlot = uint256(keccak256(abi.encode(address(v2Stablecoin), uint256(6))));
        assertEq(
            uint256(vm.load(address(tokenAuthority), bytes32(seizeHandlerSlot))),
            uint256(uint160(address(burnAndRemintSeizeHandler)))
        );
        assertEq(uint256(vm.load(address(tokenAuthority), bytes32(uint256(7)))), 0, "slot 7 unused");
        assertEq(
            address(uint160(uint256(vm.load(address(tokenAuthority), bytes32(uint256(5)))))),
            address(idempotencyKeyRegistry),
            "idempotencyKeyRegistry still slot 5"
        );
    }

}
