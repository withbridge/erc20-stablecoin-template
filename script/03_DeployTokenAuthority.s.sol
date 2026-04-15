// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import {
    DeterministicProxyFactoryFixture
} from "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";

contract DeployTokenAuthority is Common {

    function _run() internal override {
        address reserveLedger = reserveLedgerAddress();
        requireDeployed(reserveLedger, "RESERVE_LEDGER");

        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");
        uint96 saltNonce = uint96(vm.envUint("TA_SALT_NONCE"));

        require(taAdmin != address(0), "TOKEN_AUTHORITY_ADMIN not set");

        vm.startBroadcast();

        // Deploy TokenAuthority implementation with initializers disabled
        address taImplementation = address(new TokenAuthority(reserveLedger, true));
        console.log("TokenAuthority implementation:", taImplementation);

        // Deploy proxy via DeterministicProxyFactory
        bytes32 salt = PermissionedSalt.createPermissionedSalt(msg.sender, saltNonce);
        address taProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: msg.sender,
            implementation: taImplementation,
            callData: abi.encodeCall(TokenAuthority.initialize, (taAdmin))
        });

        vm.stopBroadcast();

        console.log("TokenAuthority proxy:", taProxy);
        console.log("---");
        console.log("Set in .env: TOKEN_AUTHORITY=%s", taProxy);
    }

}
