// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Verify } from "scripts/06_Verify.s.sol";
import { DeployAll } from "scripts/DeployAll.s.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";

/**
 * @title DeployAllE2ETest
 * @notice End-to-end test for the full deployment via DeployAll. All scenarios
 *         live in a single test function because vm.setEnv is process-global in
 *         Foundry — multiple test functions leak env vars and cause flaky
 *         failures. Chain state is isolated between scenarios via vm.snapshot /
 *         vm.revertTo.
 *
 *         Scenarios covered:
 *         1. Deployer != admin: full handover + renunciation
 *         2. Deployer == admin: renunciation skipped
 *         3. Mint→burn round-trip through the TokenAuthority
 *         4. Adding a second stablecoin to existing infrastructure
 */
contract DeployAllE2ETest is Test, DeployAll {

    bytes32 constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function test_fullDeployment() public {
        // ================================================================
        // Scenario 1: deployer != admin (full handover + renunciation)
        // ================================================================
        uint256 snap = vm.snapshotState();

        _setEnvVars(false);

        DeployResult memory r1 = _execute(address(this));
        _setVerifyEnvVars(r1);
        (new Verify()).run();

        vm.revertToState(snap);

        // ================================================================
        // Scenario 2: deployer == admin + mint/burn + second stablecoin
        // ================================================================
        _setEnvVars(true);

        DeployResult memory r2 = _execute(address(this));
        _setVerifyEnvVars(r2);
        (new Verify()).run();

        // --- Mint and burn smoke test ---
        _smokeTestMintAndBurn(r2);

        // --- Add a second stablecoin ---
        vm.setEnv("STABLECOIN_NAME", "EUR Stablecoin");
        vm.setEnv("STABLECOIN_SYMBOL", "EURB");
        vm.setEnv("STABLECOIN_DECIMALS", "6");
        vm.setEnv("SC_SALT_NONCE", "50");
        vm.setEnv("STABLECOIN_MAX_SUPPLY", "500000000000000");

        vm.setEnv("MINTER_ADDRESS", vm.toString(makeAddr("minter_sc2")));
        vm.setEnv("TXN_MINT_LIMIT", "50000000000");
        vm.setEnv("MINTER_ALLOWANCE", "500000000000000");
        vm.setEnv("PAUSER_ADDRESS", vm.toString(makeAddr("pauser_sc2")));
        vm.setEnv("UNPAUSER_ADDRESS", vm.toString(makeAddr("unpauser_sc2")));
        vm.setEnv("BLOCKED_ADDRESS_BURNER_ADDRESS", vm.toString(makeAddr("blockedBurner_sc2")));
        vm.setEnv("STABLECOIN_ADMIN", vm.toString(makeAddr("scAdmin_sc2")));

        address firstSc = r2.stablecoin;

        (address secondSc,) = _deployStablecoin(
            r2.authRegistry, r2.reserveLedger, r2.transferPolicyId, address(this)
        );
        address secondHandler =
            _deployTokenHandler(r2.reserveLedger, r2.tokenAuthority);
        _configure(
            r2.reserveLedger, r2.tokenAuthority, secondHandler, secondSc, address(this)
        );
        _handover(r2.reserveLedger, r2.tokenAuthority, secondSc, address(this));

        vm.setEnv("STABLECOIN", vm.toString(secondSc));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));
        (new Verify()).run();

        // First stablecoin should be unaffected
        assertTrue(firstSc != secondSc, "Stablecoins should be at different addresses");

        StablecoinTemplateV3 first = StablecoinTemplateV3(firstSc);
        assertEq(first.name(), "USD Stablecoin");
        assertEq(first.symbol(), "USDB");
        assertEq(first.decimals(), 6);
        assertTrue(
            IAccessControl(firstSc).hasRole(MINTER_ROLE, r2.tokenAuthority),
            "First SC: TokenAuthority should still have MINTER_ROLE"
        );

        TokenAuthority ta = TokenAuthority(r2.tokenAuthority);
        assertEq(ta.getStablecoinTxnMintLimit(firstSc), 100000000000);
        // Minter allowance was reduced by 1_000_000 during the mint smoke test
        assertEq(ta.getMinterAllowance(firstSc, makeAddr("minter")), 999999999999999 - 1_000_000);

        StablecoinTemplateV3 second = StablecoinTemplateV3(secondSc);
        assertEq(second.name(), "EUR Stablecoin");
        assertEq(second.symbol(), "EURB");
        assertEq(ta.getStablecoinTxnMintLimit(secondSc), 50000000000);
        assertEq(ta.getMinterAllowance(secondSc, makeAddr("minter_sc2")), 500000000000000);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Mint / Burn Smoke Test
    //////////////////////////////////////////////////////////////////////////*/

    function _smokeTestMintAndBurn(DeployResult memory result) internal {
        TokenAuthority ta = TokenAuthority(result.tokenAuthority);
        AuthRegistry registry = AuthRegistry(result.authRegistry);
        StablecoinTemplateV3 sc = StablecoinTemplateV3(result.stablecoin);
        StablecoinTemplateV3Base rl = StablecoinTemplateV3Base(result.reserveLedger);

        address minter = makeAddr("minter");
        address recipient = makeAddr("recipient");
        uint256 mintAmount = 1_000_000; // 1 USDB (6 decimals)

        // Whitelist addresses on the transfer policy. address(0) must be
        // whitelisted for ERC20 mint/burn (_update checks both from and to).
        uint64 transferPolicyId = rl.getTransferPolicyId();
        registry.modifyPolicyWhitelist(transferPolicyId, address(0), true);
        registry.modifyPolicyWhitelist(transferPolicyId, recipient, true);
        registry.modifyPolicyWhitelist(transferPolicyId, result.stablecoin, true);
        registry.modifyPolicyWhitelist(transferPolicyId, result.tokenHandler, true);
        registry.modifyPolicyWhitelist(transferPolicyId, result.tokenAuthority, true);

        // Whitelist recipient on SC mint recipient policy
        uint64 scMintPolicyId = sc.getMintRecipientPolicyId();
        registry.modifyPolicyWhitelist(scMintPolicyId, recipient, true);

        // Whitelist handler on RL mint recipient policy
        uint64 rlMintPolicyId = rl.getMintRecipientPolicyId();
        registry.modifyPolicyWhitelist(rlMintPolicyId, result.tokenHandler, true);

        // --- Mint ---
        vm.prank(minter);
        ta.mint(result.stablecoin, recipient, mintAmount);

        assertEq(sc.balanceOf(recipient), mintAmount, "Recipient should hold minted stablecoins");
        assertEq(sc.totalSupply(), mintAmount, "SC total supply should equal minted amount");

        // --- Burn ---
        address burner = makeAddr("burner");
        registry.modifyPolicyWhitelist(transferPolicyId, burner, true);
        IAccessControl(result.tokenAuthority).grantRole(BURNER_ROLE, burner);

        vm.prank(recipient);
        IERC20(result.stablecoin).transfer(burner, mintAmount);

        vm.startPrank(burner);
        IERC20(result.stablecoin).approve(result.tokenAuthority, mintAmount);
        ta.burn(result.stablecoin, mintAmount);
        vm.stopPrank();

        assertEq(sc.balanceOf(burner), 0, "Burner balance should be zero after burn");
        assertEq(sc.totalSupply(), 0, "SC total supply should be zero after burn");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Env Var Helpers
    //////////////////////////////////////////////////////////////////////////*/

    function _setEnvVars(bool deployerIsAdmin) internal {
        address deployer = address(this);

        vm.setEnv("POLICY_ADMIN", vm.toString(deployer));
        vm.setEnv("RL_NAME", "Reserve Ledger Dollar");
        vm.setEnv("RL_SYMBOL", "RD");
        vm.setEnv("RL_DECIMALS", "6");
        vm.setEnv("RL_SALT_NONCE", "0");

        vm.setEnv("STABLECOIN_NAME", "USD Stablecoin");
        vm.setEnv("STABLECOIN_SYMBOL", "USDB");
        vm.setEnv("STABLECOIN_DECIMALS", "6");
        vm.setEnv("SC_SALT_NONCE", "2");

        vm.setEnv("MINTER_ADDRESS", vm.toString(makeAddr("minter")));
        vm.setEnv("TXN_MINT_LIMIT", "100000000000");
        vm.setEnv("MINTER_ALLOWANCE", "999999999999999");

        vm.setEnv("RL_MAX_SUPPLY", "999999999999999");
        vm.setEnv("STABLECOIN_MAX_SUPPLY", "999999999999999");

        vm.setEnv("PAUSER_ADDRESS", vm.toString(makeAddr("pauser")));
        vm.setEnv("UNPAUSER_ADDRESS", vm.toString(makeAddr("unpauser")));
        vm.setEnv("BLOCKED_ADDRESS_BURNER_ADDRESS", vm.toString(makeAddr("blockedBurner")));

        if (deployerIsAdmin) {
            vm.setEnv("RL_ADMIN", vm.toString(deployer));
            vm.setEnv("STABLECOIN_ADMIN", vm.toString(deployer));
            vm.setEnv("TOKEN_AUTHORITY_ADMIN", vm.toString(deployer));
        } else {
            vm.setEnv("RL_ADMIN", vm.toString(makeAddr("rlAdmin")));
            vm.setEnv("STABLECOIN_ADMIN", vm.toString(makeAddr("scAdmin")));
            vm.setEnv("TOKEN_AUTHORITY_ADMIN", vm.toString(makeAddr("taAdmin")));
        }
    }

    function _setVerifyEnvVars(DeployResult memory result) internal {
        vm.setEnv("AUTH_REGISTRY", vm.toString(result.authRegistry));
        vm.setEnv("RESERVE_LEDGER", vm.toString(result.reserveLedger));
        vm.setEnv("TOKEN_AUTHORITY", vm.toString(result.tokenAuthority));
        vm.setEnv("STABLECOIN", vm.toString(result.stablecoin));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));
    }

}
