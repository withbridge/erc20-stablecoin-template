// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20BurnMint, MockERC20WrapUnwrap} from "./utils/MockERC20.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {ITokenAuthority} from "src/tokenAuthority/ITokenAuthority.sol";
import {TokenAuthority} from "src/tokenAuthority/TokenAuthority.sol";

import {AuthRegistry, IAuthRegistry} from "auth-registry/src/AuthRegistry.sol";

import {ReserveLedger} from "src/v3/ReserveLedger.sol";
import {StablecoinTemplateV3} from "src/v3/StablecoinTemplateV3.sol";
import {StablecoinTemplateV3Base} from "src/v3/StablecoinTemplateV3Base.sol";

import {SingleTokenHandler} from "src/tokenAuthority/tokenHandler/SingleTokenHandler.sol";
import {ReserveLedgerBackedHandler} from "src/tokenAuthority/tokenHandler/ReserveLedgerBackedHandler.sol";
import {ReserveLedgerWrappedHandler} from "src/tokenAuthority/tokenHandler/ReserveLedgerWrappedHandler.sol";

contract TokenAuthorityTest is Test {

    error InvalidInitialization();
    
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant MINT_RATE_LIMIT_SETTER_ROLE =
        keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UNWRAPPER_ROLE = keccak256("UNWRAPPER_ROLE");
    bytes32 public constant BRIDGE_ECOSYSTEM_CONTRACT_ROLE =
        keccak256("BRIDGE_ECOSYSTEM_CONTRACT_ROLE");
    bytes32 public constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");

    TokenAuthority tokenAuthority;
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
        uint64 parentMintRecipientPolicyId = authRegistry.createPolicy(
            bridgeAdmin,
            IAuthRegistry.PolicyType.WHITELIST
        );
        uint64 parentBlocklistPolicyId = authRegistry.createPolicy(
            bridgeAdmin,
            IAuthRegistry.PolicyType.BLACKLIST
        );

        uint64 reserveLedgerMintRecipientPolicyId = authRegistry.createPolicy(
            reserveLedgerAdmin,
            IAuthRegistry.PolicyType.WHITELIST,
            parentMintRecipientPolicyId
        );
        uint64 reserveLedgerBlocklistPolicyId = authRegistry.createPolicy(
            reserveLedgerAdmin,
            IAuthRegistry.PolicyType.BLACKLIST,
            parentBlocklistPolicyId
        );

        uint64 wrappedStablecoinMintRecipientPolicyId = authRegistry.createPolicy(
            wrappedStablecoinAdmin,
            IAuthRegistry.PolicyType.WHITELIST,
            parentMintRecipientPolicyId
        );
        uint64 wrappedStablecoinBlocklistPolicyId = authRegistry.createPolicy(
            wrappedStablecoinAdmin,
            IAuthRegistry.PolicyType.BLACKLIST,
            parentBlocklistPolicyId
        );

        uint64 backedStablecoinMintRecipientPolicyId = authRegistry.createPolicy(
            backedStablecoinAdmin,
            IAuthRegistry.PolicyType.WHITELIST,
            parentMintRecipientPolicyId
        );
        uint64 backedStablecoinBlocklistPolicyId = authRegistry.createPolicy(
            backedStablecoinAdmin,
            IAuthRegistry.PolicyType.BLACKLIST,
            parentBlocklistPolicyId
        );

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy ReserveLedger
        ////////////////////////////////////////////////////////////////////////////////////////////
        ReserveLedger reserveLedgerImpl = new ReserveLedger(
            address(authRegistry)
        );
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
        StablecoinTemplateV3 stablecoinImpl = new StablecoinTemplateV3(address(reserveLedgerToken), address(authRegistry));
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
        tokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        tokenAuthority.initialize(tokenAuthorityAdmin);

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Deploy Token Handlers
        ////////////////////////////////////////////////////////////////////////////////////////////
        singleTokenHandler = new SingleTokenHandler(address(tokenAuthority));
        reserveLedgerBackedHandler = new ReserveLedgerBackedHandler(address(reserveLedgerToken), address(tokenAuthority));
        reserveLedgerWrappedHandler = new ReserveLedgerWrappedHandler(address(reserveLedgerToken), address(tokenAuthority));

        ////////////////////////////////////////////////////////////////////////////////////////////
        // Setup Permissions - GrantRoles, add to mint recipients, add to blocklist, mint allowances/ lmits
        ////////////////////////////////////////////////////////////////////////////////////////////
        
        // Parent Policies
        vm.startPrank(bridgeAdmin);
        authRegistry.modifyPolicyWhitelist(parentMintRecipientPolicyId, address(reserveLedgerBackedHandler), true);
        authRegistry.modifyPolicyWhitelist(parentMintRecipientPolicyId, address(reserveLedgerWrappedHandler), true);
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
        tokenAuthority.setTokenHandler(address(reserveLedgerToken), address(singleTokenHandler));
        tokenAuthority.setTokenHandler(address(wrappedStablecoin), address(reserveLedgerWrappedHandler));
        tokenAuthority.setTokenHandler(address(backedStablecoin), address(reserveLedgerBackedHandler));
        vm.stopPrank();

    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test minting functionality
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_mintReserveLedgerTokens() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        assertEq(reserveLedgerToken.balanceOf(alice), 100e6, "rl alice bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter), 150e6, "rl minter allowance");
    }

    function test_mintStablecoinsWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        assertEq(reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 100e6, "rl wrappedStablecoin bal");
        assertEq(wrappedStablecoin.balanceOf(bob), 100e6, "rl wrappedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(wrappedStablecoin.totalSupply(), 100e6, "wrappedStablecoin total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 900e6, "wrappedStablecoin minter allowance");
    }

    function test_mintStablecoinsBacked() public {
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), 100e6, "rl backedStablecoin bal");
        assertEq(backedStablecoin.balanceOf(charles), 100e6, "rl backedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 100e6, "backedStablecoin total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(backedStablecoin), minter), 900e6, "backedStablecoin minter allowance");
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
        tokenAuthority.burn(address(reserveLedgerToken), 100e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(alice), 0, "rl alice bal");
        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 0, "rl admin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter), 150e6, "rl minter allowance");
    }

    function test_burnStablecoinsWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        vm.prank(bob);
        wrappedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        wrappedStablecoin.approve(address(tokenAuthority), 100e6);
        tokenAuthority.burn(address(wrappedStablecoin), 100e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 0, "rl wrappedStablecoin bal");
        assertEq(wrappedStablecoin.balanceOf(bob), 0, "rl wrappedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
        assertEq(wrappedStablecoin.totalSupply(), 0, "wrappedStablecoin total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 900e6, "wrappedStablecoin minter allowance");
    }

    function test_burnStablecoinsBacked() public {
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        vm.prank(charles);
        backedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        backedStablecoin.approve(address(tokenAuthority), 100e6);
        tokenAuthority.burn(address(backedStablecoin), 100e6);
        vm.stopPrank();

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), 0, "rl backedStablecoin bal");
        assertEq(backedStablecoin.balanceOf(charles), 0, "rl backedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 0, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 0, "backedStablecoin total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(backedStablecoin), minter), 900e6, "backedStablecoin minter allowance");
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
        assertEq(tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter), 150e6, "rl minter allowance");
    }

    function test_wrapIntoWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.startPrank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);
        tokenAuthority.wrap(address(wrappedStablecoin), bob, 50e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(alice), 50e6, "rl alice bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter), 150e6, "rl minter allowance");

        assertEq(wrappedStablecoin.balanceOf(bob), 50e6, "wrappedStablecoin bob bal");
        assertEq(reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 50e6, "rl wrappedStablecoin bal");
        assertEq(wrappedStablecoin.totalSupply(), 50e6, "wrappedStablecoin total supply");
    }

    function test_wrapIntoBacked() public {
        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));
        assertEq(reserveStore, address(0), "reserve store shouldnt be set yet");

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), alice, 100e6);

        vm.startPrank(alice);
        reserveLedgerToken.approve(address(tokenAuthority), 50e6);
        tokenAuthority.wrap(address(backedStablecoin), charles, 50e6);
        vm.stopPrank();

        reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        assertEq(reserveLedgerToken.balanceOf(alice), 50e6, "rl alice bal");
        assertEq(reserveLedgerToken.balanceOf(reserveStore), 50e6, "rl reserve store bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter), 150e6, "rl minter allowance");

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
        assertEq(tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter), 150e6, "rl minter allowance");
    }

    function test_unwrapStablecoinsWrapped() public {
        vm.prank(minter);
        tokenAuthority.mint(address(wrappedStablecoin), bob, 100e6);

        vm.prank(bob);
        wrappedStablecoin.transfer(tokenAuthorityAdmin, 100e6);
        
        vm.startPrank(tokenAuthorityAdmin);
        wrappedStablecoin.approve(address(tokenAuthority), 100e6);
        tokenAuthority.unwrap(address(wrappedStablecoin), 100e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(address(wrappedStablecoin)), 0, "rl wrappedStablecoin bal");
        assertEq(wrappedStablecoin.balanceOf(bob), 0, "bob rl wrappedStablecoin bal");
        assertEq(wrappedStablecoin.balanceOf(tokenAuthorityAdmin), 0, "token auth admin rl wrappedStablecoin bal");
        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 100e6, "token auth admin wrappedStablecoin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(wrappedStablecoin.totalSupply(), 0, "wrappedStablecoin total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(wrappedStablecoin), minter), 900e6, "wrappedStablecoin minter allowance");
    }

    function test_unwrapStablecoinsBacked() public {
        vm.prank(minter);
        tokenAuthority.mint(address(backedStablecoin), charles, 100e6);

        address reserveStore = reserveLedgerBackedHandler.reserveStores(address(backedStablecoin));

        vm.prank(charles);
        backedStablecoin.transfer(tokenAuthorityAdmin, 100e6);

        vm.startPrank(tokenAuthorityAdmin);
        backedStablecoin.approve(address(tokenAuthority), 100e6);
        tokenAuthority.unwrap(address(backedStablecoin), 100e6);
        vm.stopPrank();

        assertEq(reserveLedgerToken.balanceOf(address(reserveStore)), 0, "rl backedStablecoin bal");
        assertEq(backedStablecoin.balanceOf(charles), 0, "rl backedStablecoin bal");
        assertEq(reserveLedgerToken.balanceOf(charles), 0, "rl charles bal");
        assertEq(reserveLedgerToken.balanceOf(tokenAuthorityAdmin), 100e6, "rl token auth admin bal");
        assertEq(reserveLedgerToken.totalSupply(), 100e6, "rl total supply");
        assertEq(backedStablecoin.totalSupply(), 0, "backedStablecoin total supply");
        assertEq(tokenAuthority.getMinterAllowance(address(backedStablecoin), minter), 900e6, "backedStablecoin minter allowance");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////
    // Test intiailizer
    ////////////////////////////////////////////////////////////////////////////////////////////

    function test_tokenAuthorityInitialize() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), false);
        newTokenAuthority.initialize(bridgeAdmin);
        bool adminHasRole = newTokenAuthority.hasRole(DEFAULT_ADMIN_ROLE, bridgeAdmin);

        assert(adminHasRole);
    }

    function test_tokenAuthorityInitialize_revertWhenDisabled() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), true);
        vm.expectRevert(InvalidInitialization.selector);
        newTokenAuthority.initialize(bridgeAdmin);

    }

    
}
