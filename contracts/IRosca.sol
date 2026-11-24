// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Immutable group proposal; all monetary amounts are six-decimal USDC units.
struct Terms {
    uint8 n;
    uint256 c;
    uint16 phiBps;
    uint256 d;
    uint256 rho;
    uint64 startTime;
    uint64 period;
    uint64 grace;
    uint64 cure;
    uint64 acceptDeadline;
    bool useGate;
    uint32 minScoreMilli;
    uint256 ungatedCap;
    address[] members;
}

/// @notice Attester-signed Passport score bound to a wallet and this group's terms.
struct Attestation {
    uint32 scoreMilli;
    uint64 expiresAt;
    uint256 nonce;
    bytes sig;
}

interface IDefaultRegistry {
    /// @notice Append a factory-group default, excluding issuer-blocked losses from bans.
    function record(address wallet, address group, uint256 unrecovered, bool issuerBlocked) external;
    /// @notice Whether the wallet has any non-issuer-blocked unrecovered loss.
    function isBanned(address wallet) external view returns (bool);
}

interface IPassportGate {
    /// @notice Validate an EIP-712 HumanAttestation without consuming its nonce.
    function verify(
        address wallet, bytes32 termsHash, uint32 scoreMilli,
        uint64 expiresAt, uint256 nonce, bytes calldata sig
    ) external view returns (bool);
}

interface IUSDCBlacklist {
    /// @notice Query issuer blocking; group callers treat query failure as false.
    function isBlacklisted(address wallet) external view returns (bool);
}

interface IGroupFactory {
    /// @notice Whether this factory created the supplied group.
    function isGroup(address group) external view returns (bool);
}

interface IRosca {
    /// @notice Initialize a fresh EIP-1167 clone atomically from the factory.
    function initialize(Terms calldata t, address registry_, address gate_, address creator_) external;
    /// @notice Chain-, clone- and proposal-bound commitment accepted by members.
    function termsHash() external view returns (bytes32);
}
