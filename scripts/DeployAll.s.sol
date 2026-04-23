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
contract DeployAll is Script {

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

    function run() public {
        vm.startBroadcast();
        DeployResult memory result = _execute(msg.sender);
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
    function _execute(address deployer) internal returns (DeployResult memory result) {
        result.authRegistry = _deployAuthRegistry();
        (result.reserveLedger, result.transferPolicyId, result.rlMintPolicyId) =
            _deployReserveLedger(result.authRegistry, deployer);
        result.tokenAuthority = _deployTokenAuthority(result.reserveLedger, deployer);
        result.tokenHandler = _deployTokenHandler(result.reserveLedger, result.tokenAuthority);
        (result.stablecoin, result.scMintPolicyId) = _deployStablecoin(
            result.authRegistry, result.reserveLedger, result.transferPolicyId, deployer
        );

        _configure(
            result.reserveLedger,
            result.tokenAuthority,
            result.tokenHandler,
            result.stablecoin,
            deployer
        );
        _handover(result.reserveLedger, result.tokenAuthority, result.stablecoin, deployer);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Deploy
    //////////////////////////////////////////////////////////////////////////*/

    function _deployAuthRegistry() internal returns (address) {
        AuthRegistry registry = new AuthRegistry{ salt: bytes32(0) }();
        console.log("AuthRegistry deployed at", address(registry));
        return address(registry);
    }

    function _deployReserveLedger(address authRegistry, address deployer)
        internal
        returns (address rlProxy, uint64 transferPolicyId, uint64 rlMintPolicyId)
    {
        address policyAdmin = vm.envAddress("POLICY_ADMIN");

        transferPolicyId = AuthRegistry(authRegistry)
            .createPolicy(policyAdmin, IAuthRegistry.PolicyType.WHITELIST);
        rlMintPolicyId = AuthRegistry(authRegistry)
            .createPolicy(policyAdmin, IAuthRegistry.PolicyType.WHITELIST);

        rlProxy = _deployProxy(
            address(new ReserveLedger(authRegistry)),
            uint96(vm.envUint("RL_SALT_NONCE")),
            vm.envString("RL_NAME"),
            vm.envString("RL_SYMBOL"),
            uint8(vm.envUint("RL_DECIMALS")),
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
        address deployer
    ) internal returns (address scProxy, uint64 scMintPolicyId) {
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
            scMintPolicyId,
            deployer
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
        uint64 mintRecipientPolicyId,
        address deployer
    ) internal returns (address proxy) {
        bytes32 salt = PermissionedSalt.createPermissionedSalt(deployer, saltNonce);
        proxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: salt,
            initialOwner: deployer,
            implementation: implementation,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (name, symbol, decimals, deployer, transferPolicyId, mintRecipientPolicyId)
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
        address deployer
    ) internal {
        _configureRoles(rlProxy, taProxy, scProxy);
        _registerStablecoin(rlProxy, taProxy, handler, scProxy, deployer);
        _configureLimits(taProxy, scProxy, deployer);
        _configureMaxSupply(rlProxy, scProxy);
    }

    function _registerStablecoin(
        address rlProxy,
        address taProxy,
        address handler,
        address scProxy,
        address deployer
    ) internal {
        // Handler needs MINTER_ROLE on RL (to mint reserve tokens) and on SC (to unwrap)
        IAccessControl(rlProxy).grantRole(MINTER_ROLE, handler);
        IAccessControl(scProxy).grantRole(MINTER_ROLE, handler);

        IAccessControl(taProxy).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, deployer);
        TokenAuthority(taProxy).registerStablecoin(scProxy, handler, vm.envUint("TXN_MINT_LIMIT"));
        console.log("Registered stablecoin with handler on TA");
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

    function _configureLimits(address taProxy, address scProxy, address deployer) internal {
        // Deployer grants itself MINT_RATE_LIMIT_SETTER_ROLE temporarily to set limits
        IAccessControl(taProxy).grantRole(MINT_RATE_LIMIT_SETTER_ROLE, deployer);
        TokenAuthority(taProxy)
            .setMinterAllowance(
                scProxy, vm.envAddress("MINTER_ADDRESS"), vm.envUint("MINTER_ALLOWANCE")
            );
        console.log("Set minter allowance on TA");
    }

    function _configureMaxSupply(address rlProxy, address scProxy) internal {
        StablecoinTemplateV3Base(rlProxy).setMaxSupply(vm.envUint("RL_MAX_SUPPLY"));
        StablecoinTemplateV3Base(scProxy).setMaxSupply(vm.envUint("STABLECOIN_MAX_SUPPLY"));
        console.log("Set max supply on RL and SC");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Handover
    //////////////////////////////////////////////////////////////////////////*/

    function _handover(address rlProxy, address taProxy, address scProxy, address deployer)
        internal
    {
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
        IAccessControl(taProxy).grantRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, taAdmin);
        console.log("TA: granted admin roles to", taAdmin);

        // -- Renounce deployer's roles (skip if deployer == final admin) --
        if (taAdmin != deployer) {
            IAccessControl(taProxy).renounceRole(TOKEN_AUTHORITY_HANDLER_SETTER_ROLE, deployer);
            IAccessControl(taProxy).renounceRole(MINT_RATE_LIMIT_SETTER_ROLE, deployer);
            IAccessControl(taProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        if (rlAdmin != deployer) {
            IAccessControl(rlProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        if (scAdmin != deployer) {
            IAccessControl(scProxy).renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        }
        console.log("Deployer handover complete");
    }

}
