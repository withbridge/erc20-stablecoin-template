// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Verify } from "scripts/06_Verify.s.sol";
import { DeployAll } from "scripts/DeployAll.s.sol";

/**
 * @title DeployAllE2ETest
 * @notice End-to-end test that runs the full deployment via DeployAll, then
 *         validates the result with the 06_Verify script. Catches regressions
 *         where deploy scripts and verification drift apart, or where a script
 *         change breaks the deployment flow.
 *
 *         Uses a single test to avoid vm.setEnv leaking between tests (env vars
 *         are process-global in Foundry, not per-test).
 */
contract DeployAllE2ETest is Test, DeployAll {

    function test_fullDeployment_passesVerification() public {
        // --- Scenario 1: deployer != admin (full handover + renunciation) ---
        _setDeploymentEnvVars();

        DeployResult memory result = _execute(address(this));

        vm.setEnv("AUTH_REGISTRY", vm.toString(result.authRegistry));
        vm.setEnv("RESERVE_LEDGER", vm.toString(result.reserveLedger));
        vm.setEnv("TOKEN_AUTHORITY", vm.toString(result.tokenAuthority));
        vm.setEnv("STABLECOIN", vm.toString(result.stablecoin));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));

        Verify verifier = new Verify();
        verifier.run();
    }

    function test_fullDeployment_deployerIsAdmin() public {
        // --- Scenario 2: deployer == admin (renunciation skipped) ---
        _setDeployerIsAdminEnvVars();

        DeployResult memory result = _execute(address(this));

        vm.setEnv("AUTH_REGISTRY", vm.toString(result.authRegistry));
        vm.setEnv("RESERVE_LEDGER", vm.toString(result.reserveLedger));
        vm.setEnv("TOKEN_AUTHORITY", vm.toString(result.tokenAuthority));
        vm.setEnv("STABLECOIN", vm.toString(result.stablecoin));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));

        Verify verifier = new Verify();
        verifier.run();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Env Var Setup
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev All env vars are set explicitly so neither test depends on state
    ///      left behind by the other (vm.setEnv is process-global).
    function _setDeploymentEnvVars() internal {
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

        address minter = makeAddr("minter");
        vm.setEnv("MINTER_ADDRESS", vm.toString(minter));
        vm.setEnv("TXN_MINT_LIMIT", "100000000000");
        vm.setEnv("MINTER_ALLOWANCE", "999999999999999");

        vm.setEnv("RL_MAX_SUPPLY", "999999999999999");
        vm.setEnv("STABLECOIN_MAX_SUPPLY", "999999999999999");

        vm.setEnv("PAUSER_ADDRESS", vm.toString(makeAddr("pauser")));
        vm.setEnv("UNPAUSER_ADDRESS", vm.toString(makeAddr("unpauser")));
        vm.setEnv("BLOCKED_ADDRESS_BURNER_ADDRESS", vm.toString(makeAddr("blockedBurner")));

        // Admin addresses distinct from deployer to test handover + renunciation
        vm.setEnv("RL_ADMIN", vm.toString(makeAddr("rlAdmin")));
        vm.setEnv("STABLECOIN_ADMIN", vm.toString(makeAddr("scAdmin")));
        vm.setEnv("TOKEN_AUTHORITY_ADMIN", vm.toString(makeAddr("taAdmin")));
    }

    function _setDeployerIsAdminEnvVars() internal {
        address deployer = address(this);

        vm.setEnv("POLICY_ADMIN", vm.toString(deployer));
        vm.setEnv("RL_NAME", "Reserve Ledger Dollar");
        vm.setEnv("RL_SYMBOL", "RD");
        vm.setEnv("RL_DECIMALS", "6");
        vm.setEnv("RL_SALT_NONCE", "10");

        vm.setEnv("STABLECOIN_NAME", "USD Stablecoin");
        vm.setEnv("STABLECOIN_SYMBOL", "USDB");
        vm.setEnv("STABLECOIN_DECIMALS", "6");
        vm.setEnv("SC_SALT_NONCE", "12");

        address minter = makeAddr("minter2");
        vm.setEnv("MINTER_ADDRESS", vm.toString(minter));
        vm.setEnv("TXN_MINT_LIMIT", "100000000000");
        vm.setEnv("MINTER_ALLOWANCE", "999999999999999");

        vm.setEnv("RL_MAX_SUPPLY", "999999999999999");
        vm.setEnv("STABLECOIN_MAX_SUPPLY", "999999999999999");

        vm.setEnv("PAUSER_ADDRESS", vm.toString(makeAddr("pauser2")));
        vm.setEnv("UNPAUSER_ADDRESS", vm.toString(makeAddr("unpauser2")));
        vm.setEnv("BLOCKED_ADDRESS_BURNER_ADDRESS", vm.toString(makeAddr("blockedBurner2")));

        // Deployer IS the admin — renunciation should be skipped
        vm.setEnv("RL_ADMIN", vm.toString(deployer));
        vm.setEnv("STABLECOIN_ADMIN", vm.toString(deployer));
        vm.setEnv("TOKEN_AUTHORITY_ADMIN", vm.toString(deployer));
    }

}
