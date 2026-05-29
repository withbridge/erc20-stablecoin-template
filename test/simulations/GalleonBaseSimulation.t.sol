// SPDX-License-Identifier: MIT


// From Zach on 5/21
// Run with clear; forge test --match-path test/simulations/GalleonBaseSimulation.t.sol --rpc-url https://base-mainnet.g.alchemy.com/v2/LRK-SfyiJZ8JiuYPVgRXi -vvvv

pragma solidity ^0.8.24;

import { Test, console2 as console } from "forge-std/Test.sol";
import { ReserveLedger } from "../../src/v3/ReserveLedger.sol";
import { ReserveLedgerBackedHandler } from "../../src/tokenAuthority/tokenHandler/ReserveLedgerBackedHandler.sol";
import { StablecoinTemplateV3Base } from "../../src/v3/StablecoinTemplateV3Base.sol";
import { TokenAuthority } from "../../src/tokenAuthority/TokenAuthority.sol";
import { AuthRegistry } from "auth-registry-1/src/AuthRegistry.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { StablecoinTemplateV3 } from "../../src/v3/StablecoinTemplateV3.sol";

contract GalleonBaseSimulation is Test {

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
        // TODO: xUSD address from token_addresses.rb
        xusd = 0x342D26B096ed426C1C4C255A98e4059bDDD492Bd;
        // TODO: Inventory from address_book.rb
        inventory = 0x6c86f85865476A2a14F043991f3d3178c9015447;

        // Constants
        fireblocksAdmin = 0x79C6631FA15CdA38777FB9DD7a6348bAEe794a4E;

        hotwalletStablesmith = 0x42363cb98490128e7932a92c192dCf03d1115e89;

        fireblocksStablesmith = 0x19810813f2E46cF01e7c543f6d8C3ecC8eA2001E;

        rd = 0xd155f0ddc9586233BD554588AeeAA544f13d7A76;

        tokenAuthority = 0x8e9c32A536Ab623a2e0e9961BcE6F5fe7504e084;

        backedHandler = 0xDb8eBA382b18EB395985192337fD62C34F495114;

        authRegistry = 0x73531Fc88a2A537C668F17cd1B1117C45C15185D;

        complianceAddress = 0x251d2711ebeB0a09fdB8992F5506f3D949175246;

    }

    function test_galleon_base_simulation() public {

        // Registration
        {
            console.log("registration starting");
            vm.startPrank(fireblocksAdmin);

            // register (v2 handler)
            TokenAuthority(tokenAuthority).registerStablecoin(xusd, backedHandler, 75_000_000e6);

            uint64 rdTransferRecipientPolicyId = ReserveLedger(rd).getTransferPolicyId();

            // set minter allowance
            TokenAuthority(tokenAuthority).setMinterAllowance(xusd, fireblocksStablesmith, 75_000_000e6);

            // burner role
            AccessControlEnumerableUpgradeable(tokenAuthority).grantRole(TokenAuthority(tokenAuthority).BURNER_ROLE(), fireblocksStablesmith);
            vm.stopPrank();


            // get reserves store
            reserveStore = getOrPredictReserveStore(xusd);
            console.log("reserve store", reserveStore);

            vm.startPrank(complianceAddress);

            // rd transfer whitelist
            AuthRegistry(authRegistry).modifyPolicyWhitelist(rdTransferRecipientPolicyId, reserveStore, true);
            vm.stopPrank();

            vm.startPrank(fireblocksAdmin);

            // minter role
            AccessControlEnumerableUpgradeable(xusd).grantRole(StablecoinTemplateV3Base(xusd).MINTER_ROLE(), backedHandler);
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
