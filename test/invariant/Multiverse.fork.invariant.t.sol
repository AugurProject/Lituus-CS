// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";
import { MultiverseForkHandler } from "./handlers/MultiverseForkHandler.sol";

/// @notice Stateful fuzzing of a forked genesis: random sequences of spawn, migrate, migrateStake, time
///         moves and the fork's resolution must keep the migration accounting consistent.
/// @dev The genesis is forked in setUp on a query the three actors staked on (one of them on a third
///      outcome that never reaches the cap), so every handler action has something to work with from the
///      first call. The parked balance at the fork is pinned here and the invariants hold the counters
///      against it.
contract MultiverseForkInvariantTest is MultiverseDeployFixture {
    uint256 internal constant ACTOR_REP_BALANCE = 1000 ether;
    uint256 internal constant ACTOR_COUNT = 3;

    MultiverseForkHandler internal handler;
    address[] internal actors;
    uint256 internal forkQueryId;
    uint256 internal parkedAtFork;

    function setUp() public override {
        super.setUp();

        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
            _fundWithRep(actors[i], ACTOR_REP_BALANCE);
        }
        // Top the supply up to 3200 ether so the per-outcome cap is 32 ether and the default fee sits on
        // the cap grid, like the functional suites.
        underlying.mint(address(this), 200 ether);
        assertEq(_capWrep(), 32 * DEFAULT_FEE);

        // actor0 and actor1 alternate A and B to the cap, actor2 holds a stake on C that never gets there.
        forkQueryId = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        address[6] memory reporters = [actors[0], actors[1], actors[2], actors[0], actors[1], actors[0]];
        uint8[6] memory outcomes = [OUTCOME_A, OUTCOME_B, OUTCOME_C, OUTCOME_A, OUTCOME_B, OUTCOME_A];
        for (uint256 i = 0; i < reporters.length; i++) {
            vm.prank(reporters[i]);
            multiverse.report(GENESIS_UID, forkQueryId, outcomes[i]);
        }
        (, Multiverse.UniverseState state,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(uint8(state), uint8(Multiverse.UniverseState.Migration));
        parkedAtFork = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);

        handler = new MultiverseForkHandler(multiverse, zoltar, genesisRep, GENESIS_UID, forkQueryId, actors);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The parent's outflow is exactly what the counted lanes moved: wallet migrations in full and the
    ///      forking query's stakes at their principal.
    function invariant_OutflowMatchesTheCountedLanes() public view {
        (,,,,,,,,,, uint128 totalOut,,) = multiverse.universes(GENESIS_UID);
        assertEq(totalOut, handler.ghostWalletMigrated() + handler.ghostPrincipalClaimed());
    }

    /// @dev Counted plus still-parked supply only grows by what wallets bring in after the fork: stake
    ///      claims move value from parked to counted, never create or destroy it.
    function invariant_CountedPlusParkedIsConserved() public view {
        (,,,,,,,,,, uint128 totalOut,, uint128 unmigrated) = multiverse.universes(GENESIS_UID);
        assertEq(uint256(totalOut) + unmigrated, parkedAtFork + handler.ghostWalletMigrated());
    }

    /// @dev Every child's inflow matches what was moved into it, the inflows add up to the outflow, and the
    ///      running max points at a child holding it.
    function invariant_ChildInflowsMatchTheOutflow() public view {
        (,,,,, uint248 favoriteChild,,, uint128 maxOut,, uint128 totalOut,,) = multiverse.universes(GENESIS_UID);
        uint256 inflows;
        uint256 largest;
        uint256 favoriteInflow;
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint8 outcome = handler.outcomeAt(i);
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
        uint256 outstanding;
        for (uint256 a = 0; a < handler.actorsLength(); ++a) {
            for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
                outstanding += multiverse.getUserStake(
                    GENESIS_UID, forkQueryId, handler.actorAt(a), handler.outcomeAt(i)
                );
            }
        }
        (,,,,, uint96 totalStaked,,) = multiverse.queryResolutions(GENESIS_UID, forkQueryId);
        assertEq(outstanding + handler.ghostPrincipalClaimed(), totalStaked);
    }
}
