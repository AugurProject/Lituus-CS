// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltarQuestionData } from "../interfaces/IZoltar.sol";

contract MockZoltarQuestionData is IZoltarQuestionData {
    function createQuestion(QuestionData memory, string[] calldata) external pure returns (uint256) {
        return 1;
    }

    function questions(uint256) external pure returns (QuestionData memory questionData) {
        // Non-zero endTime so the Multiverse accepts the question as an existing Zoltar fork question.
        questionData.title = "Mock Zoltar question";
        questionData.endTime = 1;
        return questionData;
    }
}
