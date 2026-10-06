// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @notice Mirroring native Zoltar forks (mirror-by-id): the entry points (auto-mirror in resolve(), the
///         explicit mirrorZoltarFork), lazy spawn keyed by Zoltar answer, migration and settlement, and the
///         lineage reads through getOutcome. The Lituus-trigger-while-Zoltar-is-forking revert lives in the
///         fork suite. Scalar answers are opaque placeholder numbers: no encoding is asserted.
contract MultiverseZoltarForkTest is MultiverseFixtures {
    uint256 internal constant ZOLTAR_INVALID = 0;

    struct UniverseView {
        Multiverse.UniverseState state;
        uint48 forkTime;
        bool isCanonical;
        uint248 parent;
        uint248 favoriteChild;
        bool isLituusFork;
        uint128 forkQuery;
        uint128 totalQueryFees;
        uint128 unmigratedSupply;
    }

    function _universe(uint248 universeId) internal view returns (UniverseView memory u) {
        (
            ,
            u.state,
            u.forkTime,
            u.isCanonical,
            u.parent,
            u.favoriteChild,
            u.isLituusFork,,,
            u.forkQuery,,
            u.totalQueryFees,
            u.unmigratedSupply
        ) = multiverse.universes(universeId);
    }

    function _repOf(uint248 universeId) internal view returns (ILituusRep repToken) {
        (repToken,,,,,,,,,,,,) = multiverse.universes(universeId);
    }

    function _childId(uint256 outcome) internal view returns (uint248) {
        return zoltar.getChildUniverseId(GENESIS_UID, outcome);
    }

    /// @dev Mirrors the genesis's native fork explicitly, as a bystander. Returns the mirrored query id.
    function _mirror() internal returns (uint256 forkQuery) {
        vm.prank(bystander);
        multiverse.mirrorZoltarFork(GENESIS_UID);
        forkQuery = _universe(GENESIS_UID).forkQuery;
    }

    function _spawn(uint256 outcome) internal {
        vm.prank(bystander);
        multiverse.spawnChildUniverse(GENESIS_UID, outcome);
    }

    /// @dev Asserts the genesis just entered Migration as a mirror of `zoltarQuestionId`: a Zoltar-defined,
    ///      feeless query at forkQuery, the pot parked, the vault paused, the fee aggregate untouched by the
    ///      mirror itself (`feesExpected` is what the caller expects it to read).
    function _assertMirrored(uint256 zoltarQuestionId, uint256 potExpected, uint128 feesExpected) internal view {
        UniverseView memory u = _universe(GENESIS_UID);
        assertEq(uint8(u.state), uint8(Multiverse.UniverseState.Migration));
        assertEq(u.forkTime, uint48(vm.getBlockTimestamp()));
        assertFalse(u.isLituusFork);
        assertEq(u.forkQuery, multiverse.queryCount() - 1);
        (uint8 numberOfOutcomes, uint248 originUniverse, uint256 fee, string memory question, uint256 zq) =
            multiverse.queries(u.forkQuery);
        assertEq(numberOfOutcomes, 0);
        assertEq(originUniverse, GENESIS_UID);
        assertEq(fee, 0);
        assertEq(bytes(question).length, 0);
        assertEq(zq, zoltarQuestionId);
        assertTrue(genesisRep.unwrapPaused());
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
        assertEq(u.unmigratedSupply, potExpected);
        assertEq(zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID), potExpected);
        assertEq(u.totalQueryFees, feesExpected);
        // The forking universe itself never resolves its own fork question.
        assertEq(multiverse.getOutcome(GENESIS_UID, u.forkQuery), multiverse.UNRESOLVED());
    }

    /* ============================================ ENTRY POINTS ============================================= */

    function test_Mirror_AutoOnResolve() public {
        uint256 queryId = _createDefaultQuery();
        uint256 inFlightQueryId = _createDefaultQuery();
        uint256 zq = _createZoltarCategoricalQuestion(3);
        _forkZoltarNatively(zq);
        // Zoltar forked, nothing touched the Lituus universe yet: still Active.
        assertEq(uint8(_universe(GENESIS_UID).state), uint8(Multiverse.UniverseState.Active));

        // Resolve the unreported query past the full resolver ramp: the resolver takes the whole fee out of
        // the vault, nothing is burned, and the rest of the pot is parked by the mirror in the same tx.
        vm.warp(START_TIME + 2 * multiverse.THREE_DAYS() + 1);
        uint256 potBefore = genesisRep.balanceOf(address(multiverse));
        uint128 feesBefore = _universe(GENESIS_UID).totalQueryFees;

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryResolved(bystander, GENESIS_UID, queryId, multiverse.INVALID());
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryCreated(bystander, 2, GENESIS_UID, "", 0);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.UniverseForked(GENESIS_UID, 2, zq, false);
        vm.prank(bystander);
        multiverse.resolve(GENESIS_UID, queryId);

        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), multiverse.INVALID());
        assertEq(multiverse.queryCount(), 3);
        // The fee aggregate lost only the resolved query's fee; the in-flight query's fee is still carried.
        _assertMirrored(zq, potBefore - DEFAULT_FEE, feesBefore - DEFAULT_FEE);
        assertEq(inFlightQueryId, 1);
    }

    function test_Mirror_AutoOnResolveStakesPath() public {
        uint256 queryId = _createResolvableReportedQuery(OUTCOME_A);
        uint256 zq = _createZoltarCategoricalQuestion(2);
        _forkZoltarNatively(zq);

        uint256 potBefore = genesisRep.balanceOf(address(multiverse));
        uint256 reporterBefore = genesisRep.balanceOf(user);
        _resolve(bystander, queryId);

        // Settlement ran before the parking: the sole reporter got the stake back (the report landed at
        // creation, so the ramped fee share is zero) and the whole fee was burned as profit. Stake == fee on
        // the fixture grid, so the pot shrank by 2*fee before the remainder was parked.
        assertEq(genesisRep.balanceOf(user), reporterBefore + DEFAULT_FEE);
        _assertMirrored(zq, potBefore - 2 * DEFAULT_FEE, 0);
    }

    function test_Mirror_AutoOnResolveMultiStakeParksWinnersClaims() public {
        // user->A (fee), challenger->B (2*fee), bystander->A (3*fee): A wins with 4*fee staked against 2*fee.
        uint256 queryId = _createReportedLadder();
        uint256 zq = _createZoltarCategoricalQuestion(2);
        _forkZoltarNatively(zq);
        uint256 userBefore = genesisRep.balanceOf(user);

        assertEq(_resolve(challenger, queryId), OUTCOME_A);

        // Only the reporter reward is pushed (a quarter of the fee: first report 18h into the 3-day ramp);
        // the winners' bonds and their share of the losing stakes stay pull-based.
        assertEq(genesisRep.balanceOf(user), userBefore + DEFAULT_FEE / 4);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), DEFAULT_FEE);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, bystander, OUTCOME_A), 3 * DEFAULT_FEE);

        // The same tx mirrored the fork, so the parent is no longer Active: claim() is closed here for good.
        // The winners' recourse is the claim-and-migrate lane (not built yet): their value is parked, not lost.
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.claim(GENESIS_UID, queryId);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.claim(GENESIS_UID, queryId);

        // What the winners are owed — 4*fee of bonds plus the distributable 80% of the 2*fee losing stake
        // (5.6*fee) — is exactly the share balance left after the push and the profit burn, and the parked
        // underlying covers it (the burn only raised the rate above 1).
        uint256 parked = _universe(GENESIS_UID).unmigratedSupply;
        assertGe(parked, 56 * DEFAULT_FEE / 10);
        assertApproxEqRel(parked, 56 * DEFAULT_FEE / 10, 0.001e18);
        _assertMirrored(zq, parked, 0);
    }

    function test_Mirror_Explicit() public {
        uint256 queryId = _createDefaultQuery();
        uint256 zq = _createZoltarScalarQuestion();
        _forkZoltarNatively(zq);
        uint256 potBefore = genesisRep.balanceOf(address(multiverse));
        uint128 feesBefore = _universe(GENESIS_UID).totalQueryFees;

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.UniverseForked(GENESIS_UID, 1, zq, false);
        uint256 forkQuery = _mirror();

        assertEq(forkQuery, 1);
        _assertMirrored(zq, potBefore, feesBefore);
        // The in-flight query is untouched: unresolved, fee still carried.
        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), multiverse.UNRESOLVED());

        // Mirrored once: the universe is no longer Active.
        vm.prank(bystander);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.mirrorZoltarFork(GENESIS_UID);
    }

    function test_Mirror_RevertsWhenZoltarNotForking() public {
        vm.prank(bystander);
        vm.expectRevert(Multiverse.ZoltarUniverseIsNotForking.selector);
        multiverse.mirrorZoltarFork(GENESIS_UID);
    }

    /* ============================================= LAZY SPAWN ============================================== */

    function test_Mirror_CategoricalLazySpawn() public {
        _createDefaultQuery();
        uint256 zq = _createZoltarCategoricalQuestion(3);
        _forkZoltarNatively(zq);
        uint256 forkQuery = _mirror();

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryResolved(bystander, _childId(ZOLTAR_INVALID), forkQuery, multiverse.INVALID());
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ChildUniverseSpawned(GENESIS_UID, _childId(ZOLTAR_INVALID), ZOLTAR_INVALID);
        _spawn(ZOLTAR_INVALID);
        _spawn(1);
        _spawn(3);

        // Each child answers the mirrored question its own way; Zoltar's Invalid (0) reads as INVALID.
        assertEq(multiverse.getOutcome(_childId(ZOLTAR_INVALID), forkQuery), multiverse.INVALID());
        assertEq(multiverse.getOutcome(_childId(1), forkQuery), 1);
        assertEq(multiverse.getOutcome(_childId(3), forkQuery), 3);

        UniverseView memory child = _universe(_childId(3));
        assertEq(uint8(child.state), uint8(Multiverse.UniverseState.Active));
        assertEq(child.parent, GENESIS_UID);
        assertFalse(child.isLituusFork);
        // The fee copy funds the child (rate is 1: assets == shares).
        assertEq(child.totalQueryFees, DEFAULT_FEE);
        // The Zoltar-side child carries the same keying.
        assertEq(zoltar.universes(_childId(3)).forkingOutcomeIndex, 3);
        assertEq(zoltar.universes(_childId(3)).parentUniverseId, GENESIS_UID);

        // Zoltar's rule rejects everything outside {0, 1..3}: the Lituus INVALID sentinel included.
        // TODO: this rule is temporary until Zoltar finalizes the format.
        uint256 lituusInvalid = multiverse.INVALID();
        vm.prank(bystander);
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, 4);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.spawnChildUniverse(GENESIS_UID, lituusInvalid);
    }

    function test_Mirror_UnstructuredAnswersLazySpawnAndMigrate() public {
        uint256 zq = _createZoltarScalarQuestion();
        _forkZoltarNatively(zq);
        uint256 forkQuery = _mirror();

        // Opaque answers: whatever Zoltar's scalar encoding ends up being, Lituus stores and keys it verbatim.
        uint256 answerA = 777_777;
        uint256 answerB = 2 ** 200 + 5;
        _spawn(ZOLTAR_INVALID);
        _spawn(answerA);
        _spawn(answerB);
        assertEq(multiverse.getOutcome(_childId(ZOLTAR_INVALID), forkQuery), multiverse.INVALID());
        assertEq(multiverse.getOutcome(_childId(answerA), forkQuery), answerA);
        assertEq(multiverse.getOutcome(_childId(answerB), forkQuery), answerB);

        vm.prank(user);
        multiverse.migrate(GENESIS_UID, answerA, 320 ether);
        vm.prank(challenger);
        multiverse.migrate(GENESIS_UID, answerB, 400 ether);
        assertEq(_repOf(_childId(answerB)).balanceOf(challenger), 400 ether);

        vm.warp(vm.getBlockTimestamp() + multiverse.SIXTY_DAYS());
        multiverse.advanceForkState(GENESIS_UID);

        assertEq(uint8(_universe(GENESIS_UID).state), uint8(Multiverse.UniverseState.PostFork));
        assertTrue(_universe(_childId(answerB)).isCanonical);
        assertEq(multiverse.canonicalHeir(), _childId(answerB));
        // Settled: the genesis now reads the winner's answer.
        assertEq(multiverse.getOutcome(GENESIS_UID, forkQuery), answerB);
    }

    /* ======================================= SETTLEMENT AND LINEAGE ======================================== */

    function test_Mirror_MigrateAndAdvanceCategorical() public {
        uint256 zq = _createZoltarCategoricalQuestion(2);
        _forkZoltarNatively(zq);
        uint256 forkQuery = _mirror();
        _spawn(1);
        _spawn(2);
        uint248 child1 = _childId(1);
        uint248 child2 = _childId(2);

        vm.prank(user);
        multiverse.migrate(GENESIS_UID, 1, 320 ether);
        vm.prank(challenger);
        multiverse.migrate(GENESIS_UID, 2, 400 ether);
        // Unsettled: the running max is not followed.
        assertEq(multiverse.getOutcome(GENESIS_UID, forkQuery), multiverse.UNRESOLVED());

        vm.warp(vm.getBlockTimestamp() + multiverse.SIXTY_DAYS());
        multiverse.advanceForkState(GENESIS_UID);
        assertEq(multiverse.canonicalHeir(), child2);
        assertEq(multiverse.getOutcome(GENESIS_UID, forkQuery), 2);
        // The losing sibling keeps its own answer.
        assertEq(multiverse.getOutcome(child1, forkQuery), 1);

        // A nested native fork of the winner, mirrored in turn: its children inherit the first mirrored
        // answer through the ancestor walk and answer the second question themselves.
        uint256 zq2 = _createZoltarCategoricalQuestion(2);
        // Zoltar burns the fork threshold from the initiator, so this contract needs child2 REP in hand.
        MockERC20(address(zoltar.childRepTokens(child2))).mint(address(this), zoltar.getForkThreshold(child2));
        zoltar.forkUniverse(child2, zq2);
        vm.prank(bystander);
        multiverse.mirrorZoltarFork(child2);
        uint256 forkQuery2 = _universe(child2).forkQuery;
        assertEq(uint8(_universe(child2).state), uint8(Multiverse.UniverseState.Migration));
        vm.prank(bystander);
        multiverse.spawnChildUniverse(child2, 1);
        uint248 grandchild = zoltar.getChildUniverseId(child2, 1);

        assertEq(multiverse.getOutcome(grandchild, forkQuery2), 1);
        assertEq(multiverse.getOutcome(grandchild, forkQuery), 2);
    }

    function test_Mirror_InheritedQueriesUseMirrorTime() public {
        // A ladder whose appeal window lapses before the mirror tx, and a query created right before it.
        uint256 settledId = _createReportedQuery(OUTCOME_B);
        uint256 zq = _createZoltarCategoricalQuestion(2);
        _forkZoltarNatively(zq);
        vm.warp(START_TIME + multiverse.ONE_DAY() + 1);
        uint256 freshId = _createDefaultQuery();
        uint256 mirrorTime = vm.getBlockTimestamp();
        _mirror();
        _spawn(1);
        uint248 child1 = _childId(1);

        // The mirrored child is a fully functional universe: migrate in, create and report a new query.
        // (Done before the inherited resolutions below: those burn nearly all of the child's fee-copy
        // shares, which — by the vault's burn-to-appreciate design — makes the few remaining shares, and
        // therefore the share-denominated fee cap, far dearer.)
        vm.prank(bystander);
        multiverse.migrate(GENESIS_UID, 1, 50 ether);
        ILituusRep childRep = _repOf(child1);
        vm.startPrank(bystander);
        childRep.approve(address(multiverse), type(uint256).max);
        uint256 newQueryId = multiverse.queryCount();
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        multiverse.report(child1, newQueryId, OUTCOME_A);
        vm.stopPrank();
        assertEq(multiverse.getOutcomeStakes(child1, newQueryId, OUTCOME_A).firstReporter, bystander);

        // Settled before the (Lituus-time) fork: resolvable at once in the child, to the frozen outcome.
        vm.prank(bystander);
        multiverse.resolve(child1, settledId);
        assertEq(multiverse.getOutcome(child1, settledId), OUTCOME_B);

        _spawn(2);
        uint248 child2 = _childId(2);
        vm.prank(bystander);
        multiverse.resolve(child2, settledId);
        assertEq(multiverse.getOutcome(child2, settledId), OUTCOME_B);

        // Fresh: its clock restarts at the mirror tx, so it is not resolvable until that window lapses.
        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(child1, freshId);
        vm.warp(mirrorTime + multiverse.THREE_DAYS() + 1);
        vm.prank(bystander);
        multiverse.resolve(child1, freshId);
        assertEq(multiverse.getOutcome(child1, freshId), multiverse.INVALID());
    }
}
