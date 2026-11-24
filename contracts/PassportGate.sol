// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPassportGate} from "./IRosca.sol";

/// @notice Stateless EOA-attester Passport verification; replay checks live in each group.
contract PassportGate is EIP712, IPassportGate {
    uint32 public constant MIN_SCORE_FLOOR_MILLI = 20_000;
    bytes32 public constant HUMAN_ATTESTATION_TYPEHASH = keccak256(
        "HumanAttestation(address wallet,bytes32 termsHash,uint32 scoreMilli,uint64 expiresAt,uint256 nonce)"
    );
    address public immutable attester;
    error InvalidAttester();

    /// @notice Fix the attester and EIP-712 domain for this gate's lifetime.
    constructor(address attester_) EIP712("RoscaPassportGate", "1") {
        if (attester_ == address(0)) revert InvalidAttester();
        attester = attester_;
    }

    /// @inheritdoc IPassportGate
    function verify(
        address wallet, bytes32 termsHash, uint32 scoreMilli,
        uint64 expiresAt, uint256 nonce, bytes calldata sig
    ) external view override returns (bool) {
        if (expiresAt < block.timestamp || scoreMilli <= MIN_SCORE_FLOOR_MILLI) return false;
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            HUMAN_ATTESTATION_TYPEHASH, wallet, termsHash, scoreMilli, expiresAt, nonce
        )));
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        return err == ECDSA.RecoverError.NoError && signer == attester;
    }
}
