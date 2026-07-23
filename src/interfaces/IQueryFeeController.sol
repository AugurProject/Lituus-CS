// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

interface IQueryFeeController {
    function getQueryFee(uint248 universeId) external view returns (uint256);
    function changeBaseFee(uint248 universeId, uint256 currentProfit, uint256 lastProfit) external;
    function INITIAL_BASE_FEE() external view returns (uint256);
}
