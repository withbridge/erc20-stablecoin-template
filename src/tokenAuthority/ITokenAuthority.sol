// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenAuthority
/// @author Bridge
/// @notice Interface for the TokenAuthority contract which manages minting rate limits and
/// allowances for stablecoins
/// @dev This contract enforces three types of limits: global cumulative limits, per-transaction
/// limits, and per-minter allowances
interface ITokenAuthority {

    /*//////////////////////////////////////////////////////////////////////////
                                    Errors
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a mint operation would exceed the global mint limit for a stablecoin
    /// @dev The global limit represents the cumulative amount that can be minted
    error MintGlobalLimitExceeded();

    /// @notice Thrown when a mint operation would exceed the per-transaction mint limit
    /// @dev The transaction limit caps individual mint operations regardless of global limit
    error MintTxnLimitExceeded();

    /// @notice Thrown when a mint operation would exceed the minter's allowance
    /// @dev Each minter has an individual allowance that decrements with each mint
    error MinterAllowanceExceeded();

    /// @notice Thrown when attempting to unwrap the reserve ledger token
    /// @dev Unwrapping is only applicable to wrapped stablecoins
    error CannotUnwrapReserveLedgerToken();

    /// @notice Thrown when attempting to perform an operation with an amount of zero
    /// @dev This prevents operations that would result in zero value transfers or operations
    /// that would have no effect
    error AmountCannotBeZero();

    /// @notice Thrown when a mint operation would exceed the absolute maximum amount
    /// @dev This prevents operations that would result in an amount exceeding the absolute
    /// maximum amount
    error AmountExceedsAbsoluteMax();

    /// @notice Thrown when there is a mismatch in reserve ledger balance.
    error ReserveLedgerBalanceMismatch();

    /// @notice Thrown when the token authority handler is not set
    error TokenHandlerNotSet();

    /// @notice Thrown when the stablecoin is not registered
    error StablecoinNotRegistered();

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when only the per-transaction mint limit is updated for a stablecoin
    /// @param sender The address that set the limit (must have MINT_RATE_LIMIT_SETTER_ROLE)
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param mintTxnLimit The new per-transaction mint limit
    event TxnMintLimitSet(
        address indexed sender, address indexed stablecoinContract, uint256 mintTxnLimit
    );

    /// @notice Emitted when a minter's allowance is set for a stablecoin
    /// @param sender The address that set the allowance (must have MINT_RATE_LIMIT_SETTER_ROLE)
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param minter The address of the minter whose allowance is being set
    /// @param minterAllowance The new allowance for the minter
    event MinterAllowanceSet(
        address indexed sender,
        address indexed stablecoinContract,
        address indexed minter,
        uint256 minterAllowance
    );

    /// @notice Emitted when tokens are minted to a recipient
    /// @param sender The address that initiated the mint operation
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param to The address receiving the minted tokens
    /// @param amount The amount of tokens minted
    event Mint(
        address indexed sender,
        address indexed stablecoinContract,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when tokens are burned
    /// @param sender The address that initiated the burn operation
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param amount The amount of tokens burned
    event Burn(address indexed sender, address indexed stablecoinContract, uint256 amount);

    /// @notice Emitted when tokens are unwrapped
    /// @param sender The address that initiated the unwrap operation
    /// @param stablecoinContract The address of the wrapped stablecoin contract
    /// @param amount The amount of wrapped tokens unwrapped
    event Unwrap(address indexed sender, address indexed stablecoinContract, uint256 amount);

    /**
     * @notice Wraps reserve ledger tokens into the specified stablecoin and sends them to a
     * recipient
     * @dev Approves the stablecoin contract to spend the specified amount of reserve ledger tokens,
     * then wraps the tokens to the `to` address
     * @param stablecoinContract The address of the target stablecoin contract
     * @param to The address to receive the wrapped tokens
     * @param amount The amount of reserve tokens to wrap
     */
    event Wrap(
        address indexed sender,
        address indexed stablecoinContract,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when a bridge ecosystem contract is enabled or disabled
    /// @param sender The address that enabled or disabled the bridge ecosystem contract (must have
    /// DEFAULT_ADMIN_ROLE) @param bridgeEcosystemContract The address of the bridge ecosystem
    /// contract
    /// @param enabled Set to true to enable, false to disable
    event BridgeEcosystemContractSet(
        address indexed sender, address indexed bridgeEcosystemContract, bool enabled
    );

    /// @notice Emitted when a token handler is set for a stablecoin contract
    /// @param sender The address that set the token handler (must have
    /// TOKEN_AUTHORITY_HANDLER_SETTER_ROLE) @param stablecoinContract The address of the stablecoin
    /// contract
    /// @param tokenHandler The address of the token handler
    event TokenHandlerSet(
        address indexed sender, address indexed stablecoinContract, address indexed tokenHandler
    );

    /// @notice Emitted when a stablecoin is registered
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param tokenHandler The address of the token handler
    /// @param mintTxnLimit The mint transaction limit
    event StablecoinRegistered(
        address indexed sender,
        address indexed stablecoinContract,
        address indexed tokenHandler,
        uint256 mintTxnLimit
    );

    /// @notice Emitted when a stablecoin is unregistered
    /// @param stablecoinContract The address of the stablecoin contract
    event StablecoinUnregistered(address indexed sender, address indexed stablecoinContract);

    /*//////////////////////////////////////////////////////////////////////////
                                    Functions
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints stablecoins to a recipient address
     * @dev Checks and decrements global limit, transaction limit, and minter allowance before
     * minting
     * @param stablecoinContract The address of the stablecoin contract to mint from
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address stablecoinContract, address to, uint256 amount) external;

    /**
     * @notice Mints stablecoins to a specified address for bridge ecosystem contracts.
     * @dev Callable only by contracts with the BRIDGE_ECOSYSTEM_CONTRACT_ROLE.
     *      Does not enforce minter allowance or per-transaction mint limits.
     * @param stablecoinContract The address of the stablecoin contract to mint from.
     * @param to The recipient address that will receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mintBridgeEcosystem(address stablecoinContract, address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the sender's balance for a given stablecoin contract
     * @dev Allows the caller to burn their own tokens. If the stablecoin contract is the reserve
     * ledger token, it calls burn directly; otherwise, it calls unwrap on the Stablecoin
     * @param stablecoinContract The address of the stablecoin contract first.
     * @param amount The amount of tokens to burn
     */
    function burn(address stablecoinContract, uint256 amount) external;

    /**
     * @notice Unwraps a given amount of a wrapped stablecoin for the caller
     * @dev Reverts if the stablecoin contract provided is the reserve ledger token,
     *      since unwrapping is only applicable to wrapped stablecoins.
     *      Calls unwrap on the wrapped stablecoin, which should send the underlying reserve
     *      tokens to this contract, then transfers those reserve tokens to the caller.
     * @param stablecoinContract The address of the wrapped stablecoin contract
     * @param amount The amount of wrapped tokens to unwrap
     */
    function unwrap(address stablecoinContract, uint256 amount) external;

    /**
     * @notice Sets the per-transaction mint limit for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param mintTxnLimit The per-transaction mint limit to set
     */
    function setTxnMintLimit(address stablecoinContract, uint256 mintTxnLimit) external;

    /**
     * @notice Sets the mint allowance for a specific minter on a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param minter The address of the minter
     * @param minterAllowance The allowance amount to set for the minter
     */
    function setMinterAllowance(address stablecoinContract, address minter, uint256 minterAllowance)
        external;

    /**
     * @notice Gets the mint allowance for a specific minter on a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param minter The address of the minter
     * @return minterAllowance The remaining allowance for the minter
     */
    function getMinterAllowance(address stablecoinContract, address minter)
        external
        view
        returns (uint256 minterAllowance);

    /**
     * @notice Gets the per-transaction mint limit for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return mintTxnLimit The per-transaction mint limit
     */
    function getStablecoinTxnMintLimit(address stablecoinContract)
        external
        view
        returns (uint256 mintTxnLimit);

    /**
     * @notice Sets the token handler for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param tokenHandler The address of the token handler
     */
    function setTokenHandler(address stablecoinContract, address tokenHandler) external;

    /**
     * @notice Gets the token handler for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return tokenHandler The address of the token handler
     */
    function getTokenHandler(address stablecoinContract)
        external
        view
        returns (address tokenHandler);

}
