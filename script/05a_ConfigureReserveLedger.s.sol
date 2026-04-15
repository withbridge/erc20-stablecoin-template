// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

contract ConfigureReserveLedger is Common {

    function _run() internal override {
        address authRegistry = authRegistryAddress();
        address reserveLedger = reserveLedgerAddress();
        address tokenAuthority = tokenAuthorityAddress();
        requireDeployed(authRegistry, "AUTH_REGISTRY");
        requireDeployed(reserveLedger, "RESERVE_LEDGER");
        requireDeployed(tokenAuthority, "TOKEN_AUTHORITY");

        uint256 rlMaxSupply = vm.envUint("RL_MAX_SUPPLY");
        uint64 rlMintRecipientPolicyId = uint64(vm.envUint("RL_MINT_RECIPIENT_POLICY_ID"));
        address pauser = pauserAddress();
        address unpauser = unpauserAddress();
        address blockedBurner = blockedAddressBurnerAddress();

        ReserveLedger rl = ReserveLedger(reserveLedger);

        vm.startBroadcast();

        // Set max supply
        rl.setMaxSupply(rlMaxSupply);
        console.log("RL max supply set to", rlMaxSupply);

        // Grant MINTER_ROLE to TokenAuthority — critical for mint flow
        rl.grantRole(rl.MINTER_ROLE(), tokenAuthority);
        console.log("RL MINTER_ROLE granted to TokenAuthority", tokenAuthority);

        // Grant operational roles
        rl.grantRole(rl.PAUSER_ROLE(), pauser);
        console.log("RL PAUSER_ROLE granted to", pauser);

        rl.grantRole(rl.UNPAUSER_ROLE(), unpauser);
        console.log("RL UNPAUSER_ROLE granted to", unpauser);

        rl.grantRole(rl.BLOCKED_ADDRESS_BURNER_ROLE(), blockedBurner);
        console.log("RL BLOCKED_ADDRESS_BURNER_ROLE granted to", blockedBurner);

        // Whitelist TokenAuthority as RL mint recipient (required for _update() hook)
        AuthRegistry(authRegistry).modifyPolicyWhitelist(
            rlMintRecipientPolicyId, tokenAuthority, true
        );
        console.log("TokenAuthority whitelisted in RL mint recipient policy");

        // Grant MINT_RATE_LIMIT_SETTER_ROLE on TokenAuthority to the TA admin
        // (needed by 05b to call setTxnMintLimit and setMinterAllowance)
        TokenAuthority ta = TokenAuthority(tokenAuthority);
        ta.grantRole(ta.MINT_RATE_LIMIT_SETTER_ROLE(), vm.envAddress("TOKEN_AUTHORITY_ADMIN"));
        console.log("TokenAuthority MINT_RATE_LIMIT_SETTER_ROLE granted to TA admin");

        vm.stopBroadcast();

        console.log("---");
        console.log("ReserveLedger + TokenAuthority configuration complete");
    }

}
