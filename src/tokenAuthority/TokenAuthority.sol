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

import { IMintIntent, MintIntent } from "../mintIntent/MintIntent.sol";
import { IMintIntentRegistry } from "../mintIntent/interfaces/IMintIntentRegistry.sol";
import { Seize } from "../seize/Seize.sol";
import {
    IBurnAndRemintStablecoin,
    IForceTransferStablecoin,
    IReserveWrappedStablecoin,
    ISeizableStablecoin
} from "../seize/interfaces/ISeizableStablecoin.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title TokenAuthority
/// @author Bridge
/// @notice Central authority contract for managing stablecoin minting, burning, and wrapping
/// @dev Coordinates token operations through pluggable token handlers and enforces rate limits
contract TokenAuthority is
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable,
    MintIntent,
    Seize,
    ITokenAuthority
{

    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Mintable;
    using SafeERC20 for IWrappedERC20;
    using SafeERC20 for IBurnAndRemintStablecoin;

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

    /// @dev Role IDs a stablecoin reports when it exposes each seize mode's functions. Read from
    /// the stablecoin in {setSeizeConfig}; these are the stablecoins' roles, not this contract's.
    bytes32 private constant STABLECOIN_FORCE_TRANSFER_ROLE = keccak256("FORCE_TRANSFER_ROLE");
    bytes32 private constant STABLECOIN_UNBLOCKER_ROLE = keccak256("UNBLOCKER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                    Structs
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Reserve ledger balances and supply captured around a seize, compared after it.
    struct ReserveSnapshot {
        uint256 stablecoinReserveBalance;
        uint256 tokenAuthorityReserveBalance;
        uint256 reserveTotalSupply;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Maps each stablecoin contract address and user address to the minter allowance for
    /// that user on the stablecoin.
    /// @dev minterAllowances[stablecoinContract][user] = minterAllowance (remaining tokens that can
    /// be minted by the user)
    mapping(address stablecoinContract => mapping(address user => uint256 minterAllowance))
        minterAllowances;

    /// @notice Maps each stablecoin contract address to its respective mint rate limits.
    /// @dev mintRateLimits[stablecoinContract] = MintRateLimit struct (global and per-transaction
    /// mint limits for the stablecoin)
    mapping(address stablecoinContract => uint256 mintTxnLimit) mintTxnLimits;

    /// @notice Maps each stablecoin contract address to its respective token handler
    mapping(address stablecoinContract => address tokenHandler) tokenHandlers;

    /// @notice The current mint intent version
    MintIntentVersion public mintIntentVersion;

    /// @notice Maps a stablecoin to whether or not minting/burning/wrapping/unwrapping is paused
    mapping(address stablecoinContract => bool isPaused) public stablecoinIsPaused;

    /// @notice The shared registry that owns all mint intent state
    /// @dev Shared with every other controller deployment so that operation IDs and hold IDs are
    /// single-use across all of them. Declared here rather than in {MintIntent} so the slot is
    /// appended after this contract's existing variables instead of shifting them.
    IMintIntentRegistry public mintIntentRegistry;

    /// @notice Maps each stablecoin contract address to its seize settings
    /// @dev Appended after {mintIntentRegistry} so the upgrade keeps every existing slot.
    mapping(address stablecoinContract => SeizeConfig seizeConfig) seizeConfigs;

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
     * @param _publisher The address to be granted the publisher role
     * @param _registry The shared mint intent registry. This TokenAuthority must be granted
     * CONTROLLER_ROLE on the registry before mint intents can be used.
     */
    function initialize(address _admin, address _publisher, address _registry) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __MintIntent_init(_publisher, _registry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                        Mint
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints stablecoins to a recipient address
     * @dev Checks and decrements transaction limit, and minter allowance before
     * minting
     * @param stablecoinContract The address of the stablecoin contract to mint from
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address stablecoinContract, address to, uint256 amount) public {
        require(mintIntentVersion == MintIntentVersion.Optional, MintIntentRequired());
        require(amount > 0, AmountCannotBeZero());

        uint256 mintTxnLimit = mintTxnLimits[stablecoinContract];
        uint256 minterAllowance = minterAllowances[stablecoinContract][msg.sender];
        require(minterAllowance >= amount, MinterAllowanceExceeded());
        require(mintTxnLimit >= amount, MintTxnLimitExceeded());

        minterAllowances[stablecoinContract][msg.sender] -= amount;

        _mint(stablecoinContract, to, amount);
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
     * @notice Mints stablecoins to a recipient address with an approval
     * @dev Checks and decrements transaction limit, and minter allowance before
     * minting
     * @param _params The parameters for the mint operation
     * @custom:param _params.stablecoinContract The address of the stablecoin contract to mint from
     * @custom:param _params.to The address to receive the minted tokens
     * @custom:param _params.amount The amount of tokens to mint
     * @custom:param _params.operationId The operation ID
     * @custom:param _params.holdId The hold ID
     */
    function mintWithApproval(IMintIntent.ApprovalParams calldata _params) public {
        require(_params.amount > 0, AmountCannotBeZero());

        uint256 mintTxnLimit = mintTxnLimits[_params.stablecoin];
        uint256 minterAllowance = minterAllowances[_params.stablecoin][msg.sender];
        require(minterAllowance >= _params.amount, MinterAllowanceExceeded());
        require(mintTxnLimit >= _params.amount, MintTxnLimitExceeded());

        minterAllowances[_params.stablecoin][msg.sender] -= _params.amount;

        _consumeApproval(_params);

        _mint(_params.stablecoin, _params.recipient, _params.amount);
    }

    /**
     * @notice Burns tokens from the sender's balance for a given stablecoin contract
     * @dev Allows the caller to burn their own tokens. If the stablecoin contract is the reserve
     * ledger token, it calls burn directly; otherwise, it calls unwrap on the ERC20WrapUnwrap
     * interface.
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     */
    function burn(address stablecoinContract, uint256 amount) public onlyRole(BURNER_ROLE) {
        _burn(stablecoinContract, amount);
    }

    /**
     * @notice Burns tokens with a globally unique operation ID.
     * @dev The operation ID can only be consumed once across mint approvals and burn operations.
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     * @param operationId The operation ID to consume for this burn
     */
    function burnWithOperationId(address stablecoinContract, uint256 amount, uint256 operationId)
        public
        onlyRole(BURNER_ROLE)
    {
        _consumeUnusedOperationId(operationId);
        _burn(stablecoinContract, amount);
    }

    /**
     * @notice Unwraps a given amount of a wrapped stablecoin for the caller
     * @dev Reverts if the stablecoin contract provided is the reserve ledger token,
     *      since unwrapping is only applicable to wrapped stablecoins.
     *      Calls unwrap on the wrapped stablecoin, which should send the underlying reserve
     *      tokens to this contract, then transfers those reserve tokens to the caller.
     * @param stablecoinContract The address of the wrapped stablecoin contract
     * @param amount The amount of wrapped tokens to unwrap
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
     * contract, approves the stablecoin contract to spend these tokens, and then wraps the tokens
     * for the recipient.
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
     * @dev Only callable by the admin role
     * @param stablecoinContract The address of the stablecoin contract
     * @param tokenHandler The address of the token handler
     * @param mintTxnLimit The mint transaction limit
     */
    function registerStablecoin(
        address stablecoinContract,
        address tokenHandler,
        uint256 mintTxnLimit
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
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
     * @dev Only callable by the admin role
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
     * @notice Sets or clears the seize settings for a stablecoin contract
     * @dev Does not require the stablecoin to be registered with a token handler: seize never uses
     * a handler, and registration is an issuance concern.
     * @param stablecoinContract The address of the stablecoin contract
     * @param mode How coins are moved; None clears the settings
     * @param seizureWalletRegistry The registry holding the Seizure Wallet list
     * @param seizureWalletListId The Seizure Wallet list ID
     */
    function setSeizeConfig(
        address stablecoinContract,
        SeizeMode mode,
        address seizureWalletRegistry,
        uint64 seizureWalletListId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stablecoinContract != address(0), ZeroAddress());

        if (mode == SeizeMode.None) {
            // Clearing with leftover arguments is ambiguous, so it is refused rather than ignored.
            require(
                seizureWalletRegistry == address(0) && seizureWalletListId == 0,
                InvalidSeizeConfig()
            );
            delete seizeConfigs[stablecoinContract];
        } else {
            _requireValidSeizureWalletList(seizureWalletRegistry, seizureWalletListId);
            require(
                _stablecoinSupportsSeizeMode(stablecoinContract, mode),
                SeizeModeMismatch(stablecoinContract, mode)
            );
            seizeConfigs[stablecoinContract] = SeizeConfig({
                mode: mode,
                seizureWalletRegistry: seizureWalletRegistry,
                seizureWalletListId: seizureWalletListId
            });
        }

        emit SeizeConfigSet(
            msg.sender, stablecoinContract, mode, seizureWalletRegistry, seizureWalletListId
        );
    }

    /**
     * @notice Sets whether mint intents are optional or required
     * @dev When `Required`, plain `mint` reverts with {MintIntentRequired} and callers must use
     *      `mintWithApproval` against a published intent. `mintBridgeEcosystem` is unaffected.
     * @param _mintIntentVersion The new mint intent version
     */
    function setMintIntentVersion(MintIntentVersion _mintIntentVersion)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        mintIntentVersion = _mintIntentVersion;

        emit MintIntentVersionSet(msg.sender, mintIntentVersion);
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

    /**
     * @notice Gets the seize settings for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return seizeConfig The settings; mode is None when the stablecoin cannot be seized
     */
    function getSeizeConfig(address stablecoinContract)
        public
        view
        returns (SeizeConfig memory seizeConfig)
    {
        return seizeConfigs[stablecoinContract];
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

    /// @inheritdoc Seize
    function _seizureWalletList(address stablecoinContract)
        internal
        view
        override
        returns (address registry, uint64 listId)
    {
        SeizeConfig memory seizeConfig = seizeConfigs[stablecoinContract];
        require(seizeConfig.mode != SeizeMode.None, SeizeNotConfigured(stablecoinContract));

        return (seizeConfig.seizureWalletRegistry, seizeConfig.seizureWalletListId);
    }

    /// @inheritdoc Seize
    /// @dev Checked here for both modes even though each coin re-checks it, so the rule holds
    /// regardless of the coin's own implementation.
    function _isHolderBlocked(address stablecoinContract, address holder)
        internal
        view
        override
        returns (bool)
    {
        return ISeizableStablecoin(stablecoinContract).isBlocked(holder);
    }

    /**
     * @inheritdoc Seize
     * @dev Also asserts the move left the reserve ledger untouched. {Seize} checks only the
     * stablecoin's own balances and supply, and only this contract knows the reserve ledger. A
     * coin whose burn releases backing would otherwise pass every stablecoin-level check: a V3
     * coin's `burnFromBlockedAddress` pays its reserve ledger tokens to the caller, so burning and
     * re-minting it leaves the re-minted coins unbacked.
     */
    function _executeSeize(
        address stablecoinContract,
        address from,
        address to,
        uint256 amount,
        uint256 holderBalance
    ) internal override {
        SeizeMode mode = seizeConfigs[stablecoinContract].mode;
        ReserveSnapshot memory reserveBefore = _reserveSnapshot(stablecoinContract);

        if (mode == SeizeMode.ForceTransfer) {
            // The coin bypasses its own pause and freeze for this one move, and its reserve
            // backing never leaves the coin.
            IForceTransferStablecoin(stablecoinContract).forceTransfer(from, to, amount);
        } else {
            // _seizureWalletList already rejected None, so the only mode left is BurnAndRemint.
            assert(mode == SeizeMode.BurnAndRemint);
            _seizeByBurnAndRemint(
                IBurnAndRemintStablecoin(stablecoinContract), from, to, amount, holderBalance
            );
        }

        _requireReserveBackingUnchanged(stablecoinContract, reserveBefore);
    }

    function _reserveSnapshot(address stablecoinContract)
        internal
        view
        returns (ReserveSnapshot memory)
    {
        IERC20 reserveLedger = IERC20(RESERVE_LEDGER_TOKEN);
        return ReserveSnapshot({
            stablecoinReserveBalance: reserveLedger.balanceOf(stablecoinContract),
            tokenAuthorityReserveBalance: reserveLedger.balanceOf(address(this)),
            reserveTotalSupply: reserveLedger.totalSupply()
        });
    }

    function _requireReserveBackingUnchanged(
        address stablecoinContract,
        ReserveSnapshot memory reserveBefore
    ) internal view {
        ReserveSnapshot memory reserveAfter = _reserveSnapshot(stablecoinContract);
        require(
            reserveAfter.stablecoinReserveBalance == reserveBefore.stablecoinReserveBalance,
            SeizeReserveBalanceChanged(
                stablecoinContract,
                reserveBefore.stablecoinReserveBalance,
                reserveAfter.stablecoinReserveBalance
            )
        );
        require(
            reserveAfter.tokenAuthorityReserveBalance == reserveBefore.tokenAuthorityReserveBalance,
            SeizeReserveBalanceChanged(
                address(this),
                reserveBefore.tokenAuthorityReserveBalance,
                reserveAfter.tokenAuthorityReserveBalance
            )
        );
        require(
            reserveAfter.reserveTotalSupply == reserveBefore.reserveTotalSupply,
            SeizeReserveSupplyChanged(
                reserveBefore.reserveTotalSupply, reserveAfter.reserveTotalSupply
            )
        );
    }

    /**
     * @notice Whether the stablecoin exposes the functions `mode` drives
     * @dev Catches a stablecoin configured under the wrong standard when the settings are made,
     * rather than at seize time:
     * - ForceTransfer needs StablecoinTemplateV3's FORCE_TRANSFER_ROLE, which only coins
     *   upgraded with `forceTransfer` report. A V2 coin, the reserve ledger, or a V3 coin that
     *   has not been upgraded is refused.
     * - BurnAndRemint needs StablecoinTemplateV2's UNBLOCKER_ROLE, and the coin must not hold its
     *   own reserve backing (RESERVE_LEDGER_ADDRESS), because burning its balance would release
     *   that backing.
     * This is a configuration-time guard; {_requireReserveBackingUnchanged} is what enforces the
     * backing invariant on every seize.
     */
    function _stablecoinSupportsSeizeMode(address stablecoinContract, SeizeMode mode)
        internal
        view
        returns (bool)
    {
        if (mode == SeizeMode.ForceTransfer) {
            (bool reportsForceTransferRole, bytes32 forceTransferRole) = _staticcallWord(
                stablecoinContract, abi.encodeCall(IForceTransferStablecoin.FORCE_TRANSFER_ROLE, ())
            );
            return reportsForceTransferRole && forceTransferRole == STABLECOIN_FORCE_TRANSFER_ROLE;
        }

        (bool reportsUnblockerRole, bytes32 unblockerRole) = _staticcallWord(
            stablecoinContract, abi.encodeCall(IBurnAndRemintStablecoin.UNBLOCKER_ROLE, ())
        );
        (bool holdsOwnReserve,) = _staticcallWord(
            stablecoinContract, abi.encodeCall(IReserveWrappedStablecoin.RESERVE_LEDGER_ADDRESS, ())
        );
        return
            reportsUnblockerRole && unblockerRole == STABLECOIN_UNBLOCKER_ROLE && !holdsOwnReserve;
    }

    /// @dev Calls a 32-byte view on `target`. A missing function, a revert, or an address without
    /// code reads as unanswered instead of reverting, so absence can be tested.
    function _staticcallWord(address target, bytes memory callData)
        private
        view
        returns (bool answered, bytes32 word)
    {
        (bool success, bytes memory returnData) = target.staticcall(callData);
        if (!success || returnData.length != 32) {
            return (false, bytes32(0));
        }
        return (true, abi.decode(returnData, (bytes32)));
    }

    /**
     * @notice Seizes from a StablecoinTemplateV2 coin, which can only burn a blocked holder's
     * whole balance
     * @dev Burns all of `holderBalance`, mints `amount` to `to`, then returns the unseized
     * remainder by minting it to this contract and transferring it to `from`. A transfer is used
     * instead of a mint to `from` because `from` is not a mint recipient, and only the coin's
     * admin can make it one. `from` is unblocked only for that transfer, and only on the partial
     * path.
     *
     * Direct mints here total exactly `holderBalance`, the amount just burned, so supply is
     * unchanged. Nothing goes through a token handler, so no reserve ledger tokens are minted.
     *
     * The coin must be unpaused for its burn, mint, and transfer, so a paused coin is unpaused
     * for the duration and re-paused before returning.
     */
    function _seizeByBurnAndRemint(
        IBurnAndRemintStablecoin stablecoin,
        address from,
        address to,
        uint256 amount,
        uint256 holderBalance
    ) internal {
        bool wasPaused = stablecoin.paused();
        if (wasPaused) {
            stablecoin.unpause();
        }

        stablecoin.burnFromBlockedAddress(from);
        stablecoin.mint(to, amount);

        uint256 remainder = holderBalance - amount;
        if (remainder > 0) {
            stablecoin.mint(address(this), remainder);
            stablecoin.unblockAddress(from);
            stablecoin.safeTransfer(from, remainder);
            stablecoin.blockAddress(from);
        }

        if (wasPaused) {
            stablecoin.pause();
        }
    }

    /// @inheritdoc MintIntent
    function _setMintIntentRegistry(IMintIntentRegistry _registry) internal override {
        mintIntentRegistry = _registry;
    }

    /// @inheritdoc MintIntent
    function _mintIntentRegistry() internal view override returns (IMintIntentRegistry) {
        return mintIntentRegistry;
    }

}
