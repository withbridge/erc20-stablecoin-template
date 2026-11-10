// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IdempotencyKeyRegistry } from "src/idempotency/IdempotencyKeyRegistry.sol";

/**
 * @title DeployIdempotencyKeyRegistry
 * @notice Deploys the shared IdempotencyKeyRegistry.
 *
 *         Deploy this ONCE per environment and reuse the same proxy address for
 *         every controller (TokenAuthority, TIP20Controller). Keys are only
 *         single-use within the storage that tracks them, so sharing one
 *         registry is what makes them single-use across controller deployments
 *         rather than once per controller.
 *
 *         Each controller must then be granted CONTROLLER_ROLE on this registry
 *         (done in step 05).
 */
contract DeployIdempotencyKeyRegistry is Common {

    function run() public {
        vm.startBroadcast();

        // Deploy implementation with initializers disabled
        IdempotencyKeyRegistry registryImplementation = new IdempotencyKeyRegistry(true);
        console.log("IdempotencyKeyRegistry implementation:", address(registryImplementation));

        // Admin is set to msg.sender so the deployer can grant CONTROLLER_ROLE to
        // controllers before handing over to the final admin in step 05.
        IdempotencyKeyRegistry registryProxy = IdempotencyKeyRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation),
                    abi.encodeCall(IdempotencyKeyRegistry.initialize, (msg.sender))
                )
            )
        );

        vm.stopBroadcast();

        console.log("IdempotencyKeyRegistry proxy:", address(registryProxy));
        console.log("---");
        console.log("Set in .env: IDEMPOTENCY_KEY_REGISTRY=%s", address(registryProxy));
    }

}
