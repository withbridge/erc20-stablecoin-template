// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

abstract contract Common is Script {

    function run() public {
        _run();
    }

    function _run() internal virtual;

    /*//////////////////////////////////////////////////////////////////////////
                                Prerequisite Checks
    //////////////////////////////////////////////////////////////////////////*/

    function requireDeployed(address target, string memory label) internal view {
        require(target.code.length > 0, string.concat(label, " not deployed at specified address"));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Env Var Helpers
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

    function policyAdminAddress() internal view returns (address) {
        address addr = vm.envAddress("POLICY_ADMIN");
        require(addr != address(0), "POLICY_ADMIN not set");
        return addr;
    }

}
