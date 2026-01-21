// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct TokenAuthorityStorage {
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
}

library TokenAuthorityStorageLib {

    /// @custom:storage-location eip7201:bridge.TokenAuthority
    bytes32 constant TOKEN_AUTHORITY_SLOT =
        0x31bc481a801f5473b2acf93396aa4c08d22a827cb51d66b18e9d13ccb098c200;

    function getStorage() internal pure returns (TokenAuthorityStorage storage s) {
        bytes32 slot = TOKEN_AUTHORITY_SLOT;
        assembly {
            s.slot := slot
        }
    }

}
