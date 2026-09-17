// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { console } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";
import { MultiverseHandler } from "./handlers/MultiverseHandler.sol";

/// @notice Stateful fuzzing of the full query lifecycle: createQuery, report, resolve, and claim.
///         Random sequences of handler calls must never violate the global invariants below.
/// @dev Inherits the deployment from MultiverseDeployFixture; funds the handler (query creator)
///      and the reporter actors here, since the amounts are invariant-specific.
///      Settlement zeroes `stake.amount` in storage, so amount-reading invariants compare against
///      the handler's per-stake ghosts and accept a zeroed amount only for a settled stake.
contract MultiverseInvariantTest is MultiverseDeployFixture {
    // Per-account balance pinned so the TOTAL underlying supply is exactly the contract's
    // documented REP domain (100M * 1e18 = 1e26, see the uint96 note on QueryResolution in
    // src/Multiverse.sol): 4 funded accounts (handler + 3 actors) x 2.5e25. Each outcome's stakes
    // are capped at 1% of the supply (1e24) and a fork triggers once two outcomes reach it, so a
    // query's total staked stays orders of magnitude under the uint96 max (~7.9e28), keeping the
    // contract's uint96 stake fields lossless.
    uint256 internal constant HANDLER_REP_BALANCE = 2.5e25;
    uint256 internal constant ACTOR_COUNT = 3;

    MultiverseHandler internal handler;

    function setUp() public override {
        super.setUp();

        address[] memory actors = new address[](ACTOR_COUNT);
        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }

        handler = new MultiverseHandler(multiverse, feeCtl, genesisRep, GENESIS_UID, actors);

        // Fund the handler (query creator) and every actor (reporters) with REP and approve the
        // multiverse to pull query fees and stakes.
        _fundWithRep(address(handler), HANDLER_REP_BALANCE);
        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            _fundWithRep(actors[i], HANDLER_REP_BALANCE);
        }

        // Direct the fuzzer at the handler only, keeps inputs bounded.
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev queryCount equals the number of successful createQuery calls.
    function invariant_QueryCountMatchesGhost() public view {
        assertEq(multiverse.queryCount(), handler.ghostQueriesCreated());
    }

    /// @dev The REP held by the multiverse equals every fee charged plus every stake placed,
    ///      minus everything settlement paid out (resolver/reporter rewards and claims) and minus
    ///      the loser burns destroyed at resolve: REP is conserved through the whole lifecycle.
    function invariant_RepBalanceMatchesFeesAndStakes() public view {
        assertEq(
            genesisRep.balanceOf(address(multiverse)),
            handler.ghostTotalFees() + handler.ghostTotalStaked() - handler.ghostTotalPaidOut()
                - handler.ghostTotalBurned()
        );
    }

    /// @dev Settlement only ever pays out of prior deposits, burn included.
    function invariant_PayoutsNeverExceedDeposits() public view {
        assertLe(
            handler.ghostTotalPaidOut() + handler.ghostTotalBurned(),
            handler.ghostTotalFees() + handler.ghostTotalStaked()
        );
    }

    /// @dev Every created query has a valid outcome count and origin universe.
    function invariant_QueryRecordsWellFormed() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            (uint8 numberOfOutcomes, uint248 originUniverse,,) = multiverse.queries(i);
            assertGe(numberOfOutcomes, multiverse.MIN_OUTCOMES());
            assertLe(numberOfOutcomes, multiverse.MAX_OUTCOMES());
            assertEq(originUniverse, GENESIS_UID);
        }
    }

    /// @dev The escalation ladder respects the per-outcome cap and its live totals match the
    ///      ghosts: every landed stake is at most the cap and so is every outcome's total, each
    ///      outcome's total is the sum of the ghost stakes placed on it, the query total is the sum
    ///      of all of them, and a staker's
    ///      live balance on an outcome equals their ghost stakes on it, or zero exactly when those
    ///      stakes have settled.
    function invariant_LadderTotalsMatchGhosts() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 stakeCount = handler.ghostStakeCount(i);
            if (stakeCount == 0) continue;
            ResolutionView memory r = _resolution(i);
            uint256 totalStaked;
            for (uint256 j = 0; j < stakeCount; ++j) {
                uint256 ghostAmount = handler.ghostStakeAmount(i, j);
                assertLe(ghostAmount, r.cap);
                totalStaked += ghostAmount;

                // The staker's live balance on this outcome: the sum of their unsettled ghost stakes on it.
                address owner = handler.ghostStakeReporter(i, j);
                uint8 outcome = handler.ghostStakeOutcome(i, j);
                uint256 expectedUserStake;
                for (uint256 k = 0; k < stakeCount; ++k) {
                    if (handler.ghostStakeReporter(i, k) != owner || handler.ghostStakeOutcome(i, k) != outcome) continue;
                    if (!handler.ghostClaimed(i, k)) expectedUserStake += handler.ghostStakeAmount(i, k);
                }
                assertEq(multiverse.getUserStake(GENESIS_UID, i, owner, outcome), expectedUserStake);
            }
            assertEq(r.totalStaked, totalStaked);

            // Per-outcome totals: the sum of the ghost stakes placed on each outcome.
            for (uint256 j = 0; j < stakeCount; ++j) {
                uint8 outcome = handler.ghostStakeOutcome(i, j);
                uint256 expectedOutcomeStaked;
                for (uint256 k = 0; k < stakeCount; ++k) {
                    if (handler.ghostStakeOutcome(i, k) == outcome) expectedOutcomeStaked += handler.ghostStakeAmount(i, k);
                }
                assertEq(multiverse.getOutcomeStakes(GENESIS_UID, i, outcome).totalOutcomeStaked, expectedOutcomeStaked);
                assertLe(expectedOutcomeStaked, r.cap);
            }
        }
    }

    /// @dev Every stake after the first one leaves the outcome it backed holding exactly twice the
    ///      total of every other outcome, or sitting at the per-outcome cap when twice the rest would
    ///      have exceeded it. This is what prices an appeal, so it holds after any sequence of
    ///      reports the handler produces.
    function invariant_LatestOutcomeHoldsTwiceTheRestOrSitsAtCap() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            ResolutionView memory r = _resolution(i);
            if (r.stakeCount < 2) continue;
            uint256 onLatest =
                multiverse.getOutcomeStakes(GENESIS_UID, i, r.lastReportedOutcome).totalOutcomeStaked;
            uint256 onTheRest = uint256(r.totalStaked) - onLatest;
            assertTrue(onLatest == 2 * onTheRest || onLatest == r.cap);
        }
    }

    /// @dev Stake times never decrease (same-block stakes are legal, amounts still differ) and
    ///      every stake landed inside its window: the first within THREE_DAYS of the query's
    ///      creation in this universe, each escalation within ONE_DAY of the previous stake. The
    ///      live head time is the ghost time of the latest stake.
    function invariant_StakeTimesMonotonicAndInWindow() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 stakeCount = handler.ghostStakeCount(i);
            if (stakeCount == 0) continue;
            ResolutionView memory r = _resolution(i);
            assertGe(handler.ghostStakeTime(i, 0), r.queryCreateTime);
            assertLe(handler.ghostStakeTime(i, 0), uint256(r.queryCreateTime) + multiverse.THREE_DAYS());
            for (uint256 j = 1; j < stakeCount; ++j) {
                assertGe(handler.ghostStakeTime(i, j), handler.ghostStakeTime(i, j - 1));
                assertLe(handler.ghostStakeTime(i, j), handler.ghostStakeTime(i, j - 1) + multiverse.ONE_DAY());
            }
            assertEq(r.lastStakeTime, handler.ghostStakeTime(i, stakeCount - 1));
        }
    }

    /// @dev A query is resolved on-chain exactly when the handler resolved it, to the outcome the
    ///      escalation determined (the last reported outcome, or INVALID for an expired unreported
    ///      query), and its creation time never moves after createQuery set it.
    function invariant_ResolutionMatchesGhosts() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            ResolutionView memory r = _resolution(i);
            if (handler.ghostResolved(i)) {
                assertEq(r.outcome, handler.ghostResolvedOutcome(i));
                assertTrue(r.outcome != multiverse.UNRESOLVED());
            } else {
                assertEq(r.outcome, multiverse.UNRESOLVED());
            }
            assertEq(r.queryCreateTime, handler.ghostQueryCreateTime(i));
        }
    }

    /// @dev The escalation records match the ghosts: every ghost stake carries a valid outcome (one
    ///      of the query's outcomes or INVALID), consecutive ghost outcomes differ, the stake count
    ///      and latest outcome agree with the handler, and each outcome's first reporter is the
    ///      reporter of the first ghost stake placed on it.
    function invariant_StakeRecordsMatchGhosts() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 stakeCount = handler.ghostStakeCount(i);
            (uint8 numberOfOutcomes,,,) = multiverse.queries(i);
            ResolutionView memory r = _resolution(i);
            assertEq(r.stakeCount, stakeCount);
            for (uint256 j = 0; j < stakeCount; ++j) {
                uint8 outcome = handler.ghostStakeOutcome(i, j);
                assertTrue((outcome >= 1 && outcome <= numberOfOutcomes) || outcome == multiverse.INVALID());
                if (j > 0) assertTrue(outcome != handler.ghostStakeOutcome(i, j - 1));

                bool firstOnOutcome = true;
                for (uint256 k = 0; k < j; ++k) {
                    if (handler.ghostStakeOutcome(i, k) == outcome) firstOnOutcome = false;
                }
                if (firstOnOutcome) {
                    Multiverse.OutcomeStakes memory outcomeStakes = multiverse.getOutcomeStakes(GENESIS_UID, i, outcome);
                    assertEq(outcomeStakes.firstReporter, handler.ghostStakeReporter(i, j));
                    assertEq(outcomeStakes.firstReportTime, handler.ghostStakeTime(i, j));
                }
            }
            if (stakeCount > 0) {
                assertEq(r.lastReportedOutcome, handler.ghostLastOutcome(i));
            }
        }
    }

    /// @dev Only winning stakes of resolved queries ever settle: a claimed ghost implies the query
    ///      is resolved and the stake backed the winning outcome, and an unresolved query has no
    ///      settled stakes.
    function invariant_OnlyWinnersSettle() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 stakeCount = handler.ghostStakeCount(i);
            for (uint256 j = 0; j < stakeCount; ++j) {
                if (!handler.ghostClaimed(i, j)) continue;
                assertTrue(handler.ghostResolved(i));
                assertEq(handler.ghostStakeOutcome(i, j), handler.ghostResolvedOutcome(i));
            }
        }
    }

    /// @dev Per-actor conservation: an actor's REP only moves into stakes it placed itself and
    ///      back out through settlement payouts it received (claims, rewards, auto-settlement).
    function invariant_ActorBalancesConserved() public view {
        for (uint256 i = 0; i < handler.actorsLength(); ++i) {
            address actor = handler.actorAt(i);
            assertEq(
                genesisRep.balanceOf(actor),
                HANDLER_REP_BALANCE - handler.ghostActorStaked(actor) + handler.ghostActorReceived(actor)
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    /// @dev Diagnostic-only, prints handler call counts. Run with `-vv`.
    function invariant_CallSummary() public view {
        console.log("queriesCreated :", handler.ghostQueriesCreated());
        console.log("reportsPlaced  :", handler.ghostReportsPlaced());
        console.log("resolves       :", handler.ghostResolvesPerformed());
        console.log("claims         :", handler.ghostClaimsPerformed());
        console.log("totalFees      :", handler.ghostTotalFees());
        console.log("totalStaked    :", handler.ghostTotalStaked());
        console.log("totalPaidOut   :", handler.ghostTotalPaidOut());
        console.log("totalBurned    :", handler.ghostTotalBurned());
    }
}
