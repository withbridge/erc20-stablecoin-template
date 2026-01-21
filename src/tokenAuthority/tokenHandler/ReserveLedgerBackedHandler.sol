// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TokenHandler} from "./TokenHandler.sol";
import {ReserveStore} from "../../reserveStore/ReserveStore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWrappedERC20} from "../../utils/IWrappedERC20.sol";
import {IERC20Mintable} from "../../utils/IERC20Mintable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ReserveLedgerBackedHandler is TokenHandler {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Mintable;

    address public immutable RESERVE_LEDGER_TOKEN;

    mapping(address stablecoinContract => address reserveStore) public reserveStores;

    error ReserveStoreNotFound();

    constructor(address _reserveLedgerToken, address _tokenAuthority) TokenHandler(_tokenAuthority) {
        RESERVE_LEDGER_TOKEN = _reserveLedgerToken;
    }

    function mint(address stablecoinContract, address to, uint256 amount) external onlyTokenAuthority {
        IERC20Mintable(RESERVE_LEDGER_TOKEN).mint(address(this), amount);
        address reserveStore = reserveStores[stablecoinContract];
        if (reserveStore == address(0)) {
            reserveStore = address(new ReserveStore(RESERVE_LEDGER_TOKEN, address(this), stablecoinContract));
            reserveStores[stablecoinContract] = reserveStore;
        }
        IERC20(RESERVE_LEDGER_TOKEN).transfer(reserveStore, amount);
        IERC20Mintable(stablecoinContract).mint(to, amount);
    }

    function burn(address stablecoinContract, uint256 amount) external onlyTokenAuthority {
        address reserveStore = reserveStores[stablecoinContract];
        require(reserveStore != address(0), ReserveStoreNotFound());
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).burn(amount);
        IERC20(RESERVE_LEDGER_TOKEN).safeTransferFrom(reserveStore, address(this), amount);
        IERC20Mintable(RESERVE_LEDGER_TOKEN).burn(amount);
    }

    function wrap(address stablecoinContract, address to, uint256 amount) external onlyTokenAuthority {
        address reserveStore = reserveStores[stablecoinContract];
        if (reserveStore == address(0)) {
            reserveStore = address(new ReserveStore(RESERVE_LEDGER_TOKEN, address(this), stablecoinContract));
            reserveStores[stablecoinContract] = reserveStore;
        }
        IERC20(RESERVE_LEDGER_TOKEN).safeTransferFrom(msg.sender, reserveStore, amount);
        IERC20Mintable(stablecoinContract).mint(to, amount);
    }

    function unwrap(address stablecoinContract, address to, uint256 amount) external onlyTokenAuthority {
        address reserveStore = reserveStores[stablecoinContract];
        require(reserveStore != address(0), ReserveStoreNotFound());
        IERC20(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).burn(amount);
        IERC20(RESERVE_LEDGER_TOKEN).safeTransferFrom(reserveStore, to, amount);
    }
}
