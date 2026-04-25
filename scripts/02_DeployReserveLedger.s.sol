// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";
import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import {
    DeterministicProxyFactoryFixture
} from "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";

contract DeployReserveLedger is Common {

    function run(address authRegistry, TokenConfig calldata config) public {
        requireDeployed(authRegistry, "authRegistry");

        require(bytes(config.name).length != 0, "name is empty");
        require(bytes(config.symbol).length != 0, "symbol is empty");

        vm.startBroadcast();

        uint64 transferPolicyId = AuthRegistry(authRegistry)
            .createPolicy(config.policyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        console.log("Transfer policy ID:", transferPolicyId);

        uint64 rlMintRecipientPolicyId = AuthRegistry(authRegistry)
            .createPolicy(config.policyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        console.log("RL mint recipient policy ID:", rlMintRecipientPolicyId);

        address rlImplementation = address(new ReserveLedger(authRegistry));
        console.log("ReserveLedger implementation:", rlImplementation);

        bytes32 salt = PermissionedSalt.createPermissionedSalt(msg.sender, config.saltNonce);
        address rlProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: msg.sender,
            implementation: rlImplementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (
                    config.name,
                    config.symbol,
                    config.decimals,
                    msg.sender,
                    transferPolicyId,
                    rlMintRecipientPolicyId
                )
            )
        });

        vm.stopBroadcast();

        console.log("ReserveLedger proxy:", rlProxy);
        console.log("---");
        console.log("Outputs for subsequent steps:");
        console.log("RESERVE_LEDGER=%s", rlProxy);
        console.log("TRANSFER_POLICY_ID=%d", uint256(transferPolicyId));
        console.log("RL_MINT_RECIPIENT_POLICY_ID=%d", uint256(rlMintRecipientPolicyId));
    }

}
