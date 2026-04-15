// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";
import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";

contract DeployAuthRegistry is Common {

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _run() internal override {
        // Pre-compute the deterministic address
        bytes32 salt = bytes32(0);
        bytes memory creationCode = type(AuthRegistry).creationCode;
        address predicted = _computeCreate2Address(salt, creationCode);

        // Idempotent: skip if already deployed
        if (predicted.code.length > 0) {
            console.log("AuthRegistry already deployed at", predicted);
            return;
        }

        vm.startBroadcast();

        (bool success, bytes memory result) =
            CREATE2_DEPLOYER.call(abi.encodePacked(salt, creationCode));
        require(success, "AuthRegistry CREATE2 deployment failed");

        address deployed;
        assembly {
            deployed := mload(add(result, 0x20))
        }
        require(deployed == predicted, "AuthRegistry address mismatch");

        vm.stopBroadcast();

        console.log("AuthRegistry deployed at", deployed);
    }

    function _computeCreate2Address(bytes32 salt, bytes memory creationCode)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(creationCode))))
            )
        );
    }

}
