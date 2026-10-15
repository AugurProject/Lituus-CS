// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";
import { MultiverseForkHandler } from "./handlers/MultiverseForkHandler.sol";

/// @notice Stateful fuzzing of a forked genesis: random sequences of spawn, migrate, stake settlements, time
///         moves and the fork's resolution must keep the migration accounting consistent.
/// @dev The genesis is forked in setUp on a query the three actors staked on (one of them on a third
///      outcome that never reaches the cap), next to a query resolved before the fork and one left open, so
///      every handler action has something to work with from the first call. The resolution burns before
///      the fork, so the parent's rate is above 1 throughout. The pot at the fork is pinned here, at face
///      value and as parked (net of Zoltar's burn on the fork bond), and the invariants hold the counters
///      against them.
contract MultiverseForkInvariantTest is MultiverseDeployFixture {
    uint256 internal constant ACTOR_REP_BALANCE = 1000 ether;
    uint256 internal constant ACTOR_COUNT = 3;

    MultiverseForkHandler internal handler;
    address[] internal actors;
    uint256 internal forkQueryId;
    uint256 internal resolvedQueryId;
    uint256 internal openQueryId;
    uint256 internal potAtFork;
    uint256 internal parkedAtFork;

    /// @dev 3200 ether (the actors' balances plus a 200 ether pool remainder) so the per-outcome cap is
    ///      32 ether and the default fee sits on the cap grid, like the functional suites.
    function _genesisSupply() internal pure override returns (uint256) {
        return ACTOR_COUNT * ACTOR_REP_BALANCE + 200 ether;
    }

    function setUp() public override {
        super.setUp();

        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
            _fundWithRep(actors[i], ACTOR_REP_BALANCE);
        }
        assertEq(_capWrep(), 32 * DEFAULT_FEE);

        // Two queries actor0 (A) and actor1 (B) ladder to 1 + 2. The first is resolved before the fork, B
        // winning, so actor1 is owed 2 plus 80% of actor0's 1 and actor0 nothing; the second stays open.
        resolvedQueryId = _createSideQuery();
        vm.warp(vm.getBlockTimestamp() + multiverse.APPEAL_PERIOD() + 1);
        multiverse.resolve(GENESIS_UID, resolvedQueryId);
        openQueryId = _createSideQuery();

        // actor0 and actor1 alternate A and B to the cap, actor2 holds a stake on C that never gets there.
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        forkQueryId = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        address[6] memory reporters = [actors[0], actors[1], actors[2], actors[0], actors[1], actors[0]];
        uint256[6] memory outcomes = [OUTCOME_A, OUTCOME_B, OUTCOME_C, OUTCOME_A, OUTCOME_B, OUTCOME_A];
        for (uint256 i = 0; i < reporters.length; i++) {
            vm.prank(reporters[i]);
            multiverse.report(GENESIS_UID, forkQueryId, outcomes[i]);
        }
        (, Multiverse.UniverseState state,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(uint8(state), uint8(Multiverse.UniverseState.Migration));
        parkedAtFork = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        (,,,,,,,,,,,, uint128 unmigratedAtFork) = multiverse.universes(GENESIS_UID);
        potAtFork = unmigratedAtFork;
        assertEq(potAtFork, parkedAtFork + forkThreshold / zoltar.FORK_BURN_DIVISOR());

        handler = new MultiverseForkHandler(
            multiverse, zoltar, genesisRep, GENESIS_UID, forkQueryId, resolvedQueryId, openQueryId, actors
        );
        targetContract(address(handler));
    }

    /// @dev A default query created by actor0, with actor0 on A and actor1 on B.
    function _createSideQuery() internal returns (uint256 queryId) {
        queryId = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.prank(actors[0]);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
        vm.prank(actors[1]);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);
    }

    /// @dev What the actors still hold on `queryId` across every outcome, in shares.
    function _outstandingStakes(uint256 queryId) internal view returns (uint256 outstanding) {
        for (uint256 a = 0; a < handler.actorsLength(); ++a) {
            for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
                outstanding += multiverse.getUserStake(GENESIS_UID, queryId, handler.actorAt(a), handler.outcomeAt(i));
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The parent's outflow is exactly what the counted lanes moved: wallet migrations in full, the
    ///      forking query's stakes at their principal, the other queries' stakes at what they paid out.
    function invariant_OutflowMatchesTheCountedLanes() public view {
        (,,,,,,,,,, uint128 totalOut,,) = multiverse.universes(GENESIS_UID);
        assertEq(totalOut, handler.ghostWalletMigrated() + handler.ghostPrincipalClaimed() + handler.ghostStakeVotes());
    }

    /// @dev Counted plus unmigrated supply only grows by what wallets bring in after the fork: stake
    ///      settlements move value from unmigrated to counted, never create or destroy it.
    function invariant_CountedPlusUnmigratedIsConserved() public view {
        (,,,,,,,,,, uint128 totalOut,, uint128 unmigrated) = multiverse.universes(GENESIS_UID);
        assertEq(uint256(totalOut) + unmigrated, potAtFork + handler.ghostWalletMigrated());
    }

    /// @dev Every child's inflow matches what was moved into it, the inflows add up to the outflow, and the
    ///      running max points at a child holding it.
    function invariant_ChildInflowsMatchTheOutflow() public view {
        (,,,,, uint248 favoriteChild,,, uint128 maxOut,, uint128 totalOut,,) = multiverse.universes(GENESIS_UID);
        uint256 inflows;
        uint256 largest;
        uint256 favoriteInflow;
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            uint248 childId = handler.childOf(outcome);
            (,,,,,,, uint128 totalIn,,,,,) = multiverse.universes(childId);
            assertEq(totalIn, handler.ghostMigratedInto(outcome));
            inflows += totalIn;
            if (totalIn > largest) largest = totalIn;
            if (childId == favoriteChild) favoriteInflow = totalIn;
        }
        assertEq(inflows, totalOut);
        assertEq(maxOut, largest);
        if (favoriteChild != 0) assertEq(favoriteInflow, maxOut);
    }

    /// @dev No child ever draws more than the whole parked balance from the Zoltar credit, whatever it was
    ///      paid out of it.
    function invariant_NoChildDrawsPastTheParkedBalance() public view {
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, handler.outcomeAt(i)), parked);
        }
    }

    /// @dev Once the fork resolved, the winner never moves: no counted lane is open after resolution.
    function invariant_WinnerIsFinalOnceResolved() public view {
        if (!handler.ghostResolved()) return;
        (, Multiverse.UniverseState state,,,, uint248 favoriteChild,,,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(uint8(state), uint8(Multiverse.UniverseState.PostFork));
        assertEq(favoriteChild, handler.ghostWinner());
    }

    /// @dev Every forking-query stake is either still on the parent record or was claimed, never both and
    ///      never lost: the record's totals minus what was claimed is what can still be claimed.
    function invariant_StakesAreClaimedAtMostOnce() public view {
        (,,, uint96 totalStaked,,,,,) = multiverse.queryResolutions(GENESIS_UID, forkQueryId);
        assertEq(_outstandingStakes(forkQueryId) + handler.ghostForkStakesClaimed(), totalStaked);
    }

    /// @dev The same for the other queries: the open one refunds every stake once; the resolved one pays its
    ///      winner once and never touches the loser's stake, which stays on the record for good.
    function invariant_SideStakesSettleOnce() public view {
        (,,, uint96 openStaked,,,,,) = multiverse.queryResolutions(GENESIS_UID, openQueryId);
        assertEq(_outstandingStakes(openQueryId) + handler.ghostOpenStakesRefunded(), openStaked);

        (,,, uint96 resolvedStaked,,,, uint256 winner,) = multiverse.queryResolutions(GENESIS_UID, resolvedQueryId);
        uint256 winnerStaked = multiverse.getOutcomeStakes(GENESIS_UID, resolvedQueryId, winner).totalOutcomeStaked;
        assertEq(winner, OUTCOME_B);
        assertEq(_outstandingStakes(resolvedQueryId) + handler.ghostResolvedStakesClaimed(), resolvedStaked);
        assertEq(
            multiverse.getUserStake(GENESIS_UID, resolvedQueryId, actors[0], OUTCOME_A), resolvedStaked - winnerStaked
        );
    }
}
