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
            u.unmigratedSupply,
        ) = multiverse.universes(universeId);
    }

    function _repOf(uint248 universeId) internal view returns (ILituusRep repToken) {
        (repToken,,,,,,,,,,,,,) = multiverse.universes(universeId);
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
        vm.warp(START_TIME + 2 * multiverse.REPORTING_PERIOD() + 1);
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
        // The winners' recourse is migrateStake into a child: their value is parked, not lost.
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

        vm.warp(vm.getBlockTimestamp() + multiverse.MIGRATION_DURATION());
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

        vm.warp(vm.getBlockTimestamp() + multiverse.MIGRATION_DURATION());
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
        // A ladder whose appeal window lapses before the mirror tx, and a query created right before it:
        // both restart in the children with a full window clocked from the mirror tx (the Lituus-time fork).
        uint256 settledId = _createReportedQuery(OUTCOME_B);
        uint256 zq = _createZoltarCategoricalQuestion(2);
        _forkZoltarNatively(zq);
        vm.warp(START_TIME + multiverse.APPEAL_PERIOD() + 1);
        uint256 freshId = _createDefaultQuery();
        uint256 mirrorTime = vm.getBlockTimestamp();
        _mirror();
        _spawn(1);
        uint248 child1 = _childId(1);

        // The mirrored child is a fully functional universe: migrate in, create and report a new query.
        // (Done before the inherited INVALID resolution below: it burns most of the child's fee-copy
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

        // The concluded ladder is reopened, not settled: its old outcome is not resolvable, and a fresh
        // first report lands anchored at the mirror tx.
        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(child1, settledId);
        vm.prank(bystander);
        multiverse.report(child1, settledId, OUTCOME_A);
        (uint48 childCreateTime,, uint16 childStakeCount,,,,,,,) = multiverse.queryResolutions(child1, settledId);
        assertEq(childCreateTime, mirrorTime);
        assertEq(childStakeCount, 1);

        // Fresh: its clock restarts at the mirror tx too, so it is not resolvable until that window lapses.
        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(child1, freshId);
        vm.warp(mirrorTime + multiverse.REPORTING_PERIOD() + 1);
        vm.prank(bystander);
        multiverse.resolve(child1, freshId);
        assertEq(multiverse.getOutcome(child1, freshId), multiverse.INVALID());
    }

    /* =========================================== RETURN OF STAKES ========================================== */

    function _totalMigratedOut(uint248 universeId) internal view returns (uint128 totalOut) {
        (,,,,,,,,,, totalOut,,,) = multiverse.universes(universeId);
    }

    /// @dev Asserts `staker` got its `parentShares` payout as child wREP: assets at the parent's frozen rate,
    ///      shares at the child's rate.
    function _assertPaidInto(uint248 childId, address staker, uint256 parentShares) internal view {
        ILituusRep childRep = _repOf(childId);
        assertEq(childRep.balanceOf(staker), childRep.convertToShares(genesisRep.convertToAssets(parentShares)));
    }

    function test_Mirror_MigrateStakePaysWinnersAndRefundsOpenStakes() public {
        // Before the native fork: a ladder resolved to A (user 1 and bystander 3 win, challenger's 2 loses; its
        // burn moved the rate off 1), and a six-rung ladder left open, near the cap, with every actor on both
        // sides. A mirrored fork has no forking-query stakes and no burn: the parked pot is the whole balance.
        uint256 resolvedQueryId = _createResolvedLadder();
        uint256 openQueryId = _createDefaultQuery();
        address[6] memory reporters = [user, challenger, bystander, user, challenger, bystander];
        for (uint256 i = 0; i < reporters.length; i++) {
            _report(reporters[i], openQueryId, i % 2 == 0 ? OUTCOME_A : OUTCOME_B);
        }
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));
        uint256 forkQuery = _mirror();
        uint128 pot = _universe(GENESIS_UID).unmigratedSupply;
        _spawn(ZOLTAR_INVALID);
        _spawn(1);
        _spawn(2);
        uint248 childInvalid = _childId(ZOLTAR_INVALID);

        // Nobody staked on the mirrored forking query: there is nothing to pay out for it in any child.
        vm.prank(user);
        vm.expectRevert(Multiverse.NothingToClaim.selector);
        multiverse.migrateStake(GENESIS_UID, forkQuery, 1, 1);

        // The resolved query's winners are paid what claim() would have paid, into any child, the one keyed
        // by Zoltar's Invalid (0) included: bystander 3 + 3/4 of 80% of 2, user 1 + 1/4 of it.
        uint256 bystanderPayout = 3 * DEFAULT_FEE + 3 * DEFAULT_FEE * (2 * DEFAULT_FEE * 4 / 5) / (4 * DEFAULT_FEE);
        uint256 userPayout = DEFAULT_FEE + DEFAULT_FEE * (2 * DEFAULT_FEE * 4 / 5) / (4 * DEFAULT_FEE);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeMigrated(
            bystander, GENESIS_UID, childInvalid, resolvedQueryId, genesisRep.convertToAssets(bystanderPayout)
        );
        vm.prank(bystander);
        multiverse.migrateStake(GENESIS_UID, resolvedQueryId, OUTCOME_A, ZOLTAR_INVALID);
        _assertPaidInto(childInvalid, bystander, bystanderPayout);
        vm.prank(user);
        multiverse.migrateStake(GENESIS_UID, resolvedQueryId, OUTCOME_A, 1);
        _assertPaidInto(_childId(1), user, userPayout);
        // The losing side was paid out at resolution, to the winners.
        vm.prank(challenger);
        vm.expectRevert(Multiverse.NotAWinningOutcome.selector);
        multiverse.migrateStake(GENESIS_UID, resolvedQueryId, OUTCOME_B, 2);
        uint256 votes = genesisRep.convertToAssets(bystanderPayout) + genesisRep.convertToAssets(userPayout);

        // The open ladder is refunded at face value, the side at the cap too: nothing about it was decided, and
        // only the mirrored query is the forking one. Each actor takes both its stakes into the child 2 in one
        // batch.
        uint256[] memory queryIds = new uint256[](2);
        uint256[] memory outcomes = new uint256[](2);
        queryIds[0] = openQueryId;
        queryIds[1] = openQueryId;
        outcomes[0] = OUTCOME_A;
        outcomes[1] = OUTCOME_B;
        address[3] memory stakers = [user, challenger, bystander];
        for (uint256 i = 0; i < stakers.length; i++) {
            uint256 stakeA = multiverse.getUserStake(GENESIS_UID, openQueryId, stakers[i], OUTCOME_A);
            uint256 stakeB = multiverse.getUserStake(GENESIS_UID, openQueryId, stakers[i], OUTCOME_B);
            uint256 refund = genesisRep.convertToAssets(stakeA) + genesisRep.convertToAssets(stakeB);
            vm.prank(stakers[i]);
            multiverse.migrateStakes(GENESIS_UID, queryIds, outcomes, 2);
            assertEq(_repOf(_childId(2)).balanceOf(stakers[i]), _repOf(_childId(2)).convertToShares(refund));
            assertEq(multiverse.getUserStake(GENESIS_UID, openQueryId, stakers[i], OUTCOME_A), 0);
            assertEq(multiverse.getUserStake(GENESIS_UID, openQueryId, stakers[i], OUTCOME_B), 0);
            votes += refund;
        }

        // Every lane voted its whole payout out of the parked pot. What stays parked is the open query's fee,
        // copied to each child at spawn, and the rounding of the per-stake conversions.
        assertEq(_totalMigratedOut(GENESIS_UID), votes);
        uint128 unmigrated = _universe(GENESIS_UID).unmigratedSupply;
        assertEq(unmigrated, pot - votes);
        (,, uint256 openFee,,) = multiverse.queries(openQueryId);
        assertApproxEqAbs(unmigrated, genesisRep.convertToAssets(openFee), 10);
        assertGe(unmigrated, genesisRep.convertToAssets(openFee));
        uint256 parked = zoltar.getMigrationRepBalance(address(multiverse), GENESIS_UID);
        assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, 2), parked);
        assertLe(zoltar.splitPerChild(address(multiverse), GENESIS_UID, ZOLTAR_INVALID), parked);
    }

    /* ========================================== STRANDED LINEAGE =========================================== */

    function test_Mirror_StrandedLineageIsReachableLevelByLevel() public {
        // A query is open in the genesis when, outside Lituus, the genesis forks natively, its outcome-1 child is
        // deployed and forks natively in turn, and that child's outcome-2 grandchild is deployed. Lituus sees
        // none of it, for a year.
        uint256 openQueryId = _createDefaultQuery();
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));
        uint248 child1 = _childId(1);
        zoltar.deployChild(GENESIS_UID, 1);
        MockERC20(address(zoltar.childRepTokens(child1))).mint(address(this), zoltar.getForkThreshold(child1));
        zoltar.forkUniverse(child1, _createZoltarCategoricalQuestion(2));
        zoltar.deployChild(child1, 2);
        uint248 grandchild = zoltar.getChildUniverseId(child1, 2);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        // No Lituus vault: nothing wraps. No Lituus parent: the grandchild cannot be spawned directly.
        vm.prank(user);
        vm.expectRevert();
        multiverse.wrap(grandchild, 10 ether, 0);
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.spawnChildUniverse(child1, 2);

        // The descent, one level at a time and all in one block: mirror the genesis (still Active, nothing resolved
        // there since the native fork), spawn child1, mirror child1's native fork, spawn the grandchild.
        vm.startPrank(user);
        multiverse.mirrorZoltarFork(GENESIS_UID);
        multiverse.spawnChildUniverse(GENESIS_UID, 1);
        multiverse.mirrorZoltarFork(child1);
        multiverse.spawnChildUniverse(child1, 2);
        vm.stopPrank();
        uint256 forkQuery1 = _universe(GENESIS_UID).forkQuery;
        uint256 forkQuery2 = _universe(child1).forkQuery;

        // The grandchild sits on the real Zoltar lineage and answers both fork questions.
        UniverseView memory g = _universe(grandchild);
        assertEq(uint8(g.state), uint8(Multiverse.UniverseState.Active));
        assertEq(g.parent, child1);
        assertEq(_universe(child1).parent, GENESIS_UID);
        assertEq(multiverse.getOutcome(grandchild, forkQuery1), 1);
        assertEq(multiverse.getOutcome(grandchild, forkQuery2), 2);
        // The genesis fee pot was carried through the intermediate level: parked at child1's mirror, copied again
        // at the grandchild's spawn.
        assertEq(_universe(child1).unmigratedSupply, DEFAULT_FEE);
        assertEq(g.totalQueryFees, DEFAULT_FEE);

        // A user who migrated to the grandchild at the Zoltar level now wraps in, and the grandchild runs queries.
        // The genesis-era query is inherited there, reopened with a full window clocked from child1's mirror, not
        // from the year-old fork.
        _wrapFromZoltar(grandchild, user, 10 ether);
        uint256 queryId = multiverse.queryCount();
        vm.startPrank(user);
        multiverse.createQuery(grandchild, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        multiverse.report(grandchild, openQueryId, OUTCOME_A);
        vm.stopPrank();
        assertEq(multiverse.queryCount(), queryId + 1);
        (uint48 inheritedCreateTime,, uint16 inheritedStakeCount,,,,,,,) =
            multiverse.queryResolutions(grandchild, openQueryId);
        assertEq(inheritedCreateTime, _universe(child1).forkTime);
        assertEq(inheritedStakeCount, 1);

        // The intermediate levels settle root-first on their own clocks with nobody voting: no favorite child at
        // either level, and the canonical timeline dead-ends at the genesis.
        vm.warp(vm.getBlockTimestamp() + multiverse.MIGRATION_DURATION());
        multiverse.advanceForkState(GENESIS_UID);
        multiverse.advanceForkState(child1);
        assertEq(_universe(GENESIS_UID).favoriteChild, 0);
        assertEq(_universe(child1).favoriteChild, 0);
        assertEq(multiverse.canonicalHeir(), GENESIS_UID);
        assertFalse(_universe(grandchild).isCanonical);
    }
}
