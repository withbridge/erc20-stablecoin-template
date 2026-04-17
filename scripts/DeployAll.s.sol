// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

import { PermissionedSalt } from "deterministic-proxy-factory/PermissionedSalt.sol";
import {
    DeterministicProxyFactoryFixture
} from "deterministic-proxy-factory/fixtures/DeterministicProxyFactoryFixture.sol";

/**
 * @title DeployAll
 * @notice Orchestrates a full greenfield deployment: AuthRegistry, ReserveLedger,
 *         TokenAuthority, and one stablecoin, followed by role configuration and
 *         admin handover.
 *
 *         Execution order: deploy (01→04) → configure → handover
 *
 *         The deployer retains DEFAULT_ADMIN_ROLE throughout deployment and
 *         configuration, then hands over admin to the final admin addresses
 *         and renounces its own admin role.
 *
 *         For additional stablecoins on an existing chain, run
 *         04_DeployStablecoin + 05_ConfigureAndHandover separately.
 */
contract DeployAll is Script {

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");
    bytes32 constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function run() public {
        vm.startBroadcast();

        // ── Deploy
        // ──────────────────────────────────────────────────
        address authRegistry = _deployAuthRegistry();
        (address rlProxy, uint64 transferPolicyId, uint64 rlMintPolicyId) =
            _deployReserveLedger(authRegistry);
        address taProxy = _deployTokenAuthority(rlProxy);
        (address scProxy, uint64 scMintPolicyId) =
            _deployStablecoin(authRegistry, rlProxy, transferPolicyId);

        // ── Configure
        // ───────────────────────────────────────────────
        _configure(rlProxy, taProxy, scProxy);

        // ── Handover
        // ────────────────────────────────────────────────
        _handover(rlProxy, taProxy, scProxy);

        vm.stopBroadcast();

        console.log("===== Deployment Complete =====");
        console.log("AuthRegistry:       ", authRegistry);
        console.log("ReserveLedger:      ", rlProxy);
        console.log("TokenAuthority:     ", taProxy);
        console.log("Stablecoin:         ", scProxy);
        console.log("Transfer Policy ID: ", uint256(transferPolicyId));
        console.log("RL Mint Policy ID:  ", uint256(rlMintPolicyId));
        console.log("SC Mint Policy ID:  ", uint256(scMintPolicyId));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Deploy
    //////////////////////////////////////////////////////////////////////////*/

    function _deployAuthRegistry() internal returns (address) {
        AuthRegistry registry = new AuthRegistry{ salt: bytes32(0) }();
        console.log("AuthRegistry deployed at", address(registry));
        return address(registry);
    }

    function _deployReserveLedger(address authRegistry)
        internal
        returns (address rlProxy, uint64 transferPolicyId, uint64 rlMintPolicyId)
    {
        address policyAdmin = vm.envAddress("POLICY_ADMIN");

        transferPolicyId = AuthRegistry(authRegistry)
            .createPolicy(policyAdmin, IAuthRegistry.PolicyType.BLACKLIST);
        rlMintPolicyId = AuthRegistry(authRegistry)
            .createPolicy(policyAdmin, IAuthRegistry.PolicyType.WHITELIST);

        rlProxy = _deployProxy(
            address(new ReserveLedger(authRegistry)),
            uint96(vm.envUint("RL_SALT_NONCE")),
            vm.envString("RL_NAME"),
            vm.envString("RL_SYMBOL"),
            uint8(vm.envUint("RL_DECIMALS")),
            transferPolicyId,
            rlMintPolicyId
        );
        console.log("ReserveLedger proxy:", rlProxy);
    }

    function _deployTokenAuthority(address rlProxy) internal returns (address taProxy) {
        TokenAuthority taImpl = new TokenAuthority(rlProxy, true);

        taProxy = address(
            new ERC1967Proxy(
                address(taImpl), abi.encodeCall(TokenAuthority.initialize, (msg.sender))
            )
        );
        console.log("TokenAuthority proxy:", taProxy);
    }

    function _deployStablecoin(address authRegistry, address rlProxy, uint64 transferPolicyId)
        internal
        returns (address scProxy, uint64 scMintPolicyId)
    {
        address policyAdmin = vm.envAddress("POLICY_ADMIN");

        scMintPolicyId = AuthRegistry(authRegistry)
            .createPolicy(policyAdmin, IAuthRegistry.PolicyType.WHITELIST);

        scProxy = _deployProxy(
            address(new StablecoinTemplateV3(rlProxy, authRegistry)),
            uint96(vm.envUint("SC_SALT_NONCE")),
            vm.envString("STABLECOIN_NAME"),
            vm.envString("STABLECOIN_SYMBOL"),
            uint8(vm.envUint("STABLECOIN_DECIMALS")),
            transferPolicyId,
            scMintPolicyId
        );
        console.log("StablecoinTemplateV3 proxy:", scProxy);
    }

    function _deployProxy(
        address implementation,
        uint96 saltNonce,
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint64 transferPolicyId,
        uint64 mintRecipientPolicyId
    ) internal returns (address proxy) {
        bytes32 salt = PermissionedSalt.createPermissionedSalt(msg.sender, saltNonce);
        proxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: msg.sender,
            implementation: implementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (name, symbol, decimals, msg.sender, transferPolicyId, mintRecipientPolicyId)
            )
        });
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Configure
    //////////////////////////////////////////////////////////////////////////*/

    function _configure(address rlProxy, address taProxy, address scProxy) internal {
        _configureRoles(rlProxy, taProxy, scProxy);
        _configureLimits(taProxy, scProxy);
        _configureMaxSupply(rlProxy, scProxy);
    }

    function _configureRoles(address rlProxy, address taProxy, address scProxy) internal {
        // TokenAuthority needs MINTER_ROLE on RL and SC
        IAccessControl(rlProxy).grantRole(MINTER_ROLE, taProxy);
        IAccessControl(scProxy).grantRole(MINTER_ROLE, taProxy);

        // Operational roles on stablecoin
        IAccessControl(scProxy).grantRole(PAUSER_ROLE, vm.envAddress("PAUSER_ADDRESS"));
        IAccessControl(scProxy).grantRole(UNPAUSER_ROLE, vm.envAddress("UNPAUSER_ADDRESS"));
        IAccessControl(scProxy)
            .grantRole(BLOCKED_ADDRESS_BURNER_ROLE, vm.envAddress("BLOCKED_ADDRESS_BURNER_ADDRESS"));
        console.log("Granted roles on RL and SC");
    }

    function _configureLimits(address taProxy, address scProxy) internal {
        // Deployer grants itself MINT_RATE_LIMIT_SETTER_ROLE temporarily to set limits
        IAccessControl(taProxy).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
        TokenAuthority(taProxy).setTxnMintLimit(scProxy, vm.envUint("TXN_MINT_LIMIT"));
        TokenAuthority(taProxy)
            .setMinterAllowance(
                scProxy, vm.envAddress("MINTER_ADDRESS"), vm.envUint("MINTER_ALLOWANCE")
            );
        console.log("Set txn mint limit and minter allowance on TA");
    }

    function _configureMaxSupply(address rlProxy, address scProxy) internal {
        StablecoinTemplateV3Base(rlProxy).setMaxSupply(vm.envUint("RL_MAX_SUPPLY"));
        StablecoinTemplateV3Base(scProxy).setMaxSupply(vm.envUint("STABLECOIN_MAX_SUPPLY"));
        console.log("Set max supply on RL and SC");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Handover
    //////////////////////////////////////////////////////////////////////////*/

    function _handover(address rlProxy, address taProxy, address scProxy) internal {
        address rlAdmin = vm.envAddress("RL_ADMIN");
        address scAdmin = vm.envAddress("STABLECOIN_ADMIN");
        address taAdmin = vm.envAddress("TOKEN_AUTHORITY_ADMIN");

        require(rlAdmin != address(0), "RL_ADMIN not set");
        require(scAdmin != address(0), "STABLECOIN_ADMIN not set");
        require(taAdmin != address(0), "TOKEN_AUTHORITY_ADMIN not set");

        // -- Grant admin to final addresses --
        IAccessControl(rlProxy).grantRole(DEFAULT_ADMIN_ROLE, rlAdmin);
        StablecoinTemplateV3Base(rlProxy).transferOwnership(rlAdmin);
        console.log("RL: granted DEFAULT_ADMIN_ROLE and ownership to", rlAdmin);

        IAccessControl(scProxy).grantRole(DEFAULT_ADMIN_ROLE, scAdmin);
        StablecoinTemplateV3Base(scProxy).transferOwnership(scAdmin);
        console.log("SC: granted DEFAULT_ADMIN_ROLE and ownership to", scAdmin);

        IAccessControl(taProxy).grantRole(DEFAULT_ADMIN_ROLE, taAdmin);
        IAccessControl(taProxy).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, taAdmin);
        console.log("TA: granted DEFAULT_ADMIN_ROLE and MINT_RATE_LIMIT_SETTER_ROLE to", taAdmin);

        // -- Renounce deployer's roles (skip if deployer == final admin) --
        if (taAdmin != msg.sender) {
            IAccessControl(taProxy).renounceRole(MINT_RATE_LIMIT_SETTER_ROLE, msg.sender);
            IAccessControl(taProxy).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (rlAdmin != msg.sender) {
            IAccessControl(rlProxy).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (scAdmin != msg.sender) {
            IAccessControl(scProxy).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        console.log("Deployer handover complete");
    }

}
