// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenAuthority
/// @notice Interface for the TokenAuthority contract which manages minting rate limits and
/// allowances for stablecoins
/// @dev This contract enforces three types of limits: global cumulative limits, per-transaction
/// limits, and per-minter allowances
interface ITokenAuthority {

    /*//////////////////////////////////////////////////////////////////////////
                                    Structs
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Stores the mint rate limits for a stablecoin contract
    /// @dev Both limits are enforced during minting operations
    struct MintRateLimit {
        /// @notice The remaining cumulative amount that can be minted globally for this stablecoin
        /// @dev This limit decrements with each mint and acts as a total supply cap over a period
        uint256 mintGlobalLimit;
        /// @notice The maximum amount that can be minted in a single transaction
        /// @dev This limit does not decrement and serves as a per-transaction cap
        uint256 mintTxnLimit;
    }

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

    /*//////////////////////////////////////////////////////////////////////////
                                    Events
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when both mint rate limits are set for a stablecoin
    /// @param sender The address that set the limits (must have MINT_RATE_LIMIT_SETTER_ROLE)
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param mintGlobalLimit The new global mint limit
    /// @param mintTxnLimit The new per-transaction mint limit
    event MintRateLimitsSet(
        address indexed sender,
        address indexed stablecoinContract,
        uint256 mintGlobalLimit,
        uint256 mintTxnLimit
    );

    /// @notice Emitted when only the global mint limit is updated for a stablecoin
    /// @param sender The address that set the limit (must have MINT_RATE_LIMIT_SETTER_ROLE)
    /// @param stablecoinContract The address of the stablecoin contract
    /// @param mintGlobalLimit The new global mint limit
    event GlobalMintLimitSet(
        address indexed sender, address indexed stablecoinContract, uint256 mintGlobalLimit
    );

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
     * @notice Burns tokens from the sender's balance for a given stablecoin contract
     * @dev Allows the caller to burn their own tokens. If the stablecoin contract is the reserve
     * ledger token,
     *      it calls burn directly; otherwise, it calls unwrap on the ERC20WrapUnwrap interface.
     * @param stablecoinContract The address of the stablecoin contract
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
     * @notice Sets both the global and per-transaction mint limits for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param mintGlobalLimit The global mint limit to set
     * @param mintTxnLimit The per-transaction mint limit to set
     */
    function setMintRateLimits(
        address stablecoinContract,
        uint256 mintGlobalLimit,
        uint256 mintTxnLimit
    ) external;

    /**
     * @notice Sets the global mint limit for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param mintGlobalLimit The global mint limit to set
     */
    function setGlobalMintLimit(address stablecoinContract, uint256 mintGlobalLimit) external;

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
     * @notice Gets the mint rate limits for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return mintGlobalLimit The global mint limit remaining
     * @return mintTxnLimit The per-transaction mint limit
     */
    function getStablecoinMintRateLimits(address stablecoinContract)
        external
        view
        returns (uint256 mintGlobalLimit, uint256 mintTxnLimit);

}
