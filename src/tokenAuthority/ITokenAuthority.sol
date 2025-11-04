// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITokenAuthority {

    struct MintRateLimit {
        uint256 mintGlobalLimit;
        uint256 mintTxnLimit;
    }

    error MintGlobalLimitExceeded();
    error MintTxnLimitExceeded();
    error MinterAllowanceExceeded();

    event MintRateLimitsSet(address indexed sender, address indexed stablecoinContract, uint256 mintGlobalLimit, uint256 mintTxnLimit);
    event GlobalMintLimitSet(address indexed sender, address indexed stablecoinContract, uint256 mintGlobalLimit);
    event TxnMintLimitSet(address indexed sender, address indexed stablecoinContract, uint256 mintTxnLimit);
    event MinterAllowanceSet(address indexed sender, address indexed stablecoinContract, address indexed minter, uint256 minterAllowance);
    event Mint(address indexed sender, address indexed stablecoinContract, address indexed to, uint256 amount);

    function getMinterAllowance(address stablecoinContract, address minter)
        external
        view
        returns (uint256 minterAllowance);

    function getStablecoinMintRateLimits(address stablecoinContract)
        external
        view
        returns (uint256 mintGlobalLimit, uint256 mintTxnLimit);

}
