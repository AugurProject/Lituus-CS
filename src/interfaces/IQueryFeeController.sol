// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IQueryFeeController {
    function getQueryFee(uint248 universeId) external view returns (uint256);
}
