// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";

/// @notice Expected-fee mirror shared by the query fee, fork statistics and fuzz suites. Reimplements the
///         contract's integer operations (same order, same floors), so an expectation can be stated from the
///         scenario's volumes where a hand-derived literal would be opaque, and so a random fuzz schedule can
///         be checked at all. The hand-derived literal anchors in the unit suites are what keep it honest.
/// @dev A library taking the deployed Multiverse as its first argument, so it attaches to any fixture layer
///      without inheritance; called explicitly as `QueryFeeMirror.expectedFee(multiverse, ...)`. SCALE and
///      BOOT_VOLUME are read from the contract.
library QueryFeeMirror {
    /// @dev Mirror of `_calculateCurveModifier`.
    function curveModifier(Multiverse multiverse, uint256 sixty, uint256 recent)
        internal
        view
        returns (uint256 modifier_)
    {
        uint256 scale = multiverse.SCALE();
        uint256 ratio = sixty == 0 ? scale : 20 * recent * scale / sixty;

        if (ratio >= scale) {
            modifier_ = (4 * scale) / 5 + ratio / 5;
        } else {
            uint256 shortage = scale - ratio;
            uint256 powered = scale;
            for (uint256 i = 0; i < 6; i++) {
                powered = powered * shortage / scale;
            }
            modifier_ = scale * scale / (scale + 100 * powered);
        }
    }

    /// @dev The deepest down-curve point: an empty recent window over any nonzero sixty.
    function floorModifier(Multiverse multiverse) internal view returns (uint256) {
        return curveModifier(multiverse, 1, 0);
    }

    /// @dev Mirror of `_calculateFeeAndApplyVolume`'s local-volume math, both regimes. Volumes are
    ///      the test-known query counts. The mirror predicts the UNCAPPED fee: the half-fork-threshold
    ///      cap applied by createQuery is asserted directly in the cap tests, never mirrored.
    /// @param multiverse The deployed contract, for SCALE and BOOT_VOLUME.
    /// @param baseFee The controller base fee the modifier applies to.
    /// @param windowId The current window id.
    /// @param fractionElapsed Fraction of the current window elapsed, SCALE-scaled.
    /// @param currentVol Real query count already in window `windowId`.
    /// @param prevVol Real query count in window `windowId-1` (ignored for windowId == 0: bootstrap is used).
    /// @param sixtyStorage The real running sum of windows windowId-1..windowId-20 (universeStatistics value).
    /// @param oldestVol Real query count in window `windowId-20` (only read in the real regime, windowId >= 20).
    function expectedFee(
        Multiverse multiverse,
        uint256 baseFee,
        uint256 windowId,
        uint256 fractionElapsed,
        uint256 currentVol,
        uint256 prevVol,
        uint256 sixtyStorage,
        uint256 oldestVol
    ) internal view returns (uint256) {
        uint256 scale = multiverse.SCALE();
        uint256 boot = multiverse.BOOT_VOLUME();

        uint256 previous = windowId >= 1 ? prevVol : boot;
        uint256 recent = currentVol + (scale - fractionElapsed) * previous / scale;

        uint256 sixty = currentVol + sixtyStorage;
        if (windowId >= 20) {
            // Real regime: the oldest window's elapsed tail has rolled out of the 60-day span.
            sixty -= fractionElapsed * oldestVol / scale;
        } else {
            // Bootstrap regime: top up the missing pre-genesis windows, oldest one trimmed.
            sixty += (20 - windowId - 1) * boot + (scale - fractionElapsed) * boot / scale;
        }

        return baseFee * curveModifier(multiverse, sixty, recent) / scale;
    }
}
