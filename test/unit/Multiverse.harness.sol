// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";

/// @notice Test harness exposing the Multiverse's internal statistics views as external functions.
/// @dev Suites that need it override `_deployMultiverse` to deploy this instead of the production contract.
contract MultiverseHarness is Multiverse {
    constructor(
        IZoltar zoltar,
        uint248 genesisUniverseId,
        IQueryFeeController queryFeeController,
        address queryTokenizer,
        uint256 migrationDuration,
        uint256 reportingPeriod,
        uint256 appealPeriod
    )
        Multiverse(
            zoltar,
            genesisUniverseId,
            queryFeeController,
            queryTokenizer,
            migrationDuration,
            reportingPeriod,
            appealPeriod
        )
    { }

    /// @dev The profit view as of now, as `updateBaseFee` reads it.
    function exposed_getProfits(uint248 universeId) external view returns (uint256, uint256) {
        return _getProfits(universeId, _getCurrentThreeDayWindow(), _windowFraction(block.timestamp));
    }

    /// @dev One stored 3-day bucket of a universe, as (profit, volume). Never bootstrap: storage holds real
    ///      values, plus a child's rate-filled fork gap.
    function exposed_threeDayInfo(uint248 universeId, uint256 windowId)
        external
        view
        returns (uint128 profit, uint128 volume)
    {
        ThreeDayInfo storage info = universeStatistics[universeId].threeDayInfo[windowId];
        return (info.threeDayProfit, info.threeDayVolume);
    }

    /// @dev The 3-day volume the universe is priced on now, as the fee path reads it.
    function exposed_recentVolume(uint248 universeId) external view returns (uint256 recentVolume) {
        UniverseStatistics storage stats = universeStatistics[universeId];
        uint256 windowId = _getCurrentThreeDayWindow();
        recentVolume = _recentVolume(
            stats, windowId, _windowFraction(block.timestamp), stats.threeDayInfo[windowId].threeDayVolume
        );
    }
}
