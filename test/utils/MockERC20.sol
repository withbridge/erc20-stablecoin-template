// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20BurnMint } from "src/utils/IERC20BurnMint.sol";
import { IERC20WrapUnwrap } from "src/utils/IERC20WrapUnwrap.sol";

// Mock ERC20 token for testing
contract MockERC20BurnMint is IERC20BurnMint {

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

}

// Mock ERC20 token with wrap/unwrap functionality for testing stablecoins
contract MockERC20WrapUnwrap is IERC20WrapUnwrap {

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string public name = "Mock Wrapped Token";
    string public symbol = "MOCKW";
    uint8 public decimals = 18;

    IERC20BurnMint public immutable UNDERLYING_TOKEN;

    constructor(address _underlyingToken) {
        UNDERLYING_TOKEN = IERC20BurnMint(_underlyingToken);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    function wrap(address to, uint256 amount) external {
        // For simplicity in testing, we assume the caller has already minted or transferred
        // the underlying tokens to themselves. We use transfer instead of transferFrom
        // to avoid needing approval setup in tests.
        // In production code, this would properly check allowances.
        bool success = UNDERLYING_TOKEN.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        // Mint wrapped tokens to recipient
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function unwrap(uint256 amount) external {
        // Burn wrapped tokens from caller
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        // Transfer underlying tokens to caller
        UNDERLYING_TOKEN.transfer(msg.sender, amount);
    }

}
