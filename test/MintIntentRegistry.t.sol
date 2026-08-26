// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { MockERC20BurnMint } from "./utils/MockERC20.sol";
import { MintIntentRegistry } from "src/mintIntent/MintIntentRegistry.sol";
import { Approval, OperationState } from "src/mintIntent/MintIntentStorage.sol";
import { IMintIntent } from "src/mintIntent/interfaces/IMintIntent.sol";
import { IMintIntentErrors } from "src/mintIntent/interfaces/IMintIntentErrors.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { SingleTokenHandler } from "src/tokenAuthority/tokenHandler/SingleTokenHandler.sol";

/**
 * @title MintIntentRegistryTest
 * @notice Tests the shared mint intent registry.
 *
 *         The regression under test: operation IDs and hold IDs are only single-use within the
 *         storage that tracks them. When each controller proxy kept its own intent mappings, the
 *         same source-bridge operation could be published and consumed once per controller. These
 *         tests assert that pointing multiple controllers at one registry makes those identifiers
 *         single-use across all of them.
 */
contract MintIntentRegistryTest is Test {

    MintIntentRegistry registry;

    address admin;
    address controllerA;
    address controllerB;
    address stranger;
    address recipient;
    address stablecoin;

    uint64 expiry;

    /// @dev Cached so tests never read them from the registry between a vm.prank and the pranked
    /// call, since the intervening external call would consume the prank.
    bytes32 controllerRole;
    bytes32 defaultAdminRole;

    function setUp() public {
        admin = makeAddr("admin");
        controllerA = makeAddr("controllerA");
        controllerB = makeAddr("controllerB");
        stranger = makeAddr("stranger");
        recipient = makeAddr("recipient");
        stablecoin = makeAddr("stablecoin");

        expiry = uint64(block.timestamp + 1 days);

        registry = _deployRegistry(admin);

        controllerRole = registry.CONTROLLER_ROLE();
        defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        registry.grantRole(controllerRole, controllerA);
        registry.grantRole(controllerRole, controllerB);
        vm.stopPrank();
    }

    function _deployRegistry(address registryAdmin) internal returns (MintIntentRegistry) {
        MintIntentRegistry implementation = new MintIntentRegistry(false);
        return MintIntentRegistry(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(MintIntentRegistry.initialize, (registryAdmin))
                )
            )
        );
    }

    function _params(uint256 operationId, bytes32 holdId)
        internal
        view
        returns (IMintIntent.ApprovalParams memory)
    {
        return IMintIntent.ApprovalParams({
            operationId: operationId,
            holdId: holdId,
            amount: 100e6,
            recipient: recipient,
            stablecoin: stablecoin
        });
    }

    /*//////////////////////////////////////////////////////////////////////////
            Cross-deployment uniqueness (the regression this registry fixes)
    //////////////////////////////////////////////////////////////////////////*/

    function test_operationIdIsSingleUseAcrossControllers_publish() public {
        uint256 operationId = 1;

        vm.prank(controllerA);
        registry.publishApproval(_params(operationId, keccak256("holdA")), expiry);

        // A second controller sharing the registry cannot reuse the operation ID, even with a
        // different hold ID. Before the shared registry this succeeded once per controller.
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        registry.publishApproval(_params(operationId, keccak256("holdB")), expiry);
    }

    function test_holdIdIsSingleUseAcrossControllers_publish() public {
        bytes32 holdId = keccak256("shared-hold");

        vm.prank(controllerA);
        registry.publishApproval(_params(1, holdId), expiry);

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.ApprovalExistsForHoldId.selector, holdId)
        );
        registry.publishApproval(_params(2, holdId), expiry);
    }

    function test_consumedOperationIdCannotBeReusedByAnotherController() public {
        uint256 operationId = 7;
        bytes32 holdId = keccak256("hold-7");
        IMintIntent.ApprovalParams memory params = _params(operationId, holdId);

        vm.startPrank(controllerA);
        registry.publishApproval(params, expiry);
        registry.consumeApproval(params);
        vm.stopPrank();

        assertEq(uint256(registry.getOperationState(operationId)), uint256(OperationState.CONSUMED));

        // Controller B cannot consume it: ownership is checked before spent-state, so B is turned
        // away as a non-owner rather than being told the approval is already spent.
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector, holdId, controllerA, controllerB
            )
        );
        registry.consumeApproval(params);

        // The owning controller cannot double-spend it either
        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.InvalidApproval.selector, holdId, uint256(1))
        );
        registry.consumeApproval(params);

        // ...nor can B republish the operation ID.
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        registry.publishApproval(_params(operationId, keccak256("hold-other")), expiry);
    }

    function test_burnOperationIdIsSingleUseAcrossControllers() public {
        uint256 operationId = 42;

        vm.prank(controllerA);
        registry.consumeUnusedOperationId(operationId);

        // A burn on another controller cannot reuse the same operation ID
        vm.prank(controllerB);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        registry.consumeUnusedOperationId(operationId);

        // Nor can it be published as a mint approval
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        registry.publishApproval(_params(operationId, keccak256("hold-42")), expiry);
    }

    function test_revokedOperationIdIsRevokedForAllControllers() public {
        uint256 operationId = 99;

        vm.prank(controllerA);
        registry.revokeOperationId(operationId);

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        registry.publishApproval(_params(operationId, keccak256("hold-99")), expiry);

        vm.prank(controllerB);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        registry.consumeUnusedOperationId(operationId);
    }

    /// @dev Two real TokenAuthority deployments sharing one registry. This is the exact scenario
    /// from the finding: the same source operation published into two controllers.
    function test_twoTokenAuthoritiesShareOperationIdNamespace() public {
        address publisher = makeAddr("publisher");
        (TokenAuthority taA, TokenAuthority taB) = _deployTwoTokenAuthorities(publisher);

        uint256 operationId = 555;

        vm.prank(publisher);
        taA.publishApproval(_params(operationId, keccak256("hold-A")), expiry);

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExistsForOperationId.selector, operationId
            )
        );
        taB.publishApproval(_params(operationId, keccak256("hold-B")), expiry);

        // The approval published through A is readable through B: one shared source of truth
        Approval memory approvalViaB = taB.getApproval(keccak256("hold-A"));
        assertEq(approvalViaB.operationId, operationId);
        assertEq(approvalViaB.recipient, recipient);
    }

    /*//////////////////////////////////////////////////////////////////////////
        Per-approval ownership: IDs are shared, authority over an approval is not
    //////////////////////////////////////////////////////////////////////////*/

    function test_publishApproval_recordsPublishingController() public {
        bytes32 holdId = keccak256("hold-owner");

        vm.prank(controllerA);
        registry.publishApproval(_params(1, holdId), expiry);

        assertEq(registry.getApproval(holdId).controller, controllerA);
    }

    function test_revokeApproval_revertWhenNotPublishingController() public {
        uint256 operationId = 3;
        bytes32 holdId = keccak256("hold-3");

        vm.prank(controllerA);
        registry.publishApproval(_params(operationId, holdId), expiry);

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector, holdId, controllerA, controllerB
            )
        );
        registry.revokeApproval(holdId);

        // A's approval is untouched and still usable by A
        assertEq(uint256(registry.getOperationState(operationId)), uint256(OperationState.RESERVED));
        vm.prank(controllerA);
        assertEq(registry.revokeApproval(holdId), operationId);
    }

    function test_extendApproval_revertWhenNotPublishingController() public {
        bytes32 holdId = keccak256("hold-4");

        vm.prank(controllerA);
        registry.publishApproval(_params(4, holdId), expiry);

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector, holdId, controllerA, controllerB
            )
        );
        registry.extendApproval(holdId, expiry + 1 days);

        assertEq(registry.getApproval(holdId).expiry, expiry, "expiry must be unchanged");
    }

    function test_consumeApproval_revertWhenNotPublishingController() public {
        uint256 operationId = 5;
        bytes32 holdId = keccak256("hold-5");
        IMintIntent.ApprovalParams memory params = _params(operationId, holdId);

        vm.prank(controllerA);
        registry.publishApproval(params, expiry);

        // B cannot spend an intent that A published, even with perfectly matching params
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector, holdId, controllerA, controllerB
            )
        );
        registry.consumeApproval(params);

        assertEq(uint256(registry.getOperationState(operationId)), uint256(OperationState.RESERVED));
        vm.prank(controllerA);
        registry.consumeApproval(params);
        assertEq(uint256(registry.getOperationState(operationId)), uint256(OperationState.CONSUMED));
    }

    function test_revokeOperationId_revertWhenNotPublishingController() public {
        uint256 operationId = 6;
        bytes32 holdId = keccak256("hold-6");

        vm.prank(controllerA);
        registry.publishApproval(_params(operationId, holdId), expiry);

        // Revoking the operation ID would revoke A's approval with it
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector, holdId, controllerA, controllerB
            )
        );
        registry.revokeOperationId(operationId);

        assertEq(uint256(registry.getOperationState(operationId)), uint256(OperationState.RESERVED));
    }

    /// @dev An operation ID with no approval has no owner, so any controller may retire it. This is
    /// inherent to a shared ID namespace and is asserted so the behavior is deliberate, not
    /// accidental.
    function test_unownedOperationIdCanBeRetiredByAnyController() public {
        vm.prank(controllerA);
        registry.revokeOperationId(31);
        assertEq(uint256(registry.getOperationState(31)), uint256(OperationState.REVOKED));

        vm.prank(controllerB);
        registry.consumeUnusedOperationId(32);
        assertEq(uint256(registry.getOperationState(32)), uint256(OperationState.CONSUMED));
    }

    /// @dev Ownership is per approval, so two controllers can hold live approvals simultaneously
    /// and each may only act on its own.
    function test_controllersActIndependentlyOnTheirOwnApprovals() public {
        bytes32 holdA = keccak256("hold-indep-A");
        bytes32 holdB = keccak256("hold-indep-B");

        vm.prank(controllerA);
        registry.publishApproval(_params(41, holdA), expiry);
        vm.prank(controllerB);
        registry.publishApproval(_params(42, holdB), expiry);

        vm.prank(controllerA);
        assertEq(registry.extendApproval(holdA, expiry + 1 days), 41);
        vm.prank(controllerB);
        assertEq(registry.revokeApproval(holdB), 42);

        assertEq(uint256(registry.getOperationState(41)), uint256(OperationState.RESERVED));
        assertEq(uint256(registry.getOperationState(42)), uint256(OperationState.REVOKED));
        assertEq(registry.getApproval(holdA).controller, controllerA);
        assertEq(registry.getApproval(holdB).controller, controllerB);
    }

    /// @dev The case where ownership actually prevents a loss: BOTH controllers are fully
    /// authorized to mint the same stablecoin (allowance, txn limit, and a handler that can mint).
    /// Without per-approval ownership, controller B could spend an intent published through A,
    /// minting real tokens against A's operation ID under B's limits. Asserts B is blocked and no
    /// tokens move.
    function test_dualAuthorizedControllerCannotSpendAnothersApproval() public {
        address publisher = makeAddr("publisher");
        (TokenAuthority taA, TokenAuthority taB) = _deployTwoTokenAuthorities(publisher);

        MockERC20BurnMint token = new MockERC20BurnMint();
        SingleTokenHandler handlerA = new SingleTokenHandler(address(taA));
        SingleTokenHandler handlerB = new SingleTokenHandler(address(taB));

        address minter = makeAddr("dualMinter");
        uint256 amount = 100e6;

        // Both authorities can mint this token: registered, handler wired, minter funded.
        // MockERC20BurnMint has no minter gating, so both handlers really can mint.
        vm.startPrank(admin);
        taA.registerStablecoin(address(token), address(handlerA), amount);
        taB.registerStablecoin(address(token), address(handlerB), amount);
        taA.grantRole(taA.MINT_RATE_LIMIT_SETTER_ROLE(), admin);
        taB.grantRole(taB.MINT_RATE_LIMIT_SETTER_ROLE(), admin);
        taA.setMinterAllowance(address(token), minter, amount);
        taB.setMinterAllowance(address(token), minter, amount);
        vm.stopPrank();

        IMintIntent.ApprovalParams memory params = IMintIntent.ApprovalParams({
            operationId: 8888,
            holdId: keccak256("hold-dual"),
            amount: amount,
            recipient: recipient,
            stablecoin: address(token)
        });

        vm.prank(publisher);
        taA.publishApproval(params, expiry);

        // B is fully capable of minting this token, and is turned away purely on ownership
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector,
                params.holdId,
                address(taA),
                address(taB)
            )
        );
        taB.mintWithApproval(params);

        assertEq(token.balanceOf(recipient), 0, "no tokens may be minted through B");
        assertEq(
            uint256(registry.getOperationState(8888)),
            uint256(OperationState.RESERVED),
            "intent must remain spendable by A"
        );
        assertEq(taB.getMinterAllowance(address(token), minter), amount, "B allowance untouched");

        // A, the publisher's controller, can still spend it exactly once
        vm.prank(minter);
        taA.mintWithApproval(params);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(uint256(registry.getOperationState(8888)), uint256(OperationState.CONSUMED));
    }

    /// @dev End-to-end: TokenAuthority B cannot revoke an intent published through TokenAuthority
    /// A, even though both share the registry and the same publisher EOA holds PUBLISHER_ROLE on
    /// both.
    /// Revoking needs no minting authorization at all, so this is a pure griefing vector that
    /// per-approval ownership closes.
    function test_tokenAuthorityCannotRevokeAnotherAuthoritysApproval() public {
        address publisher = makeAddr("publisher");
        (TokenAuthority taA, TokenAuthority taB) = _deployTwoTokenAuthorities(publisher);

        bytes32 holdId = keccak256("hold-e2e-owner");

        vm.prank(publisher);
        taA.publishApproval(_params(777, holdId), expiry);

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.NotApprovalController.selector, holdId, address(taA), address(taB)
            )
        );
        taB.revokeApproval(holdId);

        vm.prank(publisher);
        taA.revokeApproval(holdId);
        assertEq(uint256(registry.getOperationState(777)), uint256(OperationState.REVOKED));
    }

    function _deployTwoTokenAuthorities(address publisher)
        internal
        returns (TokenAuthority taA, TokenAuthority taB)
    {
        // A real token, not an EOA: registerStablecoin reads decimals() off the reserve ledger for
        // its precision check. MockERC20BurnMint is 18 decimals, matching stablecoins registered
        // below in tests that need one.
        address reserveLedger = address(new MockERC20BurnMint());

        TokenAuthority implementation = new TokenAuthority(reserveLedger, true);

        taA = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(TokenAuthority.initialize, (admin, publisher, address(registry)))
                )
            )
        );
        taB = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(TokenAuthority.initialize, (admin, publisher, address(registry)))
                )
            )
        );

        vm.startPrank(admin);
        registry.grantRole(controllerRole, address(taA));
        registry.grantRole(controllerRole, address(taB));
        vm.stopPrank();
    }

    function _deployTokenAuthority(address publisher, address registryAddress)
        internal
        returns (TokenAuthority ta)
    {
        // A real token, not an EOA: registerStablecoin reads decimals() off the reserve ledger.
        TokenAuthority implementation = new TokenAuthority(address(new MockERC20BurnMint()), true);

        ta = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(TokenAuthority.initialize, (admin, publisher, registryAddress))
                )
            )
        );

        vm.prank(admin);
        registry.grantRole(controllerRole, address(ta));
    }

    /*//////////////////////////////////////////////////////////////////////////
                        Terminal states and existence guards
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The require that makes CONSUMED and REVOKED terminal. Without it an operation ID could
    /// be walked back out of a terminal state and reused.
    function test_revokeOperationId_revertWhenTerminalState() public {
        // consumed via the burn path
        vm.prank(controllerA);
        registry.consumeUnusedOperationId(50);

        // consumed via an approval
        IMintIntent.ApprovalParams memory p51 = _params(51, keccak256("hold-51"));
        vm.startPrank(controllerA);
        registry.publishApproval(p51, expiry);
        registry.consumeApproval(p51);

        // revoked as an unused id
        registry.revokeOperationId(52);

        // revoked via its approval
        registry.publishApproval(_params(53, keccak256("hold-53")), expiry);
        registry.revokeApproval(keccak256("hold-53"));
        vm.stopPrank();

        uint256[4] memory ids = [uint256(50), 51, 52, 53];
        OperationState[4] memory expected = [
            OperationState.CONSUMED,
            OperationState.CONSUMED,
            OperationState.REVOKED,
            OperationState.REVOKED
        ];

        for (uint256 i = 0; i < ids.length; i++) {
            vm.prank(controllerA);
            vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
            registry.revokeOperationId(ids[i]);

            assertEq(
                uint256(registry.getOperationState(ids[i])),
                uint256(expected[i]),
                "terminal state must be unchanged"
            );
        }
    }

    /// @dev Without the existence guard, revoking an unknown hold ID would read a zeroed Approval,
    /// write _operationStates[0] = REVOKED, and emit ApprovalRevoked(..., operationId: 0).
    function test_revokeApproval_revertWhenMissingOrAlreadySpent() public {
        bytes32 missing = keccak256("never-published");

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.ApprovalNotExistsForHoldId.selector, missing)
        );
        registry.revokeApproval(missing);

        assertEq(
            uint256(registry.getOperationState(0)),
            uint256(OperationState.UNUSED),
            "operation ID 0 must not be written"
        );

        // Already revoked
        bytes32 revoked = keccak256("hold-60");
        vm.startPrank(controllerA);
        registry.publishApproval(_params(60, revoked), expiry);
        registry.revokeApproval(revoked);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.InvalidApproval.selector, revoked, uint256(2))
        );
        registry.revokeApproval(revoked);

        // Already consumed
        bytes32 consumed = keccak256("hold-61");
        IMintIntent.ApprovalParams memory p61 = _params(61, consumed);
        registry.publishApproval(p61, expiry);
        registry.consumeApproval(p61);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.InvalidApproval.selector, consumed, uint256(1))
        );
        registry.revokeApproval(consumed);
        vm.stopPrank();
    }

    /// @dev Pins `<=` rather than `<` on the expiry check: an approval is dead exactly AT its
    /// expiry timestamp, not one second later.
    function test_consumeApproval_expiryBoundary() public {
        IMintIntent.ApprovalParams memory pLive = _params(62, keccak256("hold-62"));
        IMintIntent.ApprovalParams memory pDead = _params(63, keccak256("hold-63"));

        vm.startPrank(controllerA);
        registry.publishApproval(pLive, expiry);
        registry.publishApproval(pDead, expiry);

        vm.warp(expiry - 1);
        registry.consumeApproval(pLive);
        assertEq(uint256(registry.getOperationState(62)), uint256(OperationState.CONSUMED));

        vm.warp(expiry);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApprovalParams.selector,
                false,
                false,
                false,
                false,
                false,
                true
            )
        );
        registry.consumeApproval(pDead);
        vm.stopPrank();
    }

    /// @dev A client swapping hold IDs between two live intents must be rejected. Note this is
    /// caught by the operation-ID cross-check, NOT by the ownership check, so it needs pinning
    /// independently.
    function test_consumeApproval_revertWhenLiveIntentsCrossed() public {
        bytes32 hA = keccak256("hold-cross-A");
        bytes32 hB = keccak256("hold-cross-B");

        vm.startPrank(controllerA);
        registry.publishApproval(_params(64, hA), expiry);
        registry.publishApproval(_params(65, hB), expiry);

        // operationId 64 paired with the other intent's hold ID
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApprovalParams.selector,
                false,
                true,
                false,
                false,
                false,
                false
            )
        );
        registry.consumeApproval(_params(64, hB));
        vm.stopPrank();

        assertEq(uint256(registry.getOperationState(64)), uint256(OperationState.RESERVED));
        assertEq(uint256(registry.getOperationState(65)), uint256(OperationState.RESERVED));
    }

    /// @dev Revoking CONTROLLER_ROLE is the kill switch. It must halt the controller without
    /// destroying intent state and without releasing its operation IDs back to other controllers.
    function test_revokingControllerRoleHaltsOperationsWithoutReleasingIds() public {
        bytes32 holdId = keccak256("hold-killswitch");

        vm.prank(controllerA);
        registry.publishApproval(_params(66, holdId), expiry);

        vm.prank(admin);
        registry.revokeRole(controllerRole, controllerA);

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                controllerA,
                controllerRole
            )
        );
        registry.revokeApproval(holdId);

        // State survives, and the ID is still claimed
        assertEq(uint256(registry.getOperationState(66)), uint256(OperationState.RESERVED));
        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.ApprovalExistsForOperationId.selector, 66)
        );
        registry.publishApproval(_params(66, keccak256("hold-other")), expiry);

        // Re-granting restores the controller, and its approval is still actionable
        vm.prank(admin);
        registry.grantRole(controllerRole, controllerA);
        vm.prank(controllerA);
        assertEq(registry.revokeApproval(holdId), 66);
    }

    /// @dev The lowest-privilege path into the shared namespace: a burner on B must not be able to
    /// retire an operation ID that A has reserved.
    function test_burnOnBCannotRetireOperationIdReservedByA() public {
        vm.prank(controllerA);
        registry.publishApproval(_params(67, keccak256("hold-67")), expiry);

        vm.prank(controllerB);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        registry.consumeUnusedOperationId(67);

        assertEq(uint256(registry.getOperationState(67)), uint256(OperationState.RESERVED));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Registry Migration (setter)
    //////////////////////////////////////////////////////////////////////////*/

    function test_setMintIntentRegistry_updatesRegistryAndEmits() public {
        address publisher = makeAddr("publisher");
        TokenAuthority ta = _deployTokenAuthority(publisher, address(registry));

        MintIntentRegistry newRegistry = _deployRegistry(admin);
        vm.prank(admin);
        newRegistry.grantRole(controllerRole, address(ta));

        vm.prank(admin);
        vm.expectEmit(true, true, true, false, address(ta));
        emit IMintIntent.MintIntentRegistrySet(admin, address(registry), address(newRegistry));
        ta.setMintIntentRegistry(address(newRegistry));

        assertEq(address(ta.mintIntentRegistry()), address(newRegistry));

        // Intents now land in the new registry, not the old one
        vm.prank(publisher);
        ta.publishApproval(_params(1, keccak256("hold-migrated")), expiry);

        assertEq(newRegistry.getApproval(keccak256("hold-migrated")).operationId, 1);
        assertEq(registry.getApproval(keccak256("hold-migrated")).operationId, 0);
    }

    /// @dev Migrating to a FRESH registry re-opens already-spent operation IDs, because uniqueness
    /// only ever held within one registry's storage. This is the same double-processing the audit
    /// finding is about, reachable through this setter, so it is pinned here deliberately: a
    /// replacement registry must be a UUPS upgrade of the same proxy, never a new deployment.
    function test_setMintIntentRegistry_freshRegistryReopensSpentOperationIds() public {
        address publisher = makeAddr("publisher");
        TokenAuthority ta = _deployTokenAuthority(publisher, address(registry));

        MockERC20BurnMint token = new MockERC20BurnMint();
        SingleTokenHandler handler = new SingleTokenHandler(address(ta));
        address minter = makeAddr("replayMinter");
        uint256 amount = 100e6;

        vm.startPrank(admin);
        ta.registerStablecoin(address(token), address(handler), amount);
        ta.grantRole(ta.MINT_RATE_LIMIT_SETTER_ROLE(), admin);
        ta.setMinterAllowance(address(token), minter, 2 * amount);
        vm.stopPrank();

        IMintIntent.ApprovalParams memory params = IMintIntent.ApprovalParams({
            operationId: 1234,
            holdId: keccak256("hold-replay"),
            amount: amount,
            recipient: recipient,
            stablecoin: address(token)
        });

        vm.prank(publisher);
        ta.publishApproval(params, expiry);
        vm.prank(minter);
        ta.mintWithApproval(params);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(uint256(registry.getOperationState(1234)), uint256(OperationState.CONSUMED));

        // Point the controller at a brand-new registry with empty storage
        MintIntentRegistry freshRegistry = _deployRegistry(admin);
        vm.prank(admin);
        freshRegistry.grantRole(controllerRole, address(ta));
        vm.prank(admin);
        ta.setMintIntentRegistry(address(freshRegistry));

        // The identical source operation is now replayable
        vm.prank(publisher);
        ta.publishApproval(params, expiry);
        vm.prank(minter);
        ta.mintWithApproval(params);

        assertEq(
            token.balanceOf(recipient),
            2 * amount,
            "a fresh registry re-opens a spent operation ID: migrate by upgrading the proxy instead"
        );
        assertEq(
            uint256(registry.getOperationState(1234)),
            uint256(OperationState.CONSUMED),
            "the old registry still records it as spent"
        );
    }

    /// @dev Migrating away strands an in-flight approval: it can be neither spent nor cancelled,
    /// because both paths resolve through the controller's current registry pointer.
    function test_setMintIntentRegistry_strandsInFlightApprovals() public {
        address publisher = makeAddr("publisher");
        TokenAuthority ta = _deployTokenAuthority(publisher, address(registry));

        bytes32 holdId = keccak256("hold-stranded");
        vm.prank(publisher);
        ta.publishApproval(_params(77, holdId), expiry);

        MintIntentRegistry newRegistry = _deployRegistry(admin);
        vm.prank(admin);
        newRegistry.grantRole(controllerRole, address(ta));
        vm.prank(admin);
        ta.setMintIntentRegistry(address(newRegistry));

        // Cannot be cancelled through the controller any more
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(IMintIntentErrors.ApprovalNotExistsForHoldId.selector, holdId)
        );
        ta.revokeApproval(holdId);

        // The old registry still holds it as RESERVED, so drain or revoke before migrating
        assertEq(uint256(registry.getOperationState(77)), uint256(OperationState.RESERVED));
        assertEq(uint256(newRegistry.getOperationState(77)), uint256(OperationState.UNUSED));
    }

    function test_setMintIntentRegistry_sameAddressIsNoOp() public {
        address publisher = makeAddr("publisher");
        TokenAuthority ta = _deployTokenAuthority(publisher, address(registry));

        bytes32 holdId = keccak256("hold-noop");
        vm.prank(publisher);
        ta.publishApproval(_params(78, holdId), expiry);

        vm.prank(admin);
        ta.setMintIntentRegistry(address(registry));

        assertEq(address(ta.mintIntentRegistry()), address(registry));

        // The reserved intent is untouched and still actionable
        vm.prank(publisher);
        assertEq(ta.getApproval(holdId).operationId, 78);
        vm.prank(publisher);
        assertEq(registry.getApproval(holdId).controller, address(ta));
    }

    function test_setMintIntentRegistry_revertWhenNotAdmin() public {
        TokenAuthority ta = _deployTokenAuthority(makeAddr("publisher"), address(registry));

        MintIntentRegistry newRegistry = _deployRegistry(admin);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, defaultAdminRole
            )
        );
        ta.setMintIntentRegistry(address(newRegistry));
    }

    function test_setMintIntentRegistry_revertWhenZeroAddress() public {
        TokenAuthority ta = _deployTokenAuthority(makeAddr("publisher"), address(registry));

        vm.prank(admin);
        vm.expectRevert(IMintIntentErrors.InvalidRegistry.selector);
        ta.setMintIntentRegistry(address(0));
    }

    /// @dev Without this guard an admin could point the controller at a registry it is not
    /// authorized on, leaving every publish/consume reverting.
    function test_setMintIntentRegistry_revertWhenControllerNotAuthorized() public {
        TokenAuthority ta = _deployTokenAuthority(makeAddr("publisher"), address(registry));

        MintIntentRegistry newRegistry = _deployRegistry(admin);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ControllerNotAuthorizedOnRegistry.selector, address(newRegistry)
            )
        );
        ta.setMintIntentRegistry(address(newRegistry));

        // The original registry is retained
        assertEq(address(ta.mintIntentRegistry()), address(registry));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Access Control
    //////////////////////////////////////////////////////////////////////////*/

    function test_publishApproval_revertWhenNotController() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.publishApproval(_params(1, keccak256("hold")), expiry);
    }

    function test_consumeApproval_revertWhenNotController() public {
        IMintIntent.ApprovalParams memory params = _params(1, keccak256("hold"));

        vm.prank(controllerA);
        registry.publishApproval(params, expiry);

        // Without CONTROLLER_ROLE an arbitrary caller cannot consume an intent, which would
        // otherwise let anyone mark a bridge operation as spent.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.consumeApproval(params);
    }

    function test_consumeUnusedOperationId_revertWhenNotController() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.consumeUnusedOperationId(1);
    }

    function test_revokeApproval_revertWhenNotController() public {
        bytes32 holdId = keccak256("hold");

        vm.prank(controllerA);
        registry.publishApproval(_params(1, holdId), expiry);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.revokeApproval(holdId);
    }

    function test_revokeOperationId_revertWhenNotController() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.revokeOperationId(1);
    }

    function test_extendApproval_revertWhenNotController() public {
        bytes32 holdId = keccak256("hold");

        vm.prank(controllerA);
        registry.publishApproval(_params(1, holdId), expiry);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.extendApproval(holdId, expiry + 1);
    }

    function test_controllerRoleCanBeRevokedByAdmin() public {
        vm.prank(admin);
        registry.revokeRole(controllerRole, controllerA);

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                controllerA,
                controllerRole
            )
        );
        registry.publishApproval(_params(1, keccak256("hold")), expiry);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Registry State
    //////////////////////////////////////////////////////////////////////////*/

    function test_initialize_grantsAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_publishApproval_storesApproval() public {
        uint256 operationId = 11;
        bytes32 holdId = keccak256("hold-11");

        vm.prank(controllerA);
        registry.publishApproval(_params(operationId, holdId), expiry);

        Approval memory approval = registry.getApproval(holdId);
        assertEq(approval.amount, 100e6);
        assertEq(approval.recipient, recipient);
        assertEq(approval.stablecoin, stablecoin);
        assertEq(approval.expiry, expiry);
        assertEq(approval.operationId, operationId);
        assertEq(approval.flags, 0);

        assertEq(registry.getOperationHoldId(operationId), holdId);
        assertEq(uint256(registry.getOperationState(operationId)), uint256(OperationState.RESERVED));
    }

    function test_extendApproval_updatesExpiryAndReturnsOperationId() public {
        uint256 operationId = 12;
        bytes32 holdId = keccak256("hold-12");

        vm.prank(controllerA);
        registry.publishApproval(_params(operationId, holdId), expiry);

        vm.prank(controllerA);
        uint256 returnedOperationId = registry.extendApproval(holdId, expiry + 1 days);

        assertEq(returnedOperationId, operationId);
        assertEq(registry.getApproval(holdId).expiry, expiry + 1 days);
    }

    function test_extendApproval_revertWhenNotExtended() public {
        bytes32 holdId = keccak256("hold-13");

        vm.prank(controllerA);
        registry.publishApproval(_params(13, holdId), expiry);

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.ApprovalExpiryNotExtended.selector, holdId, expiry, expiry
            )
        );
        registry.extendApproval(holdId, expiry);
    }

    function test_revokeOperationId_returnsAssociatedHoldId() public {
        uint256 operationId = 14;
        bytes32 holdId = keccak256("hold-14");

        vm.prank(controllerA);
        registry.publishApproval(_params(operationId, holdId), expiry);

        vm.prank(controllerA);
        bytes32 returnedHoldId = registry.revokeOperationId(operationId);

        assertEq(returnedHoldId, holdId);
        assertTrue(registry.getApproval(holdId).flags != 0);
    }

    function test_revokeOperationId_returnsZeroHoldIdWhenUnused() public {
        vm.prank(controllerA);
        bytes32 returnedHoldId = registry.revokeOperationId(15);

        assertEq(returnedHoldId, bytes32(0));
    }

    function test_consumeApproval_revertWhenExpired() public {
        uint256 operationId = 16;
        bytes32 holdId = keccak256("hold-16");
        IMintIntent.ApprovalParams memory params = _params(operationId, holdId);

        vm.prank(controllerA);
        registry.publishApproval(params, expiry);

        vm.warp(expiry + 1);

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintIntentErrors.InvalidApprovalParams.selector,
                false,
                false,
                false,
                false,
                false,
                true
            )
        );
        registry.consumeApproval(params);
    }

    function test_publishApproval_revertWhenExpiryInPast() public {
        vm.prank(controllerA);
        vm.expectRevert(IMintIntentErrors.InvalidExpiry.selector);
        registry.publishApproval(_params(17, keccak256("hold-17")), uint64(block.timestamp));
    }

    function test_publishApproval_revertWhenOperationIdIsZero() public {
        vm.prank(controllerA);
        vm.expectRevert(IMintIntentErrors.InvalidOperationId.selector);
        registry.publishApproval(_params(0, keccak256("hold-18")), expiry);
    }

    function test_publishApproval_revertWhenHoldIdIsZero() public {
        vm.prank(controllerA);
        vm.expectRevert(IMintIntentErrors.InvalidHoldId.selector);
        registry.publishApproval(_params(19, bytes32(0)), expiry);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Upgrade Logic
    //////////////////////////////////////////////////////////////////////////*/

    function test_upgrade_revertWhenNotAdmin() public {
        address newImplementation = address(new MintIntentRegistry(true));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, defaultAdminRole
            )
        );
        registry.upgradeToAndCall(newImplementation, "");
    }

    function test_upgrade_success() public {
        address newImplementation = address(new MintIntentRegistry(true));

        vm.prank(admin);
        registry.upgradeToAndCall(newImplementation, "");

        // State survives the upgrade
        assertTrue(registry.hasRole(registry.CONTROLLER_ROLE(), controllerA));
    }

}
