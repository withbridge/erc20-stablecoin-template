// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockERC20BurnMint, MockERC20WrapUnwrap } from "./utils/MockERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { ITokenAuthority } from "src/tokenAuthority/ITokenAuthority.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

contract TokenAuthorityTest is Test {

    TokenAuthority tokenAuthority;
    MockERC20WrapUnwrap mockToken;
    MockERC20BurnMint reserveLedgerToken;
    address admin;
    address minter;
    address user1;
    address user2;

    function setUp() public {
        admin = address(this);
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock reserve ledger token
        reserveLedgerToken = new MockERC20BurnMint();

        // Deploy TokenAuthority implementation
        TokenAuthority implementation = new TokenAuthority(address(reserveLedgerToken), false);

        // Deploy proxy
        bytes memory initData = abi.encodeCall(TokenAuthority.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        tokenAuthority = TokenAuthority(address(proxy));

        // Grant MINT_RATE_LIMIT_SETTER_ROLE to admin
        tokenAuthority.grantRole(tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE(), admin);

        // Deploy mock stablecoin token (wrap/unwrap token)
        mockToken = new MockERC20WrapUnwrap(address(reserveLedgerToken));

        // The tokenAuthority needs to approve mockToken to spend reserve ledger tokens
        // We need to call this from the tokenAuthority contract
        vm.prank(address(tokenAuthority));
        reserveLedgerToken.approve(address(mockToken), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Initialization Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_failsWhenDisabled() public {
        TokenAuthority newTokenAuthority = new TokenAuthority(address(reserveLedgerToken), true);

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        newTokenAuthority.initialize(admin);
    }

    function test_initialize_sets_admin() public view {
        assertTrue(tokenAuthority.hasRole(tokenAuthority.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_immutable_reserve_ledger_token() public view {
        assertEq(tokenAuthority.RESERVE_LEDGER_TOKEN(), address(reserveLedgerToken));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Mint Rate Limit Setter Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_setMintRateLimits_success() public {
        uint256 txnLimit = 100;

        vm.prank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), txnLimit);

        uint256 returnedTxnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(returnedTxnLimit, txnLimit);
    }

    function test_setMintRateLimits_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE()
            )
        );
        tokenAuthority.setTxnMintLimit(address(mockToken), 100);
        vm.stopPrank();
    }

    function test_setTxnMintLimit_success() public {
        uint256 txnLimit = 100;

        vm.prank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), txnLimit);

        uint256 returnedTxnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(returnedTxnLimit, txnLimit);
    }

    function test_setTxnMintLimit_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE()
            )
        );
        tokenAuthority.setTxnMintLimit(address(mockToken), 100);
        vm.stopPrank();
    }

    function test_setMinterAllowance_success() public {
        uint256 allowance = 500;

        vm.prank(admin);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, allowance);

        uint256 returnedAllowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(returnedAllowance, allowance);
    }

    function test_setMinterAllowance_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE()
            )
        );
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Mint Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        uint256 mintAmount = 50;

        // Setup limits and allowances
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 100);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        vm.stopPrank();

        // Mint
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify token was minted
        assertEq(mockToken.balanceOf(user1), mintAmount);

        // Verify global limit was decremented, txn limit stays the same
        uint256 txnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(txnLimit, 100); // Txn limit is not decremented

        // Verify allowance was decremented
        uint256 remainingAllowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(remainingAllowance, 500 - mintAmount);
    }

    function test_mint_cannot_be_zero() public {
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.AmountCannotBeZero.selector);
        tokenAuthority.mint(address(mockToken), user1, 0);
    }

    function test_mint_with_max_limits_no_decrement() public {
        uint256 mintAmount = 50;

        // Setup with max uint256 limits (unlimited)
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), type(uint256).max);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, type(uint256).max);
        vm.stopPrank();

        // Mint
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify token was minted
        assertEq(mockToken.balanceOf(user1), mintAmount);

        // Verify limits were NOT decremented (still max)
        uint256 txnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(txnLimit, type(uint256).max);

        // Verify allowance was NOT decremented (still max)
        uint256 remainingAllowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(remainingAllowance, type(uint256).max);
    }

    function test_mint_revert_txn_limit_exceeded_low_txn_limit() public {
        uint256 mintAmount = 100;

        // Setup limits where txn limit is less than mint amount
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken), 50);
        tokenAuthority.setTxnMintLimit(address(mockToken), 50);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 500);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        vm.stopPrank();

        // Attempt to mint
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintTxnLimitExceeded.selector);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);
    }

    function test_mint_revert_txn_limit_exceeded_low_allowance() public {
        uint256 mintAmount = 100;

        // Setup limits where minter allowance is less than mint amount
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken), 1000);
        tokenAuthority.setTxnMintLimit(address(mockToken), 1000);

        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 50);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 50);
        vm.stopPrank();

        // Attempt to mint - should fail due to low allowance
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MinterAllowanceExceeded.selector);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);
    }

    function test_mint_revert_minter_allowance_exceeded() public {
        uint256 mintAmount = 100;

        // Setup limits where minter allowance is less than mint amount
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken), 1000);
        tokenAuthority.setTxnMintLimit(address(mockToken), 1000);

        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 50);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 50);
        vm.stopPrank();

        // Attempt to mint
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MinterAllowanceExceeded.selector);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);
    }

    function test_mint_multiple_times_depletes_limits() public {
        // Setup limits
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken), 100);
        tokenAuthority.setTxnMintLimit(address(mockToken), 100);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 100);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 100);
        vm.stopPrank();

        // First mint
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.Mint(minter, address(mockToken), user1, 30);
        tokenAuthority.mint(address(mockToken), user1, 30);

        // Check remaining limits
        uint256 txnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(txnLimit, 100); // Txn limit is not decremented
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 70);

        // Second mint should succeed with txn limit (30 < 100)
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, 30);

        // Verify total minted and remaining allowance
        assertEq(mockToken.balanceOf(user1), 60);
        txnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(txnLimit, 100); // Txn limit is not decremented
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 40);
    }

    function test_mint_different_stablecoins_separate_limits() public {
        MockERC20WrapUnwrap mockToken2 = new MockERC20WrapUnwrap(address(reserveLedgerToken));

        // Approve mockToken2 to spend reserve ledger tokens from tokenAuthority
        vm.prank(address(tokenAuthority));
        reserveLedgerToken.approve(address(mockToken2), type(uint256).max);

        // Setup limits for both tokens
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken), 100);
        tokenAuthority.setTxnMintLimit(address(mockToken), 100);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 100);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 100);

        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken2), 200);
        tokenAuthority.setTxnMintLimit(address(mockToken2), 200);
        tokenAuthority.setMinterAllowance(address(mockToken2), minter, 200);
        vm.stopPrank();

        // Mint from first token
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, 30);

        // Verify txn limit is unchanged (it's a per-txn cap)
        uint256 txnLimit1 = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(txnLimit1, 100); // Txn limit is not decremented

        // Verify allowance decreased
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 70);

        // Verify second token limits unchanged
        uint256 txnLimit2 = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken2));
        assertEq(txnLimit2, 200);
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken2), minter), 200);

        // Mint from second token should work
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken2), user1, 50);

        assertEq(mockToken2.balanceOf(user1), 50);
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken2), minter), 150);
    }

    function test_mint_different_minters_separate_allowances() public {
        address minter2 = makeAddr("minter2");

        // Setup limits for both minters
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 500);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 100);
        tokenAuthority.setMinterAllowance(address(mockToken), minter2, 200);
        vm.stopPrank();

        // Mint from first minter
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, 50);

        // Verify first minter allowance decreased
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 50);

        // Verify second minter allowance unchanged
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter2), 200);

        // Mint from second minter should work
        vm.prank(minter2);
        tokenAuthority.mint(address(mockToken), user2, 100);

        assertEq(mockToken.balanceOf(user2), 100);
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter2), 100);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Mint Reserve Ledger Token Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_reserve_ledger_token_directly() public {
        uint256 mintAmount = 50;

        // Setup limits and allowances for reserve ledger token
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(reserveLedgerToken), 100);
        tokenAuthority.setMinterAllowance(address(reserveLedgerToken), minter, 500);
        vm.stopPrank();

        // Mint reserve ledger tokens directly (not wrapped)
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), user1, mintAmount);

        // Verify tokens were minted directly to user1 (not wrapped)
        assertEq(reserveLedgerToken.balanceOf(user1), mintAmount);

        // Verify txn limit is not decremented
        uint256 txnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(reserveLedgerToken));
        assertEq(txnLimit, 100);

        // Verify allowance was decremented
        uint256 remainingAllowance =
            tokenAuthority.getMinterAllowance(address(reserveLedgerToken), minter);
        assertEq(remainingAllowance, 500 - mintAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Bridge Ecosystem Contract Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_setBridgeEcosystemContract_success() public {
        address bridgeContract = makeAddr("bridge");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.BridgeEcosystemContractSet(admin, bridgeContract, true);
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, true);

        assertTrue(tokenAuthority.bridgeEcosystemContracts(bridgeContract));
    }

    function test_setBridgeEcosystemContract_disable() public {
        address bridgeContract = makeAddr("bridge");

        // First enable
        vm.prank(admin);
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, true);
        assertTrue(tokenAuthority.bridgeEcosystemContracts(bridgeContract));

        // Then disable
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.BridgeEcosystemContractSet(admin, bridgeContract, false);
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, false);

        assertFalse(tokenAuthority.bridgeEcosystemContracts(bridgeContract));
    }

    function test_setBridgeEcosystemContract_revert_not_admin() public {
        address bridgeContract = makeAddr("bridge");

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.DEFAULT_ADMIN_ROLE()
            )
        );
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, true);
        vm.stopPrank();
    }

    function test_mint_bridge_ecosystem_bypasses_limits() public {
        address bridgeContract = makeAddr("bridge");
        uint256 mintAmount = 1000;

        // Enable bridge contract
        vm.prank(admin);
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, true);

        // Do NOT set any limits or allowances for the bridge contract

        // Bridge contract should be able to mint without limits
        vm.prank(bridgeContract);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify tokens were minted
        assertEq(mockToken.balanceOf(user1), mintAmount);
    }

    function test_mint_bridge_ecosystem_ignores_txn_limit() public {
        address bridgeContract = makeAddr("bridge");
        uint256 mintAmount = 1000;

        // Enable bridge contract
        vm.prank(admin);
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, true);

        // Set very low txn limit (would normally prevent minting)
        vm.prank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 10);

        // Bridge contract should still be able to mint despite low txn limit
        vm.prank(bridgeContract);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify tokens were minted
        assertEq(mockToken.balanceOf(user1), mintAmount);
    }

    function test_mint_bridge_ecosystem_ignores_minter_allowance() public {
        address bridgeContract = makeAddr("bridge");
        uint256 mintAmount = 1000;

        // Enable bridge contract
        vm.prank(admin);
        tokenAuthority.setBridgeEcosystemContract(bridgeContract, true);

        // Set very low minter allowance (would normally prevent minting)
        vm.prank(admin);
        tokenAuthority.setMinterAllowance(address(mockToken), bridgeContract, 10);

        // Bridge contract should still be able to mint despite low allowance
        vm.prank(bridgeContract);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify tokens were minted
        assertEq(mockToken.balanceOf(user1), mintAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Burn Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_burn_reserve_ledger_token_success() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 30;

        // Setup: mint some reserve ledger tokens first to the TokenAuthority contract
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(reserveLedgerToken), 200);
        tokenAuthority.setMinterAllowance(address(reserveLedgerToken), minter, 500);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), minter);
        vm.stopPrank();

        // Mint to tokenAuthority contract (burn() will burn from the contract's balance)
        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), address(tokenAuthority), mintAmount);

        assertEq(reserveLedgerToken.balanceOf(address(tokenAuthority)), mintAmount);

        // Burn some tokens (burn will burn from TokenAuthority contract's balance)
        vm.prank(minter);
        tokenAuthority.burn(address(reserveLedgerToken), burnAmount);

        // Verify tokens were burned from TokenAuthority contract
        assertEq(reserveLedgerToken.balanceOf(address(tokenAuthority)), mintAmount - burnAmount);
    }

    function test_burn_wrapped_stablecoin_success() public {
        uint256 mintAmount = 100;
        uint256 burnAmount = 30;

        // Setup: mint some wrapped tokens first
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 200);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), minter);
        vm.stopPrank();

        // Mint to the TokenAuthority contract
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), address(tokenAuthority), mintAmount);

        assertEq(mockToken.balanceOf(address(tokenAuthority)), mintAmount);

        // Burn wrapped tokens (unwrap) - unwrap is called from TokenAuthority contract
        vm.prank(minter);
        tokenAuthority.burn(address(mockToken), burnAmount);

        // Verify wrapped tokens were burned (unwrapped) from TokenAuthority
        assertEq(mockToken.balanceOf(address(tokenAuthority)), mintAmount - burnAmount);
        // And transfers underlying tokens were burned as well
        assertEq(reserveLedgerToken.balanceOf(address(tokenAuthority)), 0);
    }

    function test_burn_revert_not_burner() public {
        // Setup: mint some tokens first
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(reserveLedgerToken), 200);
        tokenAuthority.setMinterAllowance(address(reserveLedgerToken), minter, 500);
        vm.stopPrank();

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), user1, 100);

        // Try to burn without BURNER_ROLE (user1 doesn't have BURNER_ROLE)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.BURNER_ROLE()
            )
        );
        vm.prank(user1);
        tokenAuthority.burn(address(reserveLedgerToken), 30);
    }

    function test_burn_zero_amount() public {
        // Setup: grant burner role and mint tokens
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(reserveLedgerToken), 200);
        tokenAuthority.setMinterAllowance(address(reserveLedgerToken), minter, 500);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        tokenAuthority.mint(address(reserveLedgerToken), address(tokenAuthority), 100);

        // Burning zero amount should work (no revert in contract, but ERC20 might revert)
        // This tests the edge case behavior
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.Burn(minter, address(reserveLedgerToken), 0);
        tokenAuthority.burn(address(reserveLedgerToken), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Unwrap Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_unwrap_success() public {
        uint256 mintAmount = 100;
        uint256 unwrapAmount = 30;

        // Setup: mint some wrapped tokens first
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 200);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        tokenAuthority.grantRole(tokenAuthority.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        // Mint wrapped tokens to the TokenAuthority contract
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), address(tokenAuthority), mintAmount);

        assertEq(mockToken.balanceOf(address(tokenAuthority)), mintAmount);

        // Unwrap tokens - should transfer reserve tokens to minter
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.Unwrap(minter, address(mockToken), unwrapAmount);
        tokenAuthority.unwrap(address(mockToken), unwrapAmount);

        // Verify wrapped tokens were burned from TokenAuthority
        assertEq(mockToken.balanceOf(address(tokenAuthority)), mintAmount - unwrapAmount);
        // Verify reserve tokens were transferred to minter
        assertEq(reserveLedgerToken.balanceOf(minter), unwrapAmount);
    }

    function test_unwrap_revert_not_unwrapper() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.UNWRAPPER_ROLE()
            )
        );
        tokenAuthority.unwrap(address(mockToken), 30);
        vm.stopPrank();
    }

    function test_unwrap_revert_reserve_ledger_token() public {
        vm.startPrank(admin);
        tokenAuthority.grantRole(tokenAuthority.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        vm.startPrank(minter);
        vm.expectRevert(ITokenAuthority.CannotUnwrapReserveLedgerToken.selector);
        tokenAuthority.unwrap(address(reserveLedgerToken), 30);
        vm.stopPrank();
    }

    function test_unwrap_revert_exceeds_balance() public {
        vm.startPrank(admin);
        tokenAuthority.grantRole(tokenAuthority.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        // Try to unwrap when TokenAuthority has no wrapped token balance
        vm.startPrank(minter);
        vm.expectRevert();
        tokenAuthority.unwrap(address(mockToken), 100);
        vm.stopPrank();
    }

    function test_unwrap_multiple_times() public {
        uint256 mintAmount = 100;
        uint256 unwrapAmount1 = 30;
        uint256 unwrapAmount2 = 20;

        // Setup: mint some wrapped tokens first
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 200);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        tokenAuthority.grantRole(tokenAuthority.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        // Mint wrapped tokens to the TokenAuthority contract
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), address(tokenAuthority), mintAmount);

        // First unwrap
        vm.prank(minter);
        tokenAuthority.unwrap(address(mockToken), unwrapAmount1);

        assertEq(mockToken.balanceOf(address(tokenAuthority)), mintAmount - unwrapAmount1);
        assertEq(reserveLedgerToken.balanceOf(minter), unwrapAmount1);

        // Second unwrap
        vm.prank(minter);
        tokenAuthority.unwrap(address(mockToken), unwrapAmount2);

        assertEq(
            mockToken.balanceOf(address(tokenAuthority)), mintAmount - unwrapAmount1 - unwrapAmount2
        );
        assertEq(reserveLedgerToken.balanceOf(minter), unwrapAmount1 + unwrapAmount2);
    }

    function test_unwrap_zero_amount() public {
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), 200);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500);
        tokenAuthority.grantRole(tokenAuthority.UNWRAPPER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), address(tokenAuthority), 100);

        // Unwrapping zero amount should work (tests edge case)
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.Unwrap(minter, address(mockToken), 0);
        tokenAuthority.unwrap(address(mockToken), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Wrap Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_wrap_success() public {
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount);

        // User1 approves tokenAuthority to spend their reserve ledger tokens
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);

        // Wrap tokens for user2
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.Wrap(user1, address(mockToken), user2, wrapAmount);
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount);

        // Verify user2 received wrapped tokens
        assertEq(mockToken.balanceOf(user2), wrapAmount);
        // Verify user1's reserve tokens were transferred
        assertEq(reserveLedgerToken.balanceOf(user1), 0);
        // Verify reserve tokens are now held by the mockToken contract
        assertEq(reserveLedgerToken.balanceOf(address(mockToken)), wrapAmount);
    }

    function test_wrap_to_self() public {
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount);

        // User1 approves tokenAuthority to spend their reserve ledger tokens
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);

        // Wrap tokens for self
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken), user1, wrapAmount);

        // Verify user1 received wrapped tokens
        assertEq(mockToken.balanceOf(user1), wrapAmount);
        // Verify reserve tokens are now held by the mockToken contract
        assertEq(reserveLedgerToken.balanceOf(address(mockToken)), wrapAmount);
    }

    function test_wrap_multiple_times() public {
        uint256 wrapAmount1 = 100;
        uint256 wrapAmount2 = 50;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount1 + wrapAmount2);

        // User1 approves tokenAuthority to spend their reserve ledger tokens
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount1 + wrapAmount2);

        // First wrap
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount1);

        assertEq(mockToken.balanceOf(user2), wrapAmount1);
        assertEq(reserveLedgerToken.balanceOf(user1), wrapAmount2);

        // Second wrap
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount2);

        assertEq(mockToken.balanceOf(user2), wrapAmount1 + wrapAmount2);
        assertEq(reserveLedgerToken.balanceOf(user1), 0);
    }

    function test_wrap_different_users() public {
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to both users
        reserveLedgerToken.mint(user1, wrapAmount);
        reserveLedgerToken.mint(user2, wrapAmount);

        // Both users approve tokenAuthority
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);
        vm.prank(user2);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);

        // User1 wraps
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken), user1, wrapAmount);

        // User2 wraps
        vm.prank(user2);
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount);

        // Verify both users received their wrapped tokens
        assertEq(mockToken.balanceOf(user1), wrapAmount);
        assertEq(mockToken.balanceOf(user2), wrapAmount);
    }

    function test_wrap_different_stablecoins() public {
        MockERC20WrapUnwrap mockToken2 = new MockERC20WrapUnwrap(address(reserveLedgerToken));
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount * 2);

        // User1 approves tokenAuthority
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount * 2);

        // Wrap into first token
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken), user1, wrapAmount);

        // Wrap into second token
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken2), user1, wrapAmount);

        // Verify wrapped tokens in both contracts
        assertEq(mockToken.balanceOf(user1), wrapAmount);
        assertEq(mockToken2.balanceOf(user1), wrapAmount);
    }

    function test_wrap_zero_amount() public {
        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, 100);

        // User1 approves tokenAuthority
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), 100);

        // Wrap zero amount
        vm.prank(user1);
        vm.expectRevert(ITokenAuthority.AmountCannotBeZero.selector);
        tokenAuthority.wrap(address(mockToken), user2, 0);

        // Verify no tokens were wrapped
        assertEq(mockToken.balanceOf(user2), 0);
        assertEq(reserveLedgerToken.balanceOf(user1), 100);
    }

    function test_wrap_revert_insufficient_balance() public {
        uint256 wrapAmount = 100;

        // User1 has no reserve ledger tokens
        assertEq(reserveLedgerToken.balanceOf(user1), 0);

        // User1 approves tokenAuthority (approval without balance)
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);

        // Attempt to wrap should fail
        vm.prank(user1);
        vm.expectRevert();
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount);
    }

    function test_wrap_revert_insufficient_approval() public {
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount);

        // User1 approves less than wrap amount
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount - 1);

        // Attempt to wrap should fail
        vm.prank(user1);
        vm.expectRevert();
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount);
    }

    function test_wrap_revert_no_approval() public {
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount);

        // User1 does not approve tokenAuthority

        // Attempt to wrap should fail
        vm.prank(user1);
        vm.expectRevert();
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount);
    }

    function test_wrap_large_amount() public {
        uint256 wrapAmount = type(uint128).max; // Large but safe amount

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount);

        // User1 approves tokenAuthority
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);

        // Wrap large amount
        vm.prank(user1);
        tokenAuthority.wrap(address(mockToken), user2, wrapAmount);

        // Verify wrapped tokens
        assertEq(mockToken.balanceOf(user2), wrapAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Getter Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_getMinterAllowance_returns_zero_by_default() public view {
        uint256 allowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(allowance, 0);
    }

    function test_getStablecoinTxnMintLimit_returns_zero_by_default() public view {
        uint256 txnLimit = tokenAuthority.getStablecoinTxnMintLimit(address(mockToken));
        assertEq(txnLimit, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Role Management Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_role_constants() public view {
        bytes32 mintRateLimitSetterRole = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
        bytes32 burnerRole = keccak256("BURNER_ROLE");
        bytes32 unwrapperRole = keccak256("UNWRAPPER_ROLE");

        assertEq(tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE(), mintRateLimitSetterRole);
        assertEq(tokenAuthority.BURNER_ROLE(), burnerRole);
        assertEq(tokenAuthority.UNWRAPPER_ROLE(), unwrapperRole);
    }

    function test_grantRole_multiple_roles() public {
        vm.startPrank(admin);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user1);
        tokenAuthority.grantRole(tokenAuthority.UNWRAPPER_ROLE(), user1);
        tokenAuthority.grantRole(tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE(), user1);
        vm.stopPrank();

        assertTrue(tokenAuthority.hasRole(tokenAuthority.BURNER_ROLE(), user1));
        assertTrue(tokenAuthority.hasRole(tokenAuthority.UNWRAPPER_ROLE(), user1));
        assertTrue(tokenAuthority.hasRole(tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE(), user1));
    }

    function test_revokeRole_success() public {
        // Grant role first
        vm.prank(admin);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user1);
        assertTrue(tokenAuthority.hasRole(tokenAuthority.BURNER_ROLE(), user1));

        // Revoke role
        vm.prank(admin);
        tokenAuthority.revokeRole(tokenAuthority.BURNER_ROLE(), user1);
        assertFalse(tokenAuthority.hasRole(tokenAuthority.BURNER_ROLE(), user1));
    }

    function test_getRoleMemberCount() public {
        vm.startPrank(admin);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user1);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user2);
        vm.stopPrank();

        assertEq(tokenAuthority.getRoleMemberCount(tokenAuthority.BURNER_ROLE()), 2);
    }

    function test_getRoleMember() public {
        vm.startPrank(admin);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user1);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user2);
        vm.stopPrank();

        address member0 = tokenAuthority.getRoleMember(tokenAuthority.BURNER_ROLE(), 0);
        address member1 = tokenAuthority.getRoleMember(tokenAuthority.BURNER_ROLE(), 1);

        assertTrue(member0 == user1 || member0 == user2);
        assertTrue(member1 == user1 || member1 == user2);
        assertTrue(member0 != member1);
    }

    function test_getRoleAdmin() public view {
        bytes32 defaultAdminRole = tokenAuthority.DEFAULT_ADMIN_ROLE();
        assertEq(tokenAuthority.getRoleAdmin(tokenAuthority.BURNER_ROLE()), defaultAdminRole);
        assertEq(tokenAuthority.getRoleAdmin(tokenAuthority.UNWRAPPER_ROLE()), defaultAdminRole);
        assertEq(
            tokenAuthority.getRoleAdmin(tokenAuthority.MINT_RATE_LIMIT_SETTER_ROLE()),
            defaultAdminRole
        );
    }

    function test_renounceRole_success() public {
        // Grant role first
        vm.prank(admin);
        tokenAuthority.grantRole(tokenAuthority.BURNER_ROLE(), user1);
        assertTrue(tokenAuthority.hasRole(tokenAuthority.BURNER_ROLE(), user1));

        // User renounces their own role (msg.sender must match the account parameter)
        vm.startPrank(user1);
        tokenAuthority.renounceRole(tokenAuthority.BURNER_ROLE(), user1);
        vm.stopPrank();
        assertFalse(tokenAuthority.hasRole(tokenAuthority.BURNER_ROLE(), user1));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Additional Edge Case Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_wrap_revert_reserve_ledger_token() public {
        uint256 wrapAmount = 100;

        // Setup: mint reserve ledger tokens to user1
        reserveLedgerToken.mint(user1, wrapAmount);

        // User1 approves tokenAuthority
        vm.prank(user1);
        reserveLedgerToken.approve(address(tokenAuthority), wrapAmount);

        // Try to wrap reserve ledger token into itself - should fail
        vm.prank(user1);
        vm.expectRevert();
        tokenAuthority.wrap(address(reserveLedgerToken), user2, wrapAmount);
    }

    function test_setTxnMintLimit_zero() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.TxnMintLimitSet(admin, address(mockToken), 0);
        tokenAuthority.setTxnMintLimit(address(mockToken), 0);

        assertEq(tokenAuthority.getStablecoinTxnMintLimit(address(mockToken)), 0);
    }

    function test_setMinterAllowance_zero() public {
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 0);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 0);

        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 0);
    }

    function test_mint_exactly_at_txn_limit() public {
        uint256 mintAmount = 100;

        // Setup limits equal to mint amount
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), mintAmount);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, mintAmount);
        vm.stopPrank();

        // Mint exactly at the limit - should succeed
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        assertEq(mockToken.balanceOf(user1), mintAmount);
    }

    function test_mint_exactly_at_minter_allowance() public {
        uint256 mintAmount = 100;

        // Setup limits equal to mint amount
        vm.startPrank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), mintAmount * 2);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, mintAmount);
        vm.stopPrank();

        // Mint exactly at the allowance - should succeed
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        assertEq(mockToken.balanceOf(user1), mintAmount);
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Upgrade Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_revert_not_admin() public {
        address newImplementation = address(new TokenAuthority(address(reserveLedgerToken), false));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.DEFAULT_ADMIN_ROLE()
            )
        );
        tokenAuthority.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function test_authorizeUpgrade_success() public {
        address newImplementation = address(new TokenAuthority(address(reserveLedgerToken), false));

        vm.prank(admin);
        tokenAuthority.upgradeToAndCall(newImplementation, "");
        // No revert - upgrade successful
    }

}
