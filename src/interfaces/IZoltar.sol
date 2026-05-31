// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IReputationToken } from "./IReputationToken.sol";

interface IZoltar {
    struct Universe {
		uint256 forkTime;
		uint256 forkQuestionId;
		uint256 forkingOutcomeIndex;

		IReputationToken reputationToken;
		uint248 parentUniverseId;
	}

    function getChildUniverseId(uint248 universeId, uint256 outcomeIndex) external pure returns (uint248);

    function getRepToken(uint248 universeId) external view returns (IReputationToken);
}