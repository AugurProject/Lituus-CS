// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title LituusRepMath
 * @notice The conversions between wREP shares and underlying REP at a given rate.
 * @dev The one source of these formulas: LituusRep converts with them at its stored rate, and ForkLib with the rate
 *      a forked universe's vault holds, which is the rate every child's vault opens at. Internal only, so each call
 *      is compiled into its caller: no external call to the vault. The rate is underlying assets per share,
 *      scaled by SCALE, and never zero (see LituusRep's constructor).
 */
library LituusRepMath {
    /// @dev Fixed-point scale of the rate (1e18).
    uint256 internal constant SCALE = 1 ether;

    /// @dev Shares for `assets` at `rate`, rounded down.
    function toShares(uint256 assets, uint256 rate) internal pure returns (uint256) {
        return assets * SCALE / rate;
    }

    /// @dev Underlying for `shares` at `rate`, rounded down.
    function toAssets(uint256 shares, uint256 rate) internal pure returns (uint256) {
        return shares * rate / SCALE;
    }

    /// @dev Shares for `assets` at `rate`, rounded up.
    function toSharesUp(uint256 assets, uint256 rate) internal pure returns (uint256) {
        return Math.ceilDiv(assets * SCALE, rate);
    }

    /// @dev Underlying for `shares` at `rate`, rounded up.
    function toAssetsUp(uint256 shares, uint256 rate) internal pure returns (uint256) {
        return Math.ceilDiv(shares * rate, SCALE);
    }
}
