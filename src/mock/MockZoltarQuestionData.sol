// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltarQuestionData } from "../interfaces/IZoltar.sol";

/// @notice Stateful mock contract for ZoltarQuestionData: stores questions under sequential ids (from 1) and
///         applies real Zoltar's categorical answer rule. A label-less (scalar) question is a placeholder —
///         every answer is well-formed — because the scalar format may still change; the mock encodes none.
///         No hash-ordering check on labels either: the Lituus side still submits placeholder labels.
contract MockZoltarQuestionData is IZoltarQuestionData {
    uint256 public nextQuestionId = 1;
    mapping(uint256 questionId => QuestionData) internal storedQuestions;
    mapping(uint256 questionId => string[]) public outcomeLabels;
    mapping(uint256 questionId => uint256) public questionCreatedTimestamp;

    function createQuestion(QuestionData memory data, string[] calldata outcomeOptions) external returns (uint256) {
        uint256 questionId = nextQuestionId++;
        storedQuestions[questionId] = data;
        outcomeLabels[questionId] = outcomeOptions;
        questionCreatedTimestamp[questionId] = block.timestamp;
        return questionId;
    }

    function questions(uint256 questionId) external view returns (QuestionData memory) {
        return storedQuestions[questionId];
    }

    function outcomeLabelCount(uint256 questionId) external view returns (uint256) {
        return outcomeLabels[questionId].length;
    }

    /// @dev Real Zoltar's categorical rule: 0 is Invalid, 1..n are the labels, anything above is malformed.
    ///      No labels = scalar placeholder: nothing is malformed.
    function isMalformedAnswerOption(uint256 questionId, uint256 answer) external view returns (bool) {
        uint256 labelCount = outcomeLabels[questionId].length;
        if (labelCount == 0) return false;
        return answer > labelCount;
    }
}
