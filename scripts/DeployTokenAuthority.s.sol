// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {TokenAuthority} from "../src/tokenAuthority/TokenAuthority.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployTokenAuthority is Script {
    address tokenAuthorityAdmin;
    address reserveLedgerToken;

    function setUp() public virtual {
        tokenAuthorityAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");
        reserveLedgerToken = vm.envAddress("RESERVE_LEDGER_TOKEN");
    }

    function run() public {
        vm.startBroadcast();
        console.log("Starting deployment...");
        console.log();

        console.log("Deploying TokenAuthority Implementation...");
        TokenAuthority tokenAuthority = new TokenAuthority(
            reserveLedgerToken,
            true
        );
        console.log(
            "TokenAuthority Implementation deployed at",
            address(tokenAuthority)
        );
        console.log();

        console.log("Deploying TokenAuthority Proxy...");
        TokenAuthority tokenAuthorityProxy = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(tokenAuthority),
                    abi.encodeCall(
                        TokenAuthority.initialize,
                        (tokenAuthorityAdmin)
                    )
                )
            )
        );
        console.log(
            "TokenAuthority Proxy deployed at",
            address(tokenAuthorityProxy)
        );
        console.log();

        vm.stopBroadcast();
    }
}
