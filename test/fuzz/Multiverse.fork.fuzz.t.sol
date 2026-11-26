// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Multiverse } from "src/Multiverse.sol";
import { LituusRep } from "src/LituusRep.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MultiverseHelpers } from "src/libraries/MultiverseHelpers.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for the forking query's payouts and the settlement of the parent's other
///         queries: random ladders over A, B, C and INVALID from three reporters, forked, spawned on every
///         outcome, and claimed into every child.
/// @dev The fee bound keeps the first stake well below the cap so ladders take several rounds to fork,
///      and keeps every reporter's cumulative stakes within its balance: the two capped outcomes hold
///      the cap each and no other outcome can exceed it. The third reporter gets wREP wrapped from the
///      test contract's unwrapped REP, so the supply and the cap stay where the fixture put them.
///      Stakes are tracked per (reporter, outcome) from the stake required before each report, so
///      every payout is checked against an independent record, not against the contract's own view.
contract MultiverseForkFuzzTest is MultiverseFuzzFixtures {
    uint256 internal constant MIN_LADDER_FEE = 1e12;
    uint256 internal constant MAX_LADDER_FEE = 0.1 ether;
    uint256 internal constant MAX_LADDER_STEPS = 256;
    uint256 internal constant EXTRA_REPORTER_BALANCE = 500 ether;
    // Shares burned to move the rate off 1: enough to register in the rate's 18 decimals at the low end, and
    // leaving the user 200 ether at the high end, enough for the cap on every outcome.
    uint256 internal constant MIN_RATE_BURN = 0.001 ether;
    uint256 internal constant MAX_RATE_BURN = 800 ether;
    // The same ahead of a fork escalated by two reporters from fresh balances: both still afford the cap.
    uint256 internal constant MAX_TIP_RATE_BURN = 100 ether;
    // Side queries of the settlement fuzz: with at most three reports on a fee of 0.1 ether or less, a
    // ladder never gets anywhere near the cap.
    uint256 internal constant SIDE_QUERIES = 3;
    uint256 internal constant MAX_SIDE_REPORTS = 3;
    uint256 internal constant INVALID_OUTCOME = type(uint256).max;

    address internal reporterTwo = makeAddr("reporterTwo");
    address[3] internal reporters;
    // The forking query's outcome set: three valid outcomes plus INVALID.
    uint256[4] internal outcomes;

    function setUp() public override {
        super.setUp();

        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, EXTRA_REPORTER_BALANCE, 0);
        genesisRep.transfer(reporterTwo, EXTRA_REPORTER_BALANCE);
        vm.prank(reporterTwo);
        genesisRep.approve(address(multiverse), type(uint256).max);
        assertEq(_capWrep(), 32 * DEFAULT_FEE);

        reporters = [user, reporter, reporterTwo];
        outcomes = [1, 2, 3, INVALID_OUTCOME];
    }

    /// @dev Builds a random ladder on a fresh query until it forks. Returns the query and the stake each
    ///      reporter placed on each outcome, indexed like `reporters` and `outcomes`.
    function _buildRandomForkingLadder(uint256 seed) internal returns (uint256 queryId, uint256[4][3] memory staked) {
        queryId = _createQuery();
        staked = _buildRandomForkingLadderOn(queryId, seed);
    }

    /// @dev Escalates `queryId` until it forks: each step picks a reporter and an outcome from the seed,
    ///      skipping outcomes the contract will not take a stake on (the latest one, or one already
    ///      holding two thirds of the total). Returns the stake each reporter placed on each outcome,
    ///      from the stake required before each report.
    function _buildRandomForkingLadderOn(uint256 queryId, uint256 seed) internal returns (uint256[4][3] memory staked) {
        for (uint256 step = 0; step < MAX_LADDER_STEPS; step++) {
            (uint256 reporterIndex, uint256 outcomeIndex, uint256 stake) =
                _placeRandomReport(queryId, uint256(keccak256(abi.encode(seed, step))));
            staked[reporterIndex][outcomeIndex] += stake;

            if (_universeState(GENESIS_UID) == Multiverse.UniverseState.Migration) return staked;
        }
        revert("ladder did not fork");
    }

    /// @dev Places one report on `queryId` from a reporter and an outcome picked by `roll`, skipping outcomes
    ///      the contract will not take a stake on (the latest one, or one already holding two thirds of the
    ///      total). Returns who staked how much on which outcome, indexed like `reporters` and `outcomes`,
    ///      with the stake read from the quote before the report.
    function _placeRandomReport(uint256 queryId, uint256 roll)
        internal
        returns (uint256 reporterIndex, uint256 outcomeIndex, uint256 stake)
    {
        reporterIndex = roll % reporters.length;
        outcomeIndex = (roll >> 8) % outcomes.length;
        bool found;
        for (uint256 shift = 0; shift < outcomes.length; shift++) {
            uint256 candidate = (outcomeIndex + shift) % outcomes.length;
            try multiverse.getNextRequiredStake(GENESIS_UID, queryId, outcomes[candidate]) returns (uint256 required) {
                outcomeIndex = candidate;
                stake = required;
                found = true;
                break;
            } catch { }
        }
        assertTrue(found, "no stakeable outcome");

        vm.prank(reporters[reporterIndex]);
        multiverse.report(GENESIS_UID, queryId, outcomes[outcomeIndex]);
    }

    /// @dev A forking query stake's payout in its child, in parent shares, from the parent record: the stake
    ///      plus the return the capped outcomes get, everything above the cap less what Zoltar burned of the
    ///      fork bond, over the cap. The same in every child.
    function _expectedChildPayout(uint256 queryId, uint256 amount) internal view returns (uint256) {
        (,,, uint96 totalStaked,, uint96 cap, uint96 forkBurn,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        uint256 distributable = uint256(totalStaked) - cap - forkBurn;
        return amount + amount * distributable / cap;
    }

    /// @dev Zoltar's burn on the fork bond, in REP, from the threshold read before the fork lowered the supply.
    function _forkBurn(uint256 forkThreshold) internal view returns (uint256) {
        return forkThreshold / zoltar.FORK_BURN_DIVISOR();
    }

    /// @dev Spawns every child and claims every recorded stake into its outcome's child, checking each payout
    ///      against the parent record: parent shares to assets at the parent rate, assets to child shares at
    ///      the child's, which starts at the parent's. Returns the claimed principal in assets, as the
    ///      contract counts it.
    ///      A known edge: a payout that makes no child share cannot be claimed on its own. That is a single wei
    ///      at a rate above 1, such as a stake that only filled the last wei to the cap. The child vault's wrap
    ///      rejects the claim and the stake stays in place (see the unit test
    ///      test_MigrateStake_AOneWeiTriggerStakeCannotBeClaimedAlone). Its entry in `staked` is cleared, so the
    ///      caller's totals count only what was claimed.
    function _claimEveryStakeInEveryChild(uint256 queryId, uint256[4][3] memory staked)
        internal
        returns (uint256 principalAssets)
    {
        for (uint256 o = 0; o < outcomes.length; o++) {
            multiverse.spawnChildUniverse(GENESIS_UID, outcomes[o]);
        }
        for (uint256 r = 0; r < reporters.length; r++) {
            for (uint256 o = 0; o < outcomes.length; o++) {
                uint256 amount = staked[r][o];
                assertEq(multiverse.getUserStake(GENESIS_UID, queryId, reporters[r], outcomes[o]), amount);
                if (amount == 0) continue;

                ILituusRep childRep = multiverse.repTokenOf(_childId(GENESIS_UID, outcomes[o]));
                uint256 balanceBefore = childRep.balanceOf(reporters[r]);
                uint256 expected =
                    childRep.convertToShares(genesisRep.convertToAssets(_expectedChildPayout(queryId, amount)));
                if (expected == 0) {
                    vm.prank(reporters[r]);
                    vm.expectRevert(LituusRep.ZeroShares.selector);
                    multiverse.migrateStake(GENESIS_UID, queryId, outcomes[o], outcomes[o]);
                    assertEq(multiverse.getUserStake(GENESIS_UID, queryId, reporters[r], outcomes[o]), amount);
                    staked[r][o] = 0;
                    continue;
                }
                vm.prank(reporters[r]);
                multiverse.migrateStake(GENESIS_UID, queryId, outcomes[o], outcomes[o]);
                assertEq(childRep.balanceOf(reporters[r]) - balanceBefore, expected);
                assertEq(multiverse.getUserStake(GENESIS_UID, queryId, reporters[r], outcomes[o]), 0);
                principalAssets += genesisRep.convertToAssets(amount);
            }
        }
    }

    /// @dev Property: for any ladder, every staker is paid in its outcome's child exactly its stake plus
    /// the capped outcomes' return on it, in that child's wREP; the fork query's stakes become the
    /// counted migration and leave the parked supply one for one; and no child ever draws more than
    /// the whole parked balance, even though every child pays its own winners.
    function testFuzz_MigrateStake_PaysEveryChildFromItsOwnCopyOfThePot(uint256 seed, uint256 fee) public {
        fee = bound(fee, MIN_LADDER_FEE, MAX_LADDER_FEE);
        feeCtl.setFee(fee);
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);

        (uint256 queryId, uint256[4][3] memory staked) = _buildRandomForkingLadder(seed);
        (,,, uint96 totalStaked,,,,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        uint128 unmigratedBefore = _universe(GENESIS_UID).unmigratedSupply;
        // The pot is carried at face value; what is parked is the pot less Zoltar's burn on the bond.
        assertEq(unmigratedBefore, parked + _forkBurn(forkThreshold));

        // The rate is 1 everywhere (no resolution ever burned), so shares equal assets throughout and every
        // payout is exact.
        uint256 principalClaimed = _claimEveryStakeInEveryChild(queryId, staked);
        assertEq(principalClaimed, totalStaked);

        // Every child drew its own winners' payouts (no fee copy: the forking query's fee is left out of it),
        // which never add up to the parked balance.
        for (uint256 o = 0; o < outcomes.length; o++) {
            assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, outcomes[o]), parked);
        }

        // The stakes left the supply as counted migration at face value; what stays is the forking query's
        // fee. The burn is accounted on the record, not here.
        uint128 totalOut = _universe(GENESIS_UID).totalMigratedOut;
        uint128 unmigratedAfter = _universe(GENESIS_UID).unmigratedSupply;
        assertEq(totalOut, totalStaked);
        assertEq(unmigratedAfter, unmigratedBefore - totalStaked);
        assertEq(unmigratedAfter, fee);
    }

    /// @dev Property: whatever the vault rate, the forking query's two outcomes at the cap hold the fork bond
    /// in shares, the fee on top covers it in REP, the fork fires and leaves no REP behind, and every stake
    /// that makes a child share is still paid in full in its child from a parked balance that is the pot less
    /// Zoltar's burn (a stake of a single wei makes none and stays unclaimed). The rate
    /// is moved directly (shares burned the way a resolution burns them) rather than through ladders, so any
    /// rate gets covered, not only the ones resolutions happen to produce.
    function testFuzz_Fork_TwoCapsCoverTheBondAtAnyRate(uint256 seed, uint256 fee, uint256 burnSeed) public {
        fee = bound(fee, MIN_LADDER_FEE, MAX_LADDER_FEE);
        feeCtl.setFee(fee);
        _burnShares(genesisRep, user, bound(burnSeed, MIN_RATE_BURN, MAX_RATE_BURN));
        assertGt(genesisRep.rate(), LituusRep(address(genesisRep)).SCALE());

        uint256 supply = zoltar.getUniverseTheoreticalSupply(GENESIS_UID);
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        uint256 bondShares = genesisRep.convertToSharesUp(forkThreshold);

        (uint256 queryId, uint256[4][3] memory staked) = _buildRandomForkingLadder(seed);
        (,,, uint96 totalStaked,, uint96 cap, uint96 forkBurn,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(cap, genesisRep.convertToSharesUp(supply / multiverse.CAP_DIVISOR()));
        assertGe(totalStaked, 2 * uint256(cap));
        assertGe(totalStaked, bondShares);
        assertGe(genesisRep.convertToAssets(totalStaked) + fee, forkThreshold);

        // Whole pot out of the vault: the bond burned by Zoltar, the credit and the rest parked.
        assertEq(underlying.balanceOf(address(multiverse)), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        uint128 unmigratedBefore = _universe(GENESIS_UID).unmigratedSupply;
        assertEq(unmigratedBefore, parked + _forkBurn(forkThreshold));
        assertEq(forkBurn, genesisRep.convertToSharesUp(_forkBurn(forkThreshold)));

        uint256 principalAssets = _claimEveryStakeInEveryChild(queryId, staked);
        for (uint256 o = 0; o < outcomes.length; o++) {
            assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, outcomes[o]), parked);
        }
        uint128 totalOut = _universe(GENESIS_UID).totalMigratedOut;
        uint128 unmigratedAfter = _universe(GENESIS_UID).unmigratedSupply;
        assertEq(totalOut, principalAssets);
        assertEq(unmigratedAfter, unmigratedBefore - principalAssets);
    }

    /// @dev Property: for any ladder and any delay before its first reports, each child pays the first
    /// reporter of its own outcome the fee ramp at spawn, measured from the query's creation to that
    /// reporter's first report, and pays nothing for an outcome nobody staked on.
    function testFuzz_Spawn_PaysEachChildsFirstReporterTheRamp(uint256 seed, uint256 delay) public {
        // Any delay inside the reporting window; at its end the ramp pays the whole fee.
        delay = bound(delay, 0, multiverse.REPORTING_PERIOD());
        feeCtl.setFee(DEFAULT_FEE);

        uint256 queryId = _createQuery();
        uint256 createdAt = vm.getBlockTimestamp();
        vm.warp(createdAt + delay);
        // The whole ladder lands in one block, so every outcome's first report is at the same time.
        _buildRandomForkingLadderOn(queryId, seed);
        uint256 expectedReward = DEFAULT_FEE * delay / multiverse.REPORTING_PERIOD();

        for (uint256 o = 0; o < outcomes.length; o++) {
            Multiverse.OutcomeStakes memory side = multiverse.getOutcomeStakes(GENESIS_UID, queryId, outcomes[o]);
            multiverse.spawnChildUniverse(GENESIS_UID, outcomes[o]);
            ILituusRep childRep = multiverse.repTokenOf(_childId(GENESIS_UID, outcomes[o]));
            if (side.firstReporter == address(0)) {
                // Nothing drawn for this child: no fee copy (the forking query's fee is left out of it) and
                // no reporter.
                assertEq(childRep.totalAssets(), 0);
                continue;
            }
            assertEq(childRep.balanceOf(side.firstReporter), expectedReward);
            assertEq(childRep.totalAssets(), expectedReward);
            assertLe(expectedReward, DEFAULT_FEE);
        }
    }

    /// @dev A query of the parent other than the forking one: who staked how much on which outcome, indexed
    ///      like `reporters` and `outcomes`, and whether it was resolved before the fork.
    struct SideQuery {
        uint256 id;
        uint256[4][3] staked;
        bool resolved;
    }

    /// @dev Creates SIDE_QUERIES queries with up to MAX_SIDE_REPORTS random reports each, lets every appeal
    ///      window lapse and resolves a random half of the reported ones. A single-stake query hands its
    ///      reporter the stake back at resolution, so its record is already settled and its entry is cleared;
    ///      a ladder of two or more keeps its winners' payouts for the claims lane.
    function _buildSideQueries(uint256 seed) internal returns (SideQuery[] memory side) {
        side = new SideQuery[](SIDE_QUERIES);
        for (uint256 q = 0; q < SIDE_QUERIES; q++) {
            side[q].id = _createQuery();
            uint256 reports = uint256(keccak256(abi.encode(seed, "reports", q))) % (MAX_SIDE_REPORTS + 1);
            for (uint256 i = 0; i < reports; i++) {
                (uint256 r, uint256 o, uint256 stake) =
                    _placeRandomReport(side[q].id, uint256(keccak256(abi.encode(seed, "side", q, i))));
                side[q].staked[r][o] += stake;
            }
        }

        vm.warp(vm.getBlockTimestamp() + multiverse.APPEAL_PERIOD() + 1);
        for (uint256 q = 0; q < SIDE_QUERIES; q++) {
            (,, uint16 stakeCount,,,,,,,) = multiverse.queryResolutions(GENESIS_UID, side[q].id);
            if (stakeCount == 0 || uint256(keccak256(abi.encode(seed, "resolve", q))) % 2 == 0) continue;
            vm.prank(resolver);
            multiverse.resolve(GENESIS_UID, side[q].id);
            side[q].resolved = true;
            if (stakeCount > 1) continue;
            for (uint256 r = 0; r < reporters.length; r++) {
                for (uint256 o = 0; o < outcomes.length; o++) {
                    if (side[q].staked[r][o] == 0) continue;
                    assertEq(multiverse.getUserStake(GENESIS_UID, side[q].id, reporters[r], outcomes[o]), 0);
                    side[q].staked[r][o] = 0;
                }
            }
        }
    }

    /// @dev Settles every side stake into a child picked by `seed`, checking each one against the record: a
    ///      resolved query's winner gets the payout claim() would have made and its loser is refused, any
    ///      other stake comes back as it was. Returns the votes added to each child, indexed like `outcomes`.
    function _settleSideStakes(SideQuery[] memory side, uint256 seed) internal returns (uint256[4] memory votes) {
        for (uint256 q = 0; q < side.length; q++) {
            (,,, uint96 totalStaked,,,, uint256 winner,,) = multiverse.queryResolutions(GENESIS_UID, side[q].id);
            for (uint256 r = 0; r < reporters.length; r++) {
                for (uint256 o = 0; o < outcomes.length; o++) {
                    uint256 amount = side[q].staked[r][o];
                    if (amount == 0) continue;
                    assertEq(multiverse.getUserStake(GENESIS_UID, side[q].id, reporters[r], outcomes[o]), amount);
                    uint256 childIndex = uint256(keccak256(abi.encode(seed, "child", q, r, o))) % outcomes.length;

                    uint256 payout = amount;
                    if (side[q].resolved) {
                        if (outcomes[o] != winner) {
                            vm.prank(reporters[r]);
                            vm.expectRevert(Multiverse.NotAWinningOutcome.selector);
                            multiverse.migrateStake(GENESIS_UID, side[q].id, outcomes[o], outcomes[childIndex]);
                            continue;
                        }
                        uint256 winnerStaked =
                            multiverse.getOutcomeStakes(GENESIS_UID, side[q].id, winner).totalOutcomeStaked;
                        uint256 losers = uint256(totalStaked) - winnerStaked;
                        payout = amount + amount * (losers - losers / multiverse.BURN_DIVIDER()) / winnerStaked;
                    }

                    ILituusRep childRep = multiverse.repTokenOf(_childId(GENESIS_UID, outcomes[childIndex]));
                    uint256 payoutAssets = genesisRep.convertToAssets(payout);
                    uint256 balanceBefore = childRep.balanceOf(reporters[r]);
                    vm.prank(reporters[r]);
                    multiverse.migrateStake(GENESIS_UID, side[q].id, outcomes[o], outcomes[childIndex]);
                    assertEq(childRep.balanceOf(reporters[r]) - balanceBefore, childRep.convertToShares(payoutAssets));
                    assertEq(multiverse.getUserStake(GENESIS_UID, side[q].id, reporters[r], outcomes[o]), 0);
                    votes[childIndex] += payoutAssets;
                }
            }
        }
    }

    /// @dev Property: alongside the forking query, every stake on every other query of the parent is settled
    /// exactly once through migrateStake, into a child of the staker's choice. A query resolved before the
    /// fork pays its winners what claim() would have and refuses its losers; any other query refunds every
    /// stake as it was. Each settlement votes with what it moved, in the child it went to; no child draws
    /// past the parked balance; and what stays unmigrated at the end is the fees of the queries still open,
    /// the forking query's among them.
    function testFuzz_MigrateStake_SettlesEveryQuerysStakesOnce(uint256 seed, uint256 fee) public {
        fee = bound(fee, MIN_LADDER_FEE, MAX_LADDER_FEE);
        feeCtl.setFee(fee);
        SideQuery[] memory side = _buildSideQueries(seed);
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);

        (uint256 forkQueryId, uint256[4][3] memory forkStaked) = _buildRandomForkingLadder(seed);
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        uint128 unmigratedBefore = _universe(GENESIS_UID).unmigratedSupply;
        assertEq(unmigratedBefore, parked + _forkBurn(forkThreshold));

        uint256 totalVotes = _claimEveryStakeInEveryChild(forkQueryId, forkStaked);
        uint256[4] memory sideVotes = _settleSideStakes(side, seed);

        // Every lane voted with what it moved, child by child, and no child overdrew its copy of the pot.
        for (uint256 o = 0; o < outcomes.length; o++) {
            uint256 forkVotes;
            for (uint256 r = 0; r < reporters.length; r++) {
                forkVotes += genesisRep.convertToAssets(forkStaked[r][o]);
            }
            assertEq(_universe(_childId(GENESIS_UID, outcomes[o])).totalMigratedIn, forkVotes + sideVotes[o]);
            totalVotes += sideVotes[o];
            assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, outcomes[o]), parked);
        }
        uint128 totalOut = _universe(GENESIS_UID).totalMigratedOut;
        uint128 unmigratedAfter = _universe(GENESIS_UID).unmigratedSupply;
        assertEq(totalOut, totalVotes);
        assertEq(unmigratedAfter, unmigratedBefore - totalVotes);

        // The fees of the queries still open are all that is left, up to one wei of rounding per settlement:
        // a resolved query consumed its fee at resolution and paid out everything else.
        (,, uint256 forkFee,,) = multiverse.queries(forkQueryId);
        uint256 openFees = genesisRep.convertToAssets(forkFee);
        uint256 settlements = 1;
        for (uint256 q = 0; q < side.length; q++) {
            settlements += reporters.length * outcomes.length;
            if (side[q].resolved) continue;
            (,, uint256 sideFee,,) = multiverse.queries(side[q].id);
            openFees += genesisRep.convertToAssets(sideFee);
        }
        assertGe(unmigratedAfter, openFees);
        assertLe(unmigratedAfter, openFees + settlements);
    }

    /// @dev Property: over two nested forks, each capped or not, at any two rates, the rounding of the tip pools
    /// and of the cuts stays within a few wei and always on the pool's side.
    /// - A fork carries its pool, capped, rounded down to what a child's vault mints for it, and a child's pool
    ///   is exactly that. The pool the fork held stays on its record.
    /// - A query reads what it was owed one level up, cut by carried / pool and rounded down.
    /// - The tips owed never exceed the pool. The pool exceeds them by at most 2 wei per level (a wei per query,
    ///   less one).
    /// - Every query is paid in full out of the grandchild's pool, and what stays in it is that dust.
    /// Three genesis queries are tipped, the first one again in the child, so records sit at both levels.
    function testFuzz_TipCap_RoundingStaysWithinBoundsOverTwoForks(
        uint256[3] memory tipSeeds,
        uint256 childTipSeed,
        uint256 burnSeed,
        uint256 childBurnSeed,
        bool smallTips
    ) public {
        _burnShares(genesisRep, user, bound(burnSeed, MIN_RATE_BURN, MAX_TIP_RATE_BURN));
        uint256 cap1 = genesisRep.totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;
        // Large tips mostly cap both forks, small ones mostly neither.
        uint256 maxTip = smallTips ? cap1 / 8 : cap1;
        uint256[3] memory ids;
        uint256[3] memory tips;
        uint256 pool1;
        for (uint256 i = 0; i < 3; i++) {
            ids[i] = _createQuery();
            tips[i] = bound(tipSeeds[i], 1, maxTip);
            vm.prank(reporter);
            multiverse.tip(GENESIS_UID, ids[i], tips[i]);
            pool1 += tips[i];
        }
        _escalateToFork(GENESIS_UID, _createQuery(), user, reporter);
        // The genesis carries its pool up to the cap, rounded down through its rate.
        uint256 carried1 = genesisRep.convertToShares(genesisRep.convertToAssets(pool1 > cap1 ? cap1 : pool1));
        assertEq(_universe(GENESIS_UID).carriedTips, carried1);
        assertEq(_universe(GENESIS_UID).totalTips, pool1);

        // One level down: the child holds what the genesis carried, and each query is cut by carried1 / pool1.
        multiverse.spawnChildUniverse(GENESIS_UID, 1);
        uint248 child = _childId(GENESIS_UID, 1);
        uint256 ledger1 = _universe(child).totalTips;
        assertEq(ledger1, carried1);
        uint256[3] memory owed1;
        uint256 sum1;
        for (uint256 i = 0; i < 3; i++) {
            owed1[i] = multiverse.getTips(child, ids[i]);
            assertEq(owed1[i], tips[i] * carried1 / pool1);
            sum1 += owed1[i];
        }
        assertLe(sum1, ledger1);
        assertLe(ledger1 - sum1, 2);

        // The child: funded, the first query tipped again, the rate moved, then forked on a query of its own.
        ILituusRep childRep = multiverse.repTokenOf(child);
        _wrapFromZoltar(child, user, USER_REP_BALANCE);
        _wrapFromZoltar(child, reporter, 100 ether);
        uint256 childTip = bound(childTipSeed, 1, maxTip);
        vm.prank(reporter);
        multiverse.tip(child, ids[0], childTip);
        owed1[0] += childTip;
        _burnShares(childRep, user, bound(childBurnSeed, MIN_RATE_BURN, MAX_TIP_RATE_BURN));
        uint256 cap2 = childRep.totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;
        uint256 pool2 = ledger1 + childTip;
        uint256 childForkQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child, "q", 3);
        _escalateToFork(child, childForkQueryId, user, user);
        uint256 carried2 = childRep.convertToShares(childRep.convertToAssets(pool2 > cap2 ? cap2 : pool2));
        assertEq(_universe(child).carriedTips, carried2);
        assertEq(_universe(child).totalTips, pool2);

        // Two levels down: the grandchild holds what the child carried, and what the child owed each query is
        // cut by carried2 / pool2.
        multiverse.spawnChildUniverse(child, 1);
        uint248 grandchild = _childId(child, 1);
        uint256 ledger2 = _universe(grandchild).totalTips;
        assertEq(ledger2, carried2);
        uint256[3] memory owed2;
        uint256 sum2;
        for (uint256 i = 0; i < 3; i++) {
            owed2[i] = multiverse.getTips(grandchild, ids[i]);
            assertEq(owed2[i], owed1[i] * carried2 / pool2);
            sum2 += owed2[i];
        }
        assertLe(sum2, ledger2);
        assertLe(ledger2 - sum2, 4);

        // Every query expires unreported in the grandchild and pays its resolver the fee plus its tips, in full.
        // Two reporting periods on, the resolver's fee share has ramped up to the whole fee.
        ILituusRep grandchildRep = multiverse.repTokenOf(grandchild);
        vm.warp(vm.getBlockTimestamp() + 2 * REPORTING_PERIOD);
        for (uint256 i = 0; i < 3; i++) {
            uint256 resolverBefore = grandchildRep.balanceOf(resolver);
            vm.prank(resolver);
            multiverse.resolve(grandchild, ids[i]);
            assertEq(grandchildRep.balanceOf(resolver) - resolverBefore, DEFAULT_FEE + owed2[i]);
        }
        uint256 leftover = _universe(grandchild).totalTips;
        assertEq(leftover, ledger2 - sum2);
        // The whole-REP fees were paid out exactly, so the dust is all the Multiverse holds there.
        assertEq(grandchildRep.balanceOf(address(multiverse)), leftover);
    }

    /// @dev Property: one cap covers the forking query's tips with an open query's, at any rate, any tip sizes
    /// (capped or not) and any report delay.
    /// - Both queries are cut by carried / held, rounded down, and the two cuts leave at most a wei of the pool.
    /// - In a child whose outcome was reported, the reporter gets the forking query's cut tips to the wei and the
    ///   fee share at most a wei above its own conversion, never above the share earned.
    /// - Every child keeps the rest of the carried pool, nobody reported or not, and holds exactly its pools.
    /// - The spawn draws the fee pool, the tips rounded up and the fee share rounded down: nothing more.
    /// - The open query is paid in full in every child.
    function testFuzz_TipCap_ForkingQuerySharesTheCap(
        uint256 forkTipSeed,
        uint256 openTipSeed,
        uint256 burnSeed,
        uint256 delaySeed
    ) public {
        _burnShares(genesisRep, user, bound(burnSeed, MIN_RATE_BURN, MAX_TIP_RATE_BURN));
        uint256 cap = genesisRep.totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;
        // Up to three caps each: capped forks and uncapped ones.
        uint256 forkTip = bound(forkTipSeed, 1, 3 * cap);
        uint256 openTip = bound(openTipSeed, 0, 3 * cap);
        uint256 openId;
        if (openTip != 0) {
            openId = _createQuery();
            vm.prank(reporter);
            multiverse.tip(GENESIS_UID, openId, openTip);
        }
        uint256 forkQueryId = _createQuery();
        vm.prank(reporter);
        multiverse.tip(GENESIS_UID, forkQueryId, forkTip);
        // The whole ladder lands in one block, `delay` after the query's creation.
        uint256 delay = bound(delaySeed, 0, multiverse.REPORTING_PERIOD());
        vm.warp(vm.getBlockTimestamp() + delay);
        _escalateToFork(GENESIS_UID, forkQueryId, user, reporter);

        uint256 held = _universe(GENESIS_UID).totalTips;
        uint256 carried = _universe(GENESIS_UID).carriedTips;
        assertEq(held, forkTip + openTip);
        assertEq(carried, genesisRep.convertToShares(genesisRep.convertToAssets(held > cap ? cap : held)));
        uint256 forkCut = Math.mulDiv(forkTip, carried, held);
        uint256 openCut = Math.mulDiv(openTip, carried, held);
        assertLe(carried - forkCut - openCut, 1);
        uint256 childPool = carried - forkCut;
        (,, uint256 fee,,) = multiverse.queries(forkQueryId);
        uint256 feeShare = fee * delay / multiverse.REPORTING_PERIOD();
        // The child copies the fee aggregate less the forking query's fee, which goes to its reporter.
        uint256 feePool = _universe(GENESIS_UID).totalQueryFees - fee;

        uint256[3] memory childOutcomes = [OUTCOME_A, OUTCOME_B, INVALID_OUTCOME];
        address[3] memory firstReporters = [user, reporter, address(0)];
        for (uint256 i = 0; i < childOutcomes.length; i++) {
            multiverse.spawnChildUniverse(GENESIS_UID, childOutcomes[i]);
            uint248 child = _childId(GENESIS_UID, childOutcomes[i]);
            ILituusRep childRep = multiverse.repTokenOf(child);
            assertEq(_universe(child).totalTips, childPool);
            if (openTip != 0) assertEq(multiverse.getTips(child, openId), openCut);
            assertEq(childRep.balanceOf(address(multiverse)), uint256(_universe(child).totalQueryFees) + childPool);

            uint256 drawn = feePool > 1 ? genesisRep.convertToAssets(feePool) : 0;
            if (firstReporters[i] == address(0)) {
                if (childPool != 0) drawn += genesisRep.convertToAssetsUp(childPool);
            } else {
                if (carried != 0) drawn += genesisRep.convertToAssetsUp(carried);
                if (feeShare > 1) drawn += genesisRep.convertToAssets(feeShare);
                // A brand-new vault: the reporter's whole balance is the spawn payment.
                uint256 feeShares = childRep.balanceOf(firstReporters[i]) - forkCut;
                assertLe(feeShares, feeShare);
                if (feeShare > 1) {
                    assertGe(feeShares, childRep.convertToShares(genesisRep.convertToAssets(feeShare)));
                }
            }
            assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, childOutcomes[i]), drawn);
        }

        // The open query expires unreported in every child and pays its resolver the fee plus its cut tips.
        if (openTip == 0) return;
        vm.warp(vm.getBlockTimestamp() + 2 * multiverse.REPORTING_PERIOD());
        (,, uint256 openFee,,) = multiverse.queries(openId);
        for (uint256 i = 0; i < childOutcomes.length; i++) {
            uint248 child = _childId(GENESIS_UID, childOutcomes[i]);
            ILituusRep childRep = multiverse.repTokenOf(child);
            uint256 before = childRep.balanceOf(resolver);
            vm.prank(resolver);
            multiverse.resolve(child, openId);
            assertEq(childRep.balanceOf(resolver) - before, openFee + openCut);
            assertEq(_universe(child).totalTips, childPool - openCut);
        }
    }

    /// @dev The fees `universeId` still owes: those of the `count` queries in `queryIds` it has not resolved.
    function _openFees(uint248 universeId, uint256[3] memory queryIds, uint256 count)
        internal
        view
        returns (uint256 owed)
    {
        for (uint256 i = 0; i < count; i++) {
            if (multiverse.getOutcome(universeId, queryIds[i]) != 0) continue;
            (,, uint256 fee,,) = multiverse.queries(queryIds[i]);
            owed += fee;
        }
    }

    /// @dev The fee pool of `universeId` is at most the fees its open queries carry and short of them by at most
    ///      `depth` wei: a wei per fork above it, the rounding of the copy. A pool short by more is a ledger bug
    ///      the clamp would hide.
    function _assertFeePoolWithinDepth(uint248 universeId, uint256[3] memory queryIds, uint256 count, uint256 depth)
        internal
        view
    {
        uint256 owed = _openFees(universeId, queryIds, count);
        uint256 pool = _universe(universeId).totalQueryFees;
        assertLe(pool, owed);
        assertLe(owed - pool, depth);
    }

    /// @dev Property: fee pools copied through two forks at any two rates run short by at most a wei per fork, and
    /// every query still resolves, consuming the fee or what is left of the pool.
    /// - Up to three queries with uneven fees; the genesis forks on a fresh query, the child on one of them or on a
    ///   fresh one of its own, at a random delay, so its reporter earns part of the fee or all of it.
    /// - In the child and the grandchild: pool <= open fees <= pool + fork depth.
    /// - The child's forking reporter is paid the ramp on the fee the spawn takes out of the child's pool: the fee,
    ///   or the pool if that is less. Both stake claims into the grandchildren succeed without drawing past the
    ///   parked balance.
    /// - In the grandchild every query resolves, some reported and some not, in a random order; each consumes the
    ///   fee or the rest of the pool, whichever is less. The pool ends empty and the Multiverse holds nothing
    ///   there.
    function testFuzz_FeePool_ShortChildsPayWhatTheyHold(
        uint256[3] memory feeSeeds,
        uint256 countSeed,
        uint256 burnSeed,
        uint256 childBurnSeed,
        bool forkOnOpenQuery,
        uint256 delaySeed,
        uint256 orderSeed,
        uint8 reportMask
    ) public {
        _burnShares(genesisRep, user, bound(burnSeed, MIN_RATE_BURN, MAX_TIP_RATE_BURN));
        uint256 count = bound(countSeed, 1, 3);
        uint256[3] memory queryIds;
        for (uint256 i = 0; i < count; i++) {
            feeCtl.setFee(bound(feeSeeds[i], 2, 2 ether));
            queryIds[i] = _createQuery();
        }
        feeCtl.setFee(DEFAULT_FEE);
        _escalateToFork(GENESIS_UID, _createQuery(), user, reporter);
        uint256 genesisForkTime = vm.getBlockTimestamp();

        // One fork level down.
        multiverse.spawnChildUniverse(GENESIS_UID, 1);
        uint248 child = _childId(GENESIS_UID, 1);
        _assertFeePoolWithinDepth(child, queryIds, count, 1);

        // The child: funded, its rate moved, then forked by `user` alone, at a random point of the window its
        // inherited queries restarted at the genesis fork.
        ILituusRep childRep = multiverse.repTokenOf(child);
        _wrapFromZoltar(child, user, USER_REP_BALANCE);
        _burnShares(childRep, user, bound(childBurnSeed, MIN_RATE_BURN, MAX_TIP_RATE_BURN));
        uint256 forkQueryId;
        if (forkOnOpenQuery) {
            forkQueryId = queryIds[0];
        } else {
            feeCtl.setFee(bound(feeSeeds[0] >> 128, 2, 2 ether));
            forkQueryId = multiverse.queryCount();
            vm.prank(user);
            multiverse.createQuery(child, "q", 3);
            feeCtl.setFee(DEFAULT_FEE);
        }
        uint256 delay = bound(delaySeed, 0, multiverse.REPORTING_PERIOD());
        vm.warp(genesisForkTime + delay);
        _escalateToFork(child, forkQueryId, user, user);
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), child);
        // The forking query's fee stays in the child's frozen pool. Each spawn takes out the fee, or what the
        // pool holds if that is less, and its reporter earns the ramp on that, from the start of the window (the
        // genesis fork) to the first reports.
        uint256 feeShare;
        {
            (,, uint256 forkFee,,) = multiverse.queries(forkQueryId);
            uint256 childPool = _universe(child).totalQueryFees;
            feeShare = MultiverseHelpers._timeBasedFeeShare(
                forkFee < childPool ? forkFee : childPool, delay, multiverse.REPORTING_PERIOD()
            );
        }

        // Two fork levels down. The forking query's reporter is paid that ramp, and the stake claims into both
        // grandchildren find their REP parked.
        uint248[2] memory grandchildren;
        for (uint256 o = 0; o < 2; o++) {
            multiverse.spawnChildUniverse(child, o + 1);
            grandchildren[o] = _childId(child, o + 1);
            ILituusRep spawnedRep = multiverse.repTokenOf(grandchildren[o]);
            // A fee share of a single wei makes no child share and stays parked.
            assertEq(
                spawnedRep.balanceOf(user),
                feeShare > 1 ? spawnedRep.convertToShares(childRep.convertToAssets(feeShare)) : 0
            );
            vm.prank(user);
            multiverse.migrateStake(child, forkQueryId, o + 1, o + 1);
            assertLe(zoltar.splitPerChild(address(multiverse), child, o + 1), parked);
        }
        uint248 grandchild = grandchildren[0];
        ILituusRep grandchildRep = multiverse.repTokenOf(grandchild);
        _assertFeePoolWithinDepth(grandchild, queryIds, count, 2);

        // Half way through the restarted window, some of the open queries are reported, the rest left to expire.
        _wrapFromZoltar(grandchild, reporter, 100 ether);
        vm.warp(vm.getBlockTimestamp() + multiverse.REPORTING_PERIOD() / 2);
        for (uint256 i = 0; i < count; i++) {
            if (multiverse.getOutcome(grandchild, queryIds[i]) != 0 || (reportMask >> i) & 1 == 0) continue;
            vm.prank(reporter);
            multiverse.report(grandchild, queryIds[i], 1);
        }
        vm.warp(vm.getBlockTimestamp() + 2 * multiverse.REPORTING_PERIOD());

        // Each resolution consumes the fee or the rest of the pool, whichever is less.
        uint256 start = bound(orderSeed, 0, count - 1);
        for (uint256 k = 0; k < count; k++) {
            uint256 queryId = queryIds[(start + k) % count];
            if (multiverse.getOutcome(grandchild, queryId) != 0) continue;
            (,, uint256 fee,,) = multiverse.queries(queryId);
            uint256 poolBefore = _universe(grandchild).totalQueryFees;
            vm.prank(resolver);
            multiverse.resolve(grandchild, queryId);
            assertEq(_universe(grandchild).totalQueryFees, poolBefore - (fee < poolBefore ? fee : poolBefore));
        }
        assertEq(_universe(grandchild).totalQueryFees, 0);
        assertEq(grandchildRep.balanceOf(address(multiverse)), 0);
    }
}
