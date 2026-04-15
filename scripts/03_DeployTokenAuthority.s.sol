// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

contract DeployTokenAuthority is Common {

    function _run() internal override {
        address reserveLedger = reserveLedgerAddress();
        requireDeployed(reserveLedger, "RESERVE_LEDGER");

        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");

        require(taAdmin != address(0), "TOKEN_AUTHORITY_ADMIN not set");

        vm.startBroadcast();

        // Deploy TokenAuthority implementation with initializers disabled
        TokenAuthority taImplementation = new TokenAuthority(reserveLedger, true);
        console.log("TokenAuthority implementation:", address(taImplementation));

        // Deploy proxy via ERC1967Proxy (not DPF — TokenAuthority.initialize uses
        // the `initializer` modifier which conflicts with the DPF fixture's
        // MinimalUpgradeableProxyOZ that consumes initializer version 1)
        TokenAuthority taProxy = TokenAuthority(
            address(
                new ERC1967Proxy(
                    address(taImplementation), abi.encodeCall(TokenAuthority.initialize, (taAdmin))
                )
            )
        );

        vm.stopBroadcast();

        console.log("TokenAuthority proxy:", address(taProxy));
        console.log("---");
        console.log("Set in .env: TOKEN_AUTHORITY=%s", address(taProxy));
    }

}
