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

    function getUniverseTheoreticalSupply(uint248 universeId) external view returns (uint256);

    function getForkThreshold(uint248 universeId) external view returns (uint256);

    function universes(uint248 universeId) external view returns (Universe memory);

    function forkUniverse(uint248 universeId, uint256 questionId) external;

    function deployChild(uint248 universeId, uint256 outcomeIndex) external;

    function zoltarQuestionData() external view returns (IZoltarQuestionData);
}

interface IZoltarQuestionData {
    struct QuestionData {
        string title;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint120 numTicks;
        int256 displayValueMin;
        int256 displayValueMax;
        string answerUnit;
    }

    function createQuestion(QuestionData memory questionData, string[] calldata outcomeOptions)
        external
        returns (uint256);

    function questions(uint256 questionId) external view returns (QuestionData memory);
}
