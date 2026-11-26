// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

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
    // The tips a fork's children carry are capped at this fraction of the forking universe's wREP supply, in
    // shares: a divisor of 1000 is 0.1%. The cap covers every unpaid tip the universe holds, the forking query's
    // included. Above it every tip is cut by the same ratio and the excess is donated to the universe's
    // query-token pool (see ForkLib._capCarriedTips).
    uint256 internal constant FORK_TIP_CAP_DIVISOR = 1000;

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

    /// @dev Marks a query's fee consumed in this universe's fee aggregate and returns what it consumed: the fee,
    ///      or what the aggregate still holds if that is less. The caller pays and burns exactly that amount.
    ///      The aggregate can run short: a child's copy of it is drawn through the vault rounded down, so it can
    ///      lose a wei at every fork level above the universe (see ForkLib._spawnChildUniverse), while every
    ///      inherited query keeps its full Query.fee. The clamp takes that shortfall off whichever query
    ///      resolves last, so every query still resolves. It is only ever the rounding: the tests hold every
    ///      aggregate within the fork depth, in wei, of the fees its open queries carry, so a ledger bug that
    ///      the clamp would otherwise absorb fails them.
    function _consumeQueryFee(Multiverse.Universe storage universe, uint256 fee) internal returns (uint256) {
        uint128 totalQueryFees = universe.totalQueryFees;
        if (fee > totalQueryFees) fee = totalQueryFees;
        // At most the aggregate, within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.totalQueryFees = totalQueryFees - uint128(fee);
        return fee;
    }

    /// @dev Marks a query's fee and tips consumed in this universe's fee and tip aggregates and returns the fee
    ///      consumed (see _consumeQueryFee). A fork rounds the carried tips down together with the aggregate they
    ///      are paid from (see ForkLib._capCarriedTips), so the tips a universe owes never exceed it, and the
    ///      subtraction is checked: it reverts if that ever breaks. An untipped query leaves the tip aggregate's
    ///      slot untouched.
    function _consumeQueryFeeAndTips(Multiverse.Universe storage universe, uint256 fee, uint256 tips)
        internal
        returns (uint256 consumedFee)
    {
        consumedFee = _consumeQueryFee(universe, fee);
        // Tips are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (tips != 0) universe.totalTips -= uint128(tips);
    }

    /// @dev What a fork that carried `carried` of the `held` tips carries of `tips`: the same ratio, rounded down.
    ///      Every query's tips are cut by it, the forking query's at spawn (see
    ///      ForkLib._drawTipsAndPayForkReporter) and an open query's where a child reads them (see
    ///      Multiverse._carriedTips). A fork that carried all it held cuts nothing, zero included.
    function _cutTips(uint256 tips, uint256 carried, uint256 held) internal pure returns (uint256) {
        // A fork that carried less than it held did hold tips, so the divisor is nonzero there.
        return carried == held ? tips : Math.mulDiv(tips, carried, held);
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
