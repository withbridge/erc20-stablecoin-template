// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Approval,
    MintIntentStorage,
    MintIntentStorageLib,
    OperationState
} from "./MintIntentStorage.sol";
import { IMintIntent } from "./interfaces/IMintIntent.sol";
import { IMintIntentRegistry } from "./interfaces/IMintIntentRegistry.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title MintIntentRegistry
/// @author Bridge
/// @notice Shared registry that owns mint intent state for every controller deployment.
/// @dev Operation IDs and hold IDs are only single-use within the storage that tracks them. When
/// each controller keeps its own intent mappings, the same source operation can be published and
/// consumed once per controller. Pointing every controller at one registry instance makes those
/// identifiers single-use across all of them.
/// @dev Controllers are granted {CONTROLLER_ROLE} and are responsible for authorizing their own
/// callers (via their publisher/burner roles) before forwarding here.
contract MintIntentRegistry is
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    IMintIntentRegistry
{

    using MintIntentStorageLib for MintIntentStorage;
    using MintIntentStorageLib for Approval;

    /*//////////////////////////////////////////////////////////////////////////
                                    Role Constants
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Role held by each controller that shares this registry.
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Error Constants
    //////////////////////////////////////////////////////////////////////////*/

    uint256 constant INVALID_HOLD_ID_FLAG = 1;
    uint256 constant INVALID_OPERATION_ID_FLAG = 2;
    uint256 constant INVALID_AMOUNT_FLAG = 4;
    uint256 constant INVALID_RECIPIENT_FLAG = 8;
    uint256 constant INVALID_STABLECOIN_FLAG = 16;
    uint256 constant INVALID_EXPIRY_FLAG = 32;

    /*//////////////////////////////////////////////////////////////////////////
                                    Constructor
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructs the MintIntentRegistry contract
     * @param _disableInitializer Whether to disable the initializer (for proxy pattern)
     */
    constructor(bool _disableInitializer) {
        if (_disableInitializer) {
            _disableInitializers();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the MintIntentRegistry contract
     * @param _admin The address to be granted the admin role
     */
    function initialize(address _admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintIntentRegistry
    function publishApproval(IMintIntent.ApprovalParams calldata _params, uint64 _expiry)
        external
        onlyRole(CONTROLLER_ROLE)
    {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        // Validate input parameters
        require(_params.operationId != 0, InvalidOperationId());
        require(_params.holdId != bytes32(0), InvalidHoldId());
        require(_params.amount > 0, InvalidAmount());
        require(_params.stablecoin != address(0), InvalidStablecoin());
        require(_params.recipient != address(0), InvalidRecipient());
        require(_expiry > block.timestamp, InvalidExpiry());

        // Check that the _holdId and _operationId are not already in use
        require(
            $._operationStates[_params.operationId] == OperationState.UNUSED
                && $._operationHoldId[_params.operationId] == bytes32(0),
            ApprovalExistsForOperationId(_params.operationId)
        );
        require(
            $._holdIdApproval[_params.holdId].stablecoin == address(0),
            ApprovalExistsForHoldId(_params.holdId)
        );

        // Store operationId for the holdId and the intent for the holdId
        $._operationStates[_params.operationId] = OperationState.RESERVED;
        $._operationHoldId[_params.operationId] = _params.holdId;
        $._holdIdApproval[_params.holdId] = Approval({
            amount: _params.amount,
            recipient: _params.recipient,
            stablecoin: _params.stablecoin,
            expiry: _expiry,
            flags: MintIntentStorageLib.DEFAULT_FLAGS,
            operationId: _params.operationId,
            controller: msg.sender
        });
    }

    /// @inheritdoc IMintIntentRegistry
    function revokeApproval(bytes32 _holdId)
        external
        onlyRole(CONTROLLER_ROLE)
        returns (uint256 operationId)
    {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Approval storage approval = $._holdIdApproval[_holdId];

        // Check that the approval exists and has not been consumed or revoked
        require(approval.stablecoin != address(0), ApprovalNotExistsForHoldId(_holdId));
        _requireApprovalController(approval, _holdId);
        require(approval.isValid(), InvalidApproval(_holdId, approval.flags));

        // Revoke the approval
        operationId = approval.operationId;
        $._operationStates[operationId] = OperationState.REVOKED;
        approval.setRevoked();
    }

    /// @inheritdoc IMintIntentRegistry
    function revokeOperationId(uint256 _operationId)
        external
        onlyRole(CONTROLLER_ROLE)
        returns (bytes32 holdId)
    {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        require(_operationId != 0, InvalidOperationId());

        OperationState state = $._operationStates[_operationId];
        require(
            state == OperationState.UNUSED || state == OperationState.RESERVED, InvalidOperationId()
        );

        holdId = $._operationHoldId[_operationId];
        if (holdId != bytes32(0)) {
            Approval storage approval = $._holdIdApproval[holdId];
            require(approval.stablecoin != address(0), ApprovalNotExistsForHoldId(holdId));
            // Revoking the operation ID would revoke the approval with it, so the same ownership
            // rule as revokeApproval applies.
            _requireApprovalController(approval, holdId);
            require(approval.isValid(), InvalidApproval(holdId, approval.flags));
            approval.setRevoked();
        }

        $._operationStates[_operationId] = OperationState.REVOKED;
    }

    /// @inheritdoc IMintIntentRegistry
    function extendApproval(bytes32 _holdId, uint64 _newExpiry)
        external
        onlyRole(CONTROLLER_ROLE)
        returns (uint256 operationId)
    {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        Approval storage approval = $._holdIdApproval[_holdId];

        // Check that the approval exists and has not been consumed or revoked
        require(approval.stablecoin != address(0), ApprovalNotExistsForHoldId(_holdId));
        _requireApprovalController(approval, _holdId);
        require(approval.isValid(), InvalidApproval(_holdId, approval.flags));

        uint64 expiry = approval.expiry;
        require(_newExpiry > expiry, ApprovalExpiryNotExtended(_holdId, _newExpiry, expiry));

        // Extend the approval
        approval.expiry = _newExpiry;

        operationId = approval.operationId;
    }

    /// @inheritdoc IMintIntentRegistry
    function consumeApproval(IMintIntent.ApprovalParams calldata _params)
        external
        onlyRole(CONTROLLER_ROLE)
    {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        bytes32 holdId = $._operationHoldId[_params.operationId];
        Approval storage approval = $._holdIdApproval[_params.holdId];
        OperationState operationState = $._operationStates[_params.operationId];

        // Only enforceable once the approval exists. A hold ID with no approval has no controller,
        // and still surfaces as InvalidApprovalParams below rather than as an ownership failure.
        if (approval.stablecoin != address(0)) {
            _requireApprovalController(approval, _params.holdId);
        }

        uint256 errors = 0;

        if (_params.holdId == bytes32(0)) {
            errors |= INVALID_HOLD_ID_FLAG;
        }

        if (
            _params.operationId == 0 || _params.holdId != holdId
                || _params.operationId != approval.operationId
                || operationState != OperationState.RESERVED
        ) {
            errors |= INVALID_OPERATION_ID_FLAG;
        }

        if (_params.amount != approval.amount) {
            errors |= INVALID_AMOUNT_FLAG;
        }

        if (_params.recipient != approval.recipient) {
            errors |= INVALID_RECIPIENT_FLAG;
        }

        if (_params.stablecoin != approval.stablecoin) {
            errors |= INVALID_STABLECOIN_FLAG;
        }

        if (approval.expiry <= block.timestamp) {
            errors |= INVALID_EXPIRY_FLAG;
        }
        require(approval.isValid(), InvalidApproval(_params.holdId, approval.flags));

        if (errors != 0) {
            revert InvalidApprovalParams(
                errors & INVALID_HOLD_ID_FLAG != 0,
                errors & INVALID_OPERATION_ID_FLAG != 0,
                errors & INVALID_AMOUNT_FLAG != 0,
                errors & INVALID_RECIPIENT_FLAG != 0,
                errors & INVALID_STABLECOIN_FLAG != 0,
                errors & INVALID_EXPIRY_FLAG != 0
            );
        }

        // Consume the approval
        $._operationStates[_params.operationId] = OperationState.CONSUMED;
        approval.setConsumed();
    }

    /// @inheritdoc IMintIntentRegistry
    function consumeUnusedOperationId(uint256 _operationId) external onlyRole(CONTROLLER_ROLE) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();

        require(_operationId != 0, InvalidOperationId());
        require(
            $._operationStates[_operationId] == OperationState.UNUSED
                && $._operationHoldId[_operationId] == bytes32(0),
            InvalidOperationId()
        );

        $._operationStates[_operationId] = OperationState.CONSUMED;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Requires that the caller is the controller that published the approval.
     * @dev Operation and hold IDs are unique registry-wide so that a source operation is processed
     * once across all controller deployments. Authority over an individual approval is a separate
     * concern and is NOT shared: only the publishing controller may consume, revoke, or extend it.
     * @param _approval The approval being acted on.
     * @param _holdId The hold ID of the approval, for the revert reason.
     */
    function _requireApprovalController(Approval storage _approval, bytes32 _holdId) internal view {
        address controller = _approval.controller;
        require(controller == msg.sender, NotApprovalController(_holdId, controller, msg.sender));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                View Functions
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintIntentRegistry
    function getApproval(bytes32 _holdId) external view returns (Approval memory) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        return $._holdIdApproval[_holdId];
    }

    /// @inheritdoc IMintIntentRegistry
    function getOperationHoldId(uint256 _operationId) external view returns (bytes32 holdId) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        return $._operationHoldId[_operationId];
    }

    /// @inheritdoc IMintIntentRegistry
    function getOperationState(uint256 _operationId) external view returns (OperationState state) {
        MintIntentStorage storage $ = MintIntentStorageLib.getStorage();
        return $._operationStates[_operationId];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Upgrade Logic
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by admin role, required by UUPS pattern
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    { }

}
