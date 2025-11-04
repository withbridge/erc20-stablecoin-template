// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20BurnMint } from "../utils/IERC20BurnMint.sol";
import { IERC20WrapUnwrap } from "../utils/IERC20WrapUnwrap.sol";

import { ITokenAuthority } from "./ITokenAuthority.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenAuthority is ITokenAuthority, AccessControlEnumerableUpgradeable, UUPSUpgradeable {

    using SafeERC20 for IERC20BurnMint;

    /*//////////////////////////////////////////////////////////////////////////
                                Immutable Variables
    //////////////////////////////////////////////////////////////////////////*/

    address public immutable RESERVE_LEDGER_TOKEN;

    /*//////////////////////////////////////////////////////////////////////////
                                Immutable Variables
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UNWRAPPER_ROLE = keccak256("UNWRAPPER_ROLE");

    /*//////////////////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Maps each stablecoin contract address and user address to the minter allowance for
    /// that user on the stablecoin.
    /// @dev minterAllowances[stablecoinContract][user] = minterAllowance (remaining tokens that can
    /// be minted by the user)
    mapping(address stablecoinContract => mapping(address user => uint256 minterAllowance)) public
        minterAllowances;

    /// @notice Maps each stablecoin contract address to its respective mint rate limits.
    /// @dev mintRateLimits[stablecoinContract] = MintRateLimit struct (global and per-transaction
    /// mint limits for the stablecoin)
    mapping(address stablecoinContract => MintRateLimit mintRateLimit) public mintRateLimits;

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
     */
    function initialize(address _admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                        Mint
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints stablecoins to a recipient address
     * @dev Checks and decrements global limit, transaction limit, and minter allowance before
     * minting
     * @param stablecoinContract The address of the stablecoin contract to mint from
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address stablecoinContract, address to, uint256 amount) public {
        MintRateLimit storage mintRateLimit = mintRateLimits[stablecoinContract];
        uint256 minterAllowance = minterAllowances[stablecoinContract][_msgSender()];
        require(mintRateLimit.mintGlobalLimit >= amount, MintGlobalLimitExceeded());
        require(mintRateLimit.mintTxnLimit >= amount, MintTxnLimitExceeded());
        require(minterAllowance >= amount, MinterAllowanceExceeded());

        if (mintRateLimit.mintGlobalLimit != type(uint256).max) {
            mintRateLimit.mintGlobalLimit -= amount;
        }

        if (minterAllowance != type(uint256).max) {
            minterAllowances[stablecoinContract][_msgSender()] -= amount;
        }

        if (stablecoinContract == RESERVE_LEDGER_TOKEN) {
            IERC20BurnMint(RESERVE_LEDGER_TOKEN).mint(to, amount);
        } else {
            IERC20BurnMint(RESERVE_LEDGER_TOKEN).mint(address(this), amount);
            IERC20WrapUnwrap(stablecoinContract).wrap(to, amount);
        }

        emit Mint(_msgSender(), stablecoinContract, to, amount);
    }

    /**
     * @notice Burns tokens from the sender's balance for a given stablecoin contract
     * @dev Allows the caller to burn their own tokens. If the stablecoin contract is the reserve
     * ledger token,
     *      it calls burn directly; otherwise, it calls unwrap on the ERC20WrapUnwrap interface.
     * @param stablecoinContract The address of the stablecoin contract
     * @param amount The amount of tokens to burn
     */
    function burn(address stablecoinContract, uint256 amount) public onlyRole(BURNER_ROLE) {
        if (stablecoinContract == RESERVE_LEDGER_TOKEN) {
            IERC20BurnMint(RESERVE_LEDGER_TOKEN).burn(amount);
        } else {
            IERC20WrapUnwrap(stablecoinContract).unwrap(amount);
        }

        emit Burn(_msgSender(), stablecoinContract, amount);
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
        require(stablecoinContract != RESERVE_LEDGER_TOKEN, CannotUnwrapReserveLedgerToken());

        // Unwrap the wrapped stablecoin, which will send underlying RESERVE_LEDGER_TOKEN to this
        // contract
        IERC20WrapUnwrap(stablecoinContract).unwrap(amount);

        // Transfer the received RESERVE_LEDGER_TOKEN to the sender
        IERC20BurnMint(RESERVE_LEDGER_TOKEN).transfer(_msgSender(), amount);

        emit Unwrap(_msgSender(), stablecoinContract, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Mint Rate Setters
    //////////////////////////////////////////////////////////////////////////*/

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
    ) public onlyRole(MINT_RATE_LIMIT_SETTER_ROLE) {
        mintRateLimits[stablecoinContract] = MintRateLimit(mintGlobalLimit, mintTxnLimit);

        emit MintRateLimitsSet(_msgSender(), stablecoinContract, mintGlobalLimit, mintTxnLimit);
    }

    /**
     * @notice Sets the global mint limit for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param mintGlobalLimit The global mint limit to set
     */
    function setGlobalMintLimit(address stablecoinContract, uint256 mintGlobalLimit)
        public
        onlyRole(MINT_RATE_LIMIT_SETTER_ROLE)
    {
        mintRateLimits[stablecoinContract].mintGlobalLimit = mintGlobalLimit;

        emit GlobalMintLimitSet(_msgSender(), stablecoinContract, mintGlobalLimit);
    }

    /**
     * @notice Sets the per-transaction mint limit for a stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @param mintTxnLimit The per-transaction mint limit to set
     */
    function setTxnMintLimit(address stablecoinContract, uint256 mintTxnLimit)
        public
        onlyRole(MINT_RATE_LIMIT_SETTER_ROLE)
    {
        mintRateLimits[stablecoinContract].mintTxnLimit = mintTxnLimit;

        emit TxnMintLimitSet(_msgSender(), stablecoinContract, mintTxnLimit);
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
        minterAllowances[stablecoinContract][minter] = minterAllowance;

        emit MinterAllowanceSet(_msgSender(), stablecoinContract, minter, minterAllowance);
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
     * @notice Gets the mint rate limits for a specific stablecoin contract
     * @param stablecoinContract The address of the stablecoin contract
     * @return mintGlobalLimit The global mint limit remaining
     * @return mintTxnLimit The per-transaction mint limit
     */
    function getStablecoinMintRateLimits(address stablecoinContract)
        public
        view
        returns (uint256 mintGlobalLimit, uint256 mintTxnLimit)
    {
        return (
            mintRateLimits[stablecoinContract].mintGlobalLimit,
            mintRateLimits[stablecoinContract].mintTxnLimit
        );
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
