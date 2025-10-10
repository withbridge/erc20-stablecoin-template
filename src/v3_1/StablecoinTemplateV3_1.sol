// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20TemporaryApprovalUpgradeable } from "../lib/ERC20TemporaryApprovalUpgradeable.sol";
import { StablecoinTemplateV3 } from "../v3/StablecoinTemplateV3.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

// TODO: add calls to auth registry for transfer check
contract StablecoinTemplateV3_1 is StablecoinTemplateV3, ERC20TemporaryApprovalUpgradeable {

    constructor() {
        _disableInitializers();
    }

    function decimals()
        public
        view
        override(StablecoinTemplateV3, ERC20Upgradeable)
        returns (uint8)
    {
        return StablecoinTemplateV3.decimals();
    }

    function _spendAllowance(address owner, address spender, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20TemporaryApprovalUpgradeable)
    {
        ERC20TemporaryApprovalUpgradeable._spendAllowance(owner, spender, value);
    }

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20Upgradeable, StablecoinTemplateV3)
    {
        StablecoinTemplateV3._update(from, to, amount);
    }

    function allowance(address owner, address spender)
        public
        view
        override(ERC20Upgradeable, ERC20TemporaryApprovalUpgradeable)
        returns (uint256)
    {
        return ERC20TemporaryApprovalUpgradeable.allowance(owner, spender);
    }

}
