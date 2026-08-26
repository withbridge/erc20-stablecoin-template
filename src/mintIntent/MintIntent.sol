// SPDX- License-Identifier: MIT
pragma solidity ^0.8.24;

import { Approval } from "./MintIntentStorage.sol";
import { IMintIntent } from "./interfaces/IMintIntent.sol";
import { IMintIntentRegistry } from "./interfaces/IMintIntentRegistry.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Client base that exposes the mint intent lifecycle on a controller and forwards it to
/// the shared {MintIntentRegistry}.
/// @dev Intent state is deliberately NOT held here. Each controller proxy would otherwise keep its
/// own operation-ID and hold-ID mappings, which makes an operation ID single-use per controller
/// rather than across every controller deployment. All state lives in the shared registry.
/// @dev The registry validates and mutates; this base emits the {IMintIntent} events so the actor
/// recorded is the original caller rather than the controller.
/// @dev Implementers must store the registry pointer themselves and expose it through
/// {_setMintIntentRegistry} and {_mintIntentRegistry}. Declaring it here would insert a slot ahead
/// of the inheriting controller's existing variables and shift its storage layout.
abstract contract MintIntent is AccessControlEnumerableUpgradeable, IMintIntent {

    /*//////////////////////////////////////////////////////////////////////////
                                    Role Constants
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    function __MintIntent_init(address _publisher, address _registry) internal onlyInitializing {
        require(_registry != address(0), InvalidRegistry());

        _grantRole(PUBLISHER_ROLE, _publisher);
        _setMintIntentRegistry(IMintIntentRegistry(_registry));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintIntent
    function publishApproval(ApprovalParams calldata _params, uint64 _expiry)
        external
        onlyRole(PUBLISHER_ROLE)
    {
        _mintIntentRegistry().publishApproval(_params, _expiry);

        emit ApprovalPublished(
            msg.sender,
            _params.operationId,
            _params.holdId,
            _params.stablecoin,
            _params.recipient,
            _params.amount,
            _expiry
        );
    }

    /// @inheritdoc IMintIntent
    function revokeApproval(bytes32 _holdId) external onlyRole(PUBLISHER_ROLE) {
        uint256 operationId = _mintIntentRegistry().revokeApproval(_holdId);

        emit ApprovalRevoked(msg.sender, _holdId, operationId);
    }

    /// @inheritdoc IMintIntent
    function revokeOperationId(uint256 _operationId) external onlyRole(PUBLISHER_ROLE) {
        bytes32 holdId = _mintIntentRegistry().revokeOperationId(_operationId);

        if (holdId != bytes32(0)) {
            emit ApprovalRevoked(msg.sender, holdId, _operationId);
        }

        emit OperationIdRevoked(msg.sender, _operationId, holdId);
    }

    // Do we need a version that takes in the operationId instead of the holdId?
    /// @inheritdoc IMintIntent
    function extendApproval(bytes32 _holdId, uint64 _expiry) external onlyRole(PUBLISHER_ROLE) {
        uint256 operationId = _mintIntentRegistry().extendApproval(_holdId, _expiry);

        emit ApprovalExtended(msg.sender, _holdId, operationId, _expiry);
    }

    /// @inheritdoc IMintIntent
    function setMintIntentRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_registry != address(0), InvalidRegistry());

        // Reject a registry this controller is not authorized on, which would otherwise leave
        // every intent operation reverting until the role were granted.
        IMintIntentRegistry newRegistry = IMintIntentRegistry(_registry);
        require(
            IAccessControl(_registry).hasRole(newRegistry.CONTROLLER_ROLE(), address(this)),
            ControllerNotAuthorizedOnRegistry(_registry)
        );

        address oldRegistry = address(_mintIntentRegistry());
        _setMintIntentRegistry(newRegistry);

        emit MintIntentRegistrySet(msg.sender, oldRegistry, _registry);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                View Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintIntent
    function getApproval(bytes32 _holdId) external view returns (Approval memory) {
        return _mintIntentRegistry().getApproval(_holdId);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    function _consumeApproval(ApprovalParams memory _params) internal {
        _mintIntentRegistry().consumeApproval(_params);

        emit ApprovalConsumed(msg.sender, _params.operationId, _params.holdId);
    }

    function _consumeUnusedOperationId(uint256 _operationId) internal {
        _mintIntentRegistry().consumeUnusedOperationId(_operationId);
    }

    /// @dev Persists the shared registry pointer in the implementer's own storage.
    function _setMintIntentRegistry(IMintIntentRegistry _registry) internal virtual;

    /// @dev Returns the shared registry that owns all mint intent state.
    function _mintIntentRegistry() internal view virtual returns (IMintIntentRegistry);

}
