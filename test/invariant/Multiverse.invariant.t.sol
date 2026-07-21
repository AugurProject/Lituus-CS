// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { console } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";
import { MultiverseHandler } from "./handlers/MultiverseHandler.sol";

/// @notice Stateful fuzzing of createQuery and report. Random sequences of handler calls must
///         never violate the global invariants below. The handler never resolves, so every
///         query must stay UNRESOLVED throughout a run.
/// @dev Inherits the deployment from MultiverseDeployFixture; funds the handler (query creator)
///      and the reporter actors here, since the amounts are invariant-specific.
contract MultiverseInvariantTest is MultiverseDeployFixture {
    // Large REP balance for the handler and each actor so cumulative fees and doubling stakes
    // never exhaust them during a run.
    uint256 internal constant HANDLER_REP_BALANCE = 1e40;
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

    /// @dev The REP held by the multiverse equals the sum of every fee charged and every stake
    ///      placed: nothing leaves the contract before resolution.
    function invariant_RepBalanceMatchesFeesAndStakes() public view {
        assertEq(genesisRep.balanceOf(address(multiverse)), handler.ghostTotalFees() + handler.ghostTotalStaked());
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
    ///      threshold (fork-level stakes are guarded out until forking is implemented).
    function invariant_LadderDeterministic() public view {
        uint256 count = multiverse.queryCount();
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        for (uint256 i = 0; i < count; ++i) {
            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            (,, uint256 fee,) = multiverse.queries(i);
            for (uint256 j = 0; j < stakes.length; ++j) {
                assertEq(stakes[j].amount, j == 0 ? fee : stakes[j - 1].amount * 2);
                assertLt(stakes[j].amount, forkThreshold);
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

    /// @dev Reporting alone never resolves: with no resolve action in the handler, every query
    ///      stays UNRESOLVED, and its creation time never moves after createQuery set it.
    function invariant_ReportNeverResolves() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            (uint48 queryCreateTime, uint8 outcome,,) = multiverse.queryResolutions(GENESIS_UID, i);
            assertEq(outcome, multiverse.UNRESOLVED());
            assertEq(queryCreateTime, handler.ghostQueryCreateTime(i));
        }
    }

    /// @dev Every stake record is well-formed and matches the ghosts: valid reported outcome
    ///      (one of the query's outcomes or INVALID), consecutive outcomes differ, and the
    ///      per-query stake count / last outcome / staked total agree with the handler.
    function invariant_StakeRecordsMatchGhosts() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, i);
            (uint8 numberOfOutcomes,,,) = multiverse.queries(i);
            uint256 totalStaked;
            for (uint256 j = 0; j < stakes.length; ++j) {
                uint8 outcome = stakes[j].reportedOutcome;
                assertTrue((outcome >= 1 && outcome <= numberOfOutcomes) || outcome == multiverse.INVALID());
                if (j > 0) assertTrue(outcome != stakes[j - 1].reportedOutcome);
                totalStaked += stakes[j].amount;
            }
            assertEq(stakes.length, handler.ghostStakeCount(i));
            assertEq(totalStaked, handler.ghostQueryStaked(i));
            if (stakes.length > 0) {
                assertEq(stakes[stakes.length - 1].reportedOutcome, handler.ghostLastOutcome(i));
            }
        }
    }

    /// @dev Per-actor conservation: an actor's REP only moves into stakes it placed itself.
    function invariant_ActorBalancesConserved() public view {
        for (uint256 i = 0; i < handler.actorsLength(); ++i) {
            address actor = handler.actorAt(i);
            assertEq(genesisRep.balanceOf(actor), HANDLER_REP_BALANCE - handler.ghostActorStaked(actor));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    /// @dev Diagnostic-only, prints handler call counts. Run with `-vv`.
    function invariant_CallSummary() public view {
        console.log("queriesCreated :", handler.ghostQueriesCreated());
        console.log("reportsPlaced  :", handler.ghostReportsPlaced());
        console.log("totalFees      :", handler.ghostTotalFees());
        console.log("totalStaked    :", handler.ghostTotalStaked());
    }
}
