// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Mintable } from "../utils/IERC20Mintable.sol";
import { IWrappedERC20 } from "../utils/IWrappedERC20.sol";

import { ITokenAuthority } from "./ITokenAuthority.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import { ITokenHandler } from "./tokenHandler/ITokenHandler.sol";

import { IdempotencyKeys } from "../idempotency/IdempotencyKeys.sol";
import { IIdempotencyKeyRegistry } from "../idempotency/interfaces/IIdempotencyKeyRegistry.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Version } from "../Version.sol";

/// @title TokenAuthority
/// @author Bridge
/// @notice Central authority contract for managing stablecoin minting, burning, and wrapping
/// @dev Coordinates token operations through pluggable token handlers and enforces rate limits
contract TokenAuthority is
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    IdempotencyKeys,
    ITokenAuthority,
    Version
{

    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWrappedERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                Immutable Variables
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The address of the reserve ledger token
    address public immutable RESERVE_LEDGER_TOKEN;

    /// @notice The absolute maximum amount of tokens that can be minted
    uint256 public immutable ABSOLUTE_MAX = 1_000_000_000 * 1e6;

    /*//////////////////////////////////////////////////////////////////////////
                                Constants
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UNWRAPPER_ROLE = keccak256("UNWRAPPER_ROLE");
    bytes32 public constant BRIDGE_ECOSYSTEM_CONTRACT_ROLE =
        keccak256("BRIDGE_ECOSYSTEM_CONTRACT_ROLE");
    bytes32 public constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");
    bytes32 public constant STABLECOIN_PAUSER_ROLE = keccak256("STABLECOIN_PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Maps each stablecoin contract address and user address to the minter allowance for
    /// that user on the stablecoin.
    /// @dev minterAllowances[stablecoinContract][user] = minterAllowance (remaining tokens that can
    /// be minted by the user)
    mapping(address stablecoinContract => mapping(address user => uint256 minterAllowance))
        minterAllowances;

    /// @notice Maps each stablecoin contract address to its per-transaction mint limit.
    mapping(address stablecoinContract => uint256 mintTxnLimit) mintTxnLimits;

    /// @notice Maps each stablecoin contract address to its respective token handler
    mapping(address stablecoinContract => address tokenHandler) tokenHandlers;

    /// @notice Whether idempotency keys are optional or required for `mint`
    IdempotencyKeysVersion public idempotencyKeysVersion;

    /// @notice Maps a stablecoin to whether or not minting/burning/wrapping/unwrapping is paused
    mapping(address stablecoinContract => bool isPaused) public stablecoinIsPaused;

    /// @notice The shared registry that owns all idempotency-key state
    /// @dev Shared with every other controller deployment so that keys are single-use across all
    /// of them. Declared here rather than in {IdempotencyKeys} so the slot is appended after this
    /// contract's existing variables instead of shifting them.
    IIdempotencyKeyRegistry public idempotencyKeyRegistry;

    /*//////////////////////////////////////////////////////////////////////////
                                    Constructor
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructs the TokenAuthority contract
     * @param _reserveLedgerToken The address of the reserve ledger token
     * @param _disableInitializer Whether to disable the initializer (for proxy pattern)
     */
    constructor(address _reserveLedgerToken, bool _disableInitializer) {
        RESERVE_LEDGER_TOKEN = _reserveLedgerToken;

        if (_disableInitializer) {
            _disableInitializers();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Initializer
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the TokenAuthority contract
     * @param _admin The address to be granted the admin role
     * @param _registry The shared idempotency-key registry. This TokenAuthority must be granted
     * CONTROLLER_ROLE on the registry before keys can be used.
     */
    function initialize(address _admin, address _registry) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __IdempotencyKeys_init(_registry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                        Mint
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints stablecoins to a recipient address
     * @param stablecoinContract The address of the stablecoin contract to mint from
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     * @dev Checks transaction limit and decrements minter allowance before minting.
     *      Only allowed when {idempotencyKeysVersion} is {IdempotencyKeysVersion-Optional}.
     */
    function mint(address stablecoinContract, address to, uint256 amount) public {
        require(
            idempotencyKeysVersion == IdempotencyKeysVersion.Optional, IdempotencyKeysRequired()
        );
        _mintWithLimits(stablecoinContract, to, amount);
    }

    /**
     * @notice Mints stablecoins to a recipient address
     * @param stablecoinContract The address of the stablecoin contract to mint from
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     * @param keys Idempotency keys to mark used. Empty skips the registry when Optional.
     * @dev Checks transaction limit and decrements minter allowance before minting.
     *      Non-empty `keys` are marked used in the shared registry before those checks; a later
     *      revert rolls the key state back. Empty `keys` is allowed only when
     *      {idempotencyKeysVersion} is {IdempotencyKeysVersion-Optional}.
     */
    function mint(address stablecoinContract, address to, uint256 amount, bytes32[] calldata keys)
        public
    {
        if (keys.length == 0) {
            mint(stablecoinContract, to, amount);
            return;
        }

        _useKeys(false, keys);
        _mintWithLimits(stablecoinContract, to, amount);
    }

    /**
     * @notice Mints stablecoins to a specified address for bridge ecosystem contracts.
     * @dev Callable only by contracts with the BRIDGE_ECOSYSTEM_CONTRACT_ROLE.
     *      Does not enforce minter allowance or per-transaction mint limits.
     * @param stablecoinContract The address of the stablecoin contract to mint from.
     * @param to The recipient address that will receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mintBridgeEcosystem(address stablecoinContract, address to, uint256 amount)
        public
        onlyRole(BRIDGE_ECOSYSTEM_CONTRACT_ROLE)
    {
        _mint(stablecoinContract, to, amount);
    }

    /**
     * @notice Burns tokens from the sender's balance for a given stablecoin contract
     * @dev Transfers the caller's tokens to this contract, approves the registered handler,
     * and delegates burning to it. The handler determines how the token and any backing
     * reserves are burned.
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     */
    function burn(address stablecoinContract, uint256 amount) public onlyRole(BURNER_ROLE) {
        _burn(stablecoinContract, amount);
    }

    /**
     * @notice Burns tokens, marking the given idempotency keys used.
     * @dev Keys can only be consumed once across mint and burn operations, registry-wide.
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     * @param keys The idempotency keys to mark used
     */
    function burn(address stablecoinContract, uint256 amount, bytes32[] calldata keys)
        public
        onlyRole(BURNER_ROLE)
    {
        _useKeys(idempotencyKeysVersion == IdempotencyKeysVersion.Optional, keys);
        _burn(stablecoinContract, amount);
    }

    /**
     * @notice Unwraps a given amount of a stablecoin for the caller
     * @dev Transfers the caller's stablecoins to this contract and approves the registered
     * handler to unwrap them. The handler sends reserve tokens directly to the caller
     * and determines whether the token supports unwrapping.
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of stablecoins to unwrap
     *
     * Emits a {Unwrap} event for tracking unwrapping operations.
     */
    function unwrap(address stablecoinContract, uint256 amount) public onlyRole(UNWRAPPER_ROLE) {
        _requireStablecoinNotPaused(stablecoinContract);
        address tokenHandler = tokenHandlers[stablecoinContract];
        require(tokenHandler != address(0), TokenHandlerNotSet());
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(stablecoinContract).approve(tokenHandler, amount);
        ITokenHandler(tokenHandler).unwrap(stablecoinContract, msg.sender, amount);

        emit Unwrap(msg.sender, stablecoinContract, amount);
    }

    /**
     * @notice Wraps reserve ledger tokens into the specified stablecoin and sends them to a
     * recipient.
     * @dev Transfers the specified amount of reserve ledger tokens from the caller to this
     * contract, approves the registered handler to spend these tokens, and calls the handler
     * to wrap them for the recipient.
     * @dev Emits a {Wrap} event upon successful wrapping.
     * @param stablecoinContract The address of the target stablecoin contract.
     * @param to The address to receive the wrapped tokens.
     * @param amount The amount of reserve tokens to wrap.
     */
    function wrap(address stablecoinContract, address to, uint256 amount) public {
        _requireStablecoinNotPaused(stablecoinContract);
        require(to != address(0), ZeroAddress());
        require(amount > 0, AmountCannotBeZero());

        address tokenHandler = tokenHandlers[stablecoinContract];
        require(tokenHandler != address(0), TokenHandlerNotSet());

        IERC20Mintable(RESERVE_LEDGER_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).approve(tokenHandler, amount);
        ITokenHandler(tokenHandler).wrap(stablecoinContract, to, amount);

        emit Wrap(msg.sender, stablecoinContract, to, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Setters
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the per-transaction mint limit for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param mintTxnLimit The per-transaction mint limit to set
     */
    function setTxnMintLimit(address stablecoinContract, uint256 mintTxnLimit)
        public
        onlyRole(MINT_RATE_LIMIT_SETTER_ROLE)
    {
        require(mintTxnLimit <= ABSOLUTE_MAX, AmountExceedsAbsoluteMax());
        mintTxnLimits[stablecoinContract] = mintTxnLimit;

        emit TxnMintLimitSet(msg.sender, stablecoinContract, mintTxnLimit);
    }

    /**
     * @notice Sets the mint allowance for a specific minter on a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param minter The address of the minter
     * @param minterAllowance The allowance amount to set for the minter
     */
    function setMinterAllowance(address stablecoinContract, address minter, uint256 minterAllowance)
        public
        onlyRole(MINT_RATE_LIMIT_SETTER_ROLE)
    {
        require(minterAllowance <= ABSOLUTE_MAX, AmountExceedsAbsoluteMax());
        minterAllowances[stablecoinContract][minter] = minterAllowance;

        emit MinterAllowanceSet(msg.sender, stablecoinContract, minter, minterAllowance);
    }

    /**
     * @notice Sets the paused state for a stablecoin contract
     * @dev When paused, minting/burning/wrapping/unwrapping is disabled for the stablecoin.
     *      No-ops if the stablecoin is already in the requested state.
     * @param stablecoinContract The address of the stablecoin contract
     * @param pause True to pause the stablecoin, false to unpause
     */
    function setStablecoinPaused(address stablecoinContract, bool pause)
        external
        onlyRole(STABLECOIN_PAUSER_ROLE)
    {
        bool isStablecoinPaused = stablecoinIsPaused[stablecoinContract];

        if (isStablecoinPaused == pause) {
            return;
        }

        stablecoinIsPaused[stablecoinContract] = pause;

        emit StablecoinPauseSet(msg.sender, stablecoinContract, pause);
    }

    /**
     * @notice Sets the token authority handler for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param tokenHandler The address of the token handler
     */
    function setTokenHandler(address stablecoinContract, address tokenHandler)
        public
        onlyRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE)
    {
        _requireStablecoinPaused(stablecoinContract);
        require(tokenHandlers[stablecoinContract] != address(0), StablecoinNotRegistered());
        require(stablecoinContract != address(0), ZeroAddress());
        require(tokenHandler != address(0), ZeroAddress());
        require(
            ERC165Checker.supportsInterface(tokenHandler, type(ITokenHandler).interfaceId),
            InvalidTokenHandler()
        );

        tokenHandlers[stablecoinContract] = tokenHandler;

        emit TokenHandlerSet(msg.sender, stablecoinContract, tokenHandler);
    }

    /**
     * @notice Registers a stablecoin contract with the TokenAuthority
     * @dev Only callable by TOKEN_AUTHORITY_HANDLER_SETTER_ROLE
     * @param stablecoinContract The address of the stablecoin contract
     * @param tokenHandler The address of the token handler
     * @param mintTxnLimit The mint transaction limit
     */
    function registerStablecoin(
        address stablecoinContract,
        address tokenHandler,
        uint256 mintTxnLimit
    ) public onlyRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE) {
        uint256 reserveLedgerPrecision = IERC20Metadata(RESERVE_LEDGER_TOKEN).decimals();
        uint256 stablecoinPrecision = IERC20Metadata(stablecoinContract).decimals();
        require(
            reserveLedgerPrecision == stablecoinPrecision,
            PrecisionMismatch(reserveLedgerPrecision, stablecoinPrecision)
        );

        require(tokenHandlers[stablecoinContract] == address(0), StablecoinAlreadyRegistered());
        require(stablecoinContract != address(0), ZeroAddress());
        require(tokenHandler != address(0), ZeroAddress());
        require(mintTxnLimit <= ABSOLUTE_MAX, AmountExceedsAbsoluteMax());
        require(
            ERC165Checker.supportsInterface(tokenHandler, type(ITokenHandler).interfaceId),
            InvalidTokenHandler()
        );

        tokenHandlers[stablecoinContract] = tokenHandler;
        mintTxnLimits[stablecoinContract] = mintTxnLimit;

        emit StablecoinRegistered(msg.sender, stablecoinContract, tokenHandler, mintTxnLimit);
    }

    /**
     * @notice Unregisters a stablecoin contract from the TokenAuthority
     * @dev Only callable by TOKEN_AUTHORITY_HANDLER_SETTER_ROLE
     * @dev It it on the onus of the admin to ensure that all minter allowances are zeroed out
     * @param stablecoinContract The address of the stablecoin contract
     */
    function unregisterStablecoin(address stablecoinContract)
        public
        onlyRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE)
    {
        require(stablecoinContract != address(0), ZeroAddress());
        require(tokenHandlers[stablecoinContract] != address(0), StablecoinNotRegistered());
        delete tokenHandlers[stablecoinContract];
        delete mintTxnLimits[stablecoinContract];

        emit StablecoinUnregistered(msg.sender, stablecoinContract);
    }

    /**
     * @notice Sets whether `mint` requires idempotency keys
     * @dev When `Required`, three-argument `mint` and `mint` with empty `keys` revert with
     *      {IdempotencyKeysRequired}. `mintBridgeEcosystem` is unaffected.
     * @param _idempotencyKeysVersion The new idempotency keys version
     */
    function setIdempotencyKeysVersion(IdempotencyKeysVersion _idempotencyKeysVersion)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        idempotencyKeysVersion = _idempotencyKeysVersion;

        emit IdempotencyKeysVersionSet(msg.sender, idempotencyKeysVersion);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Getters
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the mint allowance for a specific minter on a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param minter The address of the minter
     * @return minterAllowance The remaining allowance for the minter
     */
    function getMinterAllowance(address stablecoinContract, address minter)
        public
        view
        returns (uint256 minterAllowance)
    {
        return minterAllowances[stablecoinContract][minter];
    }

    /**
     * @notice Gets the per-transaction mint limit for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return mintTxnLimit The per-transaction mint limit
     */
    function getStablecoinTxnMintLimit(address stablecoinContract)
        public
        view
        returns (uint256 mintTxnLimit)
    {
        return mintTxnLimits[stablecoinContract];
    }

    /**
     * @notice Gets the token handler for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return tokenHandler The address of the token handler
     */
    function getTokenHandler(address stablecoinContract)
        public
        view
        returns (address tokenHandler)
    {
        return tokenHandlers[stablecoinContract];
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

    /*//////////////////////////////////////////////////////////////////////////
                                Internal Functions
    //////////////////////////////////////////////////////////////////////////*/

    function _mintWithLimits(address stablecoinContract, address to, uint256 amount) internal {
        require(amount > 0, AmountCannotBeZero());

        uint256 mintTxnLimit = mintTxnLimits[stablecoinContract];
        uint256 minterAllowance = minterAllowances[stablecoinContract][msg.sender];
        require(minterAllowance >= amount, MinterAllowanceExceeded());
        require(mintTxnLimit >= amount, MintTxnLimitExceeded());

        minterAllowances[stablecoinContract][msg.sender] -= amount;

        _mint(stablecoinContract, to, amount);
    }

    function _mint(address stablecoinContract, address to, uint256 amount) internal {
        require(amount <= ABSOLUTE_MAX, AmountExceedsAbsoluteMax());
        _requireStablecoinNotPaused(stablecoinContract);
        address tokenHandler = tokenHandlers[stablecoinContract];

        require(tokenHandler != address(0), TokenHandlerNotSet());

        ITokenHandler(tokenHandler).mint(stablecoinContract, to, amount);

        emit Mint(msg.sender, stablecoinContract, to, amount);
    }

    function _burn(address stablecoinContract, uint256 amount) internal {
        _requireStablecoinNotPaused(stablecoinContract);
        address tokenHandler = tokenHandlers[stablecoinContract];
        require(tokenHandler != address(0), TokenHandlerNotSet());
        IERC20Mintable(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).approve(tokenHandler, amount);
        ITokenHandler(tokenHandler).burn(stablecoinContract, amount);

        emit Burn(msg.sender, stablecoinContract, amount);
    }

    function _requireStablecoinNotPaused(address stablecoinContract) internal view {
        require(!stablecoinIsPaused[stablecoinContract], StablecoinPaused());
    }

    function _requireStablecoinPaused(address stablecoinContract) internal view {
        require(stablecoinIsPaused[stablecoinContract], StablecoinNotPaused());
    }

    /// @inheritdoc IdempotencyKeys
    function _setIdempotencyKeyRegistry(IIdempotencyKeyRegistry _registry) internal override {
        idempotencyKeyRegistry = _registry;
    }

    /// @inheritdoc IdempotencyKeys
    function _idempotencyKeyRegistry() internal view override returns (IIdempotencyKeyRegistry) {
        return idempotencyKeyRegistry;
    }

}
