// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDefaultRegistry, IGroupFactory} from "./IRosca.sol";

/// @notice Append-only defaults from one immutable factory; no owner or clearing function.
contract DefaultRegistry is IDefaultRegistry {
    address public immutable factory;
    mapping(address => uint256) public defaultCount;
    mapping(address => uint256) public blockedCount;
    mapping(address => uint256) public openUnrecovered;

    error InvalidFactory();
    error UnauthorizedGroup();
    event DefaultRecorded(address indexed wallet, address indexed group, uint256 unrecovered, bool issuerBlocked);

    /// @notice Bind the registry permanently to its creating factory.
    constructor(address factory_) {
        if (factory_ == address(0)) revert InvalidFactory();
        factory = factory_;
    }

    /// @inheritdoc IDefaultRegistry
    function record(address wallet, address group, uint256 unrecovered, bool issuerBlocked) external override {
        if (group != msg.sender || !IGroupFactory(factory).isGroup(msg.sender)) revert UnauthorizedGroup();
        ++defaultCount[wallet];
        if (issuerBlocked) ++blockedCount[wallet];
        else openUnrecovered[wallet] += unrecovered;
        emit DefaultRecorded(wallet, group, unrecovered, issuerBlocked);
    }

    /// @inheritdoc IDefaultRegistry
    function isBanned(address wallet) external view override returns (bool) {
        return openUnrecovered[wallet] > 0;
    }
}
