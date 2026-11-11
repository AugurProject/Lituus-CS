// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice The part of Zoltar's child-universe ReputationToken Lituus reads beyond IReputationToken.
interface IZoltarRepToken {
    /// @notice The child's sequence number: Zoltar numbers child REP tokens 1, 2, … in deployment order and names
    ///         them "Augur Reputation <n>" / "REP<n>". The genesis REPv2 does not implement it.
    function repNumber() external view returns (uint256);
}
