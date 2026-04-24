// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { console } from "forge-std/console.sol";

contract DeployAuthRegistry is Common {

    function run() public {
        vm.startBroadcast();
        AuthRegistry registry = new AuthRegistry{ salt: bytes32(0) }();
        vm.stopBroadcast();

        console.log("AuthRegistry deployed at", address(registry));
        console.log("---");
        console.log("Set in .env: AUTH_REGISTRY=%s", address(registry));
    }

}
