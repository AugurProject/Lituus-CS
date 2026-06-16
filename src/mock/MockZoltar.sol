// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltar } from "../interfaces/IZoltar.sol";
import { IReputationToken } from "../interfaces/IReputationToken.sol";

contract MockZoltar is IZoltar {
    uint256 constant FORK_THRESHOLD_DIVISOR = 20; // 5% of total supply atm

    IReputationToken public repToken;

    constructor(IReputationToken repToken_) {
        repToken = repToken_;
    }

    function getChildUniverseId(uint248 universeId, uint256) external pure returns (uint248) {
        return universeId;
    }

    function getRepToken(uint248) external view returns (IReputationToken) {
        return repToken;
    }

    function getUniverseTheoreticalSupply(uint248) public view returns (uint256) {
        return repToken.totalSupply();
    }

    function getForkThreshold(uint248 universeId) public view returns (uint256) {
        return getUniverseTheoreticalSupply(universeId) / FORK_THRESHOLD_DIVISOR;
    }
}
