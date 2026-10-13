// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { QueryFeeController } from "src/QueryFeeController.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";
import { MultiverseHarness } from "./Multiverse.harness.sol";
import { QueryFeeMirror } from "./QueryFee.mirror.sol";

/// @notice Shared layer for the fork statistics suites: the funded fork fixture deployed through the harness
///         (bucket reads), plus seeding helpers that build a parent history through the real pipeline.
/// @dev Windows are GENESIS_TIMESTAMP-anchored (START_TIME). Volume is seeded with createQuery (one count per
///      query), profit with create + report in one block (reporterPay = 0, so profit = fee, read back from the
///      query record) and a resolve in the target window. Expectations are hand-known literals: bucket counts,
///      cache sums and window ids from the seeded schedule, and fees as hand-derived wei with the derivation
///      beside each assertion. Fee reads sit at a window start (f = 0) or exactly mid-window (f = 0.5) so the
///      intermediates are derivable; where a scenario still lands on an opaque number (a down-branch sixth
///      power, or a non-terminating up-branch ratio) the shared mirror is called with the scenario's volumes
///      instead, which reads as the scenario itself.
abstract contract ForkStatisticsFixtures is MultiverseFixtures {
    MultiverseHarness internal harness;

    function _deployMultiverse(IQueryFeeController controller) internal override returns (Multiverse) {
        harness = new MultiverseHarness(
            zoltar, GENESIS_UID, controller, queryTokenizerStub, MIGRATION_DURATION, REPORTING_PERIOD, APPEAL_PERIOD
        );
        return Multiverse(address(harness));
    }

    /* ============================================== READS ============================================== */

    function _stats(uint248 universeId) internal view returns (uint256 sixtyDayVolume, uint256 lastWindowId) {
        (uint128 sixty, uint128 last) = multiverse.universeStatistics(universeId);
        return (sixty, last);
    }

    function _uncappedFee(uint248 universeId) internal view returns (uint256 fee) {
        (fee,,) = multiverse.getMintPricing(universeId);
    }

    function _currentWindow() internal view returns (uint256) {
        return (vm.getBlockTimestamp() - START_TIME) / multiverse.THREE_DAYS();
    }

    function _assertBucket(uint248 universeId, uint256 windowId, uint256 profit, uint256 volume) internal view {
        (uint128 storedProfit, uint128 storedVolume) = harness.exposed_threeDayInfo(universeId, windowId);
        assertEq(storedVolume, volume, string.concat("volume at window ", vm.toString(windowId)));
        assertEq(storedProfit, profit, string.concat("profit at window ", vm.toString(windowId)));
    }

    function _assertBucketEmpty(uint248 universeId, uint256 windowId) internal view {
        _assertBucket(universeId, windowId, 0, 0);
    }

    /* ============================================= SEEDING ============================================= */

    /// @dev `count` genesis queries one hour into window `windowId`: `count` volume there, nothing else.
    function _seedVolumeAt(uint256 windowId, uint256 count) internal {
        _warpToWindow(windowId, 1 hours);
        for (uint256 i = 0; i < count; i++) {
            _createDefaultQuery();
        }
    }

    /// @dev Books profit of exactly one query fee into window `windowId` (and one volume there): create +
    ///      report one hour in, resolve past the appeal window, still inside it. Returns the booked profit.
    function _seedProfitAt(uint256 windowId) internal returns (uint256 profit) {
        _warpToWindow(windowId, 1 hours);
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        (,, profit,,) = multiverse.queries(queryId);
        _warpToWindow(windowId, 1 hours + multiverse.APPEAL_PERIOD() + 1);
        _resolve(bystander, queryId);
    }

    /// @dev Creates the forking query at the current time (one volume in the current window), previews the
    ///      parent's fee with it counted, then escalates to the fork in the same block.
    function _forkGenesisWithPreview() internal returns (uint256 forkQueryId, uint256 parentFee) {
        forkQueryId = _createDefaultQuery();
        parentFee = _uncappedFee(GENESIS_UID);
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);
    }

    function _spawn(uint248 parentId, uint256 outcome) internal returns (uint248 childId) {
        vm.prank(bystander);
        multiverse.spawnChildUniverse(parentId, outcome);
        childId = _childId(parentId, outcome);
    }

    /// @dev Moves `shares` of the user's genesis wREP into `outcome`'s child and approves the child vault, so
    ///      the user can create queries there.
    function _fundUserInChild(uint256 outcome, uint256 shares) internal {
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, outcome, shares);
        ILituusRep childRep = multiverse.repTokenOf(_childId(GENESIS_UID, outcome));
        vm.prank(user);
        childRep.approve(address(multiverse), type(uint256).max);
    }

    /// @dev A query by `user` in `universeId` at the current time. Returns its id and the fee charged.
    function _createQueryIn(uint248 universeId) internal returns (uint256 queryId, uint256 fee) {
        queryId = multiverse.queryCount();
        ILituusRep repToken = multiverse.repTokenOf(universeId);
        uint256 balanceBefore = repToken.balanceOf(user);
        vm.prank(user);
        multiverse.createQuery(universeId, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        fee = balanceBefore - repToken.balanceOf(user);
    }
}

/// @notice The demand/profit history a child universe inherits at spawn: the 21 buckets ending at the spawn
///         window, the 60-day cache rolled to that window, and the resulting fee and profit reads.
contract MultiverseForkStatisticsTest is ForkStatisticsFixtures {
    /* ========================================== STORAGE-LEVEL ========================================== */

    function test_Spawn_CopiesBucketsAndCacheAnchoredAtTheSpawnWindow() public {
        // Schedule: vol[24] = 2, vol[30] = 2 with profit p (one plain query plus the profit seed's), vol[43] = 3,
        // then the forking query at the START of window 44 (f = 0): vol[44] = 1. Cache at 44 = 2 + 2 + 3 = 7.
        _seedVolumeAt(24, 2);
        _seedVolumeAt(30, 1);
        uint256 profit = _seedProfitAt(30);
        _seedVolumeAt(43, 3);

        _warpToWindow(44, 0);
        (, uint256 parentFee) = _forkGenesisWithPreview();
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);

        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childLast, 44);
        assertEq(childSixty, 7);

        _assertBucketEmpty(child, 23);
        _assertBucket(child, 24, 0, 2);
        _assertBucket(child, 30, profit, 2);
        _assertBucket(child, 43, 0, 3);
        _assertBucket(child, 44, 0, 1);
        _assertBucketEmpty(child, 45);

        // Hand-derived anchor at f = 0: recent = vol[44] + vol[43] = 1 + 3 = 4, sixty = vol[44] + cache = 1 + 7 = 8
        // (no tail of vol[24] has rolled out yet), ratio = 20 * 4 / 8 = 10 -> up-branch modifier 0.8 + 10 / 5 = 2.8
        // -> fee = 2.8 REP.
        uint256 childFee = _uncappedFee(child);
        assertEq(childFee, 2.8 ether);
        assertEq(childFee, parentFee);
    }

    function test_Spawn_CopiesExactlyTwentyOneBuckets() public {
        // Window 23 (vol 3, profit p) is one window beyond the horizon of a window-44 spawn; window 24 (vol 1)
        // is the oldest copied. Only window 24 is in the cache.
        _seedVolumeAt(23, 2);
        uint256 profit = _seedProfitAt(23);
        _seedVolumeAt(24, 1);

        _warpToWindow(44, 0);
        _forkGenesisWithPreview();
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);

        _assertBucket(GENESIS_UID, 23, profit, 3);
        _assertBucketEmpty(child, 23);
        _assertBucket(child, 24, 0, 1);
        _assertBucket(child, 44, 0, 1);
        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childSixty, 1); // had window 23 leaked into the cache it would be 4
        assertEq(childLast, 44);
    }

    function test_Spawn_CopiesProfitBookedAfterTheParentsLastQuery() public {
        // lastWindowId only moves on query creation; profit is booked into the resolve-time window. A fork
        // whose escalation spans windows leaves profit above lastWindowId — the copy must not anchor on it.
        _warpToWindow(9, 1 hours);
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        (,, uint256 profit,,) = multiverse.queries(queryId);

        // The forking query is the parent's last query: lastWindowId = 10. Its first report lands late in the
        // reporting window so the resolve below stays inside that report's appeal window.
        _warpToWindow(10, 1 hours);
        uint256 forkQueryId = _createDefaultQuery();
        _warpToWindow(10, 2 days + 23 hours);
        _report(challenger, forkQueryId, OUTCOME_B);

        // Window 11: profit booked, lastWindowId untouched.
        _warpToWindow(11, 1 hours);
        _resolve(bystander, queryId);
        (uint256 parentSixty, uint256 parentLast) = _stats(GENESIS_UID);
        assertEq(parentLast, 10);
        assertEq(parentSixty, 1); // window 9 only
        _assertBucket(GENESIS_UID, 11, profit, 0);

        // Pace the rest of the ladder 20 hours apart (inside every appeal window) until it fires, past window 11.
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger, 20 hours);
        uint256 forkWindow = _currentWindow();
        assertGt(forkWindow, 11);
        assertLt(forkWindow, 20); // keeps the window-11 profit inside the child's current month below
        (, parentLast) = _stats(GENESIS_UID);
        assertEq(parentLast, 10); // reports never roll the cache

        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);

        // Anchored at the fork window, cache rolled past the parent's anchor: windows 9 and 10 both entered.
        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childLast, forkWindow);
        assertEq(childSixty, 2);
        _assertBucket(child, 9, 0, 1);
        _assertBucket(child, 10, 0, 1);
        _assertBucket(child, 11, profit, 0);
        _assertBucketEmpty(child, forkWindow);
        // The carried profit is the whole of the child's current month (no other profit, no bootstrap there).
        (uint256 currentProfit,) = harness.exposed_getProfits(child);
        assertEq(currentProfit, profit);
    }

    function test_Spawn_MirroredForkCopiesProfitBookedByTheMirroringResolve() public {
        // The resolve that mirrors a native Zoltar fork books profit in its own tx, right before the freeze.
        _warpToWindow(9, 1 hours);
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        (,, uint256 profit,,) = multiverse.queries(queryId);
        uint256 zq = _createZoltarCategoricalQuestion(3);
        _forkZoltarNatively(zq);

        // The mirroring resolve at the START of window 11: the trigger, f = 0.
        _warpToWindow(11, 0);
        _resolve(bystander, queryId);
        assertEq(uint8(_universeState(GENESIS_UID)), uint8(Multiverse.UniverseState.Migration));
        (uint256 parentSixty, uint256 parentLast) = _stats(GENESIS_UID);
        assertEq(parentLast, 9);
        assertEq(parentSixty, 0);
        _assertBucket(GENESIS_UID, 11, profit, 0);

        uint248 child = _spawn(GENESIS_UID, 1); // a Zoltar answer

        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childLast, 11);
        assertEq(childSixty, 1); // window 9 entered the cache on the roll from 9 to 11
        _assertBucket(child, 9, 0, 1);
        _assertBucketEmpty(child, 10);
        _assertBucket(child, 11, profit, 0);
        (uint256 currentProfit,) = harness.exposed_getProfits(child);
        assertEq(currentProfit, profit);

        // A sibling at the start of window 14 gets the gap from the mirroring resolve on filled from the
        // parent's per-window values as of it: no volume (vol[11] = vol[10] = 0) and a tenth of the 30-day profit,
        // which is that resolve's own booking. Window 11 (whole, f = 0 at the trigger), 12 and 13 get it; nothing
        // into 14.
        _warpToWindow(14, 0);
        uint248 sibling = _spawn(GENESIS_UID, 2);
        uint256 profitPerWindow = profit / 10;
        (uint256 siblingSixty, uint256 siblingLast) = _stats(sibling);
        assertEq(siblingLast, 14);
        assertEq(siblingSixty, 1);
        _assertBucket(sibling, 11, profit + profitPerWindow, 0);
        _assertBucket(sibling, 12, profitPerWindow, 0);
        _assertBucket(sibling, 13, profitPerWindow, 0);
        _assertBucketEmpty(sibling, 14);
    }

    function test_Spawn_LateSiblingGetsTheCacheRolledToItsOwnSpawnWindow() public {
        // vol[24] = 1, vol[39] = 3, forking query at the start of window 40: vol[40] = 1. Child A spawns at 40
        // (cache 4). Child B spawns at the start of window 48: windows 24..27 have rolled out, and the frozen
        // gap is filled from the window before the trigger, vol[39] = 3 per window — the rest of window 40
        // (f = 0, so a whole window) to 1 + 3 = 4, windows 41..47 at 3 each, nothing into 48 (f = 0).
        // Cache = 3 + 4 + 7 * 3 = 28.
        _seedVolumeAt(24, 1);
        _seedVolumeAt(39, 3);
        _warpToWindow(40, 0);
        (, uint256 parentFee) = _forkGenesisWithPreview();
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);

        (uint256 sixtyA, uint256 lastA) = _stats(childA);
        assertEq(lastA, 40);
        assertEq(sixtyA, 4);
        _assertBucket(childA, 24, 0, 1);
        _assertBucket(childA, 39, 0, 3);
        _assertBucket(childA, 40, 0, 1);
        // Hand-derived anchor at f = 0: recent = 1 + 3 = 4, sixty = 1 + 4 = 5, ratio = 20 * 4 / 5 = 16
        // -> modifier 0.8 + 16 / 5 = 4.0 -> fee = 4 REP, as the parent priced it.
        uint256 feeA = _uncappedFee(childA);
        assertEq(feeA, 4 ether);
        assertEq(feeA, parentFee);

        _warpToWindow(48, 0);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);

        (uint256 sixtyB, uint256 lastB) = _stats(childB);
        assertEq(lastB, 48);
        assertEq(sixtyB, 28);
        _assertBucketEmpty(childB, 24);
        _assertBucketEmpty(childB, 28);
        _assertBucket(childB, 39, 0, 3);
        _assertBucket(childB, 40, 0, 4);
        _assertBucket(childB, 41, 0, 3);
        _assertBucket(childB, 47, 0, 3);
        _assertBucketEmpty(childB, 48);
        // B at 48, f = 0: recent = 0 + vol[47] = 3 over sixty 28, ratio 20 * 3 / 28 = 60e18 / 28
        // = 2142857142857142857 floored -> modifier 0.8e18 + ratio / 5 = 1228571428571428571 -> 1.228... REP:
        // not the floor an unfilled gap would give, and below A's 4 REP because the filled windows pulled the
        // 60-day average toward the previous window's count.
        assertEq(_uncappedFee(childB), 1_228_571_428_571_428_571);
    }

    function test_Spawn_GapIsFilledFromTheWindowBeforeTheTriggerNotTheTriggerWindow() public {
        // vol[24] = 4, nothing in window 39, and a quarter into window 40 three plain queries plus the forking
        // query: vol[40] = 4. The fill is vol[39] = 0 per window: the trigger window's own queries and the
        // trigger moment do not enter it, so nothing is added to window 40 for its frozen part (it stays at 4)
        // and nothing to the windows after it. (Had the fill been the parent's recent volume at the trigger,
        // 4 + floor(0.75 * 0) = 4, a spawn at the window's end would have read 4 + 3 = 7 against the parent's 4.)
        _seedVolumeAt(24, 4);
        _warpToWindow(40, multiverse.THREE_DAYS() / 4);
        _createDefaultQuery();
        _createDefaultQuery();
        _createDefaultQuery();
        (, uint256 parentFee) = _forkGenesisWithPreview();
        // Parent's own quote at the trigger: recent 4 over sixty 4 + 4 = 8, ratio 10 -> 2.8 REP.
        assertEq(parentFee, 2.8 ether);

        // Child A three quarters into window 40: recent = 4 + floor(0.25 * 0) = 4, sixty 8 -> the parent's quote.
        _warpToWindow(40, 3 * multiverse.THREE_DAYS() / 4);
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        _assertBucket(childA, 40, 0, 4);
        assertEq(_uncappedFee(childA), 2.8 ether);

        // Child B at the start of window 41: window 40 complete at 4, nothing into 41 (f = 0); cache =
        // vol[21..40] = 4 + 4 = 8. recent = 0 + vol[40] = 4, sixty 8 -> the parent's quote again.
        _warpToWindow(41, 0);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        _assertBucket(childB, 40, 0, 4);
        _assertBucketEmpty(childB, 41);
        (uint256 sixtyB,) = _stats(childB);
        assertEq(sixtyB, 8);
        assertEq(_uncappedFee(childB), 2.8 ether);

        // Child C at the start of window 42: window 41 is empty (the fill is 0), cache = vol[22..41] = 8, recent
        // = 0 + vol[41] = 0 -> the floor, as the parent itself would have read after a quiet window 41. Demand
        // that began in the trigger window is not carried forward.
        _warpToWindow(42, 0);
        uint248 childC = _spawn(GENESIS_UID, OUTCOME_C);
        _assertBucketEmpty(childC, 41);
        _assertBucketEmpty(childC, 42);
        (uint256 sixtyC,) = _stats(childC);
        assertEq(sixtyC, 8);
        assertEq(_uncappedFee(childC), FLOOR_FEE);
    }

    function test_Spawn_LateSpawnFillsTheGapForAnySpawnFraction() public {
        // Parent: profit p1 in window 35 and p2 in window 38 (one query each), vol[39] = 4, and in window 40 one
        // plain query plus the forking query, with the trigger exactly mid-window (f = 0.5): vol[40] = 2.
        // Fill at the trigger: volume vol[39] = 4 per window; profit = the parent's 30-day profit (p1 + p2,
        // both inside windows 40..31) / 10.
        uint256 p1 = _seedProfitAt(35);
        uint256 p2 = _seedProfitAt(38);
        _seedVolumeAt(39, 4);
        _warpToWindow(40, multiverse.THREE_DAYS() / 2);
        _createDefaultQuery();
        (, uint256 parentFee) = _forkGenesisWithPreview();
        // Parent's own quote at the trigger: recent 2 + 2 = 4 over sixty 2 + 6 = 8 -> ratio 10 -> 2.8 REP.
        assertEq(parentFee, 2.8 ether);
        uint256 profitPerWindow = (p1 + p2) / 10;

        // Child A spawns five windows later, a quarter into window 45.
        _warpToWindow(45, multiverse.THREE_DAYS() / 4);
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);

        // Real windows copied; the rest of window 40 (half) from vol[39] = 4 and the per-window profit; 41..44 whole;
        // 45 a quarter.
        _assertBucket(childA, 35, p1, 1);
        _assertBucket(childA, 38, p2, 1);
        _assertBucket(childA, 39, 0, 4);
        _assertBucket(childA, 40, profitPerWindow / 2, 2 + 2);
        _assertBucket(childA, 41, profitPerWindow, 4);
        _assertBucket(childA, 44, profitPerWindow, 4);
        _assertBucket(childA, 45, profitPerWindow / 4, 1);
        (uint256 sixtyA, uint256 lastA) = _stats(childA);
        assertEq(lastA, 45);
        assertEq(sixtyA, 1 + 1 + 4 + 4 + 4 * 4); // windows 25..44: 35, 38, 39, 40, 41..44

        // recent = 1 + floor(0.75 * 4) = 4: the per-window volume, as for any spawn fraction. sixty = 1 + 26 = 27,
        // ratio 80e18 / 27 = 2962962962962962962 floored -> 0.8e18 + ratio / 5 = 1392592592592592592.
        assertEq(_uncappedFee(childA), 1_392_592_592_592_592_592);

        // Child B spawns in the same window three quarters in: same recent 3 + floor(0.25 * 4) = 4, only the
        // 60-day side moves (sixty = 3 + 26 = 29): ratio 80e18 / 29 = 2758620689655172413 floored
        // -> 1351724137931034482, within 3% of A. Without the fill both would sit at the floor.
        _warpToWindow(45, 3 * multiverse.THREE_DAYS() / 4);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        _assertBucket(childB, 45, 3 * profitPerWindow / 4, 3);
        (uint256 sixtyB,) = _stats(childB);
        assertEq(sixtyB, sixtyA);
        assertEq(_uncappedFee(childB), 1_351_724_137_931_034_482);
    }

    function test_Spawn_LaterInTheTriggerWindowFillsTheFrozenPartOfIt() public {
        // Profit p in window 38 (one query), vol[39] = 4, the forking query a quarter into window 40 (vol[40]
        // = 1). Fill at the trigger: volume vol[39] = 4 per window; profit p / 10. The spawn comes three
        // quarters into the same window: the frozen half of window 40 is filled, floor(0.5 * 4) = 2 queries
        // and half the per-window profit, and nothing else changes.
        uint256 p = _seedProfitAt(38);
        _seedVolumeAt(39, 4);
        _warpToWindow(40, multiverse.THREE_DAYS() / 4);
        (, uint256 parentFee) = _forkGenesisWithPreview();
        // Parent's own quote at the trigger: recent 4 over sixty 1 + 5 = 6, ratio 80e18 / 6 -> 3.466... REP.
        assertEq(parentFee, 3_466_666_666_666_666_666);
        uint256 profitPerWindow = p / 10;

        _warpToWindow(40, 3 * multiverse.THREE_DAYS() / 4);
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);

        _assertBucket(child, 38, p, 1);
        _assertBucket(child, 39, 0, 4);
        _assertBucket(child, 40, profitPerWindow / 2, 1 + 2);
        _assertBucketEmpty(child, 41);
        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childLast, 40);
        assertEq(childSixty, 5);

        // recent = 3 + floor(0.25 * 4) = 4, as the parent read (left empty it would have read 1 + 1 = 2);
        // sixty = 3 + 5 = 8, ratio 10 -> 0.8 + 2 = 2.8 REP.
        assertEq(_uncappedFee(child), 2.8 ether);

        // The child's first query, in the same window: charged that fee, counted on top of the fill (the
        // bucket is added to, not replaced), cache and anchor untouched (no roll inside the window).
        _fundUserInChild(OUTCOME_A, 100 ether);
        (, uint256 charged) = _createQueryIn(child);
        assertEq(charged, 2.8 ether);
        _assertBucket(child, 40, profitPerWindow / 2, 1 + 2 + 1);
        (childSixty, childLast) = _stats(child);
        assertEq(childLast, 40);
        assertEq(childSixty, 5);
    }

    function test_Spawn_IdleParentRecomputesTheCacheFromRealBuckets() public {
        // The parent's only activity (vol[5] = 3) is 25 windows before the fork: the forking query's own creation
        // hits the recompute branch (gap >= 20), so the parent's cache is 0 at 30 and window 5 is outside the horizon.
        _seedVolumeAt(5, 3);

        _warpToWindow(30, 0);
        _forkGenesisWithPreview();
        (uint256 parentSixty, uint256 parentLast) = _stats(GENESIS_UID);
        assertEq(parentSixty, 0);
        assertEq(parentLast, 30);

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        (uint256 sixtyA, uint256 lastA) = _stats(childA);
        assertEq(sixtyA, 0);
        assertEq(lastA, 30);
        _assertBucketEmpty(childA, 5);
        _assertBucket(childA, 30, 0, 1);
        // Hand-derived anchor at f = 0: recent = 1 + 0 = 1, sixty = 1 + 0 = 1, ratio = 20 -> the top of the
        // up-branch, 0.8 + 20 / 5 = 4.8 REP.
        assertEq(_uncappedFee(childA), 4.8 ether);

        // A sibling five windows later: the fill is vol[29] = 0 per window, so window 30 stays at 1 and 31..34
        // stay empty. Cache = 1; recent = 0 + vol[34] = 0 -> the floor, as the parent itself would have read
        // after a quiet window 34. The profit side is what the fill is for here; see the hill-climb suite.
        _warpToWindow(35, 0);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        (uint256 sixtyB, uint256 lastB) = _stats(childB);
        assertEq(sixtyB, 1);
        assertEq(lastB, 35);
        _assertBucket(childB, 30, 0, 1);
        _assertBucketEmpty(childB, 34);
        _assertBucketEmpty(childB, 35);
        assertEq(_uncappedFee(childB), FLOOR_FEE);
    }

    function test_Spawn_BootstrapEraForkCopiesOnlyRealBuckets() public {
        // vol[1] = 1, vol[2] = 3 with profit p, forking query at the start of window 3: vol[3] = 1, cache 4.
        // Windows below 0 are pre-genesis: bootstrap ON READ for the child exactly as for the parent, never stored.
        _seedVolumeAt(1, 1);
        _seedVolumeAt(2, 2);
        uint256 profit = _seedProfitAt(2);

        _warpToWindow(3, 0);
        (, uint256 parentFee) = _forkGenesisWithPreview();
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);

        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childLast, 3);
        assertEq(childSixty, 4);
        _assertBucketEmpty(child, 0);
        _assertBucket(child, 1, 0, 1);
        _assertBucket(child, 2, profit, 3);
        _assertBucket(child, 3, 0, 1);

        // Bootstrap branch at f = 0 (window 3 < 20): vol[3] = 1, vol[2] = 3, cache 4, no real oldest window ->
        // recent 4 over sixty 1 + 4 + 16 * 3 + 3 = 56, ratio 80/56 on the up-branch -> 1.0857... REP. The mirror
        // with those volumes is the readable expectation; the same fee the parent quoted.
        uint256 childFee = _uncappedFee(child);
        assertEq(childFee, QueryFeeMirror.expectedFee(multiverse, DEFAULT_FEE, 3, 0, 1, 3, 4, 0));
        assertEq(childFee, parentFee);

        // Profit view at the start of window 3: the current month is windows 3..-6 plus the whole boundary
        // window -7 -> p + 7 * BOOT_PROFIT; the previous month is windows -8..-16 plus the whole oldest window
        // -17 -> 10 * BOOT_PROFIT.
        uint256 boot = multiverse.BOOT_PROFIT();
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(child);
        assertEq(currentProfit, profit + 7 * boot);
        assertEq(lastProfit, 10 * boot);

        // Start of window 4: window 3 is the previous window (recent 1) and the cache rolls in memory to
        // vol[0..3] = 5; sixty = 5 + 15 * 3 + 3 = 53 puts the ratio 20/53 on the down-branch (a sixth power,
        // 0.1464... REP), so the mirror with prevVol = 1 and sixtyStorage = 5 is the readable expectation.
        _warpToWindow(4, 0);
        assertEq(_uncappedFee(child), QueryFeeMirror.expectedFee(multiverse, DEFAULT_FEE, 4, 0, 0, 1, 5, 0));
    }

    function test_Spawn_ChildHistoryIsACopyNotAnAlias() public {
        _seedVolumeAt(24, 2);
        _warpToWindow(44, 0);
        _forkGenesisWithPreview();
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        _fundUserInChild(OUTCOME_A, 100 ether);

        // Activity in child A moves only child A: one query in window 44, one at the start of window 45.
        _createQueryIn(childA);
        _warpToWindow(45, 0);
        _createQueryIn(childA);

        _assertBucket(childA, 44, 0, 2);
        _assertBucket(childA, 45, 0, 1);
        (uint256 sixtyA, uint256 lastA) = _stats(childA);
        assertEq(lastA, 45);
        assertEq(sixtyA, 2); // cache at 45 = vol[25..44] = A's own window 44

        _assertBucket(childB, 44, 0, 1);
        _assertBucketEmpty(childB, 45);
        (uint256 sixtyB, uint256 lastB) = _stats(childB);
        assertEq(lastB, 44);
        assertEq(sixtyB, 2); // cache at 44 = vol[24..43] = 2
        _assertBucket(GENESIS_UID, 44, 0, 1);
        _assertBucketEmpty(GENESIS_UID, 45);
    }

    function test_Spawn_NestedForkCarriesGrandparentHistory() public {
        // Genesis: vol[30] = 3 with profit p, forking query at the start of window 44. Child A forks on its own
        // query at the start of window 49; the grandchild spawns there with cache = vol[30] + vol[44] = 4.
        _seedVolumeAt(30, 2);
        uint256 profit = _seedProfitAt(30);
        _warpToWindow(44, 0);
        _forkGenesisWithPreview();
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        _fundUserInChild(OUTCOME_A, 400 ether);

        _warpToWindow(49, 0);
        (uint256 nestedQueryId,) = _createQueryIn(childA);
        _escalateToFork(childA, nestedQueryId, user, user);
        uint248 grandchild = _spawn(childA, OUTCOME_A);

        (uint256 sixtyG, uint256 lastG) = _stats(grandchild);
        assertEq(lastG, 49);
        assertEq(sixtyG, 4);
        _assertBucketEmpty(grandchild, 28);
        _assertBucket(grandchild, 30, profit, 3); // genesis-era, two forks up
        _assertBucket(grandchild, 44, 0, 1);
        _assertBucket(grandchild, 49, 0, 1);
    }

    /* ============================================ BEHAVIOURAL ============================================ */

    function test_Spawn_ChildFeeContinuesTheParentRampAcrossTime() public {
        // vol[24] = 2, vol[43] = 3, forking query mid-window 44 (f = 0.5): vol[44] = 1, cache 5.
        _seedVolumeAt(24, 2);
        _seedVolumeAt(43, 3);
        _warpToWindow(44, multiverse.THREE_DAYS() / 2);
        (, uint256 parentFee) = _forkGenesisWithPreview();
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);
        _fundUserInChild(OUTCOME_A, 100 ether);

        // Same block, hand-derived anchor at f = 0.5: recent = vol[44] + floor(0.5 * vol[43]) = 1 + 1 = 2, sixty
        // = vol[44] + cache - floor(0.5 * vol[24]) = 1 + 5 - 1 = 5, ratio = 20 * 2 / 5 = 8 -> 0.8 + 8 / 5 = 2.4 REP.
        uint256 childFee = _uncappedFee(child);
        assertEq(childFee, 2.4 ether);
        assertEq(childFee, parentFee);

        // Start of window 45: window 44 is the previous window -> recent = 0 + 1 = 1; the cache rolls in memory
        // to vol[25..44] = 3 + 1 = 4 (window 24 left), sixty = 0 + 4 = 4, ratio = 20 * 1 / 4 = 5 -> 0.8 + 1 = 1.8 REP.
        _warpToWindow(45, 0);
        assertEq(_uncappedFee(child), 1.8 ether);

        // Start of window 46: the child's first query is charged off the empty window 45 (the floor) and
        // persists the cache rolled from the copied buckets: vol[26..45] = 3 + 1 = 4.
        _warpToWindow(46, 0);
        (, uint256 charged) = _createQueryIn(child);
        assertEq(charged, FLOOR_FEE);
        (uint256 childSixty, uint256 childLast) = _stats(child);
        assertEq(childLast, 46);
        assertEq(childSixty, 4);
        _assertBucket(child, 46, 0, 1);
    }
}

/// @notice The child's monthly base-fee hill-climb runs on the inherited profit history.
/// @dev Production controller. The read is placed at window 20 so no BOOT_PROFIT term enters either month, and
///      inherited profit (three fees, booked in window 9) sits entirely in the previous month while the child's
///      own profit (one down-curve fee, booked in window 20) is the current month. Profit "did not improve", so
///      the controller flips its fresh direction and RAISES; without the inherited history the current month
///      would beat an empty previous month and the fee would be cut instead.
contract MultiverseForkStatisticsHillClimbTest is ForkStatisticsFixtures {
    QueryFeeController internal controller;

    function _deployFeeController() internal override returns (IQueryFeeController) {
        controller = new QueryFeeController(GENESIS_UID);
        return IQueryFeeController(address(controller));
    }

    function _afterProtocolDeploy() internal override {
        controller.setMultiverse(address(multiverse));
    }

    /// @dev Three genesis queries created in window 8 and resolved in window 9: three fees of profit booked in
    ///      window 9 for a child to inherit. Returns their sum.
    function _seedInheritedProfit() internal returns (uint256 inheritedProfit) {
        _warpToWindow(8, 1 hours);
        uint256[3] memory queryIds;
        for (uint256 i = 0; i < 3; i++) {
            queryIds[i] = _createReportedQuery(OUTCOME_A);
            (,, uint256 fee,,) = multiverse.queries(queryIds[i]);
            inheritedProfit += fee;
        }
        _warpToWindow(9, 1 hours);
        for (uint256 i = 0; i < 3; i++) {
            _resolve(bystander, queryIds[i]);
        }
    }

    /// @dev One fee of the child's own profit, booked in window `windowId`: the user's query created and reported
    ///      an hour into the window before, resolved an hour into `windowId`. Returns the fee.
    function _bookOwnProfitAt(uint248 child, uint256 windowId) internal returns (uint256 ownFee) {
        _warpToWindow(windowId - 1, 1 hours);
        (uint256 ownQueryId, uint256 fee) = _createQueryIn(child);
        vm.prank(user);
        multiverse.report(child, ownQueryId, OUTCOME_A);
        _warpToWindow(windowId, 1 hours);
        vm.prank(bystander);
        multiverse.resolve(child, ownQueryId);
        return fee;
    }

    function test_UpdateBaseFee_ChildHillClimbUsesInheritedProfits() public {
        uint256 inheritedProfit = _seedInheritedProfit();

        // Fork and spawn in window 10; the child's fee state starts at the parent's base, clock at spawn.
        _warpToWindow(10, 1 hours);
        uint256 forkQueryId = _createDefaultQuery();
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);
        uint256 inheritedBase = controller.getQueryFee(child);
        assertEq(inheritedBase, controller.INITIAL_BASE_FEE());
        _fundUserInChild(OUTCOME_A, 200 ether);
        uint256 ownFee = _bookOwnProfitAt(child, 20);

        // Window 20, one day in: previous month = exactly the inherited profit, current month = the own fee.
        _warpToWindow(20, 1 days);
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(child);
        assertEq(lastProfit, inheritedProfit);
        assertEq(currentProfit, ownFee);
        assertLt(currentProfit, lastProfit);

        multiverse.updateBaseFee(child);

        assertEq(controller.getQueryFee(child), inheritedBase * controller.FEE_RATE() / controller.SCALE());
    }

    function test_UpdateBaseFee_LateChildBaselineIsTheParentsMonthAtTheRate() public {
        // Same inherited profit (three fees resolved in window 9), the trigger exactly at the start of window
        // 10, and the child spawned nine windows later at the start of window 19. The gap is filled at a tenth
        // of the parent's 30-day profit per window: the rest of window 10 (whole, f = 0) and windows 11..18.
        uint256 inheritedProfit = _seedInheritedProfit();
        _warpToWindow(10, 0);
        uint256 forkQueryId = _createDefaultQuery();
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);

        _warpToWindow(19, 0);
        uint248 child = _spawn(GENESIS_UID, OUTCOME_A);
        uint256 inheritedBase = controller.getQueryFee(child);
        uint256 profitPerWindow = inheritedProfit / 10;
        _assertBucket(child, 9, inheritedProfit, 0);
        _assertBucket(child, 10, profitPerWindow, 1); // the forking query; the volume fill is vol[9] = 0
        _assertBucket(child, 18, profitPerWindow, 0);
        _assertBucketEmpty(child, 19);
        _fundUserInChild(OUTCOME_A, 200 ether);
        uint256 ownFee = _bookOwnProfitAt(child, 29);

        // Previous month = windows 18..10 at the per-window profit plus the (1 - f) tail of window 9's inherited
        // profit; the own fee is the whole current month. An unfilled gap would have left only the window-9 tail.
        _warpToWindow(29, 1 days);
        uint256 scale = multiverse.SCALE();
        uint256 fraction = 1 days * scale / multiverse.THREE_DAYS();
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(child);
        assertEq(currentProfit, ownFee);
        assertEq(lastProfit, 9 * profitPerWindow + (scale - fraction) * inheritedProfit / scale);
        assertLt(currentProfit, lastProfit);

        multiverse.updateBaseFee(child);

        assertEq(controller.getQueryFee(child), inheritedBase * controller.FEE_RATE() / controller.SCALE());
    }
}
