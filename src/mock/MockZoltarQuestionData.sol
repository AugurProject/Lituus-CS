// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltarQuestionData } from "../interfaces/IZoltar.sol";

contract MockZoltarQuestionData is IZoltarQuestionData {
    function createQuestion(QuestionData memory, string[] calldata) external pure returns (uint256) {
        return 1;
    }

    function questions(uint256) external pure returns (QuestionData memory questionData) {
        return questionData;
    }
}
