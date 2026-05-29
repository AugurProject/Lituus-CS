// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IZoltar {
    function getChildUniverseId(uint248 universeId, uint256 outcomeIndex) external pure returns (uint248);
}