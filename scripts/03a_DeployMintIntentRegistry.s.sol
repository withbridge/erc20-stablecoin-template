// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MintIntentRegistry } from "src/mintIntent/MintIntentRegistry.sol";

/**
 * @title DeployMintIntentRegistry
 * @notice Deploys the shared MintIntentRegistry.
 *
 *         Deploy this ONCE per environment and reuse the same proxy address for
 *         every controller (TokenAuthority, TIP20Controller). Operation IDs and
 *         hold IDs are only single-use within the storage that tracks them, so
 *         sharing one registry is what makes them single-use across controller
 *         deployments rather than once per controller.
 *
 *         Each controller must then be granted CONTROLLER_ROLE on this registry
 *         (done in step 05).
 */
contract DeployMintIntentRegistry is Common {

    function run() public {
        vm.startBroadcast();

        // Deploy implementation with initializers disabled
        MintIntentRegistry registryImplementation = new MintIntentRegistry(true);
        console.log("MintIntentRegistry implementation:", address(registryImplementation));

        // Admin is set to msg.sender so the deployer can grant CONTROLLER_ROLE to
        // controllers before handing over to the final admin in step 05.
        MintIntentRegistry registryProxy = MintIntentRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImplementation),
                    abi.encodeCall(MintIntentRegistry.initialize, (msg.sender))
                )
            )
        );

        vm.stopBroadcast();

        console.log("MintIntentRegistry proxy:", address(registryProxy));
        console.log("---");
        console.log("Set in .env: MINT_INTENT_REGISTRY=%s", address(registryProxy));
    }

}
