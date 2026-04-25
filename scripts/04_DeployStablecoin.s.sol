// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import {
    DeterministicProxyFactoryFixture
} from "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";

contract DeployStablecoin is Common {

    function run(
        address authRegistry,
        address reserveLedger,
        uint64 transferPolicyId,
        TokenConfig calldata config
    ) public {
        requireDeployed(authRegistry, "authRegistry");
        requireDeployed(reserveLedger, "reserveLedger");

        require(bytes(config.name).length != 0, "name is empty");
        require(bytes(config.symbol).length != 0, "symbol is empty");

        vm.startBroadcast();

        uint64 scMintRecipientPolicyId = AuthRegistry(authRegistry)
            .createPolicy(config.policyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        console.log("Stablecoin mint recipient policy ID:", scMintRecipientPolicyId);

        address scImplementation = address(new StablecoinTemplateV3(reserveLedger, authRegistry));
        console.log("StablecoinTemplateV3 implementation:", scImplementation);

        bytes32 salt = PermissionedSalt.createPermissionedSalt(msg.sender, config.saltNonce);
        address scProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: msg.sender,
            implementation: scImplementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (
                    config.name,
                    config.symbol,
                    config.decimals,
                    msg.sender,
                    transferPolicyId,
                    scMintRecipientPolicyId
                )
            )
        });

        vm.stopBroadcast();

        console.log("StablecoinTemplateV3 proxy:", scProxy);
        console.log("---");
        console.log("Outputs for subsequent steps:");
        console.log("STABLECOIN=%s", scProxy);
        console.log("SC_MINT_RECIPIENT_POLICY_ID=%d", uint256(scMintRecipientPolicyId));
    }

}
