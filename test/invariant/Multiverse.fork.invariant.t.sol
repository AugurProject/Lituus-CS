// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { IMultiverse } from "src/interfaces/IMultiverse.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { IQueryToken } from "src/interfaces/IQueryToken.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";
import { MultiverseForkHandler } from "./handlers/MultiverseForkHandler.sol";

/// @notice Stateful fuzzing of a forked genesis: random sequences of spawn, migrate, stake settlements, query
///         token migrations and redemptions, time moves and the fork's resolution must keep the migration
///         accounting consistent.
/// @dev The genesis is forked in setUp on a query the three actors staked on (one of them on a third
///      outcome that never reaches the cap), next to a query resolved before the fork and one left open, so
///      every handler action has something to work with from the first call. The resolution burns before
///      the fork, so the parent's rate is above 1 throughout. The pot at the fork is pinned here, at face
///      value and as parked (net of Zoltar's burn on the fork bond), and the invariants hold the counters
///      against them. The real QueryTokenizer is wired in and every actor holds genesis query tokens minted
///      before the fork; their pool is the tokenizer's, outside the pot.
contract MultiverseForkInvariantTest is MultiverseDeployFixture {
    uint256 internal constant ACTOR_REP_BALANCE = 1000 ether;
    uint256 internal constant ACTOR_COUNT = 3;
    uint256 internal constant TOKENS_PER_ACTOR = 2;
    // Tips on the forking query (paid by every child to the first reporter of its outcome) and on a query left
    // unreported at the fork (carried into every child as its tip pool).
    uint256 internal constant FORK_TIP = 5 ether;
    uint256 internal constant TIPPED_TIP = 3 ether;
    // The spawn-time copies of the fee and tip pools round down twice through the parent's rate above 1, so a
    // child's pools may trail what it pays out by a few wei (the known fee-accounting dust TODO).
    uint256 internal constant POOL_DUST = 4;

    MultiverseForkHandler internal handler;
    QueryTokenizer internal tokenizer;
    address[] internal actors;
    uint256 internal forkQueryId;
    uint256 internal resolvedQueryId;
    uint256 internal openQueryId;
    uint256 internal tippedQueryId;
    uint256 internal potAtFork;
    uint256 internal parkedAtFork;
    uint256 internal tokensAtFork;
    uint256 internal poolAtFork;
    uint256 internal averageAtFork;

    /// @dev 3200 ether (the actors' balances plus a 200 ether pool remainder) so the per-outcome cap is
    ///      32 ether and the default fee sits on the cap grid, like the functional suites.
    function _genesisSupply() internal pure override returns (uint256) {
        return ACTOR_COUNT * ACTOR_REP_BALANCE + 200 ether;
    }

    /// @dev Deploys the real tokenizer first, then the Multiverse pointing at it (Deploy.s.sol order).
    function _deployMultiverse(IQueryFeeController controller) internal override returns (Multiverse) {
        tokenizer = new QueryTokenizer();
        return new Multiverse(
            zoltar, GENESIS_UID, controller, address(tokenizer), MIGRATION_DURATION, REPORTING_PERIOD, APPEAL_PERIOD
        );
    }

    function _afterProtocolDeploy() internal override {
        tokenizer.setMultiverse(IMultiverse(address(multiverse)));
    }

    function setUp() public override {
        super.setUp();

        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
            _fundWithRep(actors[i], ACTOR_REP_BALANCE);
            vm.prank(actors[i]);
            genesisRep.approve(address(tokenizer), type(uint256).max);
            vm.prank(actors[i]);
            tokenizer.mint(GENESIS_UID, TOKENS_PER_ACTOR);
        }
        assertEq(_capWrep(), 32 * DEFAULT_FEE);
        tokensAtFork = ACTOR_COUNT * TOKENS_PER_ACTOR;
        poolAtFork = tokenizer.pooledRep(GENESIS_UID);
        averageAtFork = poolAtFork / tokensAtFork;

        // Two queries actor0 (A) and actor1 (B) ladder to 1 + 2. The first is resolved before the fork, B
        // winning, so actor1 is owed 2 plus 80% of actor0's 1 and actor0 nothing; the second stays open.
        resolvedQueryId = _createSideQuery();
        vm.warp(vm.getBlockTimestamp() + multiverse.APPEAL_PERIOD() + 1);
        multiverse.resolve(GENESIS_UID, resolvedQueryId);
        openQueryId = _createSideQuery();
        // A query nobody reports, tipped: its tips carry into every child.
        tippedQueryId = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.prank(actors[1]);
        multiverse.tip(GENESIS_UID, tippedQueryId, TIPPED_TIP);

        // actor0 and actor1 alternate A and B to the cap, actor2 holds a stake on C that never gets there.
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        forkQueryId = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.prank(actors[2]);
        multiverse.tip(GENESIS_UID, forkQueryId, FORK_TIP);
        address[6] memory reporters = [actors[0], actors[1], actors[2], actors[0], actors[1], actors[0]];
        uint256[6] memory outcomes = [OUTCOME_A, OUTCOME_B, OUTCOME_C, OUTCOME_A, OUTCOME_B, OUTCOME_A];
        for (uint256 i = 0; i < reporters.length; i++) {
            vm.prank(reporters[i]);
            multiverse.report(GENESIS_UID, forkQueryId, outcomes[i]);
        }
        (, Multiverse.UniverseState state,,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(uint8(state), uint8(Multiverse.UniverseState.Migration));
        parkedAtFork = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        (,,,,,,,,,,,, uint128 unmigratedAtFork,) = multiverse.universes(GENESIS_UID);
        potAtFork = unmigratedAtFork;
        assertEq(potAtFork, parkedAtFork + forkThreshold / zoltar.FORK_BURN_DIVISOR());

        handler = new MultiverseForkHandler(
            multiverse,
            tokenizer,
            zoltar,
            genesisRep,
            GENESIS_UID,
            forkQueryId,
            resolvedQueryId,
            openQueryId,
            tippedQueryId,
            actors
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
        (,,,,,,,,,, uint128 totalOut,,,) = multiverse.universes(GENESIS_UID);
        assertEq(totalOut, handler.ghostWalletMigrated() + handler.ghostPrincipalClaimed() + handler.ghostStakeVotes());
    }

    /// @dev Counted plus unmigrated supply only grows by what wallets bring in after the fork: stake
    ///      settlements move value from unmigrated to counted, never create or destroy it.
    function invariant_CountedPlusUnmigratedIsConserved() public view {
        (,,,,,,,,,, uint128 totalOut,, uint128 unmigrated,) = multiverse.universes(GENESIS_UID);
        assertEq(uint256(totalOut) + unmigrated, potAtFork + handler.ghostWalletMigrated());
    }

    /// @dev Every child's inflow matches what was moved into it, the inflows add up to the outflow, and the
    ///      running max points at a child holding it.
    function invariant_ChildInflowsMatchTheOutflow() public view {
        (,,,,, uint248 favoriteChild,,, uint128 maxOut,, uint128 totalOut,,,) = multiverse.universes(GENESIS_UID);
        uint256 inflows;
        uint256 largest;
        uint256 favoriteInflow;
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            uint248 childId = handler.childOf(outcome);
            (,,,,,,, uint128 totalIn,,,,,,) = multiverse.universes(childId);
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
        (, Multiverse.UniverseState state,,,, uint248 favoriteChild,,,,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(uint8(state), uint8(Multiverse.UniverseState.PostFork));
        assertEq(favoriteChild, handler.ghostWinner());
    }

    /// @dev Every forking-query stake is either still on the parent record or was claimed, never both and
    ///      never lost: the record's totals minus what was claimed is what can still be claimed.
    function invariant_StakesAreClaimedAtMostOnce() public view {
        (,,, uint96 totalStaked,,,,,,) = multiverse.queryResolutions(GENESIS_UID, forkQueryId);
        assertEq(_outstandingStakes(forkQueryId) + handler.ghostForkStakesClaimed(), totalStaked);
    }

    /// @dev The same for the other queries: the open one refunds every stake once; the resolved one pays its
    ///      winner once and never touches the loser's stake, which stays on the record for good.
    function invariant_SideStakesSettleOnce() public view {
        (,,, uint96 openStaked,,,,,,) = multiverse.queryResolutions(GENESIS_UID, openQueryId);
        assertEq(_outstandingStakes(openQueryId) + handler.ghostOpenStakesRefunded(), openStaked);

        (,,, uint96 resolvedStaked,,,, uint256 winner,,) = multiverse.queryResolutions(GENESIS_UID, resolvedQueryId);
        uint256 winnerStaked = multiverse.getOutcomeStakes(GENESIS_UID, resolvedQueryId, winner).totalOutcomeStaked;
        assertEq(winner, OUTCOME_B);
        assertEq(_outstandingStakes(resolvedQueryId) + handler.ghostResolvedStakesClaimed(), resolvedStaked);
        assertEq(
            multiverse.getUserStake(GENESIS_UID, resolvedQueryId, actors[0], OUTCOME_A), resolvedStaked - winnerStaked
        );
    }

    /// @dev The tokenizer holds no wREP outside its pools: in the parent and in every child the pool is its
    ///      balance, and a child nothing arrived in has neither.
    function invariant_TokenPoolsAreTheTokenizersBalances() public view {
        assertEq(genesisRep.balanceOf(address(tokenizer)), tokenizer.pooledRep(GENESIS_UID));
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            uint248 childId = handler.childOf(outcome);
            if (!handler.ghostSpawned(outcome)) {
                assertEq(tokenizer.pooledRep(childId), 0);
                assertEq(address(tokenizer.token(childId)), address(0));
                continue;
            }
            assertEq(multiverse.repTokenOf(childId).balanceOf(address(tokenizer)), tokenizer.pooledRep(childId));
        }
    }

    /// @dev Migration moves query rights, never makes or loses any: the parent keeps what did not leave, each
    ///      child holds what arrived less what was redeemed there, and all of it adds up to what was minted.
    function invariant_QueryRightsAreConserved() public view {
        uint256 oneQuery = tokenizer.ONE_QUERY();
        uint256 parentSupply = tokenizer.token(GENESIS_UID).totalSupply();
        assertEq(parentSupply, (tokensAtFork - handler.ghostTokensMigrated()) * oneQuery);
        uint256 childSupplies;
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            IQueryToken childToken = tokenizer.token(handler.childOf(outcome));
            if (address(childToken) == address(0)) continue;
            childSupplies += childToken.totalSupply();
        }
        assertEq(parentSupply + childSupplies, (tokensAtFork - handler.ghostTokensRedeemed()) * oneQuery);
    }

    /// @dev Nothing enters the parent pool after the fork and every migration takes its share rounded down, so
    ///      the pool is what it was less what left, the average the stayers see never drops below the one at the
    ///      fork and rises by at most a wei per migration, and the last tokens out leave nothing behind.
    function invariant_ParentPoolOnlyDrainsAtTheShare() public view {
        uint256 pool = tokenizer.pooledRep(GENESIS_UID);
        assertEq(pool, poolAtFork - handler.ghostParentPoolMigrated());
        uint256 remaining = tokensAtFork - handler.ghostTokensMigrated();
        if (remaining == 0) {
            assertEq(pool, 0);
            return;
        }
        assertGe(pool / remaining, averageAtFork);
        assertLe(pool / remaining, averageAtFork + handler.ghostTokensMigrated());
    }

    /// @dev Each child's pool is what the migrations brought in less what the redemptions paid out of it, and
    ///      it backs only tokens that arrived by migration; the last token redeemed takes the whole pool.
    function invariant_ChildPoolsMatchArrivalsAndRedemptions() public view {
        uint256 oneQuery = tokenizer.ONE_QUERY();
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            uint248 childId = handler.childOf(outcome);
            assertEq(
                tokenizer.pooledRep(childId), handler.ghostChildPoolIn(outcome) - handler.ghostChildPoolOut(outcome)
            );
            IQueryToken childToken = tokenizer.token(childId);
            uint256 supply = address(childToken) == address(0) ? 0 : childToken.totalSupply();
            assertLe(supply, handler.ghostTokensMigratedInto(outcome) * oneQuery);
            if (supply == 0) assertEq(tokenizer.pooledRep(childId), 0);
        }
    }

    /// @dev The parent's tips are frozen at the fork: its pool holds only the carried query's tips (the forking
    ///      query's left it in the fork tx), the forking query's record keeps its tips for every spawn to read,
    ///      and a forked universe pays no tips itself.
    function invariant_ParentTipsFrozenAtTheFork() public view {
        (,,,,,,,,,,,,, uint128 parentTips) = multiverse.universes(GENESIS_UID);
        assertEq(parentTips, TIPPED_TIP);
        assertEq(_resolutionIn(GENESIS_UID, forkQueryId).tips, FORK_TIP);
        assertEq(_resolutionIn(GENESIS_UID, tippedQueryId).tips, TIPPED_TIP);
        assertEq(multiverse.getTips(GENESIS_UID, forkQueryId), 0);
        assertEq(multiverse.getTips(GENESIS_UID, tippedQueryId), 0);
    }

    /// @dev Each spawned child's tip pool is the parent's pool copied at spawn (a few wei short at most) plus
    ///      the tips placed there, and the carried query pays the parent's tips plus those, until it is resolved
    ///      there; then nothing is owed, the record is cleared and the pool saturates to zero. The forking query
    ///      is resolved in every child, so it owes nothing there.
    function invariant_ChildTipsMatchGhosts() public view {
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            uint248 childId = handler.childOf(outcome);
            if (!handler.ghostSpawned(outcome)) continue;
            (,,,,,,,,,,,,, uint128 childTips) = multiverse.universes(childId);
            assertLe(handler.ghostTipsCopied(outcome), TIPPED_TIP);
            assertGe(handler.ghostTipsCopied(outcome) + POOL_DUST, TIPPED_TIP);
            assertEq(multiverse.getTips(childId, forkQueryId), 0);
            if (handler.ghostTippedResolved(outcome)) {
                assertEq(childTips, 0);
                assertEq(_resolutionIn(childId, tippedQueryId).tips, 0);
                assertEq(multiverse.getTips(childId, tippedQueryId), 0);
            } else {
                assertEq(childTips, handler.ghostTipsCopied(outcome) + handler.ghostChildTips(outcome));
                assertEq(multiverse.getTips(childId, tippedQueryId), TIPPED_TIP + handler.ghostChildTips(outcome));
            }
        }
    }

    /// @dev What the Multiverse holds of each child's wREP is its fee and tip pools plus the carried query's
    ///      unsettled stake there: the forking query's reward and tips and every stake settlement are drawn fresh
    ///      from the parked balance and leave at once, never out of the pools. Only the spawn-time rounding of the
    ///      pool copies separates the two.
    function invariant_ChildHoldingsAreItsPools() public view {
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            if (!handler.ghostSpawned(outcome)) continue;
            uint248 childId = handler.childOf(outcome);
            (,,,,,,,,,,, uint128 childFees,, uint128 childTips) = multiverse.universes(childId);
            uint256 openStake = handler.ghostTippedResolved(outcome) ? 0 : handler.ghostChildStake(outcome);
            assertApproxEqAbs(
                multiverse.repTokenOf(childId).balanceOf(address(multiverse)),
                uint256(childFees) + childTips + openStake,
                POOL_DUST
            );
        }
    }
}
