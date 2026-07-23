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
    // src/Multiverse.sol): 4 funded accounts (handler + 3 actors) x 2.5e25. MockZoltar's fork
    // threshold is supply / 20 = 5e24 and stakes clamp at threshold / 2, so a query's total
    // staked stays below supply / 10 = 1e25 — orders of magnitude under the uint96 max
    // (~7.9e28), keeping the contract's totalDistributable/winnerStaked downcasts lossless.
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
    ///      minus everything settlement paid out (resolver/reporter rewards and claims): REP is
    ///      conserved through the whole lifecycle.
    function invariant_RepBalanceMatchesFeesAndStakes() public view {
        assertEq(
            genesisRep.balanceOf(address(multiverse)),
            handler.ghostTotalFees() + handler.ghostTotalStaked() - handler.ghostTotalPaidOut()
        );
    }

    /// @dev Settlement only ever pays out of prior deposits.
    function invariant_PayoutsNeverExceedDeposits() public view {
        assertLe(handler.ghostTotalPaidOut(), handler.ghostTotalFees() + handler.ghostTotalStaked());
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

    /// @dev The escalation ladder is deterministic: the first stake equals the query fee, every
    ///      escalation doubles the previous stake, and no landed stake ever reaches the fork
    ///      threshold (fork-level stakes are guarded out until forking is implemented). Ladder
    ///      arithmetic is checked on the ghost amounts; the live amount must equal its ghost, or
    ///      be zero exactly when the stake has settled.
    function invariant_LadderDeterministic() public view {
        uint256 count = multiverse.queryCount();
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        for (uint256 i = 0; i < count; ++i) {
            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            (,, uint256 fee,) = multiverse.queries(i);
            for (uint256 j = 0; j < stakes.length; ++j) {
                uint256 ghostAmount = handler.ghostStakeAmount(i, j);
                assertEq(ghostAmount, j == 0 ? fee : handler.ghostStakeAmount(i, j - 1) * 2);
                assertLt(ghostAmount, forkThreshold);
                if (handler.ghostClaimed(i, j)) {
                    assertEq(stakes[j].amount, 0);
                } else {
                    assertEq(stakes[j].amount, ghostAmount);
                }
            }
        }
    }

    /// @dev Stake times never decrease (same-block stakes are legal, amounts still differ) and
    ///      every stake landed inside its window: the first within THREE_DAYS of the query's
    ///      creation in this universe, each escalation within ONE_DAY of the previous stake.
    function invariant_StakeTimesMonotonicAndInWindow() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            if (stakes.length == 0) continue;
            (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, i);
            assertGe(stakes[0].time, queryCreateTime);
            assertLe(stakes[0].time, uint256(queryCreateTime) + multiverse.THREE_DAYS());
            for (uint256 j = 1; j < stakes.length; ++j) {
                assertGe(stakes[j].time, stakes[j - 1].time);
                assertLe(stakes[j].time, uint256(stakes[j - 1].time) + multiverse.ONE_DAY());
            }
        }
    }

    /// @dev A query is resolved on-chain exactly when the handler resolved it, to the outcome the
    ///      escalation determined (the last reported outcome, or INVALID for an expired unreported
    ///      query), and its creation time never moves after createQuery set it.
    function invariant_ResolutionMatchesGhosts() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            (uint48 queryCreateTime, uint8 outcome,,) = multiverse.queryResolutions(GENESIS_UID, i);
            if (handler.ghostResolved(i)) {
                assertEq(outcome, handler.ghostResolvedOutcome(i));
                assertTrue(outcome != multiverse.UNRESOLVED());
            } else {
                assertEq(outcome, multiverse.UNRESOLVED());
            }
            assertEq(queryCreateTime, handler.ghostQueryCreateTime(i));
        }
    }

    /// @dev Every stake record is well-formed and matches the ghosts: valid reported outcome
    ///      (one of the query's outcomes or INVALID), consecutive outcomes differ, and the
    ///      per-query stake count / last outcome / per-stake owner and outcome agree with the
    ///      handler.
    function invariant_StakeRecordsMatchGhosts() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            (uint8 numberOfOutcomes,,,) = multiverse.queries(i);
            for (uint256 j = 0; j < stakes.length; ++j) {
                uint8 outcome = stakes[j].reportedOutcome;
                assertTrue((outcome >= 1 && outcome <= numberOfOutcomes) || outcome == multiverse.INVALID());
                if (j > 0) assertTrue(outcome != stakes[j - 1].reportedOutcome);
                assertEq(outcome, handler.ghostStakeOutcome(i, j));
                assertEq(stakes[j].reporter, handler.ghostStakeReporter(i, j));
            }
            assertEq(stakes.length, handler.ghostStakeCount(i));
            if (stakes.length > 0) {
                assertEq(stakes[stakes.length - 1].reportedOutcome, handler.ghostLastOutcome(i));
            }
        }
    }

    /// @dev The totals frozen at resolution are consistent with the ladder that produced them:
    ///      winnerStaked is the sum of the original amounts staked on the winning outcome, and
    ///      totalDistributable is the losers' total minus the burn cut. Unresolved queries keep
    ///      both at zero.
    function invariant_SettlementTotalsConsistent() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, i);
            uint256 stakeCount = handler.ghostStakeCount(i);
            if (!handler.ghostResolved(i) || stakeCount == 0) {
                assertEq(totalDistributable, 0);
                assertEq(winnerStaked, 0);
                continue;
            }

            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            uint8 winnerOutcome = handler.ghostResolvedOutcome(i);
            uint256 expectedWinnerStaked;
            uint256 totalStaked;
            for (uint256 j = 0; j < stakeCount; ++j) {
                uint256 ghostAmount = handler.ghostStakeAmount(i, j);
                totalStaked += ghostAmount;
                if (stakes[j].reportedOutcome == winnerOutcome) expectedWinnerStaked += ghostAmount;
            }
            uint256 losers = totalStaked - expectedWinnerStaked;
            assertEq(winnerStaked, expectedWinnerStaked);
            // Literal on purpose (BURN_DIVIDER = 5): recomputing with the contract's own constant
            // would pass even if the constant were changed to a wrong value.
            assertEq(totalDistributable, losers - losers / 5);
        }
    }

    /// @dev Only winning stakes of resolved queries ever settle: a claimed ghost implies the query
    ///      is resolved and the stake backed the winning outcome, and an unresolved query has no
    ///      settled stakes.
    function invariant_OnlyWinnersSettle() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 stakeCount = handler.ghostStakeCount(i);
            if (stakeCount == 0) continue;
            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            for (uint256 j = 0; j < stakeCount; ++j) {
                if (!handler.ghostClaimed(i, j)) continue;
                assertTrue(handler.ghostResolved(i));
                assertEq(stakes[j].reportedOutcome, handler.ghostResolvedOutcome(i));
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
    }
}
