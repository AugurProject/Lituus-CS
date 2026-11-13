// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IQueryFeeController } from "../interfaces/IQueryFeeController.sol";

/// @notice A flat-fee controller for tests: every universe is charged `fee`, and what the Multiverse reports is
///         counted so a suite can assert the wiring without the fee math.
contract MockQueryFeeController is IQueryFeeController {
    uint256 public fee;
    uint256 public constant INITIAL_BASE_FEE = 10 ether;

    mapping(uint248 universeId => uint256) public chargedQueries;
    mapping(uint248 universeId => uint256) public recordedQueries;
    mapping(uint248 universeId => uint256) public recordedProfit;
    mapping(uint248 childId => uint248) public seededFrom;
    mapping(uint248 childId => uint256) public seededAt;

    constructor(uint256 _fee) {
        fee = _fee;
    }

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function chargeQuery(uint248 universeId) external returns (uint256) {
        chargedQueries[universeId] += 1;
        return fee;
    }

    function recordQuery(uint248 universeId) external {
        recordedQueries[universeId] += 1;
    }

    function recordProfit(uint248 universeId, uint256 profit) external {
        recordedProfit[universeId] += profit;
    }

    function seedChild(uint248 parentId, uint248 childId, uint256 forkTime) external {
        seededFrom[childId] = parentId;
        seededAt[childId] = forkTime;
    }

    function updateBaseFee(uint248) external {
        fee = INITIAL_BASE_FEE;
    }

    function previewFee(uint248) external view returns (uint256) {
        return fee;
    }
}
