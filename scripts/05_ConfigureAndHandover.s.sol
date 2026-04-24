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
 *         Prerequisites: steps 01-04 must have been run with the deployer as
 *         admin (msg.sender).
 *
 *         This script:
 *         1. Grants MINTER_ROLE on RL and SC to TokenAuthority
 *         2. Grants PAUSER, UNPAUSER, BLOCKED_ADDRESS_BURNER roles on SC
 *         3. Sets txn mint limit and minter allowance on TokenAuthority
 *         4. Sets max supply on RL and SC
 *         5. Grants DEFAULT_ADMIN_ROLE + ownership to final admin addresses
 *         6. Renounces all deployer roles
 */
contract ConfigureAndHandover is Common {

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");
    bytes32 constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function run(
        address reserveLedger,
        address tokenAuthority,
        address stablecoin,
        HandoverConfig calldata config
    ) public {
        requireDeployed(reserveLedger, "reserveLedger");
        requireDeployed(tokenAuthority, "tokenAuthority");
        requireDeployed(stablecoin, "stablecoin");

        require(config.rlAdmin != address(0), "rlAdmin is zero");
        require(config.stablecoinAdmin != address(0), "stablecoinAdmin is zero");
        require(config.tokenAuthorityAdmin != address(0), "tokenAuthorityAdmin is zero");

        vm.startBroadcast();

        _configureRoles(reserveLedger, tokenAuthority, stablecoin, config);
        _deployHandlerAndRegister(reserveLedger, tokenAuthority, stablecoin, config);
        _configureLimits(tokenAuthority, stablecoin, config);
        _configureMaxSupply(reserveLedger, stablecoin, config);
        _handover(reserveLedger, tokenAuthority, stablecoin, config);

        vm.stopBroadcast();
    }

    function _deployHandlerAndRegister(
        address rl,
        address ta,
        address sc,
        HandoverConfig calldata config
    ) internal {
        address handler = address(new ReserveLedgerWrappedHandler(rl, ta));
        console.log("ReserveLedgerWrappedHandler:", handler);

        IAccessControl(rl).grantRole(MINTER_ROLE, handler);
        IAccessControl(sc).grantRole(MINTER_ROLE, handler);

        IAccessControl(ta).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, msg.sender);
        TokenAuthority(ta).registerStablecoin(sc, handler, config.txnMintLimit);
        console.log("Registered stablecoin with handler on TA");
    }

    function _configureRoles(address rl, address ta, address sc, HandoverConfig calldata config)
        internal
    {
        IAccessControl(rl).grantRole(MINTER_ROLE, ta);
        IAccessControl(sc).grantRole(MINTER_ROLE, ta);

        IAccessControl(sc).grantRole(PAUSER_ROLE, config.pauserAddress);
        IAccessControl(sc).grantRole(UNPAUSER_ROLE, config.unpauserAddress);
        IAccessControl(sc)
            .grantRole(BLOCKED_ADDRESS_BURNER_ROLE, config.blockedAddressBurnerAddress);
        console.log("Granted roles on RL and SC");
    }

    function _configureLimits(address ta, address sc, HandoverConfig calldata config) internal {
        IAccessControl(ta).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
        TokenAuthority(ta).setMinterAllowance(sc, config.minterAddress, config.minterAllowance);
        console.log("Set minter allowance on TA");
    }

    function _configureMaxSupply(address rl, address sc, HandoverConfig calldata config) internal {
        StablecoinTemplateV3Base(rl).setMaxSupply(config.rlMaxSupply);
        StablecoinTemplateV3Base(sc).setMaxSupply(config.stablecoinMaxSupply);
        console.log("Set max supply on RL and SC");
    }

    function _handover(address rl, address ta, address sc, HandoverConfig calldata config)
        internal
    {
        IAccessControl(rl).grantRole(DEFAULT_ADMIN_ROLE, config.rlAdmin);
        StablecoinTemplateV3Base(rl).transferOwnership(config.rlAdmin);
        console.log("RL: admin handed over to", config.rlAdmin);

        IAccessControl(sc).grantRole(DEFAULT_ADMIN_ROLE, config.stablecoinAdmin);
        StablecoinTemplateV3Base(sc).transferOwnership(config.stablecoinAdmin);
        console.log("SC: admin handed over to", config.stablecoinAdmin);

        IAccessControl(ta).grantRole(DEFAULT_ADMIN_ROLE, config.tokenAuthorityAdmin);
        IAccessControl(ta).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, config.tokenAuthorityAdmin);
        IAccessControl(ta)
            .grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, config.tokenAuthorityAdmin);
        console.log("TA: admin handed over to", config.tokenAuthorityAdmin);

        if (config.tokenAuthorityAdmin != msg.sender) {
            IAccessControl(ta).renounceRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, msg.sender);
            IAccessControl(ta).renounceRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
            IAccessControl(ta).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (config.rlAdmin != msg.sender) {
            IAccessControl(rl).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (config.stablecoinAdmin != msg.sender) {
            IAccessControl(sc).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        console.log("Deployer handover complete");
    }

}
