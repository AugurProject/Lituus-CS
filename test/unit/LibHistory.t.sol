// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { LibHistory } from "src/libraries/LibHistory.sol";

// Test for the LibHistory library (path-of-inheritance bitmap).
//
// Encoding: MSB-first / left-aligned single-bit path.
//

contract LibHistoryTest is Test {
    /* ----------------------------------- appendHistory ---------------------------------- */

    /// genesis (history 0, depth 0) -> child on branch 0 and branch 1 produce distinct (history, depth).
    function test_appendHistory_genesisChildren_distinct() public {
        (bytes32 h0, uint16 d0) = LibHistory.appendHistory(bytes32(0), 0, 0);
        (bytes32 h1, uint16 d1) = LibHistory.appendHistory(bytes32(0), 0, 1);
        assertEq(d0, 1);
        assertEq(d1, 1);
        assertEq(h0, 0x0000000000000000000000000000000000000000000000000000000000000000); // 0....
        assertEq(h1, 0x8000000000000000000000000000000000000000000000000000000000000000); // 1....
        assertTrue(h0 != h1);
    }

    /// chained appends 0->1->1->0->1->0 build the path "011010" at the top 6 bits
    function test_appendHistory_chainedPath() public {
        // build path b0..b5 = 0,1,1,0,1,0 ; expect history top byte == 0x68, depth == 6,
        // and (history >> (256 - 6)) == 0b011010 (== 26).
        bytes32 history = bytes32(0); // genesis
        uint16 depth = 0; // genesis
        (history, depth) = LibHistory.appendHistory(history, depth, 0); // 0
        (history, depth) = LibHistory.appendHistory(history, depth, 1); // 01
        (history, depth) = LibHistory.appendHistory(history, depth, 1); // 011
        (history, depth) = LibHistory.appendHistory(history, depth, 0); // 0110
        (history, depth) = LibHistory.appendHistory(history, depth, 1); // 01101
        (history, depth) = LibHistory.appendHistory(history, depth, 0); // 011010
        assertEq(depth, 6);
        assertEq(history, 0x6800000000000000000000000000000000000000000000000000000000000000); // 011010.....
    }

    /// appends history when the MAX_FORK_DEPTH is not exceeded.
    function test_appendHistory_atMaxDepth() public {
        bytes32 history = bytes32(0);
        uint16 depth = 255;
        (history, depth) = LibHistory.appendHistory(history, depth, 0);
        assertEq(depth, 256);
    }

    /// reverts when parentDepth >= MAX_FORK_DEPTH (256).
    function test_appendHistory_revertsAtMaxDepth() public {
        vm.expectRevert(LibHistory.ForkDepthOverflow.selector);
        LibHistory.appendHistory(bytes32(0), 256, 0);
    }

    /// reverts for a non-binary branch value (b > 1).
    function test_appendHistory_revertsOnInvalidBranch() public {
        vm.expectRevert(LibHistory.InvalidForkOutcomeIndex.selector);
        LibHistory.appendHistory(bytes32(0), 0, 2);
    }

    // reverts if the history is not empty after the given depth.
    function test_appendHistory_revertsOnNonEmptyAfterDepth() public {
        bytes32 history = 0xF000000000000000000000000000000000000000000000000000000000000000; // 111100....
        uint16 depth = 3;
        vm.expectRevert(LibHistory.HistoryAndDepthMismatch.selector);
        LibHistory.appendHistory(history, depth, 0);
        depth = 4; // correct depth
        LibHistory.appendHistory(history, depth, 0);
    }

    /* ----------------------------------- isAncestor --------------------------------- */

    /// genesis (depth 0) is an ancestor of every universe, including itself.
    function test_isAncestor_genesisIsAncestorOfAll() public {
        bytes32 anyHistory = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        uint16 anyDepth = 256;
        assertTrue(LibHistory.isAncestor(bytes32(0), 0, anyHistory, anyDepth));
        bytes32 otherHistory = 0x1200000000000000000000000000000000000000000000000000000000000000;
        uint16 otherDepth = 8;
        assertTrue(LibHistory.isAncestor(bytes32(0), 0, otherHistory, otherDepth));
        // Check genesis is ancestor of itself
        assertTrue(LibHistory.isAncestor(bytes32(0), 0, bytes32(0), 0));
    }

    /// "0110" is an ancestor of "011010", but "0111" is not.
    function test_isAncestor_prefixMatchAndMismatch() public {
        // anc0110  (depth 4), desc011010 (depth 6) -> true
        bytes32 ancestorHistory = 0x6000000000000000000000000000000000000000000000000000000000000000; // 0110....
        uint16 ancestorDepth = 4;
        bytes32 descendantHistory = 0x6800000000000000000000000000000000000000000000000000000000000000; // 011010...
        uint16 descendantDepth = 6;
        assertTrue(LibHistory.isAncestor(ancestorHistory, ancestorDepth, descendantHistory, descendantDepth));

        // anc0111  (depth 4), desc011010 (depth 6) -> false
        ancestorHistory = 0x7000000000000000000000000000000000000000000000000000000000000000; // 0111....
        ancestorDepth = 4;
        descendantHistory = 0x6800000000000000000000000000000000000000000000000000000000000000; // 011010...
        descendantDepth = 6;
        assertFalse(LibHistory.isAncestor(ancestorHistory, ancestorDepth, descendantHistory, descendantDepth));
    }

    /// equal paths are ancestor-or-equal (true).
    function test_isAncestor_equalPathsAreAncestors() public {
        bytes32 history = 0x6000000000000000000000000000000000000000000000000000000000000000; // 0110....
        uint16 depth = 4;
        assertTrue(LibHistory.isAncestor(history, depth, history, depth));
    }

    /// a sibling is not an ancestor (false).
    function test_isAncestor_siblingIsNotAncestor() public {
        bytes32 ancestorHistory = 0x6800000000000000000000000000000000000000000000000000000000000000; // 0110....
        uint16 ancestorDepth = 6;
        bytes32 descendantHistory = 0x6C00000000000000000000000000000000000000000000000000000000000000; // 0110....
        uint16 descendantDepth = 6;
        assertFalse(LibHistory.isAncestor(ancestorHistory, ancestorDepth, descendantHistory, descendantDepth));
    }

    /// a deeper "ancestor" than the descendant can never be an ancestor (false).
    function test_isAncestor_deeperThanDescendantIsFalse() public {
        bytes32 ancestorHistory = 0x6000000000000000000000000000000000000000000000000000000000000000; // 0110....
        uint16 ancestorDepth = 6;
        bytes32 descendantHistory = 0x6000000000000000000000000000000000000000000000000000000000000000; // 0110....
        uint16 descendantDepth = 4;
        assertFalse(LibHistory.isAncestor(ancestorHistory, ancestorDepth, descendantHistory, descendantDepth));
    }

    /// boundary: ancestorDepth == 256 (full word) compares the entire path without reverting.
    function test_isAncestor_depth256Boundary() public {
        bytes32 ancestorHistory = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // 256 bits
        uint16 ancestorDepth = 256;
        bytes32 descendantHistory = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // 256 bits
        uint16 descendantDepth = 256;
        assertTrue(LibHistory.isAncestor(ancestorHistory, ancestorDepth, descendantHistory, descendantDepth));
    }

    /// all-zero-branch universes are distinguished only by depth: "00" is an ancestor of "00000",
    /// the reverse is not, and "000" is not an ancestor of the same-depth "001".
    function test_isAncestor_allZeroBranchesDisambiguatedByDepth() public {
        // "00" (depth 2) is an ancestor of "00000" (depth 5)
        assertTrue(LibHistory.isAncestor(bytes32(0), 2, bytes32(0), 5));
        // the deeper all-zero path is not an ancestor of the shorter one
        assertFalse(LibHistory.isAncestor(bytes32(0), 5, bytes32(0), 2));
        // "000" is not an ancestor of the same-depth sibling "001"
        bytes32 oneAtThird = 0x2000000000000000000000000000000000000000000000000000000000000000; // 001....
        assertFalse(LibHistory.isAncestor(bytes32(0), 3, oneAtThird, 3));
    }

    /// reverts when the ancestor history has bits set below its depth (malformed: history/depth mismatch).
    function test_isAncestor_revertsOnMalformedAncestor() public {
        // depth 0 must mean an all-zero history; a non-zero genesis history is malformed.
        vm.expectRevert(LibHistory.HistoryAndDepthMismatch.selector);
        LibHistory.isAncestor(0x8000000000000000000000000000000000000000000000000000000000000000, 0, bytes32(0), 5);
        // a stray bit below the claimed depth is also malformed.
        bytes32 strayBelowDepth = 0x6100000000000000000000000000000000000000000000000000000000000000; // 0110...1...
        vm.expectRevert(LibHistory.HistoryAndDepthMismatch.selector);
        LibHistory.isAncestor(strayBelowDepth, 4, 0x6100000000000000000000000000000000000000000000000000000000000000, 8);
    }

    /// reverts when the descendant history has bits set below its depth (malformed: history/depth mismatch).
    function test_isAncestor_revertsOnMalformedDescendant() public {
        bytes32 ancestorHistory = 0x6000000000000000000000000000000000000000000000000000000000000000; // 0110....
        // top 6 bits are a clean "011010" but a stray low bit makes depth 6 inconsistent.
        bytes32 strayLowBit = 0x6800000000000000000000000000000000000000000000000000000000000001;
        vm.expectRevert(LibHistory.HistoryAndDepthMismatch.selector);
        LibHistory.isAncestor(ancestorHistory, 4, strayLowBit, 6);
    }

    /* --------------------------------- isEmptyAfterDepth ---------------------------- */

    function test_isEmptyAfterDepth() public {
        // depth 0 requires an entirely empty history.
        assertTrue(LibHistory.isEmptyAfterDepth(bytes32(0), 0));
        assertFalse(LibHistory.isEmptyAfterDepth(0x8000000000000000000000000000000000000000000000000000000000000000, 0));
        // a single top bit is consumed by depth 1, leaving the rest empty.
        assertTrue(LibHistory.isEmptyAfterDepth(0x8000000000000000000000000000000000000000000000000000000000000000, 1));
        // "011010" is clean at depth 6 but a stray low bit is not.
        assertTrue(LibHistory.isEmptyAfterDepth(0x6800000000000000000000000000000000000000000000000000000000000000, 6));
        assertFalse(LibHistory.isEmptyAfterDepth(0x6800000000000000000000000000000000000000000000000000000000000001, 6));
        // at full depth the whole word is path, so any history is "empty after".
        assertTrue(LibHistory.isEmptyAfterDepth(bytes32(type(uint256).max), 256));
    }

    /* ------------------------------------- fuzz ------------------------------------- */

    /// a freshly-appended child always has its parent as an ancestor.
    function testFuzz_appendThenAncestor(bytes32 parentHistory, uint16 parentDepth, bool branch) public {
        parentDepth = uint16(bound(parentDepth, 0, 255));
        parentHistory = _clearHistoryAfterDepth(parentHistory, parentDepth);
        (bytes32 childHistory, uint16 childDepth) = LibHistory.appendHistory(parentHistory, parentDepth, branch ? 1 : 0);
        assertTrue(LibHistory.isAncestor(parentHistory, parentDepth, childHistory, childDepth));
    }

    function _clearHistoryAfterDepth(bytes32 history, uint16 depth) internal pure returns (bytes32) {
        uint256 shift = 256 - depth;
        uint256 mask = uint256(type(uint256).max) << shift;
        return history & bytes32(mask);
    }
}
