// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IQueryFeeController } from "../interfaces/IQueryFeeController.sol";

contract MockQueryFeeController is IQueryFeeController {
    uint256 public fee;
    uint256 public constant INITIAL_BASE_FEE = 10 ether;

    constructor(uint256 _fee) {
        fee = _fee;
    }

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function getQueryFee(uint248) external view returns (uint256) {
        return fee;
    }

    function changeBaseFee(uint248, uint256, uint256) external {
        fee = INITIAL_BASE_FEE;
    }
}
