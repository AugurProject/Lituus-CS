// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @notice Minimal forking flow: trigger inside report(), lazy spawn, migration voting, resolution.
/// @dev Runs against MockZoltar (unique keccak child ids, per-child REP, credit-only migration
///      stubs). Payouts, refunds, and SupplyRestoration are later phases and not tested here.
contract MultiverseForkTest is MultiverseFixtures {
    uint8 internal constant OUTCOME_C = 3;
    uint8 internal constant INVALID_OUTCOME = 255;

    /// @dev Escalates a query in `universeId` until the fork-level report fires, alternating
    ///      OUTCOME_A/OUTCOME_B from `reporterA`/`reporterB`. Returns the trigger stake (the full
    ///      fork threshold, recorded like any rung).
    function _escalateToFork(uint248 universeId, uint256 queryId, address reporterA, address reporterB)
        internal
        returns (uint256 triggerStake)
    {
        uint256 i = 0;
        while (true) {
            (uint256 required, uint256 threshold) = multiverse.getNextRequiredStake(universeId, queryId);
            vm.prank(i % 2 == 0 ? reporterA : reporterB);
            multiverse.report(universeId, queryId, i % 2 == 0 ? OUTCOME_A : OUTCOME_B);
            if (required >= threshold) return required;
            i++;
        }
    }

    /// @dev Forks the genesis universe on a fresh default query and returns (queryId, triggerStake).
    function _forkGenesis() internal returns (uint256 queryId, uint256 triggerStake) {
        queryId = _createDefaultQuery();
        triggerStake = _escalateToFork(GENESIS_UID, queryId, user, challenger);
    }

    function _childId(uint248 parentId, uint256 outcome) internal view returns (uint248) {
        return zoltar.getChildUniverseId(parentId, outcome);
    }

    function _universeState(uint248 universeId) internal view returns (Multiverse.UniverseState state) {
        (, state,,,,,,,,,) = multiverse.universes(universeId);
    }

    /* ============================================= FORK TRIGGER ============================================= */

    function test_Fork_TriggersAtThresholdInsideReport() public {
        (uint256 queryId, uint256 triggerStake) = _forkGenesis();

        // The forking universe enters Migration with its split moment recorded in forkTime.
        (
            ,
            Multiverse.UniverseState universeState,
            uint48 forkTime,,,
            uint248 favoriteChild,
            bool isLituusFork,,,
            uint256 forkQuery,
            uint256 totalMigratedOut
        ) = multiverse.universes(GENESIS_UID);
        assertEq(uint8(universeState), uint8(Multiverse.UniverseState.Migration));
        assertEq(forkTime, uint48(vm.getBlockTimestamp()));
        assertEq(forkQuery, queryId);
        assertTrue(isLituusFork);
        assertEq(favoriteChild, 0);
        // The electorate is a live outflow counter, not a trigger snapshot (post-fork wrappers can
        // still enter and migrate): zero until migration begins.
        assertEq(totalMigratedOut, 0);
        // The trigger stake is recorded at its FULL amount, like any other rung.
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[stakes.length - 1].amount, triggerStake);
        assertEq(triggerStake, genesisRep.convertToShares(zoltar.getForkThreshold(GENESIS_UID)));
        // The forked vault is unwrap-paused PERMANENTLY: wrapped capital exits only through the
        // counted Lituus migration/claim lanes. Zoltar-side fork started in the same tx.
        assertTrue(genesisRep.unwrapPaused());
        assertEq(zoltar.getForkTime(GENESIS_UID), vm.getBlockTimestamp());
        // The forking universe itself still reads UNRESOLVED (it never resolves the query locally).
        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), 0);
    }

    function test_Fork_RevertsWhenZoltarUniverseAlreadyForking() public {
        // The Zoltar counterpart forked natively (fork-once per universe in Zoltar) but the fork was
        // not mirrored yet. A Lituus fork-level report must revert cleanly instead of hitting
        // Zoltar's own revert.
        uint256 queryId = _createDefaultQuery();
        zoltar.forkUniverse(GENESIS_UID, 424_242);

        uint256 i = 0;
        while (true) {
            (uint256 required, uint256 threshold) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
            vm.prank(i % 2 == 0 ? user : challenger);
            if (required >= threshold) {
                break;
            }
            multiverse.report(GENESIS_UID, queryId, i % 2 == 0 ? OUTCOME_A : OUTCOME_B);
            i++;
        }

        vm.expectRevert(Multiverse.ZoltarUniverseAlreadyForking.selector);
        multiverse.report(GENESIS_UID, queryId, i % 2 == 0 ? OUTCOME_A : OUTCOME_B);
    }

    function test_Fork_ParentIsLookupOnlyDuringMigration() public {
        (uint256 queryId,) = _forkGenesis();

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.resolve(GENESIS_UID, queryId);

        // Outcome lookup stays available.
        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), 0);
    }

    /* ============================================= LAZY SPAWN ============================================== */

    function test_Spawn_CreatesChildResolvedToItsOwnOutcome() public {
        (uint256 queryId,) = _forkGenesis();

        uint248 child1 = _childId(GENESIS_UID, OUTCOME_A);
        vm.expectEmit(true, true, true, true);
        emit Multiverse.QueryResolved(bystander, child1, queryId, OUTCOME_A);
        vm.prank(bystander);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        (
            ILituusRep childRep,
            Multiverse.UniverseState universeState,
            uint48 forkTime,
            bool isCanonical,
            uint248 parent,,,,,
            uint256 forkQuery,
        ) = multiverse.universes(child1);
        // Children spawn Active: fully functional immediately, no activation step.
        assertEq(uint8(universeState), uint8(Multiverse.UniverseState.Active));
        assertEq(parent, GENESIS_UID);
        assertFalse(isCanonical);
        assertEq(forkQuery, 0);
        // A fresh child has not forked: its own forkTime stays 0.
        assertEq(forkTime, 0);
        // The child vault starts at the parent's rate, with unwrap open (only forked vaults pause).
        assertEq(childRep.rate(), genesisRep.rate());
        assertFalse(childRep.unwrapPaused());
        // Every child resolves the forking query to its own outcome; INVALID children included.
        assertEq(multiverse.getOutcome(child1, queryId), OUTCOME_A);

        vm.prank(bystander);
        multiverse.spawnChildUniverse(GENESIS_UID, INVALID_OUTCOME);
        assertEq(multiverse.getOutcome(_childId(GENESIS_UID, INVALID_OUTCOME), queryId), INVALID_OUTCOME);

        // Reporting the forking query in a child is rejected: it is already resolved there.
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.report(child1, queryId, OUTCOME_B);
    }

    function test_Spawn_Reverts() public {
        // Not forking yet.
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        _forkGenesis();

        // Outcome outside the forking query's outcome set.
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, 0);
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, DEFAULT_NUMBER_OF_OUTCOMES + 1);

        // Spawning is idempotence-safe: the same outcome cannot be spawned twice.
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        // A Zoltar child deployed directly at the Zoltar level does not block the Lituus spawn:
        // Zoltar's deployChild reverts on an existing universe, so spawn deploys a Zoltar child
        // only when the child's Zoltar rep token is still zero.
        zoltar.deployChild(GENESIS_UID, OUTCOME_B);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);

        // The spawn window closes 60 days after the fork, strictly by clock (unlike migration,
        // which extends until the parent fork resolves — inflow stays possible, spawning does not).
        vm.warp(vm.getBlockTimestamp() + multiverse.SIXTY_DAYS());
        vm.expectRevert(Multiverse.SpawnWindowClosed.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, INVALID_OUTCOME);
    }

    /* ============================================== MIGRATION ============================================== */

    function test_Migrate_CountsVotesWithRunningMax() public {
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        uint248 child1 = _childId(GENESIS_UID, OUTCOME_A);
        uint248 child2 = _childId(GENESIS_UID, OUTCOME_B);

        // user votes 100 into child1: burn-based exit, counted in underlying assets.
        uint256 userSharesBefore = genesisRep.balanceOf(user);
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 100 ether);
        assertEq(genesisRep.balanceOf(user), userSharesBefore - 100 ether);
        ILituusRep child1Rep = multiverse.repTokenOf(child1);
        assertEq(child1Rep.balanceOf(user), 100 ether); // rate parity: same share count

        (,,,,, uint248 favoriteChild,, uint128 totalIn1, uint128 maxOut,,) = multiverse.universes(child1);
        assertEq(totalIn1, 100 ether);
        (,,,,, favoriteChild,,, maxOut,,) = multiverse.universes(GENESIS_UID);
        assertEq(maxOut, 100 ether);
        assertEq(favoriteChild, child1);

        // challenger outvotes into child2: the running max flips (strict >).
        vm.prank(challenger);
        multiverse.migrate(GENESIS_UID, OUTCOME_B, 150 ether);
        (,,,,, favoriteChild,,, maxOut,,) = multiverse.universes(GENESIS_UID);
        assertEq(maxOut, 150 ether);
        assertEq(favoriteChild, child2);

        // An equal amount does NOT flip the winner: first-to-reach holds it.
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 50 ether);
        (,,,,, favoriteChild,,, maxOut,,) = multiverse.universes(GENESIS_UID);
        assertEq(maxOut, 150 ether);
        assertEq(favoriteChild, child2);

        // Adding to previously leading child does flip the winner: the running max is strict >.
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 1 ether);
        (,,,,, favoriteChild,,, maxOut,,) = multiverse.universes(GENESIS_UID);
        assertEq(maxOut, 151 ether);
        assertEq(favoriteChild, child1);

        // The parent's outflow counter accumulates every migration: the live electorate measure
        // (the 2/3 denominator and the SR max supply, read at the end of migration).
        (,,,,,,,,,, uint256 totalMigratedOut) = multiverse.universes(GENESIS_UID);
        assertEq(totalMigratedOut, 301 ether);
    }

    function test_Migrate_Reverts() public {
        // Only forking universes accept migration.
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 1 ether);

        _forkGenesis();

        // The target child must be spawned first (no auto-spawn in the minimal flow).
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 1 ether);

        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        // The forked vault is permanently unwrap-paused; migrate's exit lane is pause-exempt.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("UnwrapIsPaused()"));
        multiverse.unwrap(GENESIS_UID, 1 ether, 0);
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 1 ether);

        // The vote window closes 60 days after the fork, by clock — no state change needed.
        // The nested fork case is not tested here.
        vm.warp(vm.getBlockTimestamp() + multiverse.SIXTY_DAYS());
        vm.prank(user);
        vm.expectRevert(Multiverse.MigrationWindowClosed.selector);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 1 ether);
    }

    /* ============================================== RESOLUTION ============================================== */

    function test_AdvanceForkState_DesignatesWinnerAndRepointsCanonicalHeir() public {
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        uint248 child2 = _childId(GENESIS_UID, OUTCOME_B);
        vm.prank(challenger);
        multiverse.migrate(GENESIS_UID, OUTCOME_B, 200 ether);

        // The vote must be over before resolution.
        vm.expectRevert(Multiverse.MigrationWindowNotClosed.selector);
        multiverse.advanceForkState(GENESIS_UID);

        vm.warp(vm.getBlockTimestamp() + multiverse.SIXTY_DAYS());
        // For now advanceForkState always resolves the fork (the 2/3 check and the supply
        // restoration branch are not implemented yet).
        multiverse.advanceForkState(GENESIS_UID);

        // Parent archived, winner canonical, canonical timeline repointed. The parent vault stays
        // unwrap-paused forever: unmigrated wREP's way is the Lituus claim/migration lanes.
        assertEq(uint8(_universeState(GENESIS_UID)), uint8(Multiverse.UniverseState.PostFork));
        assertTrue(genesisRep.unwrapPaused());
        assertEq(multiverse.canonicalHeir(), child2);
        (,,, bool isCanonical,,,,,,,) = multiverse.universes(child2);
        assertTrue(isCanonical);

        // Children need no per-child resolution: they have been Active since spawn (whether the
        // parent's fork is settled is derivable from the parent's state).
        assertEq(uint8(_universeState(child2)), uint8(Multiverse.UniverseState.Active));
        assertEq(uint8(_universeState(_childId(GENESIS_UID, OUTCOME_A))), uint8(Multiverse.UniverseState.Active));
    }

    /* ============================================== END-TO-END ============================================== */

    /// @dev The minimal-flow gate: fork -> lazy spawn (children Active from birth) -> nested
    ///      fork -> migration voting -> root-first resolution -> canonical forwarding.
    function test_EndToEnd_MinimalForkFlow() public {
        // Fork the genesis on a 3-outcome query; the fork fires inside the threshold report.
        (uint256 forkQueryId,) = _forkGenesis();
        assertEq(uint8(_universeState(GENESIS_UID)), uint8(Multiverse.UniverseState.Migration));

        // Two of four possible children spawn lazily; each answers the forking query its own way.
        vm.prank(bystander);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        vm.prank(bystander);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        uint248 child1 = _childId(GENESIS_UID, OUTCOME_A);
        uint248 child2 = _childId(GENESIS_UID, OUTCOME_B);
        assertEq(multiverse.getOutcome(child1, forkQueryId), OUTCOME_A);
        assertEq(multiverse.getOutcome(child2, forkQueryId), OUTCOME_B);

        // Migration votes: child2 leads 400 to 320.
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 320 ether);
        vm.prank(challenger);
        multiverse.migrate(GENESIS_UID, OUTCOME_B, 400 ether);
        (,,,,, uint248 favoriteChild,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(favoriteChild, child2);

        // A freshly spawned child is query-functional while its parent is still mid-Migration.
        ILituusRep child1Rep = multiverse.repTokenOf(child1);
        vm.prank(user);
        child1Rep.approve(address(multiverse), type(uint256).max);
        uint256 nestedQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        // ...and can even fork (a fork during a fork): child1 goes Active -> Migration.
        _escalateToFork(child1, nestedQueryId, user, user);
        assertEq(uint8(_universeState(child1)), uint8(Multiverse.UniverseState.Migration));

        // A grandchild spawns under the nested fork.
        vm.prank(bystander);
        multiverse.spawnChildUniverse(child1, OUTCOME_A);
        uint248 grandchild = _childId(child1, OUTCOME_A);
        assertEq(multiverse.getOutcome(grandchild, nestedQueryId), OUTCOME_A);

        // Root-first ordering: the nested fork cannot advance before the genesis fork resolves.
        vm.warp(vm.getBlockTimestamp() + multiverse.SIXTY_DAYS());
        vm.expectRevert(Multiverse.ParentForkNotResolved.selector);
        multiverse.advanceForkState(child1);

        // Resolve the genesis fork (always resolves for now; the 2/3 / supply-restoration branch is
        // not implemented yet). The winner needs no per-child step: children are Active since spawn.
        multiverse.advanceForkState(GENESIS_UID);
        assertEq(multiverse.canonicalHeir(), child2);
        assertEq(uint8(_universeState(child2)), uint8(Multiverse.UniverseState.Active));
        // The canonical answer of the forking query is now the winner's outcome.
        assertEq(multiverse.getOutcome(GENESIS_UID, forkQueryId), OUTCOME_B);

        // Now the nested fork resolves (its own window is over; its parent is PostFork). child1 is
        // non-canonical, so the canonical timeline does not move. child1 forked, so its vault is
        // permanently paused — resolution does not reopen it.
        assertTrue(child1Rep.unwrapPaused());
        multiverse.advanceForkState(child1);
        assertTrue(child1Rep.unwrapPaused());
        assertEq(uint8(_universeState(child1)), uint8(Multiverse.UniverseState.PostFork));
        assertEq(uint8(_universeState(grandchild)), uint8(Multiverse.UniverseState.Active));
        assertEq(multiverse.canonicalHeir(), child2);

        // Query creation targeting the archived genesis forwards along the canonical timeline.
        ILituusRep child2Rep = multiverse.repTokenOf(child2);
        vm.startPrank(challenger);
        child2Rep.approve(address(multiverse), type(uint256).max);
        uint256 forwardedQueryId = multiverse.queryCount();
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.stopPrank();
        (, uint248 originUniverse,,) = multiverse.queries(forwardedQueryId);
        assertEq(originUniverse, child2);

        // The forwarded query is a normal query in the winner universe.
        vm.prank(challenger);
        multiverse.report(child2, forwardedQueryId, OUTCOME_A);
        assertEq(multiverse.getStakes(child2, forwardedQueryId).length, 1);
    }
}
