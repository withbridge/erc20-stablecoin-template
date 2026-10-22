// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

import { MockERC20BurnMint } from "./utils/MockERC20.sol";
import { IdempotencyKeyRegistry } from "src/idempotency/IdempotencyKeyRegistry.sol";
import { IdempotencyKeyStorageLib } from "src/idempotency/IdempotencyKeyStorage.sol";
import { IIdempotencyKeyErrors } from "src/idempotency/interfaces/IIdempotencyKeyErrors.sol";
import { IIdempotencyKeys } from "src/idempotency/interfaces/IIdempotencyKeys.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { SingleTokenHandler } from "src/tokenAuthority/tokenHandler/SingleTokenHandler.sol";

/**
 * @title IdempotencyKeyRegistryTest
 * @notice Tests the shared idempotency-key registry.
 *
 *         The regression under test: keys are only single-use within the storage that tracks them.
 *         When each controller proxy kept its own mapping, the same key could be used once per
 *         controller. These tests assert that pointing multiple controllers at one registry makes
 *         those keys single-use across all of them.
 */
contract IdempotencyKeyRegistryTest is Test {

    IdempotencyKeyRegistry registry;

    address admin;
    address controllerA;
    address controllerB;
    address stranger;

    /// @dev Cached so tests never read them from the registry between a vm.prank and the pranked
    /// call, since the intervening external call would consume the prank.
    bytes32 controllerRole;
    bytes32 defaultAdminRole;

    function setUp() public {
        admin = makeAddr("admin");
        controllerA = makeAddr("controllerA");
        controllerB = makeAddr("controllerB");
        stranger = makeAddr("stranger");

        registry = _deployRegistry(admin);

        controllerRole = registry.CONTROLLER_ROLE();
        defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        registry.grantRole(controllerRole, controllerA);
        registry.grantRole(controllerRole, controllerB);
        vm.stopPrank();
    }

    function _deployRegistry(address registryAdmin) internal returns (IdempotencyKeyRegistry) {
        IdempotencyKeyRegistry implementation = new IdempotencyKeyRegistry(false);
        return IdempotencyKeyRegistry(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(IdempotencyKeyRegistry.initialize, (registryAdmin))
                )
            )
        );
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
            Cross-deployment uniqueness (the regression this registry fixes)
    //////////////////////////////////////////////////////////////////////////*/

    function test_keyIsSingleUseAcrossControllers() public {
        bytes32 key = keccak256("shared");

        vm.prank(controllerA);
        registry.useKeys(_keys(key));

        assertFalse(registry.isFree(key));

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        registry.useKeys(_keys(key));
    }

    function test_arrayConsumedAtomicallyAcrossControllers() public {
        bytes32 opKey = keccak256("op");
        bytes32 holdKey = keccak256("hold");

        vm.prank(controllerA);
        registry.useKeys(_keys(opKey, holdKey));

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, opKey)
        );
        registry.useKeys(_keys(opKey));

        vm.prank(controllerB);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, holdKey)
        );
        registry.useKeys(_keys(holdKey));
    }

    function test_anyControllerMayUseAFreeKey() public {
        bytes32 key = keccak256("unowned");

        vm.prank(controllerB);
        registry.useKeys(_keys(key));

        assertFalse(registry.isFree(key));
    }

    function test_twoTokenAuthoritiesShareKeyNamespace() public {
        (TokenAuthority taA, TokenAuthority taB) = _deployTwoTokenAuthorities();
        MockERC20BurnMint token = new MockERC20BurnMint();
        uint256 amount = 100e6;
        bytes32 key = keccak256("cross-ta");

        _configureMinter(taA, token, admin, amount);
        _configureMinter(taB, token, admin, amount);

        vm.prank(admin);
        taA.mint(address(token), admin, amount, _keys(key));

        assertFalse(registry.isFree(key));
        assertEq(token.balanceOf(admin), amount);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        taB.mint(address(token), admin, amount, _keys(key));

        assertEq(token.balanceOf(admin), amount, "reusing a key must not mint twice");

        vm.prank(admin);
        taB.mint(address(token), admin, amount, _keys(keccak256("fresh-ta-b")));

        assertEq(token.balanceOf(admin), 2 * amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                useKeys validation
    //////////////////////////////////////////////////////////////////////////*/

    function test_useKeys_marksUsedAndIsFree() public {
        bytes32 key = keccak256("fresh");
        assertTrue(registry.isFree(key));

        vm.prank(controllerA);
        registry.useKeys(_keys(key));

        assertFalse(registry.isFree(key));
    }

    function test_useKeys_revertWhenEmpty() public {
        vm.prank(controllerA);
        vm.expectRevert(IIdempotencyKeyErrors.InvalidIdempotencyKeys.selector);
        registry.useKeys(new bytes32[](0));
    }

    function test_useKeys_revertWhenZeroKey() public {
        vm.prank(controllerA);
        vm.expectRevert(IIdempotencyKeyErrors.InvalidIdempotencyKey.selector);
        registry.useKeys(_keys(bytes32(0)));
    }

    function test_useKeys_revertWhenDuplicateInSameCall() public {
        bytes32 key = keccak256("dup");

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        registry.useKeys(_keys(key, key));
    }

    function test_useKeys_revertWhenAlreadyUsed() public {
        bytes32 key = keccak256("spent");

        vm.prank(controllerA);
        registry.useKeys(_keys(key));

        vm.prank(controllerA);
        vm.expectRevert(
            abi.encodeWithSelector(IIdempotencyKeyErrors.IdempotencyKeyUsed.selector, key)
        );
        registry.useKeys(_keys(key));
    }

    function test_useKeys_revertWhenNotController() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, controllerRole
            )
        );
        registry.useKeys(_keys(keccak256("stranger")));
    }

    function test_revokingControllerRoleHaltsUseWithoutReleasingKeys() public {
        bytes32 key = keccak256("halt");

        vm.prank(controllerA);
        registry.useKeys(_keys(key));

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
        registry.useKeys(_keys(keccak256("halt-2")));

        assertFalse(registry.isFree(key), "spent keys stay spent after role revoke");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Registry Migration (setter)
    //////////////////////////////////////////////////////////////////////////*/

    function test_setIdempotencyKeyRegistry_updatesRegistryAndEmits() public {
        TokenAuthority ta = _deployTokenAuthority(address(registry));
        MockERC20BurnMint token = new MockERC20BurnMint();
        uint256 amount = 100e6;
        _configureMinter(ta, token, admin, amount);

        IdempotencyKeyRegistry newRegistry = _deployRegistry(admin);
        vm.prank(admin);
        newRegistry.grantRole(controllerRole, address(ta));

        vm.prank(admin);
        vm.expectEmit(true, true, true, false, address(ta));
        emit IIdempotencyKeys.IdempotencyKeyRegistrySet(
            admin, address(registry), address(newRegistry)
        );
        ta.setIdempotencyKeyRegistry(address(newRegistry));

        assertEq(address(ta.idempotencyKeyRegistry()), address(newRegistry));

        bytes32 key = keccak256("migrated");
        vm.prank(admin);
        ta.mint(address(token), admin, amount, _keys(key));

        assertEq(token.balanceOf(admin), amount);
        assertFalse(newRegistry.isFree(key));
        assertTrue(registry.isFree(key));
    }

    /// @dev Migrating to a FRESH registry re-opens already-spent keys, because uniqueness only
    /// ever held within one registry's storage. A replacement registry must be a UUPS upgrade of
    /// the same proxy, never a new deployment.
    function test_setIdempotencyKeyRegistry_freshRegistryReopensSpentKeys() public {
        TokenAuthority ta = _deployTokenAuthority(address(registry));

        MockERC20BurnMint token = new MockERC20BurnMint();
        address minter = makeAddr("replayMinter");
        uint256 amount = 100e6;
        bytes32 key = keccak256("replay");

        _configureMinter(ta, token, minter, amount);

        vm.prank(minter);
        ta.mint(address(token), minter, amount, _keys(key));

        assertEq(token.balanceOf(minter), amount);
        assertFalse(registry.isFree(key));

        IdempotencyKeyRegistry freshRegistry = _deployRegistry(admin);
        vm.prank(admin);
        freshRegistry.grantRole(controllerRole, address(ta));
        vm.prank(admin);
        ta.setIdempotencyKeyRegistry(address(freshRegistry));

        vm.prank(minter);
        ta.mint(address(token), minter, amount, _keys(key));

        assertEq(
            token.balanceOf(minter),
            2 * amount,
            "a fresh registry re-opens a spent key: migrate by upgrading the proxy instead"
        );
        assertFalse(registry.isFree(key), "the old registry still records it as spent");
        assertFalse(freshRegistry.isFree(key));
    }

    function test_setIdempotencyKeyRegistry_sameAddressIsNoOp() public {
        TokenAuthority ta = _deployTokenAuthority(address(registry));

        bytes32 key = keccak256("noop");
        vm.prank(controllerA);
        registry.useKeys(_keys(key));

        vm.prank(admin);
        ta.setIdempotencyKeyRegistry(address(registry));

        assertEq(address(ta.idempotencyKeyRegistry()), address(registry));
        assertFalse(registry.isFree(key));
    }

    function test_setIdempotencyKeyRegistry_revertWhenNotAdmin() public {
        TokenAuthority ta = _deployTokenAuthority(address(registry));

        IdempotencyKeyRegistry newRegistry = _deployRegistry(admin);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, defaultAdminRole
            )
        );
        ta.setIdempotencyKeyRegistry(address(newRegistry));
    }

    function test_setIdempotencyKeyRegistry_revertWhenZeroAddress() public {
        TokenAuthority ta = _deployTokenAuthority(address(registry));

        vm.prank(admin);
        vm.expectRevert(IIdempotencyKeyErrors.InvalidRegistry.selector);
        ta.setIdempotencyKeyRegistry(address(0));
    }

    function test_setIdempotencyKeyRegistry_revertWhenControllerNotAuthorized() public {
        TokenAuthority ta = _deployTokenAuthority(address(registry));

        IdempotencyKeyRegistry newRegistry = _deployRegistry(admin);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIdempotencyKeyErrors.ControllerNotAuthorizedOnRegistry.selector,
                address(newRegistry)
            )
        );
        ta.setIdempotencyKeyRegistry(address(newRegistry));

        assertEq(address(ta.idempotencyKeyRegistry()), address(registry));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Access Control
    //////////////////////////////////////////////////////////////////////////*/

    function test_controllerRoleCanBeRevokedByAdmin() public {
        vm.prank(admin);
        registry.revokeRole(controllerRole, controllerA);

        assertFalse(registry.hasRole(controllerRole, controllerA));
    }

    function test_initialize_grantsAdminRole() public view {
        assertTrue(registry.hasRole(defaultAdminRole, admin));
    }

    function test_storageLocationMatchesErc7201() public pure {
        bytes32 expected = keccak256(
            abi.encode(uint256(keccak256("bridge.IdempotencyKeyStorage")) - 1)
        ) & ~bytes32(uint256(0xff));
        assertEq(IdempotencyKeyStorageLib.IDEMPOTENCY_KEY_STORAGE_LOCATION, expected);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Upgrade Logic
    //////////////////////////////////////////////////////////////////////////*/

    function test_upgrade_revertWhenNotAdmin() public {
        address newImplementation = address(new IdempotencyKeyRegistry(true));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, defaultAdminRole
            )
        );
        registry.upgradeToAndCall(newImplementation, "");
    }

    function test_upgrade_success() public {
        bytes32 key = keccak256("survives");
        vm.prank(controllerA);
        registry.useKeys(_keys(key));

        address newImplementation = address(new IdempotencyKeyRegistry(true));

        vm.prank(admin);
        registry.upgradeToAndCall(newImplementation, "");

        assertTrue(registry.hasRole(registry.CONTROLLER_ROLE(), controllerA));
        assertFalse(registry.isFree(key), "key state survives the upgrade");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Deploy helpers
    //////////////////////////////////////////////////////////////////////////*/

    function _configureMinter(
        TokenAuthority ta,
        MockERC20BurnMint token,
        address minter,
        uint256 amount
    ) internal {
        SingleTokenHandler handler = new SingleTokenHandler(address(ta));

        vm.startPrank(admin);
        ta.grantRole(ta.TOKEN_AUTHORITY_HANDLER_SETTER_ROLE(), admin);
        ta.registerStablecoin(address(token), address(handler), amount);
        ta.grantRole(ta.MINT_RATE_LIMIT_SETTER_ROLE(), admin);
        ta.setMinterAllowance(address(token), minter, 2 * amount);
        vm.stopPrank();
    }

    function _deployTwoTokenAuthorities()
        internal
        returns (TokenAuthority taA, TokenAuthority taB)
    {
        address reserveLedger = address(new MockERC20BurnMint());

        TokenAuthority implementation = new TokenAuthority(reserveLedger, true);

        taA = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(TokenAuthority.initialize, (admin, address(registry)))
                )
            )
        );
        taB = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(TokenAuthority.initialize, (admin, address(registry)))
                )
            )
        );

        vm.startPrank(admin);
        registry.grantRole(controllerRole, address(taA));
        registry.grantRole(controllerRole, address(taB));
        vm.stopPrank();
    }

    function _deployTokenAuthority(address registryAddress) internal returns (TokenAuthority ta) {
        TokenAuthority implementation = new TokenAuthority(address(new MockERC20BurnMint()), true);

        ta = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(TokenAuthority.initialize, (admin, registryAddress))
                )
            )
        );

        vm.prank(admin);
        registry.grantRole(controllerRole, address(ta));
    }

}
