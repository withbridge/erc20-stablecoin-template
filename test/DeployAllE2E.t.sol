// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";
import { Test } from "forge-std/Test.sol";
import { Verify } from "scripts/06_Verify.s.sol";
import { DeploySeizeHandlers } from "scripts/07_DeploySeizeHandlers.s.sol";
import { DeployAll } from "scripts/DeployAll.s.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { ISeizeHandler } from "src/tokenAuthority/seizeHandler/ISeizeHandler.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

/**
 * @title DeployAllE2ETest
 * @notice End-to-end test for the full deployment via DeployAll.
 *
 *         Scenarios covered:
 *         1. Deployer != admin: full handover + renunciation
 *         2. Deployer == admin: renunciation skipped
 *         3. Mint→burn round-trip through the TokenAuthority
 *         4. Adding a second stablecoin to existing infrastructure
 *         5. Seize end to end: the stablecoin DeployAll registered with its seize handler, and
 *            a TokenAuthority given new handlers by 07_DeploySeizeHandlers
 */
contract DeployAllE2ETest is Test, DeployAll {

    bytes32 constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 constant SEIZER_ROLE = keccak256("SEIZER_ROLE");

    function test_fullDeployment() public {
        // ================================================================
        // Scenario 1: deployer != admin (full handover + renunciation)
        // ================================================================
        uint256 snap = vm.snapshotState();

        TokenConfig memory rlConfig = _defaultRlConfig();
        TokenConfig memory scConfig = _defaultScConfig();
        HandoverConfig memory handover = _handoverConfig(false);

        DeployResult memory r1 = _execute(address(this), rlConfig, scConfig, handover);
        _setVerifyEnvVars(r1, handover);
        (new Verify()).run();

        vm.revertToState(snap);

        // ================================================================
        // Scenario 2: deployer == admin + mint/burn + second stablecoin
        // ================================================================
        handover = _handoverConfig(true);

        DeployResult memory r2 = _execute(address(this), rlConfig, scConfig, handover);
        _setVerifyEnvVars(r2, handover);
        (new Verify()).run();

        // --- Mint and burn smoke test ---
        _smokeTestMintAndBurn(r2);

        // --- Add a second stablecoin ---
        TokenConfig memory sc2Config = TokenConfig({
            name: "EUR Stablecoin",
            symbol: "EURB",
            decimals: 6,
            policyAdmin: address(this),
            saltNonce: 50
        });
        HandoverConfig memory handover2 = HandoverConfig({
            txnMintLimit: 50_000_000_000,
            minterAddress: makeAddr("minter_sc2"),
            minterAllowance: 500_000_000_000_000,
            rlMaxSupply: 999_999_999_999_999,
            stablecoinMaxSupply: 500_000_000_000_000,
            pauserAddress: makeAddr("pauser_sc2"),
            unpauserAddress: makeAddr("unpauser_sc2"),
            blockedAddressBurnerAddress: makeAddr("blockedBurner_sc2"),
            rlAdmin: address(this),
            stablecoinAdmin: makeAddr("scAdmin_sc2"),
            tokenAuthorityAdmin: address(this)
        });

        address firstSc = r2.stablecoin;

        (address secondSc,) = _deployStablecoin(
            r2.authRegistry, r2.reserveLedger, r2.transferPolicyId, address(this), sc2Config
        );
        address secondHandler = _deployTokenHandler(r2.reserveLedger, r2.tokenAuthority);
        _configure(
            r2.reserveLedger,
            r2.idempotencyKeyRegistry,
            r2.tokenAuthority,
            secondHandler,
            r2.seizeHandlers.forceTransferSeizeHandler,
            secondSc,
            address(this),
            handover2
        );
        _handover(
            r2.reserveLedger,
            r2.idempotencyKeyRegistry,
            r2.tokenAuthority,
            secondSc,
            address(this),
            handover2
        );

        vm.setEnv("STABLECOIN", vm.toString(secondSc));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));
        vm.setEnv("STABLECOIN_NAME", sc2Config.name);
        vm.setEnv("STABLECOIN_SYMBOL", sc2Config.symbol);
        vm.setEnv("STABLECOIN_DECIMALS", vm.toString(sc2Config.decimals));
        vm.setEnv("STABLECOIN_MAX_SUPPLY", vm.toString(handover2.stablecoinMaxSupply));
        vm.setEnv("STABLECOIN_ADMIN", vm.toString(handover2.stablecoinAdmin));
        vm.setEnv("TXN_MINT_LIMIT", vm.toString(handover2.txnMintLimit));
        vm.setEnv("MINTER_ADDRESS", vm.toString(handover2.minterAddress));
        vm.setEnv("MINTER_ALLOWANCE", vm.toString(handover2.minterAllowance));
        vm.setEnv("PAUSER_ADDRESS", vm.toString(handover2.pauserAddress));
        vm.setEnv("UNPAUSER_ADDRESS", vm.toString(handover2.unpauserAddress));
        vm.setEnv(
            "BLOCKED_ADDRESS_BURNER_ADDRESS", vm.toString(handover2.blockedAddressBurnerAddress)
        );
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
        assertEq(ta.getStablecoinTxnMintLimit(firstSc), 100_000_000_000);
        // Minter allowance was reduced by 1_000_000 during the mint smoke test
        assertEq(
            ta.getMinterAllowance(firstSc, makeAddr("minter")), 999_999_999_999_999 - 1_000_000
        );

        StablecoinTemplateV3 second = StablecoinTemplateV3(secondSc);
        assertEq(second.name(), "EUR Stablecoin");
        assertEq(second.symbol(), "EURB");
        assertEq(ta.getStablecoinTxnMintLimit(secondSc), 50_000_000_000);
        assertEq(ta.getMinterAllowance(secondSc, makeAddr("minter_sc2")), 500_000_000_000_000);
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

        _allowMintTo(result, recipient);
        uint64 transferPolicyId = rl.getTransferPolicyId();

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

    /// @dev Whitelists everything a wrapped-handler mint to `recipient` touches. DeployAll gives
    ///      the reserve ledger and the stablecoin one shared WHITELIST transfer policy.
    function _allowMintTo(DeployResult memory result, address recipient) internal {
        AuthRegistry registry = AuthRegistry(result.authRegistry);
        StablecoinTemplateV3Base rl = StablecoinTemplateV3Base(result.reserveLedger);
        StablecoinTemplateV3 sc = StablecoinTemplateV3(result.stablecoin);

        uint64 transferPolicyId = rl.getTransferPolicyId();
        registry.modifyPolicyWhitelist(transferPolicyId, address(0), true);
        registry.modifyPolicyWhitelist(transferPolicyId, recipient, true);
        registry.modifyPolicyWhitelist(transferPolicyId, result.stablecoin, true);
        registry.modifyPolicyWhitelist(transferPolicyId, result.tokenHandler, true);
        registry.modifyPolicyWhitelist(transferPolicyId, result.tokenAuthority, true);

        registry.modifyPolicyWhitelist(sc.getMintRecipientPolicyId(), recipient, true);
        registry.modifyPolicyWhitelist(rl.getMintRecipientPolicyId(), result.tokenHandler, true);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            Seize Handlers Deployment
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev DeployAll deploys the seize handlers and registers the stablecoin with the
    ///      ForceTransferSeizeHandler, so only the Seizure Wallet list and SEIZER_ROLE remain.
    function test_seizeEndToEnd_stablecoinRegisteredWithSeizeHandler() public {
        // deployer == admin, so this contract can act as every admin below
        DeployResult memory result =
            _execute(address(this), _defaultRlConfig(), _defaultScConfig(), _handoverConfig(true));
        address forceTransferSeizeHandler = result.seizeHandlers.forceTransferSeizeHandler;

        assertEq(
            TokenAuthority(result.tokenAuthority).getSeizeHandler(result.stablecoin),
            forceTransferSeizeHandler,
            "stablecoin registered with the force-transfer seize handler"
        );
        _assertBuiltFor(result.seizeHandlers, result.tokenAuthority);

        _seizeFromFrozenHolder(result);
    }

    /// @dev Runs 07_DeploySeizeHandlers on its own, as for a TokenAuthority that predates seize,
    ///      and moves an already-registered stablecoin onto the new handler with setSeizeHandler.
    function test_deploySeizeHandlersScript_existingStablecoin() public {
        DeployResult memory result =
            _execute(address(this), _defaultRlConfig(), _defaultScConfig(), _handoverConfig(true));
        TokenAuthority ta = TokenAuthority(result.tokenAuthority);
        StablecoinTemplateV3 sc = StablecoinTemplateV3(result.stablecoin);

        // --- Deploy the seize handlers with the script's real entry point ---
        SeizeHandlers memory seizeHandlers = (new DeploySeizeHandlers()).run(result.tokenAuthority);
        _assertBuiltFor(seizeHandlers, result.tokenAuthority);

        // --- Move the stablecoin onto them, as its admin and the TokenAuthority admin would ---
        // FORCE_TRANSFER_ROLE must keep exactly one holder, so the old handler loses it.
        sc.revokeRole(FORCE_TRANSFER_ROLE, result.seizeHandlers.forceTransferSeizeHandler);
        sc.grantRole(FORCE_TRANSFER_ROLE, seizeHandlers.forceTransferSeizeHandler);
        ta.setSeizeHandler(result.stablecoin, seizeHandlers.forceTransferSeizeHandler);

        assertEq(
            ta.getSeizeHandler(result.stablecoin),
            seizeHandlers.forceTransferSeizeHandler,
            "seize handler moved"
        );
        assertEq(sc.getRoleMemberCount(FORCE_TRANSFER_ROLE), 1, "one force-transfer holder");

        _seizeFromFrozenHolder(result);
    }

    function _assertBuiltFor(SeizeHandlers memory seizeHandlers, address tokenAuthority)
        internal
        view
    {
        assertEq(
            ISeizeHandler(seizeHandlers.forceTransferSeizeHandler).TOKEN_AUTHORITY(),
            tokenAuthority,
            "force-transfer handler built for this TA"
        );
        assertEq(
            ISeizeHandler(seizeHandlers.burnAndRemintSeizeHandler).TOKEN_AUTHORITY(),
            tokenAuthority,
            "burn-and-re-mint handler built for this TA"
        );
    }

    /// @dev Sets the Seizure Wallet list and SEIZER_ROLE (the steps no script does), funds and
    ///      freezes a holder, then seizes part of its balance through the TokenAuthority.
    function _seizeFromFrozenHolder(DeployResult memory result) internal {
        TokenAuthority ta = TokenAuthority(result.tokenAuthority);
        StablecoinTemplateV3 sc = StablecoinTemplateV3(result.stablecoin);
        AuthRegistry registry = AuthRegistry(result.authRegistry);
        address seizer = makeAddr("seizer");
        address seizureWallet = makeAddr("seizureWallet");
        address holder = makeAddr("holder");

        // --- Seizure List Authority and TokenAuthority admin setup ---
        uint64 seizureWalletPolicyId =
            registry.createPolicy(address(this), IAuthRegistry.PolicyType.WHITELIST);
        registry.modifyPolicyWhitelist(seizureWalletPolicyId, seizureWallet, true);
        // The list lives in the stablecoin's seize handler; the TokenAuthority admin sets it.
        ISeizeHandler(ta.getSeizeHandler(result.stablecoin))
            .setSeizureWalletPolicyId(seizureWalletPolicyId);
        ta.grantRole(SEIZER_ROLE, seizer);

        // --- Fund the holder, then freeze it ---
        _allowMintTo(result, holder);
        uint64 transferPolicyId = sc.getTransferPolicyId();
        // The Seizure Wallet must not be frozen: forceTransfer rejects a blocked destination.
        registry.modifyPolicyWhitelist(transferPolicyId, seizureWallet, true);
        vm.prank(makeAddr("minter"));
        ta.mint(result.stablecoin, holder, 1_000_000);
        // On DeployAll's WHITELIST transfer policy, freezing means removing the holder from it.
        registry.modifyPolicyWhitelist(transferPolicyId, holder, false);
        assertTrue(sc.isBlocked(holder), "holder frozen");

        uint256 totalSupplyBefore = sc.totalSupply();
        uint256 backingBefore = IERC20(result.reserveLedger).balanceOf(result.stablecoin);

        // --- Seize ---
        vm.prank(seizer);
        ta.seize(result.stablecoin, holder, seizureWallet, 600_000);

        assertEq(sc.balanceOf(holder), 400_000, "holder keeps the unseized remainder");
        assertEq(sc.balanceOf(seizureWallet), 600_000, "Seizure Wallet receives the seized amount");
        assertEq(sc.totalSupply(), totalSupplyBefore, "supply unchanged");
        assertEq(
            IERC20(result.reserveLedger).balanceOf(result.stablecoin),
            backingBefore,
            "reserve backing stays inside the coin"
        );
        assertTrue(sc.isBlocked(holder), "holder still frozen");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                Config Helpers
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultRlConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "Reserve Ledger Dollar",
            symbol: "RD",
            decimals: 6,
            policyAdmin: address(this),
            saltNonce: 0
        });
    }

    function _defaultScConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "USD Stablecoin",
            symbol: "USDB",
            decimals: 6,
            policyAdmin: address(this),
            saltNonce: 2
        });
    }

    function _handoverConfig(bool deployerIsAdmin) internal returns (HandoverConfig memory) {
        return HandoverConfig({
            txnMintLimit: 100_000_000_000,
            minterAddress: makeAddr("minter"),
            minterAllowance: 999_999_999_999_999,
            rlMaxSupply: 999_999_999_999_999,
            stablecoinMaxSupply: 999_999_999_999_999,
            pauserAddress: makeAddr("pauser"),
            unpauserAddress: makeAddr("unpauser"),
            blockedAddressBurnerAddress: makeAddr("blockedBurner"),
            rlAdmin: deployerIsAdmin ? address(this) : makeAddr("rlAdmin"),
            stablecoinAdmin: deployerIsAdmin ? address(this) : makeAddr("scAdmin"),
            tokenAuthorityAdmin: deployerIsAdmin ? address(this) : makeAddr("taAdmin")
        });
    }

    function _setVerifyEnvVars(DeployResult memory result, HandoverConfig memory handover)
        internal
    {
        vm.setEnv("AUTH_REGISTRY", vm.toString(result.authRegistry));
        vm.setEnv("RESERVE_LEDGER", vm.toString(result.reserveLedger));
        vm.setEnv("IDEMPOTENCY_KEY_REGISTRY", vm.toString(result.idempotencyKeyRegistry));
        vm.setEnv("TOKEN_AUTHORITY", vm.toString(result.tokenAuthority));
        vm.setEnv("STABLECOIN", vm.toString(result.stablecoin));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(this)));

        // Config vars read by Verify
        vm.setEnv("RL_NAME", "Reserve Ledger Dollar");
        vm.setEnv("RL_SYMBOL", "RD");
        vm.setEnv("RL_DECIMALS", "6");
        vm.setEnv("RL_MAX_SUPPLY", vm.toString(handover.rlMaxSupply));
        vm.setEnv("RL_ADMIN", vm.toString(handover.rlAdmin));

        vm.setEnv("STABLECOIN_NAME", "USD Stablecoin");
        vm.setEnv("STABLECOIN_SYMBOL", "USDB");
        vm.setEnv("STABLECOIN_DECIMALS", "6");
        vm.setEnv("STABLECOIN_MAX_SUPPLY", vm.toString(handover.stablecoinMaxSupply));
        vm.setEnv("STABLECOIN_ADMIN", vm.toString(handover.stablecoinAdmin));
        vm.setEnv("TOKEN_AUTHORITY_ADMIN", vm.toString(handover.tokenAuthorityAdmin));

        vm.setEnv("TXN_MINT_LIMIT", vm.toString(handover.txnMintLimit));
        vm.setEnv("MINTER_ADDRESS", vm.toString(handover.minterAddress));
        vm.setEnv("MINTER_ALLOWANCE", vm.toString(handover.minterAllowance));
        vm.setEnv("PAUSER_ADDRESS", vm.toString(handover.pauserAddress));
        vm.setEnv("UNPAUSER_ADDRESS", vm.toString(handover.unpauserAddress));
        vm.setEnv(
            "BLOCKED_ADDRESS_BURNER_ADDRESS", vm.toString(handover.blockedAddressBurnerAddress)
        );
    }

}
