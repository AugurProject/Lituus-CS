// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { LibStringParsing } from "src/lib/LibStringParsing.sol";

/// @dev Thin external wrapper so tests can pass `bytes memory` and have it landed in
///      `bytes calldata` inside the library functions.
contract LibStringParsingHarness {
    function indexOf(bytes calldata data, bytes1 symbol) external pure returns (uint256, bool) {
        return LibStringParsing.indexOf(data, symbol);
    }

    function indexOfFrom(bytes calldata data, bytes1 symbol, uint256 fromIndex)
        external
        pure
        returns (uint256, bool)
    {
        return LibStringParsing.indexOf(data, symbol, fromIndex);
    }

    function count(bytes calldata data, bytes1 symbol, uint256 startInclusive, uint256 endExclusive)
        external
        pure
        returns (uint256)
    {
        return LibStringParsing.count(data, symbol, startInclusive, endExclusive);
    }
}

contract LibStringParsingUnitTest is Test {
    LibStringParsingHarness internal harness;

    function setUp() public {
        harness = new LibStringParsingHarness();
    }

    /*//////////////////////////////////////////////////////////////
                              indexOf
    //////////////////////////////////////////////////////////////*/

    function test_IndexOf_FindsFirstOccurrence() public view {
        (uint256 idx, bool found) = harness.indexOf(bytes("hello?[A,B]"), bytes1("?"));
        assertTrue(found);
        assertEq(idx, 5);
    }

    function test_IndexOf_FindsFirstOfDuplicates() public view {
        (uint256 idx, bool found) = harness.indexOf(bytes("aabba"), bytes1("a"));
        assertTrue(found);
        assertEq(idx, 0);
    }

    function test_IndexOf_ReturnsNotFoundOnAbsent() public view {
        (uint256 idx, bool found) = harness.indexOf(bytes("hello"), bytes1("?"));
        assertFalse(found);
        assertEq(idx, 0);
    }

    function test_IndexOf_ReturnsNotFoundOnEmpty() public view {
        (uint256 idx, bool found) = harness.indexOf(bytes(""), bytes1("?"));
        assertFalse(found);
        assertEq(idx, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       indexOf with fromIndex
    //////////////////////////////////////////////////////////////*/

    function test_IndexOfFrom_FindsFirstAfterOffset() public view {
        (uint256 idx, bool found) = harness.indexOfFrom(bytes("aabba"), bytes1("a"), 1);
        assertTrue(found);
        assertEq(idx, 1);
    }

    function test_IndexOfFrom_SkipsEarlierOccurrences() public view {
        (uint256 idx, bool found) = harness.indexOfFrom(bytes("a-b-c"), bytes1("-"), 2);
        assertTrue(found);
        assertEq(idx, 3);
    }

    function test_IndexOfFrom_ReturnsNotFoundWhenOnlyEarlier() public view {
        (uint256 idx, bool found) = harness.indexOfFrom(bytes("a-b"), bytes1("a"), 1);
        assertFalse(found);
        assertEq(idx, 0);
    }

    function test_IndexOfFrom_FromEqualsLengthIsEmptySearch() public view {
        (uint256 idx, bool found) = harness.indexOfFrom(bytes("abc"), bytes1("a"), 3);
        assertFalse(found);
        assertEq(idx, 0);
    }

    function test_IndexOfFrom_RevertsWhenFromExceedsLength() public {
        vm.expectRevert(LibStringParsing.OutOfBounds.selector);
        harness.indexOfFrom(bytes("abc"), bytes1("a"), 4);
    }

    /*//////////////////////////////////////////////////////////////
                              count
    //////////////////////////////////////////////////////////////*/

    function test_Count_CountsInRange() public view {
        // "A,B,C,D" — commas at indices 1, 3, 5 within range [0, 7).
        uint256 total = harness.count(bytes("A,B,C,D"), bytes1(","), 0, 7);
        assertEq(total, 3);
    }

    function test_Count_BoundedRangeSubset() public view {
        // Range [2, 5) covers "B,C" — only one comma at index 3.
        uint256 total = harness.count(bytes("A,B,C,D"), bytes1(","), 2, 5);
        assertEq(total, 1);
    }

    function test_Count_ZeroOnEmptyRange() public view {
        uint256 total = harness.count(bytes("A,B,C"), bytes1(","), 3, 3);
        assertEq(total, 0);
    }

    function test_Count_ZeroOnAbsentSymbol() public view {
        uint256 total = harness.count(bytes("ABCDE"), bytes1(","), 0, 5);
        assertEq(total, 0);
    }

    function test_Count_RevertsWhenStartGreaterThanEnd() public {
        vm.expectRevert(LibStringParsing.InvalidRange.selector);
        harness.count(bytes("A,B,C"), bytes1(","), 4, 2);
    }

    function test_Count_RevertsWhenEndOutOfBounds() public {
        vm.expectRevert(LibStringParsing.OutOfBounds.selector);
        harness.count(bytes("A,B,C"), bytes1(","), 0, 6);
    }
}
