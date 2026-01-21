// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITokenHandler } from "./ITokenHandler.sol";

abstract contract TokenHandler is ITokenHandler {

    address public immutable TOKEN_AUTHORITY;

    modifier onlyTokenAuthority() {
        require(msg.sender == TOKEN_AUTHORITY, OnlyTokenAuthority());
        _;
    }

    constructor(address _tokenAuthority) {
        TOKEN_AUTHORITY = _tokenAuthority;
    }

}
