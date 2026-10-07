// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { LituusRep } from "src/LituusRep.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for the forking query's payouts: random ladders over A, B, C and
///         INVALID from three reporters, forked, spawned on every outcome, and claimed into every
///         child.
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

    function _childId(uint256 outcome) internal view returns (uint248) {
        return zoltar.getChildUniverseId(GENESIS_UID, outcome);
    }

    function _universeState(uint248 universeId) internal view returns (Multiverse.UniverseState state) {
        (, state,,,,,,,,,,,) = multiverse.universes(universeId);
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
            uint256 roll = uint256(keccak256(abi.encode(seed, step)));
            uint256 reporterIndex = roll % reporters.length;
            uint256 outcomeIndex = (roll >> 8) % outcomes.length;
            uint256 requiredStake;
            bool found;
            for (uint256 shift = 0; shift < outcomes.length; shift++) {
                uint256 candidate = (outcomeIndex + shift) % outcomes.length;
                try multiverse.getNextRequiredStake(GENESIS_UID, queryId, outcomes[candidate]) returns (uint256 stake) {
                    outcomeIndex = candidate;
                    requiredStake = stake;
                    found = true;
                    break;
                } catch { }
            }
            assertTrue(found, "no stakeable outcome before the fork");

            vm.prank(reporters[reporterIndex]);
            multiverse.report(GENESIS_UID, queryId, outcomes[outcomeIndex]);
            staked[reporterIndex][outcomeIndex] += requiredStake;

            if (_universeState(GENESIS_UID) == Multiverse.UniverseState.Migration) return staked;
        }
        revert("ladder did not fork");
    }

    /// @dev A forking query stake's payout in its child, in parent shares, from the parent record: the stake
    ///      plus the return the capped outcomes get, everything above the cap less what Zoltar burned of the
    ///      fork bond, over the cap. The same in every child.
    function _expectedChildPayout(uint256 queryId, uint256 amount) internal view returns (uint256) {
        (,,, uint96 totalStaked,, uint96 cap, uint96 forkBurn,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
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

                ILituusRep childRep = multiverse.repTokenOf(_childId(outcomes[o]));
                uint256 balanceBefore = childRep.balanceOf(reporters[r]);
                uint256 expected =
                    childRep.convertToShares(genesisRep.convertToAssets(_expectedChildPayout(queryId, amount)));
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
        (,,, uint96 totalStaked,,,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        (,,,,,,,,,,,, uint128 unmigratedBefore) = multiverse.universes(GENESIS_UID);
        // The pot is carried at face value; what is parked is the pot less Zoltar's burn on the bond.
        assertEq(unmigratedBefore, parked + _forkBurn(forkThreshold));

        // The rate is 1 everywhere (no resolution ever burned), so shares equal assets throughout and every
        // payout is exact.
        uint256 principalClaimed = _claimEveryStakeInEveryChild(queryId, staked);
        assertEq(principalClaimed, totalStaked);

        // Every child drew its own winners' payouts (no fee copy: the forking query's fee is excluded),
        // which never add up to the parked balance.
        for (uint256 o = 0; o < outcomes.length; o++) {
            assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, outcomes[o]), parked);
        }

        // The stakes left the supply as counted migration at face value; what stays is the forking query's
        // fee. The burn is accounted on the record, not here.
        (,,,,,,,,,, uint128 totalOut,, uint128 unmigratedAfter) = multiverse.universes(GENESIS_UID);
        assertEq(totalOut, totalStaked);
        assertEq(unmigratedAfter, unmigratedBefore - totalStaked);
        assertEq(unmigratedAfter, fee);
    }

    /// @dev Property: whatever the vault rate, the forking query's two outcomes at the cap hold the fork bond
    /// in shares, the fee on top covers it in REP, the fork fires and leaves no REP behind, and every stake
    /// is still paid in full in its child from a parked balance that is the pot less Zoltar's burn. The rate
    /// is moved directly (shares burned the way a resolution burns them) rather than through ladders, so any
    /// rate gets covered, not only the ones resolutions happen to produce.
    function testFuzz_Fork_TwoCapsCoverTheBondAtAnyRate(uint256 seed, uint256 fee, uint256 burnSeed) public {
        fee = bound(fee, MIN_LADDER_FEE, MAX_LADDER_FEE);
        feeCtl.setFee(fee);
        uint256 sharesToBurn = bound(burnSeed, MIN_RATE_BURN, MAX_RATE_BURN);
        vm.prank(user);
        genesisRep.transfer(address(multiverse), sharesToBurn);
        vm.prank(address(multiverse));
        genesisRep.burnShares(sharesToBurn);
        assertGt(genesisRep.rate(), LituusRep(address(genesisRep)).SCALE());

        uint256 supply = zoltar.getUniverseTheoreticalSupply(GENESIS_UID);
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        uint256 bondShares = genesisRep.convertToSharesUp(forkThreshold);

        (uint256 queryId, uint256[4][3] memory staked) = _buildRandomForkingLadder(seed);
        (,,, uint96 totalStaked,, uint96 cap, uint96 forkBurn,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(cap, genesisRep.convertToSharesUp(supply / multiverse.CAP_DIVISOR()));
        assertGe(totalStaked, 2 * uint256(cap));
        assertGe(totalStaked, bondShares);
        assertGe(genesisRep.convertToAssets(totalStaked) + fee, forkThreshold);

        // Whole pot out of the vault: the bond burned by Zoltar, the credit and the rest parked.
        assertEq(underlying.balanceOf(address(multiverse)), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        (,,,,,,,,,,,, uint128 unmigratedBefore) = multiverse.universes(GENESIS_UID);
        assertEq(unmigratedBefore, parked + _forkBurn(forkThreshold));
        assertEq(forkBurn, genesisRep.convertToSharesUp(_forkBurn(forkThreshold)));

        uint256 principalAssets = _claimEveryStakeInEveryChild(queryId, staked);
        for (uint256 o = 0; o < outcomes.length; o++) {
            assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, outcomes[o]), parked);
        }
        (,,,,,,,,,, uint128 totalOut,, uint128 unmigratedAfter) = multiverse.universes(GENESIS_UID);
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
            ILituusRep childRep = multiverse.repTokenOf(_childId(outcomes[o]));
            if (side.firstReporter == address(0)) {
                // Nothing drawn for this child: no fee copy (the forking query's fee is excluded) and
                // no reporter.
                assertEq(childRep.totalAssets(), 0);
                continue;
            }
            assertEq(childRep.balanceOf(side.firstReporter), expectedReward);
            assertEq(childRep.totalAssets(), expectedReward);
            assertLe(expectedReward, DEFAULT_FEE);
        }
    }
}
