// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { LibStringParsing } from "src/lib/LibStringParsing.sol";

/// @dev Mirrors `Multiverse._validateQuestionFormatAndAnswerCount` exactly, exposed as
///      `external` so its gas can be measured.
contract ValidatorHarness {
    error InvalidQuery();
    error InvalidNumberOfOutcomes();

    using LibStringParsing for bytes;

    function validate(string calldata question, uint8 numberOfOutcomes) external pure {
        bytes calldata bytesQuestion = bytes(question);
        (uint256 questionMarkIndex, bool found) = bytesQuestion.indexOf(bytes1("?"));
        if (!found) revert InvalidQuery();

        uint256 openIndex = questionMarkIndex + 1;
        uint256 length = bytesQuestion.length;
        if (openIndex >= length || bytesQuestion[openIndex] != bytes1("[")) revert InvalidQuery();

        uint256 closeIndex = length - 1;
        if (bytesQuestion[closeIndex] != bytes1("]")) revert InvalidQuery();

        (uint256 commas, bool hasAdjacent) =
            bytesQuestion.countAndCheckAdjacency(bytes1(","), "[,]", openIndex, closeIndex + 1);
        if (hasAdjacent) revert InvalidQuery();

        if (commas + 1 != numberOfOutcomes) revert InvalidNumberOfOutcomes();
    }

    /// @notice Pure no-op for measuring the external-call baseline.
    function baseline(string calldata, uint8) external pure { }
}

contract LibStringParsingBench is Test {
    ValidatorHarness internal h;

    function setUp() public {
        h = new ValidatorHarness();
    }

    // Each benchmark uses a question with the `?` roughly in the middle so the
    // scan workload is representative of typical use.

    function test_Bench_Baseline() public view {
        h.baseline("anything", 0);
    }

    function test_Bench_15bytes_2answers() public view {
        // length 15, 1 + 1 = 2 answers (3 chars text + ?[X,Y])
        h.validate("Yes or no?[Y,N]", 2);
    }

    function test_Bench_47bytes_3answers() public view {
        // length 47
        h.validate("John Doe's favorite fruit?[Apple,Banana,Carrot]", 3);
    }

    function test_Bench_62bytes_5answers() public view {
        // length 62
        h.validate("Which is the largest planet?[Mercury,Venus,Earth,Mars,Jupiter]", 5);
    }

    function test_Bench_100bytes_10answers() public view {
        // length 100
        h.validate("Pick one of these to celebrate?[Pizza,Tacos,Sushi,Pasta,Burger,Ramen,Curry,Salad,Steak,Soup]", 10);
    }

    function test_Bench_180bytes_20answers() public view {
        h.validate(
            "Choose your hero among the following twenty options to start the game with you?[Aaa,Bbb,Ccc,Ddd,Eee,Fff,Ggg,Hhh,Iii,Jjj,Kkk,Lll,Mmm,Nnn,Ooo,Ppp,Qqq,Rrr,Sss,Ttt]",
            20
        );
    }
}
