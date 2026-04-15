// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Verify is Common {

    uint256 failures;

    function _run() internal override {
        address authRegistry = authRegistryAddress();
        address reserveLedger = reserveLedgerAddress();
        address tokenAuthority = tokenAuthorityAddress();
        address stablecoin = stablecoinAddress();
        address minter = minterAddress();

        // Prerequisites
        _check(authRegistry.code.length > 0, "AuthRegistry has code");
        _check(reserveLedger.code.length > 0, "ReserveLedger has code");
        _check(tokenAuthority.code.length > 0, "TokenAuthority has code");
        _check(stablecoin.code.length > 0, "Stablecoin has code");

        ReserveLedger rl = ReserveLedger(reserveLedger);
        StablecoinTemplateV3 sc = StablecoinTemplateV3(stablecoin);
        TokenAuthority ta = TokenAuthority(tokenAuthority);

        // --- ReserveLedger checks ---
        string memory expectedRlName = vm.envString("RL_NAME");
        string memory expectedRlSymbol = vm.envString("RL_SYMBOL");

        _check(
            keccak256(bytes(rl.name())) == keccak256(bytes(expectedRlName)),
            "RL name matches"
        );
        _check(
            keccak256(bytes(rl.symbol())) == keccak256(bytes(expectedRlSymbol)),
            "RL symbol matches"
        );
        _check(rl.getMaxSupply() > 0, "RL maxSupply is set");
        _check(rl.getTransferPolicyId() > 1, "RL transferPolicyId is set (>1)");
        _check(rl.getMintRecipientPolicyId() > 1, "RL mintRecipientPolicyId is set (>1)");
        _check(
            rl.hasRole(rl.MINTER_ROLE(), tokenAuthority),
            "RL: TokenAuthority has MINTER_ROLE"
        );
        _check(
            rl.isMintRecipient(tokenAuthority),
            "RL: TokenAuthority is whitelisted mint recipient"
        );

        // --- StablecoinTemplateV3 checks ---
        string memory expectedScName = vm.envString("STABLECOIN_NAME");
        string memory expectedScSymbol = vm.envString("STABLECOIN_SYMBOL");

        _check(
            keccak256(bytes(sc.name())) == keccak256(bytes(expectedScName)),
            "Stablecoin name matches"
        );
        _check(
            keccak256(bytes(sc.symbol())) == keccak256(bytes(expectedScSymbol)),
            "Stablecoin symbol matches"
        );
        _check(sc.getMaxSupply() > 0, "Stablecoin maxSupply is set");
        _check(sc.getTransferPolicyId() > 1, "Stablecoin transferPolicyId is set (>1)");
        _check(sc.getMintRecipientPolicyId() > 1, "Stablecoin mintRecipientPolicyId is set (>1)");
        _check(
            address(sc.RESERVE_LEDGER_ADDRESS()) == reserveLedger,
            "Stablecoin RESERVE_LEDGER_ADDRESS matches"
        );
        _check(
            sc.hasRole(sc.MINTER_ROLE(), minter),
            "Stablecoin: minter has MINTER_ROLE"
        );

        // --- TokenAuthority checks ---
        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");
        _check(
            ta.hasRole(ta.DEFAULT_ADMIN_ROLE(), taAdmin),
            "TokenAuthority: admin has DEFAULT_ADMIN_ROLE"
        );
        _check(ta.RESERVE_LEDGER_TOKEN() == reserveLedger, "TokenAuthority: RESERVE_LEDGER_TOKEN matches");
        _check(
            ta.mintTxnLimits(stablecoin) > 0,
            "TokenAuthority: mintTxnLimit > 0 for stablecoin"
        );
        _check(
            ta.minterAllowances(stablecoin, minter) > 0,
            "TokenAuthority: minterAllowance > 0 for minter"
        );

        // --- Deployer permission check ---
        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (deployer != address(0)) {
            _check(
                !rl.hasRole(rl.DEFAULT_ADMIN_ROLE(), deployer),
                "RL: deployer has NO admin role"
            );
            _check(
                !sc.hasRole(sc.DEFAULT_ADMIN_ROLE(), deployer),
                "Stablecoin: deployer has NO admin role"
            );
            _check(
                !ta.hasRole(ta.DEFAULT_ADMIN_ROLE(), deployer),
                "TokenAuthority: deployer has NO admin role"
            );
        }

        // --- Summary ---
        console.log("---");
        if (failures == 0) {
            console.log("All checks passed");
        } else {
            console.log("FAILED: %d check(s) failed", failures);
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
