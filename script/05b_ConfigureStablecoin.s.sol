// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

contract ConfigureStablecoin is Common {

    function _run() internal override {
        address authRegistry = authRegistryAddress();
        address stablecoin = stablecoinAddress();
        address tokenAuthority = tokenAuthorityAddress();
        requireDeployed(authRegistry, "AUTH_REGISTRY");
        requireDeployed(stablecoin, "STABLECOIN");
        requireDeployed(tokenAuthority, "TOKEN_AUTHORITY");

        uint256 scMaxSupply = vm.envUint("STABLECOIN_MAX_SUPPLY");
        uint64 scMintRecipientPolicyId = uint64(vm.envUint("SC_MINT_RECIPIENT_POLICY_ID"));
        uint256 txnMintLimit = vm.envUint("TXN_MINT_LIMIT");
        uint256 minterAllowance = vm.envUint("MINTER_ALLOWANCE");
        address minter = minterAddress();
        address pauser = pauserAddress();
        address unpauser = unpauserAddress();
        address blockedBurner = blockedAddressBurnerAddress();

        StablecoinTemplateV3 sc = StablecoinTemplateV3(stablecoin);
        TokenAuthority ta = TokenAuthority(tokenAuthority);

        vm.startBroadcast();

        // --- Stablecoin configuration ---

        sc.setMaxSupply(scMaxSupply);
        console.log("Stablecoin max supply set to", scMaxSupply);

        // For the standard TokenAuthority mint flow, MINTER_ADDRESS should be
        // the TokenAuthority proxy address (TA calls stablecoin.mint() internally)
        sc.grantRole(sc.MINTER_ROLE(), minter);
        console.log("Stablecoin MINTER_ROLE granted to", minter);

        sc.grantRole(sc.PAUSER_ROLE(), pauser);
        console.log("Stablecoin PAUSER_ROLE granted to", pauser);

        sc.grantRole(sc.UNPAUSER_ROLE(), unpauser);
        console.log("Stablecoin UNPAUSER_ROLE granted to", unpauser);

        sc.grantRole(sc.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);
        console.log("Stablecoin BLOCKED_ADDRESS_BURNER_ROLE granted to", blockedBurner);

        // --- TokenAuthority registration ---

        ta.setTxnMintLimit(stablecoin, txnMintLimit);
        console.log("TokenAuthority txnMintLimit set to", txnMintLimit);

        ta.setMinterAllowance(stablecoin, minter, minterAllowance);
        console.log("TokenAuthority minterAllowance set to", minterAllowance);

        // --- Whitelist population ---
        // Without whitelisted recipients, the _update() hook reverts on mint.
        string memory recipientsRaw = vm.envOr("INITIAL_MINT_RECIPIENTS", string(""));
        if (bytes(recipientsRaw).length > 0) {
            // Parse comma-separated addresses
            string[] memory parts = vm.split(recipientsRaw, ",");
            for (uint256 i = 0; i < parts.length; i++) {
                address recipient = vm.parseAddress(parts[i]);
                AuthRegistry(authRegistry)
                    .modifyPolicyWhitelist(scMintRecipientPolicyId, recipient, true);
                console.log("Whitelisted mint recipient:", recipient);
            }
        }

        vm.stopBroadcast();

        console.log("---");
        console.log("Stablecoin configuration complete");
    }

}
