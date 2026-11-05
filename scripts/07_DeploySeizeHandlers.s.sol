// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Common } from "./Common.s.sol";
import { console } from "forge-std/console.sol";

import { TokenAuthority } from "src/tokenAuthority/TokenAuthority.sol";
import {
    BurnAndRemintSeizeHandler
} from "src/tokenAuthority/seizeHandler/BurnAndRemintSeizeHandler.sol";
import {
    ForceTransferSeizeHandler
} from "src/tokenAuthority/seizeHandler/ForceTransferSeizeHandler.sol";
import { ISeizeHandler } from "src/tokenAuthority/seizeHandler/ISeizeHandler.sol";

/**
 * @title SeizeHandlersDeployer
 * @notice The seize handler deployment shared by step 07 and DeployAll, so both deploy and check
 *         the handlers the same way.
 */
abstract contract SeizeHandlersDeployer is Common {

    /// @dev Separated from DeploySeizeHandlers.run() so DeployAll can call it inside its own
    ///      broadcast, and tests without one.
    function _deploySeizeHandlers(address tokenAuthority)
        internal
        returns (SeizeHandlers memory seizeHandlers)
    {
        seizeHandlers = SeizeHandlers({
            forceTransferSeizeHandler: address(new ForceTransferSeizeHandler(tokenAuthority)),
            burnAndRemintSeizeHandler: address(new BurnAndRemintSeizeHandler(tokenAuthority))
        });

        _requireBuiltFor(seizeHandlers, tokenAuthority);
    }

    /// @dev The TokenAuthority rejects a seize handler built for any other TokenAuthority, so a
    ///      mismatch here would only surface later, when the admin tries to set it.
    function _requireBuiltFor(SeizeHandlers memory seizeHandlers, address tokenAuthority)
        internal
        view
    {
        require(
            ISeizeHandler(seizeHandlers.forceTransferSeizeHandler).TOKEN_AUTHORITY()
                == tokenAuthority,
            "Should never happen: ForceTransferSeizeHandler built for another TokenAuthority"
        );
        require(
            ISeizeHandler(seizeHandlers.burnAndRemintSeizeHandler).TOKEN_AUTHORITY()
                == tokenAuthority,
            "Should never happen: BurnAndRemintSeizeHandler built for another TokenAuthority"
        );
        // The burn-and-re-mint handler asserts its own reserve ledger balance is unchanged after
        // every seize, so it must watch the TokenAuthority's reserve ledger token.
        require(
            BurnAndRemintSeizeHandler(seizeHandlers.burnAndRemintSeizeHandler)
                    .RESERVE_LEDGER_TOKEN()
                == TokenAuthority(tokenAuthority).RESERVE_LEDGER_TOKEN(),
            "Should never happen: BurnAndRemintSeizeHandler watches the wrong reserve ledger"
        );
    }

}

/**
 * @title DeploySeizeHandlers
 * @notice Deploys the two seize handlers for one TokenAuthority: a ForceTransferSeizeHandler for
 *         its StablecoinTemplateV3 coins and a BurnAndRemintSeizeHandler for its
 *         StablecoinTemplateV2 coins.
 *
 *         Run once per TokenAuthority. Seize handlers hold no state and accept calls only from
 *         the TokenAuthority they were built for, so any account can deploy them.
 *
 *         On a new chain, deploy-new-chain.sh runs this right after step 03, and step 05 then
 *         registers each new V3 stablecoin with the ForceTransferSeizeHandler. For a
 *         TokenAuthority that predates seize, run it on its own. The TokenAuthority admin and each
 *         stablecoin's admin then, from their own signers:
 *         1. Grant each handler its roles on the stablecoins it serves (FORCE_TRANSFER_ROLE on
 *            V3; the six seize roles and two mint recipients on V2)
 *         2. Call setSeizeHandler(stablecoin, handler) for every stablecoin registered before
 *            seize existed
 *         3. Call setSeizureWalletPolicyId(policyId) and grant SEIZER_ROLE
 */
contract DeploySeizeHandlers is SeizeHandlersDeployer {

    function run(address tokenAuthority) public returns (SeizeHandlers memory seizeHandlers) {
        requireDeployed(tokenAuthority, "tokenAuthority");

        vm.startBroadcast();
        seizeHandlers = _deploySeizeHandlers(tokenAuthority);
        vm.stopBroadcast();

        console.log("ForceTransferSeizeHandler:", seizeHandlers.forceTransferSeizeHandler);
        console.log("BurnAndRemintSeizeHandler:", seizeHandlers.burnAndRemintSeizeHandler);
        console.log("---");
        console.log(
            "Set in .env: FORCE_TRANSFER_SEIZE_HANDLER=%s", seizeHandlers.forceTransferSeizeHandler
        );
        console.log(
            "Set in .env: BURN_AND_REMINT_SEIZE_HANDLER=%s", seizeHandlers.burnAndRemintSeizeHandler
        );
    }

}
