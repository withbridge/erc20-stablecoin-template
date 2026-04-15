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

    function _run() internal override {
        address authRegistry = authRegistryAddress();
        address reserveLedger = reserveLedgerAddress();
        requireDeployed(authRegistry, "AUTH_REGISTRY");
        requireDeployed(reserveLedger, "RESERVE_LEDGER");

        string memory scName = vm.envString("STABLECOIN_NAME");
        string memory scSymbol = vm.envString("STABLECOIN_SYMBOL");
        uint8 scDecimals = uint8(vm.envUint("STABLECOIN_DECIMALS"));
        address scAdmin = vm.envAddress("STABLECOIN_ADMIN");
        address policyAdmin = policyAdminAddress();
        uint64 transferPolicyId = uint64(vm.envUint("TRANSFER_POLICY_ID"));
        uint96 saltNonce = uint96(vm.envUint("SC_SALT_NONCE"));

        require(scAdmin != address(0), "STABLECOIN_ADMIN not set");
        require(bytes(scName).length != 0, "STABLECOIN_NAME not set");
        require(bytes(scSymbol).length != 0, "STABLECOIN_SYMBOL not set");

        vm.startBroadcast();

        // Create stablecoin mint recipient policy
        uint64 scMintRecipientPolicyId = AuthRegistry(authRegistry).createPolicy(
            policyAdmin, IAuthRegistry.PolicyType.WHITELIST
        );
        console.log("Stablecoin mint recipient policy ID:", scMintRecipientPolicyId);

        // Deploy StablecoinTemplateV3 implementation
        address scImplementation =
            address(new StablecoinTemplateV3(reserveLedger, authRegistry));
        console.log("StablecoinTemplateV3 implementation:", scImplementation);

        // Deploy proxy via DeterministicProxyFactory
        bytes32 salt = PermissionedSalt.createPermissionedSalt(msg.sender, saltNonce);
        address scProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: msg.sender,
            implementation: scImplementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (
                    scName,
                    scSymbol,
                    scDecimals,
                    scAdmin,
                    transferPolicyId,
                    scMintRecipientPolicyId
                )
            )
        });

        vm.stopBroadcast();

        console.log("StablecoinTemplateV3 proxy:", scProxy);
        console.log("---");
        console.log("Set these in .env for subsequent steps:");
        console.log("  STABLECOIN=%s", scProxy);
        console.log("  SC_MINT_RECIPIENT_POLICY_ID=%d", uint256(scMintRecipientPolicyId));
    }

}
