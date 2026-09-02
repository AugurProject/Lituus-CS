// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MultiverseDeployFixture } from "./Multiverse.fixtures.sol";

/// @notice Test harness exposing the internal profit view as an external function.
contract MultiverseHarness is Multiverse {
    constructor(
        IZoltar zoltar,
        uint248 genesisUniverseId,
        IQueryFeeController queryFeeController,
        address queryTokenizer
    ) Multiverse(zoltar, genesisUniverseId, queryFeeController, queryTokenizer) { }

    function exposed_getProfits(uint248 universeId) external view returns (uint256, uint256) {
        return _getProfits(universeId);
    }
}

/// @notice Unit suite for _getProfits: month bucketing, the currentWindow-10 boundary split, sum conservation
///         across the boundary migration, the currentWindow-20 tail, and the pre-genesis BOOT_PROFIT fallback.
/// @dev Profit is seeded through the real pipeline (createQuery -> report in the same block, so
///      reporterPay is zero -> resolve at a chosen time), never by storage manipulation: a
///      single-stake settlement books profit = fee - reporterPay = fee, into the resolve-time
///      window. The seeded amount is read back from the query record, so the assertions are exact
///      regardless of what the demand modifier charged.
contract MultiverseProfitsTest is MultiverseDeployFixture {
    MultiverseHarness internal harness;

    function _deployMultiverse(IQueryFeeController controller) internal override returns (Multiverse) {
        harness = new MultiverseHarness(zoltar, GENESIS_UID, controller, queryTokenizerStub);
        return Multiverse(address(harness));
    }

    function setUp() public override {
        super.setUp();

        _fundWithRep(user, USER_REP_BALANCE);
    }

    /// @dev Warp to `elapsed` seconds into the given window (windows are GENESIS_TIMESTAMP-anchored,
    ///      which the fixture pins to START_TIME).
    function _warpTo(uint256 windowId, uint256 elapsed) internal {
        vm.warp(START_TIME + windowId * multiverse.THREE_DAYS() + elapsed);
    }

    /// @dev Books profit of exactly the query fee into the window containing `resolveWindow` +
    ///      `resolveElapsed`: create + report in one block two days earlier (reporterPay ramps from
    ///      elapsed reporting time, so it is zero), then resolve at the target time (the one-day
    ///      appeal window has strictly passed). Returns the booked profit.
    function _seedProfitAt(uint256 resolveWindow, uint256 resolveElapsed) internal returns (uint256 profit) {
        uint256 resolveTime = START_TIME + resolveWindow * multiverse.THREE_DAYS() + resolveElapsed;
        vm.warp(resolveTime - 2 days);

        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        (,, profit,) = multiverse.queries(queryId);

        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);

        vm.warp(resolveTime);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_GetProfits_CurrentMonthContainsFreshProfit() public {
        // Profit booked in window 37, read at the start of window 40: window 37 sits among the nine
        // completed windows of the current month, so the whole amount is current-month profit. The
        // read is at currentWindow = 40 with every referenced window (down to currentWindow-20 = 20) past genesis, so
        // no BOOT_PROFIT term can leak in; the previous month is exactly zero.
        uint256 profit = _seedProfitAt(37, 1 hours);

        _warpTo(40, 0);
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(GENESIS_UID);

        assertEq(currentProfit, profit);
        assertEq(lastProfit, 0);
    }

    function test_GetProfits_BoundaryWindowSplitsByFraction() public {
        // Profit booked in window 30, read at currentWindow = 40 where it is the boundary window currentWindow-10: the
        // current month keeps the (1 - fraction) tail and the previous month gets (fraction). Probed at fraction = 0.25
        // and fraction = 0.75 - swapped fractions must swap the shares. A fraction mix-up in the split
        // is invisible to the direction-only integration tests; this pins it directly.
        uint256 profit = _seedProfitAt(30, 1 hours);
        uint256 scale = multiverse.SCALE();

        _warpTo(40, multiverse.THREE_DAYS() / 4);
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(GENESIS_UID);
        assertEq(currentProfit, (scale - scale / 4) * profit / scale);
        assertEq(lastProfit, scale / 4 * profit / scale);

        _warpTo(40, 3 * multiverse.THREE_DAYS() / 4);
        (currentProfit, lastProfit) = harness.exposed_getProfits(GENESIS_UID);
        assertEq(currentProfit, (scale - 3 * scale / 4) * profit / scale);
        assertEq(lastProfit, 3 * scale / 4 * profit / scale);
    }

    function test_GetProfits_BoundaryMigrationConservesSum() public {
        // As the current window elapses, the boundary window's profit migrates continuously from
        // the current month to the previous one: the current share strictly falls, the previous
        // share strictly rises, and their sum equals the booked profit at every probe - nothing is
        // lost or double counted during the migration.
        uint256 profit = _seedProfitAt(30, 1 hours);

        uint256 previousCurrent = type(uint256).max;
        uint256 previousLast = 0;
        for (uint256 tenth = 1; tenth <= 9; tenth += 4) {
            _warpTo(40, tenth * multiverse.THREE_DAYS() / 10);
            (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(GENESIS_UID);

            assertEq(currentProfit + lastProfit, profit);
            assertLt(currentProfit, previousCurrent);
            assertGt(lastProfit, previousLast);

            previousCurrent = currentProfit;
            previousLast = lastProfit;
        }
    }

    function test_GetProfits_OldestWindowKeepsOnlyTail() public {
        // Profit booked in window 20, read at currentWindow = 40 where it is the oldest window currentWindow-20: only
        // its (1 - fraction) tail remains in the previous month and it never touches the current month. As fraction
        // grows the contribution fades toward zero - leaving the 60-day span is gradual, not a
        // cliff.
        uint256 profit = _seedProfitAt(20, 1 hours);
        uint256 scale = multiverse.SCALE();

        _warpTo(40, 0);
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(GENESIS_UID);
        assertEq(currentProfit, 0);
        assertEq(lastProfit, profit);

        _warpTo(40, multiverse.THREE_DAYS() / 2);
        (currentProfit, lastProfit) = harness.exposed_getProfits(GENESIS_UID);
        assertEq(currentProfit, 0);
        assertEq(lastProfit, (scale - scale / 2) * profit / scale);

        _warpTo(40, 9 * multiverse.THREE_DAYS() / 10);
        (currentProfit, lastProfit) = harness.exposed_getProfits(GENESIS_UID);
        assertEq(currentProfit, 0);
        assertEq(lastProfit, (scale - 9 * scale / 10) * profit / scale);
    }

    function test_GetProfits_ScatteredProfitsMatchHandDerivedTotals() public {
        // The realistic end-to-end anchor: profits scattered across the 60-day span, totals checked
        // against fully hand-derived literals (no mirror). Seeds resolve mid-window with elapsed of
        // two days, which places each createQuery at exactly the START of its window (fraction = 0), so
        // every fee is hand-derivable in the real regime (windowId >= 20, no bootstrap):
        //   A @ window25: no prior volume anywhere -> sixty = 0 -> neutral  -> fee = 1e18 exactly.
        //   B @ window30: sixty = {window25} = 1, recent = vol[29] = 0 -> floor  -> fee = 1e18 / 101 floored
        //            = 9900990099009900.
        //   C @ window33: sixty = 2, recent = 0 -> floor -> 9900990099009900.
        //   D @ window37: sixty = 3, recent = 0 -> floor -> 9900990099009900.
        // Read at window 40, fraction = 0.5: the current month holds C + D + half of boundary-window B;
        // the previous month holds the other half of B plus A (i = 15); the oldest window window20 is
        // empty. Hand-summed:
        //   current = 9900990099009900 * 2 + 4950495049504950 = 24752475247524750
        //   last    = 1000000000000000000 + 4950495049504950  = 1004950495049504950
        uint256 seedA = _seedProfitAt(25, 2 days);
        uint256 seedB = _seedProfitAt(30, 2 days);
        uint256 seedC = _seedProfitAt(33, 2 days);
        uint256 seedD = _seedProfitAt(37, 2 days);

        assertEq(seedA, 1 ether);
        assertEq(seedB, 9_900_990_099_009_900);
        assertEq(seedC, 9_900_990_099_009_900);
        assertEq(seedD, 9_900_990_099_009_900);

        _warpTo(40, multiverse.THREE_DAYS() / 2);
        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(GENESIS_UID);

        assertEq(currentProfit, 24_752_475_247_524_750);
        assertEq(lastProfit, 1_004_950_495_049_504_950);
    }

    function test_GetProfits_YoungUniverseUsesBootProfit() public {
        // No profit ever booked, read at the start of window 2: every window that predates genesis
        // falls back to BOOT_PROFIT. Hand-derived at fraction = 0, currentWindow = 2: the current month reads windows
        // 2, 1, 0 as real zeros, windows currentWindow-3..currentWindow-9 as boot (7 terms), and the full boundary tail
        // as boot (1 term) -> 8 x BOOT_PROFIT. The previous month reads windows currentWindow-11..currentWindow-19 as
        // boot (9 terms) plus the full oldest tail (1 term) -> 10 x BOOT_PROFIT. This is the seed the
        // hill-climb's deterministic first-month raise grows from.
        _warpTo(2, 0);

        (uint256 currentProfit, uint256 lastProfit) = harness.exposed_getProfits(GENESIS_UID);

        assertEq(currentProfit, 8 * multiverse.BOOT_PROFIT());
        assertEq(lastProfit, 10 * multiverse.BOOT_PROFIT());
    }
}
