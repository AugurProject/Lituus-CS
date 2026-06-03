// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltar } from "../interfaces/IZoltar.sol";
import { IReputationToken } from "../interfaces/IReputationToken.sol";

contract MockZoltar is IZoltar {
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
}
