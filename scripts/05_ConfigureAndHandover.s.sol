// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { ReserveLedgerWrappedHandler } from "src/tokenAuthority/tokenHandler/ReserveLedgerWrappedHandler.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

/**
 * @title ConfigureAndHandover
 * @notice Configures roles and limits on deployed contracts, then hands over
 *         admin to the final admin addresses and renounces the deployer's roles.
 *
 *         Prerequisites: steps 01-04 must have been run with the deployer as
 *         admin (msg.sender). All contract addresses must be set in .env.
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

    function _run() internal override {
        address rl = reserveLedgerAddress();
        address ta = tokenAuthorityAddress();
        address sc = stablecoinAddress();
        requireDeployed(rl, "RESERVE_LEDGER");
        requireDeployed(ta, "TOKEN_AUTHORITY");
        requireDeployed(sc, "STABLECOIN");

        vm.startBroadcast();

        _configureRoles(rl, ta, sc);
        _deployHandlerAndRegister(rl, ta, sc);
        _configureLimits(ta, sc);
        _configureMaxSupply(rl, sc);
        _handover(rl, ta, sc);

        vm.stopBroadcast();
    }

    function _deployHandlerAndRegister(address rl, address ta, address sc) internal {
        // Deploy the wrapped handler and register the stablecoin on the TokenAuthority
        address handler = address(new ReserveLedgerWrappedHandler(rl, ta));
        console.log("ReserveLedgerWrappedHandler:", handler);

        // Handler needs MINTER_ROLE on RL (to mint reserve tokens) and on SC (to unwrap)
        IAccessControl(rl).grantRole(MINTER_ROLE, handler);
        IAccessControl(sc).grantRole(MINTER_ROLE, handler);

        IAccessControl(ta).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, msg.sender);
        TokenAuthority(ta).registerStablecoin(sc, handler, vm.envUint("TXN_MINT_LIMIT"));
        console.log("Registered stablecoin with handler on TA");
    }

    function _configureRoles(address rl, address ta, address sc) internal {
        // TokenAuthority needs MINTER_ROLE on RL and SC
        IAccessControl(rl).grantRole(MINTER_ROLE, ta);
        IAccessControl(sc).grantRole(MINTER_ROLE, ta);

        // Operational roles on stablecoin
        IAccessControl(sc).grantRole(PAUSER_ROLE, vm.envAddress("PAUSER_ADDRESS"));
        IAccessControl(sc).grantRole(UNPAUSER_ROLE, vm.envAddress("UNPAUSER_ADDRESS"));
        IAccessControl(sc)
            .grantRole(BLOCKED_ADDRESS_BURNER_ROLE, vm.envAddress("BLOCKED_ADDRESS_BURNER_ADDRESS"));
        console.log("Granted roles on RL and SC");
    }

    function _configureLimits(address ta, address sc) internal {
        // Deployer grants itself MINT_RATE_LIMIT_SETTER_ROLE temporarily
        IAccessControl(ta).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
        TokenAuthority(ta)
            .setMinterAllowance(sc, vm.envAddress("MINTER_ADDRESS"), vm.envUint("MINTER_ALLOWANCE"));
        console.log("Set minter allowance on TA");
    }

    function _configureMaxSupply(address rl, address sc) internal {
        StablecoinTemplateV3Base(rl).setMaxSupply(vm.envUint("RL_MAX_SUPPLY"));
        StablecoinTemplateV3Base(sc).setMaxSupply(vm.envUint("STABLECOIN_MAX_SUPPLY"));
        console.log("Set max supply on RL and SC");
    }

    function _handover(address rl, address ta, address sc) internal {
        address rlAdmin = vm.envAddress("RL_ADMIN");
        address scAdmin = vm.envAddress("STABLECOIN_ADMIN");
        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");

        require(rlAdmin != address(0), "RL_ADMIN not set");
        require(scAdmin != address(0), "STABLECOIN_ADMIN not set");
        require(taAdmin != address(0), "TOKEN_AUTHORITY_ADMIN not set");

        // Grant admin to final addresses
        IAccessControl(rl).grantRole(DEFAULT_ADMIN_ROLE, rlAdmin);
        StablecoinTemplateV3Base(rl).transferOwnership(rlAdmin);
        console.log("RL: admin handed over to", rlAdmin);

        IAccessControl(sc).grantRole(DEFAULT_ADMIN_ROLE, scAdmin);
        StablecoinTemplateV3Base(sc).transferOwnership(scAdmin);
        console.log("SC: admin handed over to", scAdmin);

        IAccessControl(ta).grantRole(DEFAULT_ADMIN_ROLE, taAdmin);
        IAccessControl(ta).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, taAdmin);
        IAccessControl(ta).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, taAdmin);
        console.log("TA: admin handed over to", taAdmin);

        // Renounce deployer's roles (skip if deployer == final admin)
        if (taAdmin != msg.sender) {
            IAccessControl(ta).renounceRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, msg.sender);
            IAccessControl(ta).renounceRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
            IAccessControl(ta).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (rlAdmin != msg.sender) {
            IAccessControl(rl).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (scAdmin != msg.sender) {
            IAccessControl(sc).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        console.log("Deployer handover complete");
    }

}
