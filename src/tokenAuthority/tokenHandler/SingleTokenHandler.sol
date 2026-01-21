// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Mintable } from "../../utils/IERC20Mintable.sol";
import { TokenHandler } from "./TokenHandler.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SingleTokenHandler
/// @notice A token handler that handles a single token
contract SingleTokenHandler is TokenHandler {

    using SafeERC20 for IERC20Mintable;

    error NotSupported();

    constructor(address _tokenAuthority) TokenHandler(_tokenAuthority) { }

    function mint(address stablecoinContract, address to, uint256 amount)
        external
        onlyTokenAuthority
    {
        IERC20Mintable(stablecoinContract).mint(to, amount);
    }

    function burn(address stablecoinContract, uint256 amount) external onlyTokenAuthority {
        IERC20Mintable(stablecoinContract).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Mintable(stablecoinContract).approve(stablecoinContract, amount);
        IERC20Mintable(stablecoinContract).burn(amount);
    }

    function wrap(address, address, uint256) external view onlyTokenAuthority {
        revert NotSupported();
    }

    function unwrap(address, address, uint256) external view onlyTokenAuthority {
        revert NotSupported();
    }

}
