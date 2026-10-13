// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";
import { MultiverseHarness } from "../unit/Multiverse.harness.sol";
import { QueryFeeMirror } from "../unit/QueryFee.mirror.sol";

/// @notice Property-based test for the history a child inherits at spawn: a random parent history (volume and
///         profit over the 25 windows before a random fork window), a random trigger moment inside the fork
///         window and a random spawn delay inside the migration window. The child must hold the parent's real
///         buckets for the 21 windows ending at its spawn window, with the frozen gap between the trigger and
///         the spawn filled from the parent's per-window volume and profit as of the trigger, the cache those
///         buckets sum to, and the mirror's fee off them.
/// @dev The parent is frozen from the trigger, so its buckets and its profit view at the trigger are read after
///      the fact to build the expectation. The fill rule is restated here; the unit suite pins it with literals.
contract MultiverseForkStatisticsFuzzTest is MultiverseFuzzFixtures {
    uint256 internal constant MAX_FORK_WINDOW = 50;
    uint256 internal constant HISTORY_WINDOWS = 25;
    // High enough that the one-query tolerance of the pricing checks below is small against the volumes.
    uint256 internal constant MAX_VOLUME_PER_WINDOW = 6;

    MultiverseHarness internal harness;

    struct Fill {
        uint256 triggerWindow;
        uint256 triggerFraction;
        uint256 spawnWindow;
        uint256 spawnFraction;
        uint256 volumePerWindow;
        uint256 profitPerWindow;
    }

    function _deployMultiverse(IQueryFeeController controller) internal override returns (Multiverse) {
        harness = new MultiverseHarness(
            zoltar, GENESIS_UID, controller, queryTokenizerStub, MIGRATION_DURATION, REPORTING_PERIOD, APPEAL_PERIOD
        );
        return Multiverse(address(harness));
    }

    function _volume(uint248 universeId, uint256 windowId) internal view returns (uint256 volume) {
        (, volume) = harness.exposed_threeDayInfo(universeId, windowId);
    }

    function _fraction() internal view returns (uint256) {
        uint256 threeDays = multiverse.THREE_DAYS();
        return (vm.getBlockTimestamp() - START_TIME) % threeDays * multiverse.SCALE() / threeDays;
    }

    /// @dev The moment a window's history seeding is complete: the profit seed's resolve.
    function _historyEnd() internal view returns (uint256) {
        return 1 hours + multiverse.APPEAL_PERIOD() + 1;
    }

    /// @dev Create + report in one block, resolve past the appeal window: profit = fee, same window.
    function _seedProfitAt(uint256 windowId) internal {
        _warpToWindow(windowId, 1 hours);
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);
        _warpToWindow(windowId, _historyEnd());
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    /// @dev The bucket the child must hold at `windowId`: the parent's real bucket (none after the trigger
    ///      window) plus the window's frozen span — from the trigger in the trigger window, to the spawn in the
    ///      spawn window, whole in between — at the per-window values.
    function _expectedBucket(Fill memory fill, uint256 windowId)
        internal
        view
        returns (uint256 profit, uint256 volume)
    {
        uint256 scale = multiverse.SCALE();
        if (windowId <= fill.triggerWindow) (profit, volume) = harness.exposed_threeDayInfo(GENESIS_UID, windowId);
        if (windowId >= fill.triggerWindow) {
            uint256 frozenEnd = windowId == fill.spawnWindow ? fill.spawnFraction : scale;
            uint256 frozenStart = windowId == fill.triggerWindow ? fill.triggerFraction : 0;
            volume += fill.volumePerWindow * (frozenEnd - frozenStart) / scale;
            profit += fill.profitPerWindow * (frozenEnd - frozenStart) / scale;
        }
    }

    function testFuzz_Spawn_ChildInheritsTheParentsHistoryWithTheGapFilled(
        uint256 seed,
        uint256 forkWindow,
        uint256 triggerOffset,
        uint256 delay
    ) public {
        forkWindow = bound(forkWindow, 0, MAX_FORK_WINDOW);
        // Anywhere in the fork window after its history is seeded (one day and an hour in).
        triggerOffset = bound(triggerOffset, _historyEnd() + 1, multiverse.THREE_DAYS() - 1);
        delay = bound(delay, 0, MIGRATION_DURATION - 1);

        // Random history over the windows before the fork (and the fork window itself, before the trigger).
        uint256 firstWindow = forkWindow >= HISTORY_WINDOWS ? forkWindow - HISTORY_WINDOWS : 0;
        for (uint256 w = firstWindow; w <= forkWindow; w++) {
            uint256 roll = uint256(keccak256(abi.encode(seed, w)));
            if (roll % 4 == 0) _seedProfitAt(w);
            _warpToWindow(w, _historyEnd());
            for (uint256 q = 0; q < (roll >> 8) % (MAX_VOLUME_PER_WINDOW + 1); q++) {
                _createQuery();
            }
        }

        Fill memory fill;
        fill.triggerWindow = forkWindow;
        _warpToWindow(forkWindow, triggerOffset);
        fill.triggerFraction = _fraction();
        _escalateToFork(GENESIS_UID, _createQuery(), user, reporter);
        uint256 forkTime = vm.getBlockTimestamp();

        // The parent's per-window values as of the trigger, as the contract defines them: the count of the
        // window before the trigger window, and a tenth of the 30-day profit its hill-climb read. Read now: the
        // parent is frozen. Its own recent volume at the trigger is kept for the pricing check below.
        fill.volumePerWindow = forkWindow >= 1 ? _volume(GENESIS_UID, forkWindow - 1) : multiverse.BOOT_VOLUME();
        (uint256 parentCurrentProfit,) = harness.exposed_getProfits(GENESIS_UID);
        fill.profitPerWindow = parentCurrentProfit / 10;
        uint256 parentRecentVolume = harness.exposed_recentVolume(GENESIS_UID);

        vm.warp(forkTime + delay);
        multiverse.spawnChildUniverse(GENESIS_UID, 1);
        uint248 child = _childId(GENESIS_UID, 1);
        fill.spawnWindow = (vm.getBlockTimestamp() - START_TIME) / multiverse.THREE_DAYS();
        fill.spawnFraction = _fraction();

        // The 21 buckets ending at the spawn window, and nothing older.
        uint256 expectedSixty;
        for (uint256 i = 0; i <= 20; i++) {
            if (fill.spawnWindow < i) break;
            uint256 w = fill.spawnWindow - i;
            (uint256 expectedProfit, uint256 expectedVolume) = _expectedBucket(fill, w);
            (uint256 profit, uint256 volume) = harness.exposed_threeDayInfo(child, w);
            assertEq(volume, expectedVolume, "volume");
            assertEq(profit, expectedProfit, "profit");
            if (i >= 1) expectedSixty += expectedVolume;
        }
        if (fill.spawnWindow >= 21) {
            (uint256 profit, uint256 volume) = harness.exposed_threeDayInfo(child, fill.spawnWindow - 21);
            assertEq(volume, 0, "horizon volume");
            assertEq(profit, 0, "horizon profit");
        }

        // The cache the child's own roll would produce from those buckets.
        (uint128 childSixty, uint128 childLast) = multiverse.universeStatistics(child);
        assertEq(childLast, fill.spawnWindow, "lastWindowId");
        assertEq(childSixty, expectedSixty, "sixtyDayVolume");

        // What the child is priced on: inside the trigger window, the parent's recent volume at the trigger
        // (the frozen part of the window is completed from the previous window's count, as the parent was
        // extrapolating it); from the second window after the trigger, the previous window's count, whatever
        // the spawn moment. In between the two blend. The span is split across two buckets floored separately,
        // so one query can be lost against a single floor, never gained.
        uint256 childRecentVolume = harness.exposed_recentVolume(child);
        if (fill.spawnWindow == fill.triggerWindow) {
            assertLe(childRecentVolume, parentRecentVolume, "child recent volume (trigger window)");
            assertGe(childRecentVolume + 1, parentRecentVolume, "child recent volume (trigger window)");
        } else if (fill.spawnWindow >= fill.triggerWindow + 2) {
            assertLe(childRecentVolume, fill.volumePerWindow, "child recent volume (later)");
            assertGe(childRecentVolume + 1, fill.volumePerWindow, "child recent volume (later)");
        }

        // A spawn in the trigger's own block is a plain copy: the profit view is the parent's.
        if (delay == 0) {
            (uint256 childCurrent, uint256 childLastProfit) = harness.exposed_getProfits(child);
            (uint256 parentCurrent, uint256 parentLastProfit) = harness.exposed_getProfits(GENESIS_UID);
            assertEq(childCurrent, parentCurrent, "current profit");
            assertEq(childLastProfit, parentLastProfit, "last profit");
        }

        // The mirror's fee off the inherited state.
        (, uint256 currentVolume) = _expectedBucket(fill, fill.spawnWindow);
        uint256 previousVolume;
        uint256 oldestVolume;
        if (fill.spawnWindow >= 1) (, previousVolume) = _expectedBucket(fill, fill.spawnWindow - 1);
        if (fill.spawnWindow >= 20) (, oldestVolume) = _expectedBucket(fill, fill.spawnWindow - 20);
        (uint256 childFee,,) = multiverse.getMintPricing(child);
        assertEq(
            childFee,
            QueryFeeMirror.expectedFee(
                multiverse,
                DEFAULT_FEE,
                fill.spawnWindow,
                fill.spawnFraction,
                currentVolume,
                previousVolume,
                expectedSixty,
                oldestVolume
            ),
            "fee"
        );
    }
}
