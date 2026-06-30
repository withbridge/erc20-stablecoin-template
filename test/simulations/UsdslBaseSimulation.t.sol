// SPDX-License-Identifier: MIT
// Simulation for registering USDSL with Token Authority on Base
// Run with forge test --match-path test/simulations/UsdslBaseSimulation.t.sol --rpc-url $RPC_BASE -vvvv

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

contract UsdslBaseSimulation is Test {

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
        // USDSL
        // USDSL address from token_addresses.rb
        xusd = 0xCC7B940E22e1eEF83C0170608AED6D5Fd386Cdad;
        // Inventory from address_book.rb (EvmUsdslBridgeVenturesInventory)
        inventory = 0x8E6aA4D8C576192ad5d5c275e3aAFff615c08036;

        // Constants (Base-wide, shared with DKUSD / USD2 / Galleon)
        fireblocksAdmin = 0x79C6631FA15CdA38777FB9DD7a6348bAEe794a4E;

        hotwalletStablesmith = 0x42363cb98490128e7932a92c192dCf03d1115e89;

        fireblocksStablesmith = 0x19810813f2E46cF01e7c543f6d8C3ecC8eA2001E;

        rd = 0xd155f0ddc9586233BD554588AeeAA544f13d7A76;

        tokenAuthority = 0x8e9c32A536Ab623a2e0e9961BcE6F5fe7504e084;

        backedHandler = 0xDb8eBA382b18EB395985192337fD62C34F495114;

        authRegistry = 0x73531Fc88a2A537C668F17cd1B1117C45C15185D;

        complianceAddress = 0x251d2711ebeB0a09fdB8992F5506f3D949175246;

    }

    function test_usdsl_base_simulation() public {

        // Registration
        // USDSL is not yet registered on Base, so this block is active (unlike the
        // already-migrated Galleon sim). It registers the token, sets the minter
        // allowance, grants the burner/minter roles, and whitelists the reserve store.
        {
            console.log("registration starting");
            vm.startPrank(fireblocksAdmin);

            // register (v2 handler)
            TokenAuthority(tokenAuthority).registerStablecoin(xusd, backedHandler, 50_000_000e6);

            uint64 rdTransferRecipientPolicyId = ReserveLedger(rd).getTransferPolicyId();

            // set minter allowance
            TokenAuthority(tokenAuthority).setMinterAllowance(xusd, fireblocksStablesmith, 50_000_000e6);

            // burner role
            AccessControlEnumerableUpgradeable(tokenAuthority).grantRole(TokenAuthority(tokenAuthority).BURNER_ROLE(), fireblocksStablesmith);
            vm.stopPrank();

            // get reserves store
            reserveStore = getOrPredictReserveStore(xusd);
            console.log("reserve store", reserveStore);
            // expected (handler CREATE nonce 4): 0x34C35fe6d18509e7b6d237C8369a0F24093d5f6C

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
