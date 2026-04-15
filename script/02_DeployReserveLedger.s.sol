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

    function _run() internal override {
        address authRegistry = authRegistryAddress();
        requireDeployed(authRegistry, "AUTH_REGISTRY");

        string memory rlName = vm.envString("RL_NAME");
        string memory rlSymbol = vm.envString("RL_SYMBOL");
        uint8 rlDecimals = uint8(vm.envUint("RL_DECIMALS"));
        address rlAdmin = vm.envAddress("RL_ADMIN");
        address policyAdmin = policyAdminAddress();
        uint96 saltNonce = uint96(vm.envUint("RL_SALT_NONCE"));

        require(rlAdmin != address(0), "RL_ADMIN not set");
        require(bytes(rlName).length != 0, "RL_NAME not set");
        require(bytes(rlSymbol).length != 0, "RL_SYMBOL not set");

        vm.startBroadcast();

        // Create policies in AuthRegistry
        uint64 transferPolicyId =
            AuthRegistry(authRegistry).createPolicy(policyAdmin, IAuthRegistry.PolicyType.BLACKLIST);
        console.log("Transfer policy ID:", transferPolicyId);

        uint64 rlMintRecipientPolicyId = AuthRegistry(authRegistry).createPolicy(
            policyAdmin, IAuthRegistry.PolicyType.WHITELIST
        );
        console.log("RL mint recipient policy ID:", rlMintRecipientPolicyId);

        // Deploy ReserveLedger implementation
        address rlImplementation = address(new ReserveLedger(authRegistry));
        console.log("ReserveLedger implementation:", rlImplementation);

        // Deploy proxy via DeterministicProxyFactory
        bytes32 salt = PermissionedSalt.createPermissionedSalt(msg.sender, saltNonce);
        address rlProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: msg.sender,
            implementation: rlImplementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (rlName, rlSymbol, rlDecimals, rlAdmin, transferPolicyId, rlMintRecipientPolicyId)
            )
        });

        vm.stopBroadcast();

        console.log("ReserveLedger proxy:", rlProxy);
        console.log("---");
        console.log("Set these in .env for subsequent steps:");
        console.log("  RESERVE_LEDGER=%s", rlProxy);
        console.log("  TRANSFER_POLICY_ID=%d", uint256(transferPolicyId));
        console.log("  RL_MINT_RECIPIENT_POLICY_ID=%d", uint256(rlMintRecipientPolicyId));
    }

}
