// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

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
 *         TokenAuthority, and one stablecoin. For additional stablecoins, run
 *         04_DeployStablecoin + 05b_ConfigureStablecoin separately.
 *
 *         Execution order: 01 -> 02 -> 03 -> 05a -> 04 -> 05b
 *
 *         This sends multiple transactions within a single vm.startBroadcast()
 *         block — not a single atomic transaction.
 */
contract DeployAll is Script {

    function run() public {
        vm.startBroadcast();

        address authRegistry = _deployAuthRegistry();
        (address rlProxy, uint64 transferPolicyId, uint64 rlMintPolicyId) =
            _deployReserveLedger(authRegistry);
        address taProxy = _deployTokenAuthority(rlProxy);
        _configureReserveLedger(authRegistry, rlProxy, taProxy, rlMintPolicyId);
        (address scProxy, uint64 scMintPolicyId) =
            _deployStablecoin(authRegistry, rlProxy, transferPolicyId);
        _configureStablecoin(authRegistry, scProxy, taProxy, scMintPolicyId);

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

        address rlImpl = address(new ReserveLedger(authRegistry));

        uint96 saltNonce = uint96(vm.envUint("RL_SALT_NONCE"));
        rlProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: PermissionedSalt.createPermissionedSalt(msg.sender, saltNonce),
            initialOwner: msg.sender,
            implementation: rlImpl,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (
                    vm.envString("RL_NAME"),
                    vm.envString("RL_SYMBOL"),
                    uint8(vm.envUint("RL_DECIMALS")),
                    vm.envAddress("RL_ADMIN"),
                    transferPolicyId,
                    rlMintPolicyId
                )
            )
        });
        console.log("ReserveLedger proxy:", rlProxy);
    }

    function _deployTokenAuthority(address rlProxy) internal returns (address taProxy) {
        TokenAuthority taImpl = new TokenAuthority(rlProxy, true);

        // Use ERC1967Proxy directly (not DPF — TokenAuthority.initialize uses
        // the `initializer` modifier which conflicts with DPF fixture's
        // MinimalUpgradeableProxyOZ that consumes initializer version 1)
        taProxy = address(
            new ERC1967Proxy(
                address(taImpl),
                abi.encodeCall(TokenAuthority.initialize, (vm.envAddress("TOKEN_AUTHORITY_ADMIN")))
            )
        );
        console.log("TokenAuthority proxy:", taProxy);
    }

    function _configureReserveLedger(
        address authRegistry,
        address rlProxy,
        address taProxy,
        uint64 rlMintPolicyId
    ) internal {
        ReserveLedger rl = ReserveLedger(rlProxy);

        rl.setMaxSupply(vm.envUint("RL_MAX_SUPPLY"));
        rl.grantRole(rl.MINTER_ROLE(), taProxy);
        rl.grantRole(rl.PAUSER_ROLE(), vm.envAddress("PAUSER_ADDRESS"));
        rl.grantRole(rl.UNPAUSER_ROLE(), vm.envAddress("UNPAUSER_ADDRESS"));
        rl.grantRole(
            rl.BLOCKED_ADDRESS_BURNER_ROLE(), vm.envAddress("BLOCKED_ADDRESS_BURNER_ADDRESS")
        );

        AuthRegistry(authRegistry).modifyPolicyWhitelist(rlMintPolicyId, taProxy, true);

        // Grant MINT_RATE_LIMIT_SETTER_ROLE on TokenAuthority to the TA admin
        TokenAuthority ta = TokenAuthority(taProxy);
        ta.grantRole(ta.MINT_RATE_LIMIT_SETTER_ROLE(), vm.envAddress("TOKEN_AUTHORITY_ADMIN"));

        console.log("ReserveLedger + TokenAuthority configured");
    }

    function _deployStablecoin(address authRegistry, address rlProxy, uint64 transferPolicyId)
        internal
        returns (address scProxy, uint64 scMintPolicyId)
    {
        address policyAdmin = vm.envAddress("POLICY_ADMIN");

        scMintPolicyId = AuthRegistry(authRegistry)
            .createPolicy(policyAdmin, IAuthRegistry.PolicyType.WHITELIST);

        address scImpl = address(new StablecoinTemplateV3(rlProxy, authRegistry));

        uint96 saltNonce = uint96(vm.envUint("SC_SALT_NONCE"));
        scProxy = DeterministicProxyFactoryFixture.deterministicProxyOZ({
            initialProxySalt: PermissionedSalt.createPermissionedSalt(msg.sender, saltNonce),
            initialOwner: msg.sender,
            implementation: scImpl,
            callData: abi.encodeCall(
                StablecoinTemplateV3Base.reinitialize,
                (
                    vm.envString("STABLECOIN_NAME"),
                    vm.envString("STABLECOIN_SYMBOL"),
                    uint8(vm.envUint("STABLECOIN_DECIMALS")),
                    vm.envAddress("STABLECOIN_ADMIN"),
                    transferPolicyId,
                    scMintPolicyId
                )
            )
        });
        console.log("StablecoinTemplateV3 proxy:", scProxy);
    }

    function _configureStablecoin(
        address authRegistry,
        address scProxy,
        address taProxy,
        uint64 scMintPolicyId
    ) internal {
        StablecoinTemplateV3 sc = StablecoinTemplateV3(scProxy);
        address minter = vm.envAddress("MINTER_ADDRESS");

        sc.setMaxSupply(vm.envUint("STABLECOIN_MAX_SUPPLY"));
        sc.grantRole(sc.MINTER_ROLE(), minter);
        sc.grantRole(sc.PAUSER_ROLE(), vm.envAddress("PAUSER_ADDRESS"));
        sc.grantRole(sc.UNPAUSER_ROLE(), vm.envAddress("UNPAUSER_ADDRESS"));
        sc.grantRole(
            sc.BLOCKED_ADDRESS_BURNER_ROLE(), vm.envAddress("BLOCKED_ADDRESS_BURNER_ADDRESS")
        );

        TokenAuthority ta = TokenAuthority(taProxy);
        ta.setTxnMintLimit(scProxy, vm.envUint("TXN_MINT_LIMIT"));
        ta.setMinterAllowance(scProxy, minter, vm.envUint("MINTER_ALLOWANCE"));

        string memory recipientsRaw = vm.envOr("INITIAL_MINT_RECIPIENTS", string(""));
        if (bytes(recipientsRaw).length > 0) {
            string[] memory parts = vm.split(recipientsRaw, ",");
            for (uint256 i = 0; i < parts.length; i++) {
                address recipient = vm.parseAddress(parts[i]);
                AuthRegistry(authRegistry).modifyPolicyWhitelist(scMintPolicyId, recipient, true);
            }
        }

        console.log("Stablecoin configured");
    }

}
