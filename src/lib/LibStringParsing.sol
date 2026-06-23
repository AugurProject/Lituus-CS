// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/**
 * @title LibStringParsing
 * @notice Single-byte search and count primitives over `bytes calldata`.
 *
 * The library operates on raw bytes and does not interpret multi-byte
 * encodings. Callers are responsible for treating only single-byte ASCII
 * characters as `symbol`.
 */
library LibStringParsing {
    error OutOfBounds();
    error InvalidRange();

    /**
     * @notice Returns the index of the first occurrence of `symbol` in `data`.
     * @param data   Byte string to scan.
     * @param symbol Single byte to search for.
     * @return idx   Index of the first match (0 when not found).
     * @return found True if `symbol` appears in `data`.
     */
    function indexOf(bytes calldata data, bytes1 symbol) internal pure returns (uint256 idx, bool found) {
        return indexOf(data, symbol, 0);
    }

    /**
     * @notice Returns the index of the first occurrence of `symbol` in `data` at or after `fromIndex`.
     * @dev Reverts with `OutOfBounds` when `fromIndex > data.length`.
     *      `fromIndex == data.length` returns `(0, false)` without scanning.
     * @param data      Byte string to scan.
     * @param symbol    Single byte to search for.
     * @param fromIndex Inclusive start offset.
     * @return idx      Index of the first match at or after `fromIndex` (0 when not found).
     * @return found    True if `symbol` appears in `data[fromIndex..]`.
     */
    function indexOf(bytes calldata data, bytes1 symbol, uint256 fromIndex)
        internal
        pure
        returns (uint256 idx, bool found)
    {
        uint256 length = data.length;
        if (fromIndex > length) revert OutOfBounds();
        for (uint256 i = fromIndex; i < length;) {
            if (data[i] == symbol) {
                return (i, true);
            }
            unchecked {
                i += 1;
            }
        }
        return (0, false);
    }

    /**
     * @notice Counts occurrences of `symbol` in `data[startInclusive..endExclusive)`.
     * @dev Reverts with `OutOfBounds` when `endExclusive > data.length`,
     *      and with `InvalidRange` when `startInclusive > endExclusive`.
     *      An empty range (`startInclusive == endExclusive`) returns 0.
     * @param data           Byte string to scan.
     * @param symbol         Single byte to count.
     * @param startInclusive Inclusive start offset of the range.
     * @param endExclusive   Exclusive end offset of the range.
     * @return total         Number of times `symbol` appears in the range.
     */
    function count(bytes calldata data, bytes1 symbol, uint256 startInclusive, uint256 endExclusive)
        internal
        pure
        returns (uint256 total)
    {
        if (endExclusive > data.length) revert OutOfBounds();
        if (startInclusive > endExclusive) revert InvalidRange();
        for (uint256 i = startInclusive; i < endExclusive;) {
            if (data[i] == symbol) {
                unchecked {
                    total += 1;
                }
            }
            unchecked {
                i += 1;
            }
        }
    }

    /**
     * @notice Single-pass scan that counts occurrences of `symbol` in
     *         `data[startInclusive..endExclusive)` and reports whether any two adjacent
     *         bytes in the range are both members of `separators`.
     *
     *         Designed for the common pattern of validating a delimiter-separated list
     *         where the caller needs both the element count and a "no empty elements"
     *         check. Walks each byte once.
     *
     *         On the first detected adjacency the scan returns early with `hasAdjacent`
     *         set to true and a *partial* `occurrences` count. Callers that revert on
     *         adjacency (the expected pattern) never observe the partial count.
     *
     * @dev    Reverts with `OutOfBounds` when `endExclusive > data.length`, and with
     *         `InvalidRange` when `startInclusive > endExclusive`.
     *
     * @param  data           Byte string to scan.
     * @param  symbol         Single byte to count.
     * @param  separators     Set of bytes treated as separators (duplicates harmless).
     * @param  startInclusive Inclusive start offset of the range.
     * @param  endExclusive   Exclusive end offset of the range.
     * @return occurrences    Number of times `symbol` appears in the range — full count
     *                        when `hasAdjacent` is false; partial otherwise.
     * @return hasAdjacent    True if any two adjacent bytes in the range are both in
     *                        `separators`.
     */
    function countAndCheckAdjacency(
        bytes calldata data,
        bytes1 symbol,
        bytes memory separators,
        uint256 startInclusive,
        uint256 endExclusive
    ) internal pure returns (uint256 occurrences, bool hasAdjacent) {
        if (endExclusive > data.length) revert OutOfBounds();
        if (startInclusive > endExclusive) revert InvalidRange();

        // Build a 256-bit membership bitmap from `separators`:
        // bit `b` is set iff byte value `b` belongs to the set.
        // After this, membership of any byte is a single shift + bit-and.
        uint256 mask = _toBitmask(separators);

        // Walk the range once. `prevInSet` carries the previous byte's membership so
        // adjacent separators are detected without a second pass. It starts false, so
        // the very first byte can never trigger adjacency on its own.
        bool prevInSet = false;
        for (uint256 i = startInclusive; i < endExclusive;) {
            bytes1 currentByte = data[i];
            bool curInSet = ((mask >> uint8(currentByte)) & 1) == 1;
            if (prevInSet && curInSet) {
                return (occurrences, true);
            }
            if (currentByte == symbol) {
                unchecked {
                    occurrences += 1;
                }
            }
            prevInSet = curInSet;
            unchecked {
                i += 1;
            }
        }
    }

    /// @dev Folds `separators` into a 256-bit membership bitmap (bit `b` is set iff byte
    ///      `b` appears in the set). Kept private; callers build the mask implicitly each
    ///      call.
    function _toBitmask(bytes memory separators) private pure returns (uint256 mask) {
        uint256 length = separators.length;
        for (uint256 i = 0; i < length;) {
            mask |= uint256(1) << uint8(separators[i]);
            unchecked {
                i += 1;
            }
        }
    }
}
