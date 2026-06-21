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
}
