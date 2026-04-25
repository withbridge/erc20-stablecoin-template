// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AuthRegistry } from "auth-registry/src/AuthRegistry.sol";
import { IAuthRegistry } from "auth-registry/src/IAuthRegistry.sol";
import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import {
    ReserveLedgerWrappedHandler
} from "src/tokenAuthority/tokenHandler/ReserveLedgerWrappedHandler.sol";
import { ReserveLedger } from "src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "src/v3/StablecoinTemplateV3Base.sol";

import { Common } from "./Common.s.sol";
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
 *         Execution order: deploy (01->04) -> configure -> handover
 *
 *         The deployer retains DEFAULT_ADMIN_ROLE throughout deployment and
 *         configuration, then hands over admin to the final admin addresses
 *         and renounces its own admin role.
 *
 *         For additional stablecoins on an existing chain, run
 *         04_DeployStablecoin + 05_ConfigureAndHandover separately.
 */
contract DeployAll is Common {

    struct DeployResult {
        address authRegistry;
        address reserveLedger;
        address tokenAuthority;
        address tokenHandler;
        address stablecoin;
        uint64 transferPolicyId;
        uint64 rlMintPolicyId;
        uint64 scMintPolicyId;
    }

    bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 constant BLOCKED_ADDRESS_BURNER_ROLE = keccak256("BLOCKED_ADDRESS_BURNER_ROLE");
    bytes32 constant MINT_RATE_LIMIT_SETTER_ROLE = keccak256("MINT_RATE_LIMIT_SETTER_ROLE");
    bytes32 constant TOKEN_AUTHORITY_HANDLER_SETTER_ROLE =
        keccak256("TOKEN_AUTHORITY_HANDLER_SETTER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function run(
        TokenConfig calldata rlConfig,
        TokenConfig calldata scConfig,
        HandoverConfig calldata handover
    ) public {
        vm.startBroadcast();
        DeployResult memory result = _execute(msg.sender, rlConfig, scConfig, handover);
        vm.stopBroadcast();

        console.log("===== Deployment Complete =====");
        console.log("AuthRegistry:       ", result.authRegistry);
        console.log("ReserveLedger:      ", result.reserveLedger);
        console.log("TokenAuthority:     ", result.tokenAuthority);
        console.log("TokenHandler:       ", result.tokenHandler);
        console.log("Stablecoin:         ", result.stablecoin);
        console.log("Transfer Policy ID: ", uint256(result.transferPolicyId));
        console.log("RL Mint Policy ID:  ", uint256(result.rlMintPolicyId));
        console.log("SC Mint Policy ID:  ", uint256(result.scMintPolicyId));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Execute
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Core deployment logic, separated from run() so tests can call it
    ///      without vm.startBroadcast(). Pass the deployer address explicitly
    ///      since msg.sender semantics differ between script and test contexts.
    function _execute(
        address deployer,
        TokenConfig memory rlConfig,
        TokenConfig memory scConfig,
        HandoverConfig memory handover
    ) internal returns (DeployResult memory result) {
        result.authRegistry = _deployAuthRegistry();
        (result.reserveLedger, result.transferPolicyId, result.rlMintPolicyId) =
            _deployReserveLedger(result.authRegistry, deployer, rlConfig);
        result.tokenAuthority = _deployTokenAuthority(result.reserveLedger, deployer);
        result.tokenHandler = _deployTokenHandler(result.reserveLedger, result.tokenAuthority);
        (result.stablecoin, result.scMintPolicyId) = _deployStablecoin(
            result.authRegistry, result.reserveLedger, result.transferPolicyId, deployer, scConfig
        );

        _configure(
            result.reserveLedger,
            result.tokenAuthority,
            result.tokenHandler,
            result.stablecoin,
            deployer,
            handover
        );
        _handover(
            result.reserveLedger, result.tokenAuthority, result.stablecoin, deployer, handover
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Deploy
    //////////////////////////////////////////////////////////////////////////*/

    function _deployAuthRegistry() internal returns (address) {
        AuthRegistry registry = new AuthRegistry{ salt: bytes32(0) }();
        console.log("AuthRegistry deployed at", address(registry));
        return address(registry);
    }

    function _deployReserveLedger(address authRegistry, address deployer, TokenConfig memory config)
        internal
        returns (address rlProxy, uint64 transferPolicyId, uint64 rlMintPolicyId)
    {
        transferPolicyId = AuthRegistry(authRegistry)
            .createPolicy(config.policyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        rlMintPolicyId = AuthRegistry(authRegistry)
            .createPolicy(config.policyAdmin, IAuthRegistry.PolicyType.WHITELIST);

        rlProxy = _deployProxy(
            address(new ReserveLedger(authRegistry)),
            config,
            transferPolicyId,
            rlMintPolicyId,
            deployer
        );
        console.log("ReserveLedger proxy:", rlProxy);
    }

    function _deployTokenAuthority(address rlProxy, address deployer)
        internal
        returns (address taProxy)
    {
        TokenAuthority taImpl = new TokenAuthority(rlProxy, true);

        taProxy = address(
            new ERC1967Proxy(address(taImpl), abi.encodeCall(TokenAuthority.initialize, (deployer)))
        );
        console.log("TokenAuthority proxy:", taProxy);
    }

    function _deployTokenHandler(address rlProxy, address taProxy)
        internal
        returns (address handler)
    {
        handler = address(new ReserveLedgerWrappedHandler(rlProxy, taProxy));
        console.log("ReserveLedgerWrappedHandler:", handler);
    }

    function _deployStablecoin(
        address authRegistry,
        address rlProxy,
        uint64 transferPolicyId,
        address deployer,
        TokenConfig memory config
    ) internal returns (address scProxy, uint64 scMintPolicyId) {
        scMintPolicyId = AuthRegistry(authRegistry)
            .createPolicy(config.policyAdmin, IAuthRegistry.PolicyType.WHITELIST);

        scProxy = _deployProxy(
            address(new StablecoinTemplateV3(rlProxy, authRegistry)),
            config,
            transferPolicyId,
            scMintPolicyId,
            deployer
        );
        console.log("StablecoinTemplateV3 proxy:", scProxy);
    }

    function _deployProxy(
        address implementation,
        TokenConfig memory config,
        uint64 transferPolicyId,
        uint64 mintRecipientPolicyId,
        address deployer
    ) internal returns (address proxy) {
        bytes32 salt = PermissionedSalt.createPermissionedSalt(deployer, config.saltNonce);
        proxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: deployer,
            implementation: implementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (
                    config.name,
                    config.symbol,
                    config.decimals,
                    deployer,
                    transferPolicyId,
                    mintRecipientPolicyId
                )
            )
        });
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Configure
    //////////////////////////////////////////////////////////////////////////*/

    function _configure(
        address rlProxy,
        address taProxy,
        address handler,
        address scProxy,
        address deployer,
        HandoverConfig memory handover
    ) internal {
        _configureRoles(rlProxy, taProxy, scProxy, handover);
        _registerStablecoin(rlProxy, taProxy, handler, scProxy, deployer, handover);
        _configureLimits(taProxy, scProxy, deployer, handover);
        _configureMaxSupply(rlProxy, scProxy, handover);
    }

    function _registerStablecoin(
        address rlProxy,
        address taProxy,
        address handler,
        address scProxy,
        address deployer,
        HandoverConfig memory handover
    ) internal {
        IAccessControl(rlProxy).grantRole(MINTER_ROLE, handler);
        IAccessControl(scProxy).grantRole(MINTER_ROLE, handler);

        IAccessControl(taProxy).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, deployer);
        TokenAuthority(taProxy).registerStablecoin(scProxy, handler, handover.txnMintLimit);
        console.log("Registered stablecoin with handler on TA");
    }

    function _configureRoles(
        address rlProxy,
        address taProxy,
        address scProxy,
        HandoverConfig memory handover
    ) internal {
        IAccessControl(rlProxy).grantRole(MINTER_ROLE, taProxy);
        IAccessControl(scProxy).grantRole(MINTER_ROLE, taProxy);

        IAccessControl(scProxy).grantRole(PAUSER_ROLE, handover.pauserAddress);
        IAccessControl(scProxy).grantRole(UNPAUSER_ROLE, handover.unpauserAddress);
        IAccessControl(scProxy)
            .grantRole(BLOCKED_ADDRESS_BURNER_ROLE, handover.blockedAddressBurnerAddress);
        console.log("Granted roles on RL and SC");
    }

    function _configureLimits(
        address taProxy,
        address scProxy,
        address deployer,
        HandoverConfig memory handover
    ) internal {
        IAccessControl(taProxy).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, deployer);
        TokenAuthority(taProxy)
            .setMinterAllowance(scProxy, handover.minterAddress, handover.minterAllowance);
        console.log("Set minter allowance on TA");
    }

    function _configureMaxSupply(address rlProxy, address scProxy, HandoverConfig memory handover)
        internal
    {
        StablecoinTemplateV3Base(rlProxy).setMaxSupply(handover.rlMaxSupply);
        StablecoinTemplateV3Base(scProxy).setMaxSupply(handover.stablecoinMaxSupply);
        console.log("Set max supply on RL and SC");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Handover
    //////////////////////////////////////////////////////////////////////////*/

    function _handover(
        address rlProxy,
        address taProxy,
        address scProxy,
        address deployer,
        HandoverConfig memory handover
    ) internal {
        IAccessControl(rlProxy).grantRole(DEFAULT_ADMIN_ROLE, handover.rlAdmin);
        StablecoinTemplateV3Base(rlProxy).transferOwnership(handover.rlAdmin);
        console.log("RL: granted DEFAULT_ADMIN_ROLE and ownership to", handover.rlAdmin);

        IAccessControl(scProxy).grantRole(DEFAULT_ADMIN_ROLE, handover.stablecoinAdmin);
        StablecoinTemplateV3Base(scProxy).transferOwnership(handover.stablecoinAdmin);
        console.log("SC: granted DEFAULT_ADMIN_ROLE and ownership to", handover.stablecoinAdmin);

        IAccessControl(taProxy).grantRole(DEFAULT_ADMIN_ROLE, handover.tokenAuthorityAdmin);
        IAccessControl(taProxy).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, handover.tokenAuthorityAdmin);
        IAccessControl(taProxy)
            .grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, handover.tokenAuthorityAdmin);
        console.log("TA: granted admin roles to", handover.tokenAuthorityAdmin);

        if (handover.tokenAuthorityAdmin != deployer) {
            IAccessControl(taProxy).renounceRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, deployer);
            IAccessControl(taProxy).renounceRole(MINT_RATE_LIMIT_SETTER_ROLE, deployer);
            IAccessControl(taProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        if (handover.rlAdmin != deployer) {
            IAccessControl(rlProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        if (handover.stablecoinAdmin != deployer) {
            IAccessControl(scProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        console.log("Deployer handover complete");
    }

}
