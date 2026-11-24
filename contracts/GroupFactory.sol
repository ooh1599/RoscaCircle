// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Terms, IRosca, IGroupFactory} from "./IRosca.sol";
import {DefaultRegistry} from "./DefaultRegistry.sol";

/// @notice Immutable group policy; the two-step admin can only pause new creation.
contract GroupFactory is Pausable, IGroupFactory {
    uint256 public constant BPS = 10_000;
    uint32 public constant MIN_SCORE_FLOOR_MILLI = 20_000;
    address public admin;
    address public pendingAdmin;
    address public immutable implementation;
    address public immutable gate;
    DefaultRegistry public immutable registry;
    uint16 public immutable minPhiBps;
    uint16 public immutable minDepositBps;
    uint256 public immutable minC;
    uint256 public immutable maxC;
    uint64 public immutable maxDuration;
    mapping(address => bool) public override isGroup;
    address[] public groups;

    error InvalidConfiguration();
    error InvalidTerms();
    error InvalidMember();
    error Unauthorized();
    event GroupCreated(address indexed group, address indexed creator, bytes32 termsHash);
    event AdminTransferStarted(address indexed admin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Set permanent policy and deploy the factory's append-only registry.
    constructor(
        address admin_, address implementation_, address gate_, uint16 minPhiBps_,
        uint16 minDepositBps_, uint256 minC_, uint256 maxC_, uint64 maxDuration_
    ) {
        if (admin_ == address(0) || implementation_.code.length == 0 || minPhiBps_ > BPS
            || minC_ == 0 || maxC_ < minC_ || maxDuration_ < 4 hours) revert InvalidConfiguration();
        admin = admin_;
        implementation = implementation_;
        gate = gate_;
        minPhiBps = minPhiBps_;
        minDepositBps = minDepositBps_;
        minC = minC_;
        maxC = maxC_;
        maxDuration = maxDuration_;
        registry = new DefaultRegistry(address(this));
        emit AdminTransferred(address(0), admin_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    /// @notice Validate a complete proposal and create and initialize its immutable clone.
    function createGroup(Terms calldata t) external whenNotPaused returns (address group) {
        _validate(t);
        group = Clones.clone(implementation);
        isGroup[group] = true;
        groups.push(group);
        IRosca(group).initialize(t, address(registry), gate, msg.sender);
        emit GroupCreated(group, msg.sender, IRosca(group).termsHash());
    }

    /// @notice Number of groups created by this factory, including cancelled groups.
    function groupCount() external view returns (uint256) { return groups.length; }

    /// @notice Pause creation only; existing groups never consult this pause flag.
    function pauseCreation() external onlyAdmin { _pause(); }

    /// @notice Resume creation under the same immutable policy.
    function unpauseCreation() external onlyAdmin { _unpause(); }

    /// @notice Nominate a nonzero successor; the incumbent retains authority until acceptance.
    function transferAdmin(address successor) external onlyAdmin {
        if (successor == address(0)) revert InvalidConfiguration();
        pendingAdmin = successor;
        emit AdminTransferStarted(admin, successor);
    }

    /// @notice Accept a previously nominated admin transfer.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Unauthorized();
        address previous = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, msg.sender);
    }

    function _validate(Terms calldata t) private view {
        if (t.n < 4 || t.n > 10 || t.members.length != t.n || t.c < minC || t.c > maxC
            || t.phiBps < minPhiBps || t.phiBps > BPS || t.rho > t.c / 10) revert InvalidTerms();
        if (t.d < t.c + t.rho || t.d < Math.mulDiv(t.c, minDepositBps, BPS)
            || t.period < 1 hours || t.grace < 1 hours || t.grace > 14 days
            || t.cure < 1 hours || t.cure > 7 days || uint256(t.n) * t.period > maxDuration
            || t.startTime <= block.timestamp || t.acceptDeadline <= block.timestamp
            || t.acceptDeadline > t.startTime) revert InvalidTerms();
        if (t.useGate) {
            if (gate == address(0) || t.minScoreMilli < MIN_SCORE_FLOOR_MILLI) revert InvalidTerms();
        } else if (t.minScoreMilli != 0) revert InvalidTerms();
        for (uint256 i; i < t.n; ++i) {
            if (t.members[i] == address(0)) revert InvalidMember();
            for (uint256 j; j < i; ++j) {
                if (t.members[j] == t.members[i]) revert InvalidMember();
            }
        }
    }
}
