// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockERC20BurnMint } from "./utils/MockERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { ITokenAuthority } from "src/tokenAuthority/ITokenAuthority.sol";
import { IERC20BurnMint } from "src/utils/IERC20BurnMint.sol";

contract TokenAuthorityTest is Test {

    TokenAuthority tokenAuthority;
    MockERC20BurnMint mockToken;
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

        // Deploy mock stablecoin token
        mockToken = new MockERC20BurnMint();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Initialization Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_failsWhenDisabled() public {
        TokenAuthority tokenAuthority = new TokenAuthority(address(reserveLedgerToken), true);

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        tokenAuthority.initialize(admin);
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
        uint256 globalLimit = 1000 ether;
        uint256 txnLimit = 100 ether;

        vm.prank(admin);
        tokenAuthority.setMintRateLimits(address(mockToken), globalLimit, txnLimit);

        (uint256 returnedGlobalLimit, uint256 returnedTxnLimit) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));

        assertEq(returnedGlobalLimit, globalLimit);
        assertEq(returnedTxnLimit, txnLimit);
    }

    function test_setMintRateLimits_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.DEFAULT_ADMIN_ROLE()
            )
        );
        tokenAuthority.setMintRateLimits(address(mockToken), 1000 ether, 100 ether);
        vm.stopPrank();
    }

    function test_setGlobalMintLimit_success() public {
        uint256 globalLimit = 1000 ether;

        vm.prank(admin);
        tokenAuthority.setGlobalMintLimit(address(mockToken), globalLimit);

        (uint256 returnedGlobalLimit,) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(returnedGlobalLimit, globalLimit);
    }

    function test_setGlobalMintLimit_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.DEFAULT_ADMIN_ROLE()
            )
        );
        tokenAuthority.setGlobalMintLimit(address(mockToken), 1000 ether);
        vm.stopPrank();
    }

    function test_setTxnMintLimit_success() public {
        uint256 txnLimit = 100 ether;

        vm.prank(admin);
        tokenAuthority.setTxnMintLimit(address(mockToken), txnLimit);

        (, uint256 returnedTxnLimit) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(returnedTxnLimit, txnLimit);
    }

    function test_setTxnMintLimit_revert_not_admin() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user1,
                tokenAuthority.DEFAULT_ADMIN_ROLE()
            )
        );
        tokenAuthority.setTxnMintLimit(address(mockToken), 100 ether);
        vm.stopPrank();
    }

    function test_setMinterAllowance_success() public {
        uint256 allowance = 500 ether;

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
                tokenAuthority.DEFAULT_ADMIN_ROLE()
            )
        );
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500 ether);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Mint Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_mint_success() public {
        uint256 mintAmount = 50 ether;

        // Setup limits and allowances
        vm.startPrank(admin);
        tokenAuthority.setMintRateLimits(address(mockToken), 1000 ether, 100 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500 ether);
        vm.stopPrank();

        // Mint
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify token was minted
        assertEq(mockToken.balanceOf(user1), mintAmount);

        // Verify limits were decremented
        (uint256 globalLimit, uint256 txnLimit) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(globalLimit, 1000 ether - mintAmount);
        assertEq(txnLimit, 100 ether - mintAmount);

        // Verify allowance was decremented
        uint256 remainingAllowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(remainingAllowance, 500 ether - mintAmount);
    }

    function test_mint_with_max_limits_no_decrement() public {
        uint256 mintAmount = 50 ether;

        // Setup with max uint256 limits (unlimited)
        vm.startPrank(admin);
        tokenAuthority.setMintRateLimits(address(mockToken), type(uint256).max, type(uint256).max);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, type(uint256).max);
        vm.stopPrank();

        // Mint
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);

        // Verify token was minted
        assertEq(mockToken.balanceOf(user1), mintAmount);

        // Verify limits were NOT decremented (still max)
        (uint256 globalLimit, uint256 txnLimit) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(globalLimit, type(uint256).max);
        assertEq(txnLimit, type(uint256).max);

        // Verify allowance was NOT decremented (still max)
        uint256 remainingAllowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(remainingAllowance, type(uint256).max);
    }

    function test_mint_revert_global_limit_exceeded() public {
        uint256 mintAmount = 100 ether;

        // Setup limits where global limit is less than mint amount
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MintRateLimitsSet(admin, address(mockToken), 50 ether, 200 ether);
        tokenAuthority.setMintRateLimits(address(mockToken), 50 ether, 200 ether);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 500 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500 ether);
        vm.stopPrank();

        // Attempt to mint
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintGlobalLimitExceeded.selector);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);
    }

    function test_mint_revert_txn_limit_exceeded() public {
        uint256 mintAmount = 100 ether;

        // Setup limits where txn limit is less than mint amount
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MintRateLimitsSet(admin, address(mockToken), 1000 ether, 50 ether);
        tokenAuthority.setMintRateLimits(address(mockToken), 1000 ether, 50 ether);
        
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 500 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 500 ether);
        vm.stopPrank();

        // Attempt to mint
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintTxnLimitExceeded.selector);
        tokenAuthority.mint(address(mockToken), user1, mintAmount);
    }

    function test_mint_revert_minter_allowance_exceeded() public {
        uint256 mintAmount = 100 ether;

        // Setup limits where minter allowance is less than mint amount
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MintRateLimitsSet(admin, address(mockToken), 1000 ether, 200 ether);
        tokenAuthority.setMintRateLimits(address(mockToken), 1000 ether, 200 ether);
        
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 50 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 50 ether);
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
        emit ITokenAuthority.MintRateLimitsSet(admin, address(mockToken), 100 ether, 50 ether);
        tokenAuthority.setMintRateLimits(address(mockToken), 100 ether, 50 ether);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 100 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 100 ether);
        vm.stopPrank();

        // First mint
        vm.prank(minter);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.Mint(minter, address(mockToken), user1, 30 ether);
        tokenAuthority.mint(address(mockToken), user1, 30 ether);

        // Check remaining limits
        (uint256 globalLimit, uint256 txnLimit) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(globalLimit, 70 ether);
        assertEq(txnLimit, 20 ether);
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 70 ether);

        // Second mint should fail due to txn limit
        vm.prank(minter);
        vm.expectRevert(ITokenAuthority.MintTxnLimitExceeded.selector);
        tokenAuthority.mint(address(mockToken), user1, 30 ether);
    }

    function test_mint_different_stablecoins_separate_limits() public {
        MockERC20BurnMint mockToken2 = new MockERC20BurnMint();

        // Setup limits for both tokens
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MintRateLimitsSet(admin, address(mockToken), 100 ether, 50 ether);
        tokenAuthority.setMintRateLimits(address(mockToken), 100 ether, 50 ether);
        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MinterAllowanceSet(admin, address(mockToken), minter, 100 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit ITokenAuthority.MintRateLimitsSet(admin, address(mockToken2), 200 ether, 100 ether);
        tokenAuthority.setMintRateLimits(address(mockToken2), 200 ether, 100 ether);
        tokenAuthority.setMinterAllowance(address(mockToken2), minter, 200 ether);
        vm.stopPrank();

        // Mint from first token
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, 30 ether);

        // Verify first token limits decreased
        (uint256 globalLimit1, uint256 txnLimit1) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(globalLimit1, 70 ether);
        assertEq(txnLimit1, 20 ether);

        // Verify second token limits unchanged
        (uint256 globalLimit2, uint256 txnLimit2) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken2));
        assertEq(globalLimit2, 200 ether);
        assertEq(txnLimit2, 100 ether);

        // Mint from second token should work
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken2), user1, 50 ether);

        assertEq(mockToken2.balanceOf(user1), 50 ether);
    }

    function test_mint_different_minters_separate_allowances() public {
        address minter2 = makeAddr("minter2");

        // Setup limits for both minters
        vm.startPrank(admin);
        tokenAuthority.setMintRateLimits(address(mockToken), 1000 ether, 500 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter, 100 ether);
        tokenAuthority.setMinterAllowance(address(mockToken), minter2, 200 ether);
        vm.stopPrank();

        // Mint from first minter
        vm.prank(minter);
        tokenAuthority.mint(address(mockToken), user1, 50 ether);

        // Verify first minter allowance decreased
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter), 50 ether);

        // Verify second minter allowance unchanged
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter2), 200 ether);

        // Mint from second minter should work
        vm.prank(minter2);
        tokenAuthority.mint(address(mockToken), user2, 100 ether);

        assertEq(mockToken.balanceOf(user2), 100 ether);
        assertEq(tokenAuthority.getMinterAllowance(address(mockToken), minter2), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Getter Tests
    //////////////////////////////////////////////////////////////////////////*/

    function test_getMinterAllowance_returns_zero_by_default() public view {
        uint256 allowance = tokenAuthority.getMinterAllowance(address(mockToken), minter);
        assertEq(allowance, 0);
    }

    function test_getStablecoinMintRateLimits_returns_zero_by_default() public view {
        (uint256 globalLimit, uint256 txnLimit) =
            tokenAuthority.getStablecoinMintRateLimits(address(mockToken));
        assertEq(globalLimit, 0);
        assertEq(txnLimit, 0);
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
