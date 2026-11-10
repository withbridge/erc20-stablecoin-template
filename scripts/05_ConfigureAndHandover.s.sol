// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import {
    ReserveLedgerWrappedHandler
} from "src/tokenAuthority/tokenHandler/ReserveLedgerWrappedHandler.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

/**
 * @title ConfigureAndHandover
 * @notice Configures roles and limits on deployed contracts, then hands over
 *         admin to the final admin addresses and renounces the deployer's roles.
 *
 *         Prerequisites: steps 01-04 and 07 must have been run with the deployer as
 *         admin (msg.sender).
 *
 *         This script:
 *         1. Grants MINTER_ROLE on RL and SC to TokenAuthority
 *         2. Grants CONTROLLER_ROLE on the IdempotencyKeyRegistry to TokenAuthority
 *         3. Grants PAUSER, UNPAUSER, BLOCKED_ADDRESS_BURNER roles on SC
 *         4. Grants FORCE_TRANSFER_ROLE on SC to the TokenAuthority's ForceTransferSeizeHandler
 *            (step 07) and registers SC with it as its seize handler
 *         5. Sets txn mint limit and minter allowance on TokenAuthority
 *         6. Sets max supply on RL and SC
 *         7. Grants DEFAULT_ADMIN_ROLE + ownership to final admin addresses
 *         8. Renounces all deployer roles
 */
contract ConfigureAndHandover is Common {

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");
    bytes32 constant FORCE_TRANSFER_ROLE = keccak256("FORCE_TRANSFER_ROLE");
    bytes32 constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function run(
        address reserveLedger,
        address idempotencyKeyRegistry,
        address tokenAuthority,
        address stablecoin,
        address forceTransferSeizeHandler,
        HandoverConfig calldata config
    ) public {
        requireDeployed(reserveLedger, "reserveLedger");
        requireDeployed(idempotencyKeyRegistry, "idempotencyKeyRegistry");
        requireDeployed(tokenAuthority, "tokenAuthority");
        requireDeployed(stablecoin, "stablecoin");
        requireDeployed(forceTransferSeizeHandler, "forceTransferSeizeHandler");

        require(config.rlAdmin != address(0), "rlAdmin is zero");
        require(config.stablecoinAdmin != address(0), "stablecoinAdmin is zero");
        require(config.tokenAuthorityAdmin != address(0), "tokenAuthorityAdmin is zero");

        vm.startBroadcast();

        _configureRoles(reserveLedger, idempotencyKeyRegistry, tokenAuthority, stablecoin, config);
        _deployHandlerAndRegister(
            reserveLedger, tokenAuthority, stablecoin, forceTransferSeizeHandler, config
        );
        _configureLimits(tokenAuthority, stablecoin, config);
        _configureMaxSupply(reserveLedger, stablecoin, config);
        _handover(reserveLedger, idempotencyKeyRegistry, tokenAuthority, stablecoin, config);

        vm.stopBroadcast();
    }

    function _deployHandlerAndRegister(
        address reserveLedger,
        address tokenAuthority,
        address stablecoin,
        address forceTransferSeizeHandler,
        HandoverConfig calldata config
    ) internal {
        address handler = address(new ReserveLedgerWrappedHandler(tokenAuthority));
        console.log("ReserveLedgerWrappedHandler:", handler);

        IAccessControl(reserveLedger).grantRole(MINTER_ROLE, handler);
        IAccessControl(stablecoin).grantRole(MINTER_ROLE, handler);

        // StablecoinTemplateV3 holds its own backing, so it is seized by force transfer. The
        // role is granted now, while the deployer is still the stablecoin's admin.
        IAccessControl(stablecoin).grantRole(FORCE_TRANSFER_ROLE, forceTransferSeizeHandler);

        IAccessControl(tokenAuthority).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, msg.sender);
        TokenAuthority(tokenAuthority)
            .registerStablecoin(stablecoin, handler, forceTransferSeizeHandler, config.txnMintLimit);
        console.log("Registered stablecoin with token and seize handlers on TA");
    }

    function _configureRoles(
        address reserveLedger,
        address idempotencyKeyRegistry,
        address tokenAuthority,
        address stablecoin,
        HandoverConfig calldata config
    ) internal {
        IAccessControl(reserveLedger).grantRole(MINTER_ROLE, tokenAuthority);
        IAccessControl(stablecoin).grantRole(MINTER_ROLE, tokenAuthority);

        // Authorize the TokenAuthority to use keys in the shared registry
        IAccessControl(idempotencyKeyRegistry).grantRole(CONTROLLER_ROLE, tokenAuthority);

        IAccessControl(stablecoin).grantRole(PAUSER_ROLE, config.pauserAddress);
        IAccessControl(stablecoin).grantRole(UNPAUSER_ROLE, config.unpauserAddress);
        IAccessControl(stablecoin)
            .grantRole(BLOCKED_ADDRESS_BURNER_ROLE, config.blockedAddressBurnerAddress);
        console.log("Granted roles on RL and SC");
    }

    function _configureLimits(
        address tokenAuthority,
        address stablecoin,
        HandoverConfig calldata config
    ) internal {
        IAccessControl(tokenAuthority).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
        TokenAuthority(tokenAuthority)
            .setMinterAllowance(stablecoin, config.minterAddress, config.minterAllowance);
        console.log("Set minter allowance on TA");
    }

    function _configureMaxSupply(
        address reserveLedger,
        address stablecoin,
        HandoverConfig calldata config
    ) internal {
        StablecoinTemplateV3Base(reserveLedger).setMaxSupply(config.rlMaxSupply);
        StablecoinTemplateV3Base(stablecoin).setMaxSupply(config.stablecoinMaxSupply);
        console.log("Set max supply on RL and SC");
    }

    function _handover(
        address reserveLedger,
        address idempotencyKeyRegistry,
        address tokenAuthority,
        address stablecoin,
        HandoverConfig calldata config
    ) internal {
        IAccessControl(reserveLedger).grantRole(DEFAULT_ADMIN_ROLE, config.rlAdmin);
        StablecoinTemplateV3Base(reserveLedger).transferOwnership(config.rlAdmin);
        console.log("RL: admin handed over to", config.rlAdmin);

        IAccessControl(stablecoin).grantRole(DEFAULT_ADMIN_ROLE, config.stablecoinAdmin);
        StablecoinTemplateV3Base(stablecoin).transferOwnership(config.stablecoinAdmin);
        console.log("SC: admin handed over to", config.stablecoinAdmin);

        IAccessControl(tokenAuthority).grantRole(DEFAULT_ADMIN_ROLE, config.tokenAuthorityAdmin);
        IAccessControl(tokenAuthority)
            .grantRole(MINT_RATE_LIMIT_SETTER_ROLE, config.tokenAuthorityAdmin);
        IAccessControl(tokenAuthority)
            .grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, config.tokenAuthorityAdmin);
        console.log("TA: admin handed over to", config.tokenAuthorityAdmin);

        // The registry admin controls which controllers may share the key namespace
        IAccessControl(idempotencyKeyRegistry)
            .grantRole(DEFAULT_ADMIN_ROLE, config.tokenAuthorityAdmin);
        console.log("IdempotencyKeyRegistry: admin handed over to", config.tokenAuthorityAdmin);

        if (config.tokenAuthorityAdmin != msg.sender) {
            IAccessControl(tokenAuthority)
                .renounceRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, msg.sender);
            IAccessControl(tokenAuthority).renounceRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
            IAccessControl(tokenAuthority).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
            IAccessControl(idempotencyKeyRegistry).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (config.rlAdmin != msg.sender) {
            IAccessControl(reserveLedger).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (config.stablecoinAdmin != msg.sender) {
            IAccessControl(stablecoin).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        console.log("Deployer handover complete");
    }

}
