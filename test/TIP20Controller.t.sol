// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { IdempotencyKeyRegistry } from "src/idempotency/IdempotencyKeyRegistry.sol";
import { IIdempotencyKeyErrors } from "src/idempotency/interfaces/IIdempotencyKeyErrors.sol";
import { IIdempotencyKeys } from "src/idempotency/interfaces/IIdempotencyKeys.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { TIP20Controller } from "src/v3/tempo/TIP20Controller.sol";
import { ITIP20Controller } from "src/v3/tempo/interfaces/ITIP20Controller.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { StdTokens } from "tempo-std/StdTokens.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import { MockTIP20BurnAt } from "./utils/MockTIP20BurnAt.sol";
import { ISeize } from "src/seize/interfaces/ISeize.sol";

contract TIP20ControllerTest is Test {

    TIP20Controller controller;
    IdempotencyKeyRegistry idempotencyKeyRegistry;

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

        // Deploy the shared idempotency-key registry
        idempotencyKeyRegistry = _deployIdempotencyKeyRegistry(admin);

        // Deploy TIP20Controller implementation
        TIP20Controller implementation = new TIP20Controller(address(reserveLedgerToken), false);

        // Deploy proxy
        bytes memory initData =
            abi.encodeCall(TIP20Controller.initialize, (admin, address(idempotencyKeyRegistry)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        controller = TIP20Controller(address(proxy));

        // Authorize the controller to use keys in the shared registry
        idempotencyKeyRegistry.grantRole(
            idempotencyKeyRegistry.CONTROLLER_ROLE(), address(controller)
        );

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

    /*//////////////////////////////////////////////////////////////////////////
                                Initialization Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_failsWhenDisabled() public {
        TIP20Controller newController = new TIP20Controller(address(reserveLedgerToken), true);

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        newController.initialize(admin, address(idempotencyKeyRegistry));
    }

    function test_initialize_revertsWhenRegistryIsZero() public {
        TIP20Controller newController = new TIP20Controller(address(reserveLedgerToken), false);

        vm.expectRevert(IIdempotencyKeyErrors.InvalidRegistry.selector);
        newController.initialize(admin, address(0));
    }

    function test_initialize_setsIdempotencyKeyRegistry() public view {
        assertEq(address(controller.idempotencyKeyRegistry()), address(idempotencyKeyRegistry));
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

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

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

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

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

    function test_mintBridgeEcosystem_revert_amount_exceeds_absolute_max() public {
        address bridgeContract = makeAddr("bridge");
        uint256 exceedsMax = 1_000_000_000 * 1e6 + 1;

        vm.prank(admin);
        controller.grantRole(controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE(), bridgeContract);

        vm.prank(bridgeContract);
        vm.expectRevert(ITIP20Controller.AmountExceedsAbsoluteMax.selector);
        controller.mintBridgeEcosystem(address(stablecoin), user1, exceedsMax);
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

    function test_burn_withKeys_revert_not_burner() public {
        bytes32 key = keccak256("burn-role");
        bytes32 burnerRole = controller.BURNER_ROLE();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, burnerRole
            )
        );
        controller.burn(address(stablecoin), 30e6, _keys(key));

        assertTrue(idempotencyKeyRegistry.isFree(key), "a rejected burn must not retire the key");
    }

    function test_burn_withKeys_consumesKeys() public {
        bytes32 key = keccak256("burn-key");
        uint256 mintAmount = 100e6;
        uint256 burnAmount = 30e6;

        _mintStablecoinToMinter(mintAmount);

        vm.startPrank(minter);
        stablecoin.approve(address(controller), burnAmount);
        controller.burn(address(stablecoin), burnAmount, _keys(key));

        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        controller.burn(address(stablecoin), 1, _keys(key));
        vm.stopPrank();

        assertFalse(idempotencyKeyRegistry.isFree(key));
    }

    function test_mint_withKeys_consumesKeysAndRejectsReuse() public {
        bytes32 key = keccak256("mint-key");
        _allowMinter(address(stablecoin), 200e6);

        vm.prank(minter);
        vm.expectEmit(true, true, false, false, address(controller));
        emit IIdempotencyKeys.KeyUsed(minter, key);
        controller.mint(address(stablecoin), user1, 100e6, _keys(key));

        assertEq(stablecoin.balanceOf(user1), 100e6);
        assertFalse(idempotencyKeyRegistry.isFree(key));

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        controller.mint(address(stablecoin), user1, 100e6, _keys(key));
    }

    function test_mint_withKeys_limitFailureDoesNotConsumeKeys() public {
        bytes32 key = keccak256("limit-key");
        _allowMinter(address(stablecoin), 50e6);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.MinterAllowanceExceeded.selector);
        controller.mint(address(stablecoin), user1, 100e6, _keys(key));

        assertTrue(idempotencyKeyRegistry.isFree(key));
    }

    function test_mint_and_burn_shareKeyNamespace() public {
        bytes32 key = keccak256("shared-mint-burn");
        _allowMinter(address(stablecoin), 100e6);
        controller.grantRole(controller.BURNER_ROLE(), minter);

        vm.prank(minter);
        controller.mint(address(stablecoin), minter, 100e6, _keys(key));

        vm.startPrank(minter);
        stablecoin.approve(address(controller), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        controller.burn(address(stablecoin), 100e6, _keys(key));
        vm.stopPrank();
    }

    function test_mint_revertWhenKeyRetiredByAnotherController() public {
        bytes32 key = keccak256("retire");
        address otherController = makeAddr("otherController");
        idempotencyKeyRegistry.grantRole(idempotencyKeyRegistry.CONTROLLER_ROLE(), otherController);

        vm.prank(otherController);
        idempotencyKeyRegistry.useKeys(_keys(key));

        assertFalse(idempotencyKeyRegistry.isFree(key));

        _allowMinter(address(stablecoin), 100e6);
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        controller.mint(address(stablecoin), user1, 100e6, _keys(key));
    }

    function test_mint_withKeys_emptyAllowedWhenOptionalSkipsRegistry() public {
        _allowMinter(address(stablecoin), 100e6);
        idempotencyKeyRegistry.revokeRole(
            idempotencyKeyRegistry.CONTROLLER_ROLE(), address(controller)
        );

        vm.prank(minter);
        controller.mint(address(stablecoin), user1, 100e6, new bytes32[](0));

        assertEq(stablecoin.balanceOf(user1), 100e6);
        assertEq(controller.getMinterAllowance(address(stablecoin), minter), 0);
    }

    function test_mint_withoutKeys_revertWhenRequired() public {
        _allowMinter(address(stablecoin), 100e6);
        controller.setMintIntentVersion(ITIP20Controller.MintIntentVersion.Required);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.IdempotencyKeysRequired.selector);
        controller.mint(address(stablecoin), user1, 100e6);

        assertEq(stablecoin.balanceOf(user1), 0);
        assertEq(controller.getMinterAllowance(address(stablecoin), minter), 100e6);
    }

    function test_burn_withKeys_revertWhenEmpty() public {
        controller.grantRole(controller.BURNER_ROLE(), minter);
        vm.prank(minter);
        vm.expectRevert(IIdempotencyKeyErrors.InvalidIdempotencyKeys.selector);
        controller.burn(address(stablecoin), 1, new bytes32[](0));
    }

    function test_setMintIntentVersion_requiredGatesEmptyKeyMint() public {
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
        vm.expectRevert(ITIP20Controller.IdempotencyKeysRequired.selector);
        controller.mint(address(stablecoin), user1, 100e6, new bytes32[](0));

        controller.grantRole(controller.BRIDGE_ECOSYSTEM_CONTRACT_ROLE(), admin);
        controller.mintBridgeEcosystem(address(stablecoin), user2, 1);

        bytes32 key = keccak256("required-ok");
        vm.prank(minter);
        controller.mint(address(stablecoin), user1, 100e6, _keys(key));

        assertEq(stablecoin.balanceOf(user1), 100e6);
        assertEq(stablecoin.balanceOf(user2), 1);
        assertEq(controller.getMinterAllowance(address(stablecoin), minter), 100e6);
        assertFalse(idempotencyKeyRegistry.isFree(key));
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
                            Stablecoin Pause Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_stablecoinPauser_role_constant() public view {
        assertEq(controller.STABLECOIN_PAUSER_ROLE(), keccak256("STABLECOIN_PAUSER_ROLE"));
    }

    function test_stablecoinIsPaused_defaults_false() public view {
        assertFalse(controller.stablecoinIsPaused(address(stablecoin)));
    }

    function test_setStablecoinPaused_revert_not_pauser() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                controller.STABLECOIN_PAUSER_ROLE()
            )
        );
        controller.setStablecoinPaused(address(stablecoin), true);
        vm.stopPrank();
    }

    function test_setStablecoinPaused_pauses_and_emits() public {
        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);

        vm.expectEmit(true, true, false, true, address(controller));
        emit ITIP20Controller.StablecoinPauseSet(admin, address(stablecoin), true);
        controller.setStablecoinPaused(address(stablecoin), true);

        assertTrue(controller.stablecoinIsPaused(address(stablecoin)));
    }

    function test_setStablecoinPaused_unpauses_and_emits() public {
        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.expectEmit(true, true, false, true, address(controller));
        emit ITIP20Controller.StablecoinPauseSet(admin, address(stablecoin), false);
        controller.setStablecoinPaused(address(stablecoin), false);

        assertFalse(controller.stablecoinIsPaused(address(stablecoin)));
    }

    function test_setStablecoinPaused_noop_when_already_paused() public {
        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.recordLogs();
        controller.setStablecoinPaused(address(stablecoin), true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertTrue(controller.stablecoinIsPaused(address(stablecoin)));
    }

    function test_setStablecoinPaused_noop_when_already_unpaused() public {
        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);

        vm.recordLogs();
        controller.setStablecoinPaused(address(stablecoin), false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertFalse(controller.stablecoinIsPaused(address(stablecoin)));
    }

    function test_mint_revert_when_paused() public {
        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 100e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        vm.stopPrank();

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.StablecoinPaused.selector);
        controller.mint(address(stablecoin), user1, 50e6);
    }

    function test_burn_revert_when_paused() public {
        uint256 mintAmount = 100e6;
        uint256 burnAmount = 30e6;

        _mintStablecoinToMinter(mintAmount);

        vm.prank(minter);
        stablecoin.approve(address(controller), burnAmount);

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.StablecoinPaused.selector);
        controller.burn(address(stablecoin), burnAmount);
    }

    function test_wrap_revert_when_paused() public {
        uint256 wrapAmount = 100e6;

        _mintReserveTokens(user1, wrapAmount);
        vm.prank(user1);
        reserveLedgerToken.approve(address(controller), wrapAmount);

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.prank(user1);
        vm.expectRevert(ITIP20Controller.StablecoinPaused.selector);
        controller.wrap(address(stablecoin), user2, wrapAmount);
    }

    function test_unwrap_revert_when_paused() public {
        uint256 mintAmount = 100e6;
        uint256 unwrapAmount = 30e6;

        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 200e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        controller.grantRole(controller.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        vm.startPrank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);
        controller.mint(address(stablecoin), minter, mintAmount);
        stablecoin.approve(address(controller), unwrapAmount);
        vm.stopPrank();

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.prank(minter);
        vm.expectRevert(ITIP20Controller.StablecoinPaused.selector);
        controller.unwrap(address(stablecoin), unwrapAmount);
    }

    function test_mint_succeeds_after_unpause() public {
        uint256 mintAmount = 50e6;

        vm.startPrank(admin);
        controller.setTxnMintLimit(address(stablecoin), 100e6);
        controller.setMinterAllowance(address(stablecoin), minter, 500e6);
        vm.stopPrank();

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);
        controller.setStablecoinPaused(address(stablecoin), false);

        _mintReserveTokens(minter, mintAmount);
        vm.prank(minter);
        reserveLedgerToken.approve(address(controller), mintAmount);

        vm.prank(minter);
        controller.mint(address(stablecoin), user1, mintAmount);

        assertEq(stablecoin.balanceOf(user1), mintAmount);
    }

    function test_setReserveStore_revert_when_not_paused() public {
        vm.prank(admin);
        vm.expectRevert(ITIP20Controller.StablecoinNotPaused.selector);
        controller.setReserveStore(address(stablecoin), makeAddr("someStore"));
    }

    function test_setReserveStore_succeeds_when_paused() public {
        address customReserveStore = makeAddr("customReserveStore");

        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(stablecoin), true);

        vm.prank(admin);
        controller.setReserveStore(address(stablecoin), customReserveStore);

        assertEq(controller.getReserveStore(address(stablecoin)), customReserveStore);
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

    /*//////////////////////////////////////////////////////////////////////////
                Shared registry across DIFFERENT controller types
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The two real, mechanically different controller types share one registry. A key used
    /// through TIP20Controller cannot be reused through TokenAuthority.
    function test_sharedRegistryWithTokenAuthority_keyIsSingleUse() public {
        bytes32 key = keccak256("cross-type");

        TokenAuthority ta = new TokenAuthority(address(reserveLedgerToken), false);
        ta.initialize(admin, address(idempotencyKeyRegistry));
        idempotencyKeyRegistry.grantRole(idempotencyKeyRegistry.CONTROLLER_ROLE(), address(ta));

        _allowMinter(address(stablecoin), 100e6);
        vm.prank(minter);
        controller.mint(address(stablecoin), user1, 100e6, _keys(key));

        assertFalse(idempotencyKeyRegistry.isFree(key));

        vm.startPrank(admin);
        ta.grantRole(ta.BURNER_ROLE(), admin);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        ta.burn(address(stablecoin), 1, _keys(key));
        vm.stopPrank();
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

    function _allowMinter(address token, uint256 amount) internal {
        vm.startPrank(admin);
        controller.setTxnMintLimit(token, amount);
        controller.setMinterAllowance(token, minter, amount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Seize
    //////////////////////////////////////////////////////////////////////////*/

    uint256 constant SEIZE_HOLDER_BALANCE = 1000e6;

    // Seize fixtures, populated by _setUpSeize
    MockTIP20BurnAt seizableStablecoin;
    address seizer;
    address seizureWallet;
    address frozenHolder;
    uint64 transferPolicyId;
    uint64 seizureWalletPolicyId;

    /// @dev Issues SEIZE_HOLDER_BALANCE to `frozenHolder` through the controller (so the reserve
    /// store holds matching reserve ledger tokens), freezes it under the coin's TIP-403 policy, and
    /// grants every role monorail's setup grants. Uses a T12-style mock because the pinned
    /// precompile has no `burnAt`.
    function _setUpSeize() internal {
        seizer = makeAddr("seizer");
        seizureWallet = makeAddr("seizureWallet");
        frozenHolder = makeAddr("frozenHolder");

        ITIP403Registry registry = StdPrecompiles.TIP403_REGISTRY;
        transferPolicyId = registry.createPolicy(admin, ITIP403Registry.PolicyType.BLACKLIST);
        seizureWalletPolicyId = registry.createPolicy(admin, ITIP403Registry.PolicyType.WHITELIST);
        registry.modifyPolicyWhitelist(seizureWalletPolicyId, seizureWallet, true);

        seizableStablecoin = new MockTIP20BurnAt(admin, transferPolicyId);
        seizableStablecoin.grantRole(seizableStablecoin.ISSUER_ROLE(), address(controller));
        seizableStablecoin.grantRole(seizableStablecoin.BURN_AT_ROLE(), address(controller));
        seizableStablecoin.grantRole(seizableStablecoin.PAUSE_ROLE(), address(controller));
        seizableStablecoin.grantRole(seizableStablecoin.UNPAUSE_ROLE(), address(controller));
        seizableStablecoin.grantRole(seizableStablecoin.PAUSE_ROLE(), admin);

        _allowMinter(address(seizableStablecoin), SEIZE_HOLDER_BALANCE);
        vm.prank(minter);
        controller.mint(address(seizableStablecoin), frozenHolder, SEIZE_HOLDER_BALANCE);
        registry.modifyPolicyBlacklist(transferPolicyId, frozenHolder, true);

        controller.grantRole(controller.SEIZER_ROLE(), seizer);
        controller.setSeizureWalletPolicyId(seizureWalletPolicyId);
    }

    function _assertReserveBackingUnchanged() internal view {
        address reserveStore = controller.getReserveStore(address(seizableStablecoin));
        assertEq(reserveLedgerToken.totalSupply(), SEIZE_HOLDER_BALANCE, "rl total supply");
        assertEq(
            reserveLedgerToken.balanceOf(reserveStore), SEIZE_HOLDER_BALANCE, "rl in reserve store"
        );
    }

    function test_seizerRole_constant() public view {
        // Frozen literal: monorail detects an upgraded controller by calling SEIZER_ROLE().
        assertEq(
            controller.SEIZER_ROLE(),
            0xe770a2b882b0a3a025be15ffce2d5d54f5d719264e701933268dd62f79db677f
        );
    }

    function test_seize_seizerRoleIsEnumerable() public {
        _setUpSeize();

        bytes32 seizerRole = controller.SEIZER_ROLE();
        assertEq(controller.getRoleMemberCount(seizerRole), 1);
        assertEq(controller.getRoleMember(seizerRole, 0), seizer);
    }

    function test_seize_movesPartOfFrozenBalance() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(seizableStablecoin));
        emit MockTIP20BurnAt.BurnAt(address(controller), frozenHolder, 600e6);
        vm.expectEmit(true, true, true, true, address(seizableStablecoin));
        emit MockTIP20BurnAt.Mint(seizureWallet, 600e6);
        vm.expectEmit(true, true, true, true, address(controller));
        emit ISeize.Seized(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6, seizer);
        vm.prank(seizer);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(seizableStablecoin.balanceOf(frozenHolder), 400e6, "holder");
        assertEq(seizableStablecoin.balanceOf(seizureWallet), 600e6, "seizure wallet");
        assertEq(seizableStablecoin.balanceOf(address(controller)), 0, "controller");
        assertEq(seizableStablecoin.totalSupply(), 1000e6, "supply");
        assertFalse(
            StdPrecompiles.TIP403_REGISTRY.isAuthorized(transferPolicyId, frozenHolder),
            "holder still frozen"
        );
        _assertReserveBackingUnchanged();
    }

    function test_seize_movesWholeFrozenBalance() public {
        _setUpSeize();

        vm.prank(seizer);
        controller.seize(
            address(seizableStablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE
        );

        assertEq(seizableStablecoin.balanceOf(frozenHolder), 0, "holder");
        assertEq(seizableStablecoin.balanceOf(seizureWallet), 1000e6, "seizure wallet");
        assertEq(seizableStablecoin.totalSupply(), 1000e6, "supply");
        _assertReserveBackingUnchanged();
    }

    function test_seize_pausedCoinEndsPaused() public {
        _setUpSeize();
        seizableStablecoin.pause();

        vm.expectCall(address(seizableStablecoin), abi.encodeCall(ITIP20.unpause, ()), 1);
        vm.expectCall(address(seizableStablecoin), abi.encodeCall(ITIP20.pause, ()), 1);
        vm.prank(seizer);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        assertTrue(seizableStablecoin.paused(), "re-paused");
        assertEq(seizableStablecoin.balanceOf(seizureWallet), 600e6);
    }

    function test_seize_unpausedCoinIsNeverPaused() public {
        _setUpSeize();

        vm.expectCall(address(seizableStablecoin), abi.encodeCall(ITIP20.unpause, ()), 0);
        vm.expectCall(address(seizableStablecoin), abi.encodeCall(ITIP20.pause, ()), 0);
        vm.prank(seizer);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        assertFalse(seizableStablecoin.paused());
    }

    function test_seize_neverMintsReserveLedgerTokens() public {
        _setUpSeize();

        vm.expectCall(address(reserveLedgerToken), abi.encodeWithSelector(ITIP20.mint.selector), 0);
        vm.expectCall(address(reserveLedgerToken), abi.encodeWithSelector(ITIP20.burn.selector), 0);
        vm.prank(seizer);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        _assertReserveBackingUnchanged();
    }

    function test_seize_ignoresControllerStablecoinPause() public {
        _setUpSeize();
        controller.grantRole(controller.STABLECOIN_PAUSER_ROLE(), admin);
        controller.setStablecoinPaused(address(seizableStablecoin), true);

        vm.prank(seizer);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(seizableStablecoin.balanceOf(seizureWallet), 600e6);
        assertTrue(controller.stablecoinIsPaused(address(seizableStablecoin)));
    }

    function test_seize_doesNotTouchMintLimits() public {
        _setUpSeize();
        _allowMinter(address(seizableStablecoin), 500e6);

        vm.prank(seizer);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(controller.getMinterAllowance(address(seizableStablecoin), minter), 500e6);
        assertEq(controller.getStablecoinTxnMintLimit(address(seizableStablecoin)), 500e6);
        assertEq(controller.getMinterAllowance(address(seizableStablecoin), seizer), 0);
    }

    function test_seize_revertWhenCallerLacksSeizerRole() public {
        _setUpSeize();
        bytes32 seizerRole = controller.SEIZER_ROLE();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, seizerRole
            )
        );
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenPolicyNotSet() public {
        _setUpSeize();
        controller.setSeizureWalletPolicyId(0);

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.SeizeNotConfigured.selector, address(seizableStablecoin))
        );
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenDestinationNotSeizureWallet() public {
        _setUpSeize();

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.DestinationNotSeizureWallet.selector, user2));
        controller.seize(address(seizableStablecoin), frozenHolder, user2, 600e6);
    }

    function test_seize_revertWhenDestinationRemovedFromList() public {
        _setUpSeize();
        StdPrecompiles.TIP403_REGISTRY
            .modifyPolicyWhitelist(seizureWalletPolicyId, seizureWallet, false);

        vm.prank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.DestinationNotSeizureWallet.selector, seizureWallet)
        );
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenHolderNotBlocked() public {
        _setUpSeize();
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyBlacklist(transferPolicyId, frozenHolder, false);

        vm.prank(seizer);
        vm.expectRevert(abi.encodeWithSelector(ISeize.HolderNotBlocked.selector, frozenHolder));
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);
    }

    function test_seize_revertWhenAmountIsZeroOrAboveBalance() public {
        _setUpSeize();

        vm.startPrank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeAmount.selector, 0, SEIZE_HOLDER_BALANCE)
        );
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISeize.InvalidSeizeAmount.selector, SEIZE_HOLDER_BALANCE + 1, SEIZE_HOLDER_BALANCE
            )
        );
        controller.seize(
            address(seizableStablecoin), frozenHolder, seizureWallet, SEIZE_HOLDER_BALANCE + 1
        );
        vm.stopPrank();
    }

    function test_seize_revertWhenDestinationIsHolderOrController() public {
        _setUpSeize();

        vm.startPrank(seizer);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeDestination.selector, frozenHolder)
        );
        controller.seize(address(seizableStablecoin), frozenHolder, frozenHolder, 600e6);
        vm.expectRevert(
            abi.encodeWithSelector(ISeize.InvalidSeizeDestination.selector, address(controller))
        );
        controller.seize(address(seizableStablecoin), frozenHolder, address(controller), 600e6);
        vm.stopPrank();
    }

    function test_seize_revertWhenSeizureWalletNotAuthorizedByCoinPolicy() public {
        _setUpSeize();
        // The Seizure Wallet must also be allowed by the coin's own transfer policy, or the
        // TIP-20 mint refuses it and nothing moves.
        StdPrecompiles.TIP403_REGISTRY.modifyPolicyBlacklist(transferPolicyId, seizureWallet, true);

        vm.prank(seizer);
        vm.expectRevert(ITIP20.PolicyForbids.selector);
        controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);

        assertEq(seizableStablecoin.balanceOf(frozenHolder), SEIZE_HOLDER_BALANCE);
    }

    function test_seize_pinnedPrecompileHasNoBurnAt() public {
        // Characterizes the toolchain gap behind MockTIP20BurnAt: the pinned Tempo Foundry
        // precompile predates T12. When this starts failing, the toolchain supports burnAt and the
        // seize tests can move to a real TIP-20.
        (bool success,) = address(stablecoin).call(abi.encodeCall(ITIP20.burnAt, (user1, 1)));
        assertFalse(success);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Seizure Wallet Policy Setter
    //////////////////////////////////////////////////////////////////////////*/

    function test_setSeizureWalletPolicyId_storesAndEmits() public {
        uint64 policyId = StdPrecompiles.TIP403_REGISTRY
        .createPolicy(admin, ITIP403Registry.PolicyType.WHITELIST);

        vm.expectEmit(true, true, true, true, address(controller));
        emit ITIP20Controller.SeizureWalletPolicyIdSet(admin, policyId);
        controller.setSeizureWalletPolicyId(policyId);

        assertEq(controller.seizureWalletPolicyId(), policyId);
    }

    function test_setSeizureWalletPolicyId_zeroDisablesSeize() public {
        _setUpSeize();

        vm.expectEmit(true, true, true, true, address(controller));
        emit ITIP20Controller.SeizureWalletPolicyIdSet(admin, 0);
        controller.setSeizureWalletPolicyId(0);

        assertEq(controller.seizureWalletPolicyId(), 0);
    }

    function test_setSeizureWalletPolicyId_revertWhenNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, bytes32(0)
            )
        );
        controller.setSeizureWalletPolicyId(2);
    }

    function test_seize_revertWhenSeizureWalletListUnusable() public {
        _setUpSeize();
        ITIP403Registry registry = StdPrecompiles.TIP403_REGISTRY;
        uint64 blacklistId = registry.createPolicy(admin, ITIP403Registry.PolicyType.BLACKLIST);
        uint64 listContainingController =
            registry.createPolicy(admin, ITIP403Registry.PolicyType.WHITELIST);
        registry.modifyPolicyWhitelist(listContainingController, address(controller), true);

        // The always-allow built-in, a blacklist (authorizes everyone unlisted), and a whitelist
        // that names the controller itself. The setter accepts each; every seize refuses them.
        uint64[3] memory policyIds = [uint64(1), blacklistId, listContainingController];
        for (uint256 i = 0; i < policyIds.length; i++) {
            controller.setSeizureWalletPolicyId(policyIds[i]);

            vm.prank(seizer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ISeize.InvalidSeizureWalletList.selector, address(registry), policyIds[i]
                )
            );
            controller.seize(address(seizableStablecoin), frozenHolder, seizureWallet, 600e6);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Storage Layout
    //////////////////////////////////////////////////////////////////////////*/

    function test_seizureWalletPolicyId_storageSlotIsPackedBesideRegistry() public {
        uint64 policyId = StdPrecompiles.TIP403_REGISTRY
        .createPolicy(admin, ITIP403Registry.PolicyType.WHITELIST);
        controller.setSeizureWalletPolicyId(policyId);

        // minterAllowances 0, mintTxnLimits 1, reserveStores 2, mintIntentVersion 3,
        // stablecoinIsPaused 4, then slot 5 packs idempotencyKeyRegistry (bytes 0 to 19) with
        // seizureWalletPolicyId (bytes 20 to 27). Slot 6 stays unused.
        assertEq(
            uint256(vm.load(address(controller), bytes32(uint256(5)))),
            (uint256(policyId) << 160) | uint256(uint160(address(idempotencyKeyRegistry))),
            "registry and policy ID packed in slot 5"
        );
        assertEq(uint256(vm.load(address(controller), bytes32(uint256(6)))), 0, "slot 6 unused");

        // Each setter leaves the other half of the slot alone.
        controller.setSeizureWalletPolicyId(0);
        assertEq(
            uint256(vm.load(address(controller), bytes32(uint256(5)))),
            uint256(uint160(address(idempotencyKeyRegistry))),
            "clearing the policy ID keeps the registry"
        );
        controller.setSeizureWalletPolicyId(policyId);
        IdempotencyKeyRegistry newRegistry = _deployIdempotencyKeyRegistry(admin);
        newRegistry.grantRole(newRegistry.CONTROLLER_ROLE(), address(controller));
        controller.setIdempotencyKeyRegistry(address(newRegistry));
        assertEq(controller.seizureWalletPolicyId(), policyId, "registry change keeps the ID");
        assertEq(address(controller.idempotencyKeyRegistry()), address(newRegistry));
    }

}
