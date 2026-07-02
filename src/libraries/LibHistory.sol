// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title  LibHistory
 * @notice Encodes and queries a universe's path of inheritance through the fork tree as a bitmap,
 *         enabling O(1) ancestor checks via prefix matching.
 * @dev    Encoding is MSB-first / left-aligned. The genesis universe has `history == 0` and
 *         `forkDepth == 0`. Each binary fork appends one bit (the branch taken, 0 or 1) to the
 *         path; the bit for fork depth `i` (1-based because depth 0 is the genesis) lives at bit
 *         `256 - i`, so the oldest fork is the most-significant bit (i=1 -> bit 255, i=256 -> bit 0).
 *         A path of depth `d` therefore occupies the top `d` bits and the remaining `256 - d`
 *         low bits MUST be zero.
 *
 *         `forkDepth` is required to disambiguate paths: a branch-0 fork sets no bit, so a history
 *         alone cannot distinguish e.g. "0" (depth 1) from genesis (depth 0) — the depth carries
 *         that information. Ancestry is "A is an ancestor-or-equal of B if A's path is a prefix of
 *         B's path", which reduces to comparing the top `A.forkDepth` bits.
 *
 *         All functions are `pure` and operate only on their arguments. Inputs with a depth above
 *         {MAX_FORK_DEPTH}) revert rather than returning a value: this is a sanity check that
 *         should never trigger for histories built by the system through {appendHistory}.
 *
 *         Bits below the declared depth MUST be zero, but this is not enforced by the library: it is the caller's
 *         responsibility to ensure that the history is well-formed. The library does not have a validation
 *         for this because of gas optimization. It is intended to be used by the Lituus Multiverse contract,
 *         which maintains a consistent structure of universe histories.
 */
library LibHistory {
    /// @notice Maximum fork depth. A path can hold at most 256 single-bit fork branches in a bytes32.
    uint256 public constant MAX_FORK_DEPTH = 256;

    /// @notice Thrown when a fork depth exceeds {MAX_FORK_DEPTH} (or would on append).
    error ForkDepthOverflow();
    /// @notice Thrown when a fork outcome index is not a valid binary branch (must be 0 or 1).
    error InvalidForkOutcomeIndex();

    /**
     * @notice Appends a fork branch to a universe's path, producing the child universe's history.
     * @dev Reverts with {ForkDepthOverflow} if the parent is at or above {MAX_FORK_DEPTH} and it's
     *      impossible to append a value, and {InvalidForkOutcomeIndex} if `forkOutcomeIndex > 1`.
     *      The new branch bit is placed at bit `256 - newForkDepth` (MSB-first); a branch of 0
     *      leaves the bitmap unchanged and is distinguished only by the incremented depth.
     * @param history The parent universe's history bitmap.
     * @param forkDepth The parent universe's fork depth (number of branches in `history`).
     * @param forkOutcomeIndex The branch taken by the child: 0 or 1.
     * @return newHistory The child universe's history bitmap.
     * @return newForkDepth The child universe's fork depth (`forkDepth + 1`).
     */
    function appendHistory(bytes32 history, uint16 forkDepth, uint8 forkOutcomeIndex)
        internal
        pure
        returns (bytes32 newHistory, uint16 newForkDepth)
    {
        // Provided fork depth should be strictly less than MAX_FORK_DEPTH, because the new depth will be forkDepth + 1.
        if ((forkDepth >= MAX_FORK_DEPTH)) {
            revert ForkDepthOverflow();
        }
        // Only two branches are valid for the binary fork: 0 or 1.
        if (forkOutcomeIndex > 1) {
            revert InvalidForkOutcomeIndex();
        }
        newForkDepth = forkDepth + 1;
        newHistory = history | bytes32(uint256(forkOutcomeIndex) << (MAX_FORK_DEPTH - newForkDepth));
    }

    /**
     * @notice Returns whether one universe is an ancestor of (or equal to) another, i.e. whether the
     *         ancestor's path is a prefix of the descendant's path.
     * @dev O(1): compares the top `ancestorForkDepth` bits of both histories. The genesis universe
     *      (depth 0) is an ancestor of every universe. Reverts with {ForkDepthOverflow} if either
     *      depth exceeds {MAX_FORK_DEPTH}.
     * @param ancestorHistory The candidate ancestor's history bitmap.
     * @param ancestorForkDepth The candidate ancestor's fork depth.
     * @param descendantHistory The candidate descendant's history bitmap.
     * @param descendantForkDepth The candidate descendant's fork depth.
     * @return True if the ancestor's path is a prefix of the descendant's path (equal paths included).
     */
    function isAncestor(
        bytes32 ancestorHistory,
        uint16 ancestorForkDepth,
        bytes32 descendantHistory,
        uint16 descendantForkDepth
    ) internal pure returns (bool) {
        if ((ancestorForkDepth > MAX_FORK_DEPTH) || (descendantForkDepth > MAX_FORK_DEPTH)) {
            revert ForkDepthOverflow();
        }
        // A deeper path can never be a prefix of a shallower one.
        if (ancestorForkDepth > descendantForkDepth) {
            return false;
        }
        // Compare the top `ancestorForkDepth` bits. At depth 0 the mask is 0 (shift by 256),
        // so genesis (history 0) matches every descendant.
        // The shift is the number of low bits to clear, so the mask is all 1s in the top `ancestorForkDepth` bits and
        // 0s below.
        uint256 shift = MAX_FORK_DEPTH - ancestorForkDepth;
        // The mask is 1s in the top `ancestorForkDepth` bits and 0s below (to get the prefix for comparison).
        uint256 mask = uint256(type(uint256).max) << shift;
        // ANDing the mask with the descendant history clears all bits below that depth.
        // Compare the masked descendant history to the ancestor history:
        // if they are equal, the ancestor's path is a prefix of the descendant's path.
        // Example: ancestor depth 3, history 010... (top 3 bits), descendant depth 5, history 01010... (top 5 bits).
        // shift = 256 - 3 = 253, mask = 111000...0 (top 3 bits are set to 1, the rest are set to 0)
        // descendantHistory & mask = 01010... & 11100.... = 01000..., this prefix equals ancestorHistory.
        return ancestorHistory == (descendantHistory & bytes32(mask));
    }
}
