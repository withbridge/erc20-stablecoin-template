// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockERC20BurnMint, MockERC20WrapUnwrap } from "./utils/MockERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { IdempotencyKeyRegistry } from "src/idempotency/IdempotencyKeyRegistry.sol";
import { IIdempotencyKeyErrors } from "src/idempotency/interfaces/IIdempotencyKeyErrors.sol";
import { IIdempotencyKeys } from "src/idempotency/interfaces/IIdempotencyKeys.sol";
import { ITokenAuthority } from "src/tokenAuthority/ITokenAuthority.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

import { AuthRegistry, IAuthRegistry } from "auth-registry/src/AuthRegistry.sol";

import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

import { ITokenHandler } from "src/tokenAuthority/tokenHandler/ITokenHandler.sol";
import {
    ReserveLedgerBackedHandler
} from "src/tokenAuthority/tokenHandler/ReserveLedgerBackedHandler.sol";
import {
    ReserveLedgerWrappedHandler
} from "src/tokenAuthority/tokenHandler/ReserveLedgerWrappedHandler.sol";
import { SingleTokenHandler } from "src/tokenAuthority/tokenHandler/SingleTokenHandler.sol";

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
            newStablecoin, address(reserveLedgerWrappedHandler), 1_000_000e6
        );

        assertEq(tokenAuthority.getStablecoinTxnMintLimit(newStablecoin), 1_000_000e6);
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

    function test_registerStablecoin_revertWhenTokenHandlerIsZero() public {
        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.expectRevert(ITokenAuthority.ZeroAddress.selector);
        tokenAuthority.registerStablecoin(address(wrappedStablecoin), address(0), 1_000_000e6);
        vm.stopPrank();
    }

    function test_registerStablecoin_revertWhenAmountExceedsAbsoluteMax() public {
        uint256 exceedsMax = tokenAuthority.ABSOLUTE_MAX() + 1;

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.expectRevert(ITokenAuthority.AmountExceedsAbsoluteMax.selector);
        tokenAuthority.registerStablecoin(
            address(wrappedStablecoin), address(reserveLedgerWrappedHandler), exceedsMax
        );
        vm.stopPrank();
    }

    function test_registerStablecoin_revertWhenTokenHandlerIsInvalid() public {
        address invalidHandler = makeAddr("invalidHandler");

        vm.startPrank(tokenAuthorityAdmin);
        tokenAuthority.unregisterStablecoin(address(wrappedStablecoin));

        vm.expectRevert(ITokenAuthority.InvalidTokenHandler.selector);
        tokenAuthority.registerStablecoin(address(wrappedStablecoin), invalidHandler, 1_000_000e6);
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

}
