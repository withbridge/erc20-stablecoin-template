// SPDX-License-Identifier: MIT
// Simulation for registering Galleon with Token Authority on Polygon
// Run with forge test --match-path test/simulations/GalleonPolygonSimulation.t.sol --rpc-url
// $POLYGON_RPC_URL -vvvv

pragma solidity ^0.8.24;

import { TokenAuthority } from "../../src/tokenAuthority/TokenAuthority.sol";
import {
    ReserveLedgerBackedHandler
} from "../../src/tokenAuthority/tokenHandler/ReserveLedgerBackedHandler.sol";
import { ReserveLedger } from "../../src/v3/ReserveLedger.sol";
import { StablecoinTemplateV3Base } from "../../src/v3/StablecoinTemplateV3Base.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { AuthRegistry } from "auth-registry-1/src/AuthRegistry.sol";
import { Test, console2 as console } from "forge-std/Test.sol";

contract GalleonPolygonSimulation is Test {

    address fireblocksAdmin;
    address fireblocksStablesmith;

    address inventory;

    address rd;
    address xusd;

    address tokenAuthority;
    address backedHandler;

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
        // Galleon Polygon
        xusd = 0x68947DCaB8Cb55180745e0a7b81909D3F5dDED55;
        inventory = 0x6c86f85865476A2a14F043991f3d3178c9015447;

        // Base constants for shared actors.
        fireblocksAdmin = 0x79C6631FA15CdA38777FB9DD7a6348bAEe794a4E;
        fireblocksStablesmith = 0x19810813f2E46cF01e7c543f6d8C3ecC8eA2001E;
        complianceAddress = 0x251d2711ebeB0a09fdB8992F5506f3D949175246;

        // Polygon contracts.
        rd = 0x8Bc634a28c499ccFf7c25070bC13c22860a8cFC4;
        authRegistry = 0x69026c540CdA3d42a1530D0fA3feb092d0bc944d;
        tokenAuthority = 0x457471d29d19d44D218ac534a7e70635C17ed2b0;
        backedHandler = 0x7D7bbf6C5c9AB6b4505AEd5076c8cAfD9e89327f;
    }

    function test_galleon_polygon_simulation() public {
        // Registration
        {
            console.log("registration starting");
            vm.startPrank(fireblocksAdmin);

            TokenAuthority(tokenAuthority).registerStablecoin(xusd, backedHandler, 75_000_000e6);

            uint64 rdTransferRecipientPolicyId = ReserveLedger(rd).getTransferPolicyId();
            uint64 rdMintRecipientPolicyId = ReserveLedger(rd).getMintRecipientPolicyId();

            TokenAuthority(tokenAuthority)
                .setMinterAllowance(xusd, fireblocksStablesmith, 75_000_000e6);

            AccessControlEnumerableUpgradeable(tokenAuthority)
                .grantRole(TokenAuthority(tokenAuthority).BURNER_ROLE(), fireblocksStablesmith);
            vm.stopPrank();

            reserveStore = getOrPredictReserveStore(xusd);
            console.log("reserve store", reserveStore);

            vm.startPrank(complianceAddress);

            AuthRegistry(authRegistry)
                .modifyPolicyWhitelist(rdTransferRecipientPolicyId, reserveStore, true);
            AuthRegistry(authRegistry)
                .modifyPolicyWhitelist(rdMintRecipientPolicyId, reserveStore, true);
            vm.stopPrank();

            vm.startPrank(fireblocksAdmin);

            AccessControlEnumerableUpgradeable(xusd)
                .grantRole(StablecoinTemplateV3Base(xusd).MINTER_ROLE(), backedHandler);
            vm.stopPrank();
            console.log("registration done");
        }

        console.log("mint/burn test starting");

        vm.prank(fireblocksStablesmith);
        TokenAuthority(tokenAuthority).mint(xusd, inventory, 10);

        vm.prank(inventory);
        StablecoinTemplateV3Base(xusd).transfer(fireblocksStablesmith, 10);

        vm.prank(fireblocksStablesmith);
        StablecoinTemplateV3Base(xusd).approve(tokenAuthority, 10);

        vm.prank(fireblocksStablesmith);
        TokenAuthority(tokenAuthority).burn(xusd, 10);
        console.log("mint/burn test done");
    }

}
