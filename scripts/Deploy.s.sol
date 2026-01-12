// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { ReserveLedger } from "../src/v3/ReserveLedger.sol";
import { AuthRegistry } from "../dependencies/auth-registry-1/src/AuthRegistry.sol";
import { IAuthRegistry } from "../dependencies/auth-registry-1/src/IAuthRegistry.sol";
import { StablecoinTemplateV3 } from "../src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "../src/v3/StablecoinTemplateV3Base.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    uint8 constant DECIMALS = 6;
    
    address authRegistryBlockerPolicyAdmin;
    address authRegistryWhitelistPolicyAdmin;

    address authRegistry;
    address reserveLedgerImplementation;
    address stablecoinTemplateV3Implementation;

    address reserveLedgerProxy;
    address stablecoinTemplateV3Proxy;

    uint64 transferPolicyId;
    uint64 reserveLedgerMintRecipientPolicyId;
    uint64 stablecoinMintRecipientPolicyId;

    string reserveLedgerName = "Reserve Ledger Euro";
    string reserveLedgerSymbol = "RE";
    address reserveLedgerAdmin;

    string stablecoinName = "Revolut Euro";
    string stablecoinSymbol = "EURR";
    address stablecoinAdmin;

    function setUp() public virtual {
        authRegistryBlockerPolicyAdmin = vm.envAddress("AUTH_REGISTRY_BLOCKER_POLICY_ADMIN");
        authRegistryWhitelistPolicyAdmin = vm.envAddress("AUTH_REGISTRY_WHITELIST_POLICY_ADMIN");

        reserveLedgerAdmin = vm.envAddress("RESERVE_LEDGER_ADMIN");
        stablecoinAdmin = vm.envAddress("STABLECOIN_ADMIN");
    }

    function run() public virtual {
        vm.startBroadcast();
        console.log("Starting deployment...");
        console.log();

        console.log("Deploying AuthRegistry...");
        authRegistry = address(new AuthRegistry());
        console.log("AuthRegistry deployed at", authRegistry);
        console.log();

        console.log("Deploying ReserveLedger implementation...");
        reserveLedgerImplementation = address(new ReserveLedger(authRegistry));
        console.log("ReserveLedger implementation deployed at", reserveLedgerImplementation);
        console.log();

        console.log("Deploying StablecoinTemplateV3 implementation...");
        stablecoinTemplateV3Implementation = address(new StablecoinTemplateV3(reserveLedgerImplementation, authRegistry));
        console.log("StablecoinTemplateV3 implementation deployed at", stablecoinTemplateV3Implementation);
        console.log();

        console.log("Setting up policies...");
        transferPolicyId = AuthRegistry(authRegistry).createPolicy(authRegistryBlockerPolicyAdmin, IAuthRegistry.PolicyType.BLACKLIST);
        reserveLedgerMintRecipientPolicyId = AuthRegistry(authRegistry).createPolicy(authRegistryWhitelistPolicyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        stablecoinMintRecipientPolicyId = AuthRegistry(authRegistry).createPolicy(authRegistryWhitelistPolicyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        console.log("Transfer policy ID:", transferPolicyId);
        console.log("Reserve ledger mint recipient policy ID:", reserveLedgerMintRecipientPolicyId);
        console.log("Stablecoin mint recipient policy ID:", stablecoinMintRecipientPolicyId);
        console.log();

        console.log("Deploying ReserveLedger proxy...");
        reserveLedgerProxy = address(
            new ERC1967Proxy(
                reserveLedgerImplementation, 
                abi.encodeCall(
                    StablecoinTemplateV3Base.initialize, 
                    (
                        reserveLedgerName,
                        reserveLedgerSymbol,
                        DECIMALS,
                        reserveLedgerAdmin,
                        transferPolicyId,
                        reserveLedgerMintRecipientPolicyId
                    )
                )
            )
        );

        console.log(StablecoinTemplateV3(reserveLedgerProxy).name());

        console.log("ReserveLedger proxy deployed at", reserveLedgerProxy);
        console.log();

        console.log("Deploying StablecoinTemplateV3 proxy...");
        stablecoinTemplateV3Proxy = address(
            new ERC1967Proxy(
                stablecoinTemplateV3Implementation, 
                abi.encodeCall(
                    StablecoinTemplateV3Base.initialize, 
                    (
                        stablecoinName, 
                        stablecoinSymbol, 
                        DECIMALS, 
                        stablecoinAdmin, 
                        transferPolicyId, 
                        stablecoinMintRecipientPolicyId
                    )
                )
            )
        );
        console.log("StablecoinTemplateV3 proxy deployed at", stablecoinTemplateV3Proxy);
        console.log();

        vm.stopBroadcast();
    }
}
