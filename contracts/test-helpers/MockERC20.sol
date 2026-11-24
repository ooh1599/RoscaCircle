// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only 6-decimal ERC20 for etching at the fixed USDC address.
/// Storage-free decimals so vm.etch of the runtime code works. Supports an optional
/// transfer fee (burned) and a positive transfer bonus (minted to receiver) to exercise
/// the group's received-amount checks, plus an issuer blacklist view.
contract MockERC20 {
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlacklisted;
    uint256 public feeBps;
    uint256 public bonus;
    bool public blacklistViewReverts;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8) {
        name = n;
        symbol = s;
    }

    function decimals() external pure returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function setFeeBps(uint256 v) external { feeBps = v; }
    function setBonus(uint256 v) external { bonus = v; }
    function setBlacklisted(address a, bool v) external { isBlacklisted[a] = v; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        totalSupply -= fee;
        balanceOf[to] += amount - fee + bonus;
        totalSupply += bonus;
        emit Transfer(from, to, amount - fee);
    }
}
