// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Multiverse } from "../Multiverse.sol";

/**
 * @title MultiverseHelpers
 * @notice Helpers shared by the Multiverse and ForkLib.
 * @dev Internal only: each function is compiled into every contract or library that calls it, so a call is a plain
 *      jump with no DELEGATECALL. One source copy keeps the two sides from drifting apart (e.g. the payout math
 *      claim() and migrateStake() both pay by).
 */
library MultiverseHelpers {
    // Query outcomes live in one uint256 domain, shared with Zoltar's answer space:
    // 0 - UNRESOLVED
    // 1..numberOfOutcomes - valid categorical outcomes (a query has MIN_OUTCOMES..MAX_OUTCOMES of them, see Multiverse)
    // type(uint256).max - INVALID
    uint256 internal constant UNRESOLVED = 0; // the query is not resolved yet
    // The invalid outcome: reportable on any query, and the outcome of an expired one.
    // TODO: map to Zoltar's INVALID
    uint256 internal constant INVALID = type(uint256).max;
    // This is the divider for the burn depending on losingStakes on a query.
    // If burn ratio is 20% (1/5), then BURN_DIVIDER is 5.
    uint256 internal constant BURN_DIVIDER = 5;

    /**
     * @notice Checks that a universe can be operated on directly — it must exist and be Active — and
     *         returns it.
     * @dev Reverts with InvalidUniverse if the universe does not exist
     *      and InvalidUniverseState if it is in any forking state.
     */
    function _checkUniverseState(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        uint248 universeId
    ) internal view returns (Multiverse.Universe storage universe) {
        universe = universes[universeId];
        Multiverse.UniverseState universeState = universe.universeState;
        if (universeState == Multiverse.UniverseState.NotExisting) revert Multiverse.InvalidUniverse();
        if (universeState != Multiverse.UniverseState.Active) {
            revert Multiverse.InvalidUniverseState();
        }
    }

    /// @dev Marks a query's fee and tips consumed in this universe's fee and tip aggregates. Saturating: the
    ///      spawn-time splits round down, so a child's carried aggregates can run short of the nominal sums by
    ///      dust. An untipped query leaves the tip aggregate's slot untouched.
    // TODO: rewrite the fee accounting so that it correctly handles dust and rounding issues.
    function _consumeQueryFeeAndTips(Multiverse.Universe storage universe, uint256 fee, uint256 tips) internal {
        uint128 totalQueryFees = universe.totalQueryFees;
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.totalQueryFees = fee >= totalQueryFees ? 0 : totalQueryFees - uint128(fee);
        if (tips == 0) return;
        uint128 totalTips = universe.totalTips;
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.totalTips = tips >= totalTips ? 0 : totalTips - uint128(tips);
    }

    /// @dev A winning stake's payout: the stake itself plus its pro-rata share of the losing stakes after the burn cut.
    function _winningPayout(Multiverse.QueryResolution storage resolution, uint256 winnerOutcome, uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint256 winnerStaked = resolution.outcomes[winnerOutcome].totalOutcomeStaked;
        uint256 totalLoserStakes = resolution.totalStaked - winnerStaked;
        uint256 totalDistributable = totalLoserStakes - totalLoserStakes / BURN_DIVIDER;
        return amount + amount * totalDistributable / winnerStaked;
    }

    /**
     * @notice Time-proportional share of a query fee: ramps linearly over the reporting period, then caps at the
     *         full fee with no deadline.
     * @dev Works both for the query fee after reporting and when no reporting exists (INVALID on resolve).
     * @param fee The query fee the share is drawn from.
     * @param elapsed Seconds since the ramp's origin.
     * @param reportingPeriod The Multiverse's REPORTING_PERIOD.
     * @return The earned share.
     */
    function _timeBasedFeeShare(uint256 fee, uint256 elapsed, uint256 reportingPeriod) internal pure returns (uint256) {
        return elapsed >= reportingPeriod ? fee : fee * elapsed / reportingPeriod;
    }
}
