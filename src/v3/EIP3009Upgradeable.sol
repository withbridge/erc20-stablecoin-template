// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    EIP712Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title EIP3009Upgradeable
/// @author Bridge
/// @notice Upgradeable implementation of EIP-3009 (Transfer With Authorization).
/// @dev Allows token holders to authorize transfers via EIP-712 signed messages, enabling
/// gasless transfers and front-running protection through `receiveWithAuthorization`.
/// Authorization state is tracked per-(authorizer, nonce) using EIP-7201 namespaced storage.
abstract contract EIP3009Upgradeable is Initializable, ERC20Upgradeable, EIP712Upgradeable {

    /// @custom:storage-location eip7201:bridge.EIP3009
    struct EIP3009Storage {
        mapping(address authorizer => mapping(bytes32 nonce => bool used)) _authorizationStates;
    }

    // keccak256(abi.encode(uint256(keccak256("bridge.EIP3009")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EIP3009_STORAGE_LOCATION =
        0xb4496dc7e5db09e7db11531e41d0b3b6d3dbe25b7e589cf51f1c760a82e3af00;

    /// @notice EIP-712 typehash for `transferWithAuthorization`.
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @notice EIP-712 typehash for `receiveWithAuthorization`.
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @notice EIP-712 typehash for `cancelAuthorization`.
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /**
     * @notice Emitted when an authorization is consumed by a transfer.
     * @param authorizer The address whose signature was consumed.
     * @param nonce The unique nonce of the authorization.
     */
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    /**
     * @notice Emitted when an authorization is canceled before being used.
     * @param authorizer The address whose authorization was canceled.
     * @param nonce The unique nonce of the canceled authorization.
     */
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /// @notice Thrown when an authorization has already been used or canceled.
    error EIP3009AuthorizationAlreadyUsed(address authorizer, bytes32 nonce);

    /// @notice Thrown when an authorization is presented before it becomes valid.
    error EIP3009AuthorizationNotYetValid(uint256 validAfter);

    /// @notice Thrown when an authorization has expired.
    error EIP3009AuthorizationExpired(uint256 validBefore);

    /// @notice Thrown when the recovered signer does not match the expected authorizer.
    error EIP3009InvalidSignature();

    /// @notice Thrown when `receiveWithAuthorization` is invoked by an account other than `to`.
    error EIP3009InvalidCaller(address expected, address actual);

    function _getEIP3009Storage() private pure returns (EIP3009Storage storage $) {
        assembly {
            $.slot := EIP3009_STORAGE_LOCATION
        }
    }

    /**
     * @notice Returns whether an authorization has been used or canceled.
     * @param authorizer The address that signed the authorization.
     * @param nonce The unique nonce associated with the authorization.
     * @return `true` if the authorization is no longer usable, `false` otherwise.
     */
    function authorizationState(address authorizer, bytes32 nonce) public view returns (bool) {
        return _getEIP3009Storage()._authorizationStates[authorizer][nonce];
    }

    /**
     * @notice Executes a transfer using a signed authorization from `from`.
     *
     * Emits a {Transfer} event and an {AuthorizationUsed} event.
     *
     * Requirements:
     * - The current block timestamp must be strictly greater than `validAfter`.
     * - The current block timestamp must be strictly less than `validBefore`.
     * - The `(from, nonce)` pair must not have been used or canceled.
     * - `(v, r, s)` must be a valid EIP-712 signature by `from` over the
     *   `TransferWithAuthorization` struct.
     * - All transfer-side constraints from `_update` apply (paused state, blocklist, etc.).
     *
     * @param from The token owner authorizing the transfer.
     * @param to The recipient of the tokens.
     * @param value The amount of tokens to transfer.
     * @param validAfter Unix timestamp after which the authorization becomes valid.
     * @param validBefore Unix timestamp before which the authorization is valid.
     * @param nonce A unique 32-byte nonce chosen by `from`.
     * @param v Signature recovery byte.
     * @param r Signature r value.
     * @param s Signature s value.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _verifyTimingAndAuthorization(from, nonce, validAfter, validBefore);
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        _verifySignature(from, structHash, v, r, s);
        _markAuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    /**
     * @notice Executes a transfer using a signed authorization from `from`, where the caller
     * must be `to`. This protects against front-running by guaranteeing only the intended
     * recipient can submit the transaction.
     *
     * Emits a {Transfer} event and an {AuthorizationUsed} event.
     *
     * Requirements:
     * - `msg.sender` must equal `to`.
     * - The current block timestamp must be strictly greater than `validAfter`.
     * - The current block timestamp must be strictly less than `validBefore`.
     * - The `(from, nonce)` pair must not have been used or canceled.
     * - `(v, r, s)` must be a valid EIP-712 signature by `from` over the
     *   `ReceiveWithAuthorization` struct.
     * - All transfer-side constraints from `_update` apply (paused state, blocklist, etc.).
     *
     * @param from The token owner authorizing the transfer.
     * @param to The recipient of the tokens; must be the caller.
     * @param value The amount of tokens to transfer.
     * @param validAfter Unix timestamp after which the authorization becomes valid.
     * @param validBefore Unix timestamp before which the authorization is valid.
     * @param nonce A unique 32-byte nonce chosen by `from`.
     * @param v Signature recovery byte.
     * @param r Signature r value.
     * @param s Signature s value.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(msg.sender == to, EIP3009InvalidCaller(to, msg.sender));
        _verifyTimingAndAuthorization(from, nonce, validAfter, validBefore);
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
            )
        );
        _verifySignature(from, structHash, v, r, s);
        _markAuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    /**
     * @notice Cancels an authorization so it can never be used.
     *
     * Emits an {AuthorizationCanceled} event.
     *
     * Requirements:
     * - The `(authorizer, nonce)` pair must not have already been used or canceled.
     * - `(v, r, s)` must be a valid EIP-712 signature by `authorizer` over the
     *   `CancelAuthorization` struct.
     *
     * @param authorizer The address that signed the authorization being canceled.
     * @param nonce The unique nonce of the authorization to cancel.
     * @param v Signature recovery byte.
     * @param r Signature r value.
     * @param s Signature s value.
     */
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(
            !_getEIP3009Storage()._authorizationStates[authorizer][nonce],
            EIP3009AuthorizationAlreadyUsed(authorizer, nonce)
        );
        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        _verifySignature(authorizer, structHash, v, r, s);
        _getEIP3009Storage()._authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _verifyTimingAndAuthorization(
        address authorizer,
        bytes32 nonce,
        uint256 validAfter,
        uint256 validBefore
    ) private view {
        require(block.timestamp > validAfter, EIP3009AuthorizationNotYetValid(validAfter));
        require(block.timestamp < validBefore, EIP3009AuthorizationExpired(validBefore));
        require(
            !_getEIP3009Storage()._authorizationStates[authorizer][nonce],
            EIP3009AuthorizationAlreadyUsed(authorizer, nonce)
        );
    }

    function _verifySignature(address signer, bytes32 structHash, uint8 v, bytes32 r, bytes32 s)
        private
        view
    {
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, v, r, s);
        require(recovered == signer, EIP3009InvalidSignature());
    }

    function _markAuthorizationUsed(address authorizer, bytes32 nonce) private {
        _getEIP3009Storage()._authorizationStates[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }

}
