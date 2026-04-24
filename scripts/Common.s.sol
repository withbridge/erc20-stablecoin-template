// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";

abstract contract Common is Script {

    /*//////////////////////////////////////////////////////////////////////////
                                    Structs
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Token deployment config shared by ReserveLedger and Stablecoin scripts.
    struct TokenConfig {
        string name;
        string symbol;
        uint8 decimals;
        address policyAdmin;
        uint96 saltNonce;
    }

    /// @dev Configuration and handover params for step 05.
    struct HandoverConfig {
        uint256 txnMintLimit;
        address minterAddress;
        uint256 minterAllowance;
        uint256 rlMaxSupply;
        uint256 stablecoinMaxSupply;
        address pauserAddress;
        address unpauserAddress;
        address blockedAddressBurnerAddress;
        address rlAdmin;
        address stablecoinAdmin;
        address tokenAuthorityAdmin;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Prerequisite Checks
    //////////////////////////////////////////////////////////////////////////*/

    function requireDeployed(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat(label, " not deployed at specified address"));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Env Var Helpers (used by 06_Verify.s.sol)
    //////////////////////////////////////////////////////////////////////////*/

    function authRegistryAddress() internal view returns (address) {
        address addr = vm.envAddress("AUTH_REGISTRY");
        require(addr != address(0), "AUTH_REGISTRY not set");
        return addr;
    }

    function reserveLedgerAddress() internal view returns (address) {
        address addr = vm.envAddress("RESERVE_LEDGER");
        require(addr != address(0), "RESERVE_LEDGER not set");
        return addr;
    }

    function tokenAuthorityAddress() internal view returns (address) {
        address addr = vm.envAddress("TOKEN_AUTHORITY");
        require(addr != address(0), "TOKEN_AUTHORITY not set");
        return addr;
    }

    function stablecoinAddress() internal view returns (address) {
        address addr = vm.envAddress("STABLECOIN");
        require(addr != address(0), "STABLECOIN not set");
        return addr;
    }

}
