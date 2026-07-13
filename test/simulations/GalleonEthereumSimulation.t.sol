// SPDX-License-Identifier: MIT
// Simulation for registering Galleon with Token Authority on Ethereum
// Run with forge test --match-path test/simulations/GalleonEthereumSimulation.t.sol --rpc-url
// $RPC_ETH -vvvv

pragma solidity ^0.8.24;

import { TokenAuthority } from "../../src/tokenAuthority/TokenAuthority.sol";
import {
    ReserveLedgerBackedHandler
} from "../../src/tokenAuthority/tokenHandler/ReserveLedgerBackedHandler.sol";
import { ReserveLedger } from "../../src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3 } from "../../src/v3/StablecoinTemplateV3.sol";
import { StablecoinTemplateV3Base } from "../../src/v3/StablecoinTemplateV3Base.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AuthRegistry } from "auth-registry-1/src/AuthRegistry.sol";
import { Test, console2 as console } from "forge-std/Test.sol";

contract GalleonEthereumSimulation is Test {

    address fireblocksAdmin;

    address hotwalletStablesmith;
    address fireblocksStablesmith;

    address inventory;

    address rd;
    address xusd;

    address tokenAuthority;
    address backedHandler;
    address singleTokenHandler;

    address authRegistry;

    address reserveStore;

    address complianceAddress;

    function getOrPredictReserveStore(address stablecoin) internal view returns (address) {
        address existing = ReserveLedgerBackedHandler(backedHandler).reserveStores(stablecoin);
        if (existing != address(0)) {
            return existing;
        }

        return vm.computeCreateAddress(backedHandler, vm.getNonce(backedHandler));
    }

    function setUp() public {
        // Galleon
        // xUSD address from token_addresses.rb
        xusd = 0x2Aa1F7354e9ea7158E75CA0c95B736Cc5436C877;
        // Inventory from address_book.rb
        inventory = 0x6c86f85865476A2a14F043991f3d3178c9015447;

        // Constants
        fireblocksAdmin = 0x79C6631FA15CdA38777FB9DD7a6348bAEe794a4E;

        hotwalletStablesmith = 0x42363cb98490128e7932a92c192dCf03d1115e89;

        fireblocksStablesmith = 0x19810813f2E46cF01e7c543f6d8C3ecC8eA2001E;

        // RD Ethereum
        rd = 0x8Bc634a28c499ccFf7c25070bC13c22860a8cFC4;

        // Ethereum token authority
        tokenAuthority = 0x50eA702A75F5C08DB7CdDC1c923b0C3588657639;

        backedHandler = 0x3Bc16Ad5B142B24c52fF249d3C11722EFAd5D573;

        authRegistry = 0x69026c540CdA3d42a1530D0fA3feb092d0bc944d;

        complianceAddress = 0x251d2711ebeB0a09fdB8992F5506f3D949175246;
    }

    function test_galleon_ethereum_simulation() public {
        // Registration
        {
            console.log("registration starting");
            vm.startPrank(fireblocksAdmin);

            // register (v2 handler)
            TokenAuthority(tokenAuthority).registerStablecoin(xusd, backedHandler, 75_000_000e6);

            uint64 rdTransferRecipientPolicyId = ReserveLedger(rd).getTransferPolicyId();

            // set minter allowance
            TokenAuthority(tokenAuthority)
                .setMinterAllowance(xusd, fireblocksStablesmith, 75_000_000e6);

            // burner role
            AccessControlEnumerableUpgradeable(tokenAuthority)
                .grantRole(TokenAuthority(tokenAuthority).BURNER_ROLE(), fireblocksStablesmith);
            vm.stopPrank();

            // get reserves store
            reserveStore = getOrPredictReserveStore(xusd);
            console.log("reserve store", reserveStore);

            vm.startPrank(complianceAddress);

            // rd transfer whitelist
            AuthRegistry(authRegistry)
                .modifyPolicyWhitelist(rdTransferRecipientPolicyId, reserveStore, true);
            vm.stopPrank();

            vm.startPrank(fireblocksAdmin);

            // minter role
            AccessControlEnumerableUpgradeable(xusd)
                .grantRole(StablecoinTemplateV3Base(xusd).MINTER_ROLE(), backedHandler);
            vm.stopPrank();
            console.log("registration done");
        }

        console.log("mint/burn test starting");

        // Minting
        vm.prank(fireblocksStablesmith);
        TokenAuthority(tokenAuthority).mint(xusd, inventory, 10);

        vm.prank(inventory);
        StablecoinTemplateV3Base(xusd).transfer(fireblocksStablesmith, 10);

        // Approve
        vm.prank(fireblocksStablesmith);
        StablecoinTemplateV3Base(xusd).approve(tokenAuthority, 10);

        // Burn
        vm.prank(fireblocksStablesmith);
        TokenAuthority(tokenAuthority).burn(xusd, 10);
        console.log("mint/burn test done");
    }

}
