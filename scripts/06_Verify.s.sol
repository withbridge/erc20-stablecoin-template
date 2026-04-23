// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

/**
 * @title Verify
 * @notice Read-only script that verifies the full deployment and configuration
 *         state after steps 01-05 (deploy, configure, and handover).
 *
 *         Checks: contract existence, token metadata (name, symbol, decimals),
 *         policy IDs, immutables, role grants (minter, pauser, unpauser,
 *         blocked-address burner, mint rate limit setter), TokenAuthority
 *         config (txn mint limit, minter allowance), max supply, admin
 *         handover (ownership + DEFAULT_ADMIN_ROLE), and deployer renunciation.
 */
contract Verify is Common {

    uint256 failures;

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");
    bytes32 constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function _run() internal override {
        address authRegistry = authRegistryAddress();
        address reserveLedger = reserveLedgerAddress();
        address tokenAuthority = tokenAuthorityAddress();
        address stablecoin = stablecoinAddress();

        _verifyExistence(authRegistry, reserveLedger, tokenAuthority, stablecoin);
        _verifyReserveLedger(ReserveLedger(reserveLedger), tokenAuthority);
        _verifyStablecoin(StablecoinTemplateV3(stablecoin), reserveLedger, tokenAuthority);
        _verifyTokenAuthority(TokenAuthority(tokenAuthority), reserveLedger, stablecoin);
        _verifyDeployerRenunciation(reserveLedger, tokenAuthority, stablecoin);

        // --- Summary ---
        console.log("---");
        if (failures == 0) {
            console.log("All checks passed");
        } else {
            console.log("FAILED: %d check(s) failed", failures);
        }
        require(failures == 0, "Verification failed");
    }

    function _verifyExistence(
        address authRegistry,
        address reserveLedger,
        address tokenAuthority,
        address stablecoin
    ) internal {
        _check(authRegistry.code.length > 0, "AuthRegistry has code");
        _check(reserveLedger.code.length > 0, "ReserveLedger has code");
        _check(tokenAuthority.code.length > 0, "TokenAuthority has code");
        _check(stablecoin.code.length > 0, "Stablecoin has code");
    }

    function _verifyReserveLedger(ReserveLedger rl, address tokenAuthority) internal {
        // Metadata
        _check(
            keccak256(bytes(rl.name())) == keccak256(bytes(vm.envString("RL_NAME"))),
            "RL: name matches"
        );
        _check(
            keccak256(bytes(rl.symbol())) == keccak256(bytes(vm.envString("RL_SYMBOL"))),
            "RL: symbol matches"
        );
        _check(rl.decimals() == uint8(vm.envUint("RL_DECIMALS")), "RL: decimals match");

        // Policies
        _check(rl.getTransferPolicyId() > 1, "RL: transferPolicyId is set (>1)");
        _check(rl.getMintRecipientPolicyId() > 1, "RL: mintRecipientPolicyId is set (>1)");

        // Admin handover
        address rlAdmin = vm.envAddress("RL_ADMIN");
        _check(rl.hasRole(DEFAULT_ADMIN_ROLE, rlAdmin), "RL: admin has DEFAULT_ADMIN_ROLE");
        _check(rl.owner() == rlAdmin, "RL: owner matches RL_ADMIN");

        // Roles from step 05
        _check(rl.hasRole(MINTER_ROLE, tokenAuthority), "RL: TokenAuthority has MINTER_ROLE");

        // Max supply
        _check(rl.getMaxSupply() == vm.envUint("RL_MAX_SUPPLY"), "RL: maxSupply matches");
    }

    function _verifyStablecoin(
        StablecoinTemplateV3 sc,
        address reserveLedger,
        address tokenAuthority
    ) internal {
        // Metadata
        _check(
            keccak256(bytes(sc.name())) == keccak256(bytes(vm.envString("STABLECOIN_NAME"))),
            "SC: name matches"
        );
        _check(
            keccak256(bytes(sc.symbol())) == keccak256(bytes(vm.envString("STABLECOIN_SYMBOL"))),
            "SC: symbol matches"
        );
        _check(sc.decimals() == uint8(vm.envUint("STABLECOIN_DECIMALS")), "SC: decimals match");

        // Policies
        _check(sc.getTransferPolicyId() > 1, "SC: transferPolicyId is set (>1)");
        _check(sc.getMintRecipientPolicyId() > 1, "SC: mintRecipientPolicyId is set (>1)");

        // Immutables
        _check(
            address(sc.RESERVE_LEDGER_ADDRESS()) == reserveLedger,
            "SC: RESERVE_LEDGER_ADDRESS matches"
        );

        // Admin handover
        address scAdmin = vm.envAddress("STABLECOIN_ADMIN");
        _check(sc.hasRole(DEFAULT_ADMIN_ROLE, scAdmin), "SC: admin has DEFAULT_ADMIN_ROLE");
        _check(sc.owner() == scAdmin, "SC: owner matches STABLECOIN_ADMIN");

        // Roles from step 05
        _check(sc.hasRole(MINTER_ROLE, tokenAuthority), "SC: TokenAuthority has MINTER_ROLE");
        _check(sc.hasRole(PAUSER_ROLE, vm.envAddress("PAUSER_ADDRESS")), "SC: PAUSER_ROLE granted");
        _check(
            sc.hasRole(UNPAUSER_ROLE, vm.envAddress("UNPAUSER_ADDRESS")),
            "SC: UNPAUSER_ROLE granted"
        );
        _check(
            sc.hasRole(
                BLOCKED_ADDRESS_BURNER_ROLE, vm.envAddress("BLOCKED_ADDRESS_BURNER_ADDRESS")
            ),
            "SC: BLOCKED_ADDRESS_BURNER_ROLE granted"
        );

        // Max supply
        _check(sc.getMaxSupply() == vm.envUint("STABLECOIN_MAX_SUPPLY"), "SC: maxSupply matches");
    }

    function _verifyTokenAuthority(TokenAuthority ta, address reserveLedger, address stablecoin)
        internal
    {
        // Immutables
        _check(ta.RESERVE_LEDGER_TOKEN() == reserveLedger, "TA: RESERVE_LEDGER_TOKEN matches");

        // Admin handover
        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");
        _check(ta.hasRole(DEFAULT_ADMIN_ROLE, taAdmin), "TA: admin has DEFAULT_ADMIN_ROLE");
        _check(
            ta.hasRole(MINT_RATE_LIMIT_SETTER_ROLE, taAdmin),
            "TA: admin has MINT_RATE_LIMIT_SETTER_ROLE"
        );
        _check(
            ta.hasRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, taAdmin),
            "TA: admin has TOKEN_AUTHORITY_HANDLER_SETTER_ROLE"
        );

        // Handler registration
        _check(
            ta.getTokenHandler(stablecoin) != address(0),
            "TA: tokenHandler registered for stablecoin"
        );

        // Limits from step 05
        _check(
            ta.getStablecoinTxnMintLimit(stablecoin) == vm.envUint("TXN_MINT_LIMIT"),
            "TA: txnMintLimit matches"
        );
        _check(
            ta.getMinterAllowance(stablecoin, vm.envAddress("MINTER_ADDRESS"))
                == vm.envUint("MINTER_ALLOWANCE"),
            "TA: minterAllowance matches"
        );
    }

    function _verifyDeployerRenunciation(
        address reserveLedger,
        address tokenAuthority,
        address stablecoin
    ) internal {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (deployer == address(0)) {
            console.log("[SKIP] DEPLOYER_ADDRESS not set, skipping renunciation checks");
            return;
        }

        // If deployer == final admin, renunciation was intentionally skipped
        address rlAdmin = vm.envAddress("RL_ADMIN");
        address scAdmin = vm.envAddress("STABLECOIN_ADMIN");
        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");

        if (deployer != rlAdmin) {
            _check(
                !ReserveLedger(reserveLedger).hasRole(DEFAULT_ADMIN_ROLE, deployer),
                "RL: deployer renounced DEFAULT_ADMIN_ROLE"
            );
        }
        if (deployer != scAdmin) {
            _check(
                !StablecoinTemplateV3(stablecoin).hasRole(DEFAULT_ADMIN_ROLE, deployer),
                "SC: deployer renounced DEFAULT_ADMIN_ROLE"
            );
        }
        if (deployer != taAdmin) {
            _check(
                !TokenAuthority(tokenAuthority).hasRole(DEFAULT_ADMIN_ROLE, deployer),
                "TA: deployer renounced DEFAULT_ADMIN_ROLE"
            );
            _check(
                !TokenAuthority(tokenAuthority).hasRole(MINT_RATE_LIMIT_SETTER_ROLE, deployer),
                "TA: deployer renounced MINT_RATE_LIMIT_SETTER_ROLE"
            );
            _check(
                !TokenAuthority(tokenAuthority)
                    .hasRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, deployer),
                "TA: deployer renounced TOKEN_AUTHORITY_HANDLER_SETTER_ROLE"
            );
        }
    }

    function _check(bool condition, string memory label) internal {
        if (condition) {
            console.log("[PASS]", label);
        } else {
            console.log("[FAIL]", label);
            failures++;
        }
    }

}
