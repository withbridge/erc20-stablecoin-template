// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IBurnAndRemintStablecoin } from "../../seize/interfaces/IBurnAndRemintStablecoin.sol";
import { ITokenAuthority } from "../ITokenAuthority.sol";
import { SeizeHandler } from "./SeizeHandler.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BurnAndRemintSeizeHandler
/// @author Bridge
/// @notice Seize handler for stablecoins whose reserve backing sits in a separate reserve store
/// (StablecoinTemplateV2, issued through the ReserveLedgerBackedHandler)
/// @dev StablecoinTemplateV2 is not upgraded and has no force transfer, so the seize is built from
/// the functions it already has. Burning and re-minting leaves the reserve store untouched, so the
/// backing never moves. Needs the stablecoin's BLOCKED_ADDRESS_BURNER_ROLE, MINTER_ROLE,
/// UNBLOCKER_ROLE, BLOCKER_ROLE, PAUSER_ROLE, and UNPAUSER_ROLE, and both the Seizure Wallet and
/// this handler on the stablecoin's mint-recipient list.
contract BurnAndRemintSeizeHandler is SeizeHandler {

    using SafeERC20 for IBurnAndRemintStablecoin;

    /// @notice The address of the reserve ledger token backing the TokenAuthority's stablecoins
    address public immutable RESERVE_LEDGER_TOKEN;

    /// @notice Thrown when a seize leaves this handler holding a different balance of `token`.
    /// Should never happen: the remainder minted here is always returned, and reserve ledger
    /// tokens only arrive if the stablecoin pays out backing when burned (a StablecoinTemplateV3
    /// wrongly configured with this handler).
    error SeizeHandlerBalanceChanged(address token, uint256 balanceBefore, uint256 balanceAfter);

    /// @notice Initializes the seize handler with the TokenAuthority's reserve ledger token
    /// @param _tokenAuthority The address of the token authority
    constructor(address _tokenAuthority) SeizeHandler(_tokenAuthority) {
        RESERVE_LEDGER_TOKEN = ITokenAuthority(_tokenAuthority).RESERVE_LEDGER_TOKEN();
    }

    /**
     * @notice Seizes from a stablecoin that can only burn a blocked holder's whole balance
     * @dev Burns all of `holderBalance`, mints `amount` to `to`, then returns the unseized
     * remainder by minting it to this handler and transferring it to `from`. A transfer is used
     * instead of a mint to `from` because `from` is not a mint recipient, and only the coin's
     * admin can make it one. `from` is unblocked only for that transfer, and only on the partial
     * path.
     *
     * Direct mints here total exactly `holderBalance`, the amount just burned, so supply is
     * unchanged. Nothing goes through a token handler, so no reserve ledger tokens are minted.
     *
     * The coin must be unpaused for its burn, mint, and transfer, so a paused coin is unpaused
     * for the duration and re-paused before returning.
     * @param stablecoinContract The address of the stablecoin contract
     * @param from The frozen holder
     * @param to The Seizure Wallet
     * @param amount The amount to seize
     * @param holderBalance `from`'s balance read before the burn
     */
    function seize(
        address stablecoinContract,
        address from,
        address to,
        uint256 amount,
        uint256 holderBalance
    ) external onlyTokenAuthority {
        IBurnAndRemintStablecoin stablecoin = IBurnAndRemintStablecoin(stablecoinContract);
        uint256 stablecoinBalanceBefore = stablecoin.balanceOf(address(this));
        uint256 reserveBalanceBefore = IERC20(RESERVE_LEDGER_TOKEN).balanceOf(address(this));

        bool wasPaused = stablecoin.paused();
        if (wasPaused) {
            stablecoin.unpause();
        }

        stablecoin.burnFromBlockedAddress(from);
        stablecoin.mint(to, amount);

        uint256 remainder = holderBalance - amount;
        if (remainder > 0) {
            stablecoin.mint(address(this), remainder);
            stablecoin.unblockAddress(from);
            stablecoin.safeTransfer(from, remainder);
            stablecoin.blockAddress(from);
        }

        if (wasPaused) {
            stablecoin.pause();
        }

        // Stray coins sent to this handler outside a seize are never swept, and the backing of a
        // coin that holds its own reserve can never be released through here.
        _requireBalanceUnchanged(stablecoinContract, stablecoinBalanceBefore);
        _requireBalanceUnchanged(RESERVE_LEDGER_TOKEN, reserveBalanceBefore);

        emit Seized(stablecoinContract, from, to, amount);
    }

    function _requireBalanceUnchanged(address token, uint256 balanceBefore) internal view {
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(
            balanceAfter == balanceBefore,
            SeizeHandlerBalanceChanged(token, balanceBefore, balanceAfter)
        );
    }

}
