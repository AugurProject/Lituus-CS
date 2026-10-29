// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @notice Reporter tips: placing them, paying them to the first correct reporter or the resolver of an
///         unreported query, and carrying them through forks.
contract MultiverseTipsTest is MultiverseFixtures {
    uint256 internal constant TIP = 5 ether;
    uint256 internal constant ANOTHER_TIP = 3 ether;

    address internal tipper = makeAddr("tipper");

    function setUp() public override {
        super.setUp();
        _fundWithRep(tipper, 100 ether);
    }

    /* ================================================ HELPERS ================================================ */

    function _tip(uint248 universeId, address from, uint256 queryId, uint256 amount) internal {
        vm.prank(from);
        multiverse.tip(universeId, queryId, amount);
    }

    function _totalTips(uint248 universeId) internal view returns (uint128 totalTips) {
        (,,,,,,,,,,,,, totalTips) = multiverse.universes(universeId);
    }

    function _totalQueryFees(uint248 universeId) internal view returns (uint128 totalQueryFees) {
        (,,,,,,,,,,, totalQueryFees,,) = multiverse.universes(universeId);
    }

    function _spawn(uint248 parentId, uint256 outcome) internal returns (uint248 childId) {
        vm.prank(bystander);
        multiverse.spawnChildUniverse(parentId, outcome);
        childId = _childId(parentId, outcome);
    }

    /// @dev Funds `account` with `amount` of a child universe's wREP (approved for the multiverse).
    function _fundChild(uint248 universeId, address account, uint256 amount) internal returns (ILituusRep repToken) {
        _wrapFromZoltar(universeId, account, amount);
        repToken = multiverse.repTokenOf(universeId);
    }

    /* ================================================== TIP ================================================== */

    function test_Tip_RecordsAndPullsRep() public {
        uint256 queryId = _createDefaultQuery();
        uint256 tipperBefore = genesisRep.balanceOf(tipper);
        uint256 multiverseBefore = genesisRep.balanceOf(address(multiverse));

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryTipped(tipper, GENESIS_UID, queryId, TIP);
        _tip(GENESIS_UID, tipper, queryId, TIP);
        // Several tippers add up.
        _tip(GENESIS_UID, bystander, queryId, ANOTHER_TIP);

        assertEq(_resolution(queryId).tips, TIP + ANOTHER_TIP);
        assertEq(_totalTips(GENESIS_UID), TIP + ANOTHER_TIP);
        assertEq(multiverse.getTips(GENESIS_UID, queryId), TIP + ANOTHER_TIP);
        assertEq(genesisRep.balanceOf(tipper), tipperBefore - TIP);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBefore + TIP + ANOTHER_TIP);
    }

    function test_Tip_AcceptedUntilTheLastSecondOfTheWindow() public {
        uint256 queryId = _createDefaultQuery();
        vm.warp(uint256(_resolution(queryId).queryCreateTime) + REPORTING_PERIOD);
        _tip(GENESIS_UID, tipper, queryId, TIP);
        assertEq(_resolution(queryId).tips, TIP);
    }

    function test_Tip_Reverts() public {
        uint256 queryId = _createDefaultQuery();

        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        _tip(GENESIS_UID + 1, tipper, queryId, TIP);

        vm.expectRevert(Multiverse.ZeroTip.selector);
        _tip(GENESIS_UID, tipper, queryId, 0);

        vm.expectRevert(Multiverse.InvalidQuery.selector);
        _tip(GENESIS_UID, tipper, queryId + 1, TIP);

        // Closed by the first report.
        uint256 reportedId = _createReportedQuery(OUTCOME_A);
        vm.expectRevert(Multiverse.QueryAlreadyReported.selector);
        _tip(GENESIS_UID, tipper, reportedId, TIP);

        // Closed by the end of the reporting window.
        _warpPastReportingWindow(queryId);
        vm.expectRevert(Multiverse.QueryExpired.selector);
        _tip(GENESIS_UID, tipper, queryId, TIP);

        // Closed for good once resolved.
        _resolve(bystander, queryId);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        _tip(GENESIS_UID, tipper, queryId, TIP);
    }

    /// @dev The nearest ancestor record decides: a query resolved in the genesis before the fork, and the forking
    ///      query resolved in its child at spawn, are closed to tips in every descendant.
    function test_Tip_RevertsOnQueryResolvedInAncestor() public {
        uint256 resolvedId = _createResolvableReportedQuery(OUTCOME_A);
        _resolve(bystander, resolvedId);
        (uint256 forkQueryId,) = _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        _fundChild(child1, tipper, 100 ether);

        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        _tip(child1, tipper, resolvedId, TIP);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        _tip(child1, tipper, forkQueryId, TIP);

        // A grandchild: child1 forks on a query of its own, and both closed queries stay closed below it.
        _fundChild(child1, user, 1000 ether);
        uint256 nestedQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _escalateToFork(child1, nestedQueryId, user, user);
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        _fundChild(grandchild, tipper, 100 ether);

        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        _tip(grandchild, tipper, resolvedId, TIP);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        _tip(grandchild, tipper, forkQueryId, TIP);
    }

    function test_Tip_RevertsInForkingUniverse() public {
        uint256 openQueryId = _createDefaultQuery();
        _forkGenesis();
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
    }

    /* ============================================ REPORTER PAYOUT ============================================ */

    /// @dev A report in the creation block earns a zero fee share, but the tips are paid in full: stake + tips
    ///      in the one transfer that settles the sole stake. The tips are not profit: only the unpaid fee burns.
    function test_Payout_SoleReporterGetsFullTipsWithStake() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _report(user, queryId, OUTCOME_A); // stake = DEFAULT_FEE, fee share 0 (elapsed 0)
        _warpPastAppealWindow(queryId);

        uint256 userBefore = genesisRep.balanceOf(user);
        uint256 supplyBefore = genesisRep.totalSupply();

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0, TIP);
        _resolve(bystander, queryId);

        // Balance before + user's stake + tips. No query fee share because the report was in the creation block.
        assertEq(genesisRep.balanceOf(user), userBefore + DEFAULT_FEE + TIP);
        // Paid out: the record is cleared.
        assertEq(_resolution(queryId).tips, 0);
        // Only the unpaid fee is burned.
        assertEq(genesisRep.totalSupply(), supplyBefore - DEFAULT_FEE);
        assertEq(_totalTips(GENESIS_UID), 0);
        assertEq(multiverse.getTips(GENESIS_UID, queryId), 0);
    }

    /// @dev The canonical ladder (user→A at 18h, challenger→B, bystander→A): A wins, and its first reporter —
    ///      user, not the last reporter bystander — gets the quarter fee share plus the full tips.
    function test_Payout_FirstReporterOfWinningOutcomeGetsTips() public {
        uint256 multiverseBefore = genesisRep.balanceOf(address(multiverse));
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);

        vm.warp(vm.getBlockTimestamp() + 18 hours);
        _report(user, queryId, OUTCOME_A);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _report(challenger, queryId, OUTCOME_B);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _report(bystander, queryId, OUTCOME_A);
        _warpPastAppealWindow(queryId);

        uint256 userBefore = genesisRep.balanceOf(user);
        uint256 bystanderBefore = genesisRep.balanceOf(bystander);
        uint256 challengerBefore = genesisRep.balanceOf(challenger);
        _resolve(challenger, queryId);

        // More that 1 stake: users don't get their stakes back, they need to claim. Only the query fee
        // share and the tips are pushed to the first winning reporter
        assertEq(genesisRep.balanceOf(user), userBefore + DEFAULT_FEE / 4 + TIP);
        assertEq(genesisRep.balanceOf(bystander), bystanderBefore);
        assertEq(genesisRep.balanceOf(challenger), challengerBefore);
        assertEq(_totalTips(GENESIS_UID), 0);

        // With losers, the winners' stakes come back through claim(). A holds 4 fee (user 1, bystander 3), B lost
        // 2 fee, a fifth of it burned: 1.6 fee is shared pro rata. The tips are not part of it.
        assertEq(_claim(user, queryId), 14 * DEFAULT_FEE / 10); // 1 + 1 * 1.6 / 4
        assertEq(_claim(bystander, queryId), 42 * DEFAULT_FEE / 10); // 3 + 3 * 1.6 / 4

        // Everything the query brought in has left: fee 1 + tips 5 + stakes 6 = paid 10.85 (fee share 0.25,
        // tips, claims 5.6) + burned 1.15 (fee remainder 0.75, loser burn 0.4).
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBefore);
    }

    function test_Payout_InvalidReporterGetsTips() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _report(user, queryId, multiverse.INVALID());
        _warpPastAppealWindow(queryId);

        uint256 userBefore = genesisRep.balanceOf(user);
        _resolve(bystander, queryId);
        assertEq(genesisRep.balanceOf(user), userBefore + DEFAULT_FEE + TIP);
    }

    /* ============================================ RESOLVER PAYOUT ============================================ */

    /// @dev Unreported and expired: the resolver gets the full tips at once, next to the fee share that ramps
    ///      from the deadline (one second in here).
    function test_Payout_ResolverOfExpiredQueryGetsFullTips() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _warpPastReportingWindow(queryId);

        uint256 resolverShare = DEFAULT_FEE * 1 / REPORTING_PERIOD;
        uint256 bystanderBefore = genesisRep.balanceOf(bystander);
        uint256 supplyBefore = genesisRep.totalSupply();

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ResolverRewardPaid(bystander, GENESIS_UID, queryId, resolverShare, TIP);
        assertEq(_resolve(bystander, queryId), multiverse.INVALID());

        assertEq(genesisRep.balanceOf(bystander), bystanderBefore + resolverShare + TIP);
        assertEq(_resolution(queryId).tips, 0);
        assertEq(genesisRep.totalSupply(), supplyBefore - (DEFAULT_FEE - resolverShare));
        assertEq(_totalTips(GENESIS_UID), 0);
    }

    /* ========================================== FORK: OTHER QUERIES ========================================== */

    /// @dev An open query's tips are copied into every child; a tip placed in one child stays there.
    function test_Fork_TipsCarryIntoEveryChildAndStayLocal() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        // The forking query had no tips: the aggregate is the open query's.
        assertEq(_totalTips(GENESIS_UID), TIP);

        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 child2 = _spawn(GENESIS_UID, OUTCOME_B);
        assertEq(_totalTips(child1), TIP);
        assertEq(_totalTips(child2), TIP);
        assertEq(multiverse.getTips(child1, openQueryId), TIP);

        // First touch by tip: stores the inherited tips plus the new one.
        _fundChild(child1, tipper, 100 ether);
        _tip(child1, tipper, openQueryId, ANOTHER_TIP);
        assertEq(_resolutionIn(child1, openQueryId).tips, TIP + ANOTHER_TIP);
        assertEq(_totalTips(child1), TIP + ANOTHER_TIP);
        // The sibling is untouched.
        assertEq(multiverse.getTips(child2, openQueryId), TIP);
        assertEq(_totalTips(child2), TIP);
    }

    /// @dev First touch by report stores the inherited tips; parent and child tips are paid together.
    function test_Fork_InheritedTipsPaidAfterFirstTouchByReport() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        ILituusRep child1Rep = _fundChild(child1, user, 100 ether);
        _fundChild(child1, tipper, 100 ether);
        _tip(child1, tipper, openQueryId, ANOTHER_TIP);

        // In the fork block: zero fee share, so the reporter's gain is exactly stake + tips.
        uint256 stake = multiverse.getNextRequiredStake(child1, openQueryId, OUTCOME_A);
        vm.prank(user);
        multiverse.report(child1, openQueryId, OUTCOME_A);
        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);

        uint256 userBefore = child1Rep.balanceOf(user);
        vm.prank(bystander);
        multiverse.resolve(child1, openQueryId);
        assertEq(child1Rep.balanceOf(user), userBefore + stake + TIP + ANOTHER_TIP);
        assertEq(_resolutionIn(child1, openQueryId).tips, 0);
        assertEq(_totalTips(child1), 0);
    }

    /// @dev Two tips in a child on an inherited query: the first anchors the record with the inherited tips, the
    ///      second only adds to it. The first report then finds the record with no stakes; the reporter is paid
    ///      the inherited tips plus both child tips.
    function test_Fork_SeveralChildTipsThenReportPaysAll() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        ILituusRep child1Rep = _fundChild(child1, user, 100 ether);
        _fundChild(child1, tipper, 100 ether);
        _fundChild(child1, bystander, 100 ether);

        // First touch: inherited tips + this tip.
        _tip(child1, tipper, openQueryId, ANOTHER_TIP);
        assertEq(_resolutionIn(child1, openQueryId).tips, TIP + ANOTHER_TIP);
        // The record exists: nothing more is inherited, the tip just adds.
        _tip(child1, bystander, openQueryId, 2 ether);
        uint256 allTips = TIP + ANOTHER_TIP + 2 ether;
        assertEq(_resolutionIn(child1, openQueryId).tips, allTips);
        assertEq(_totalTips(child1), allTips);
        assertEq(multiverse.getTips(child1, openQueryId), allTips);

        // The first report: no stakes yet, but the record holds its tips and keeps them.
        uint256 stake = multiverse.getNextRequiredStake(child1, openQueryId, OUTCOME_A);
        vm.prank(user);
        multiverse.report(child1, openQueryId, OUTCOME_A);
        assertEq(_resolutionIn(child1, openQueryId).tips, allTips);

        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);
        uint256 userBefore = child1Rep.balanceOf(user);
        vm.prank(bystander);
        multiverse.resolve(child1, openQueryId);
        // In the fork block: zero fee share, so the reporter's gain is exactly stake + every tip.
        assertEq(child1Rep.balanceOf(user), userBefore + stake + allTips);
        assertEq(_resolutionIn(child1, openQueryId).tips, 0);
        assertEq(_totalTips(child1), 0);
    }

    function test_Fork_FirstTouchByReportStoresInheritedTips() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        _fundChild(child1, user, 100 ether);

        assertEq(_resolutionIn(child1, openQueryId).tips, 0); // no local record yet
        vm.prank(user);
        multiverse.report(child1, openQueryId, OUTCOME_A);
        assertEq(_resolutionIn(child1, openQueryId).tips, TIP);
    }

    /// @dev First touch by resolve: the child's window expires unreported, the resolver gets the inherited tips.
    function test_Fork_InheritedTipsPaidToResolverOnFirstTouch() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        ILituusRep child1Rep = multiverse.repTokenOf(child1);

        vm.warp(vm.getBlockTimestamp() + REPORTING_PERIOD + 1);
        uint256 resolverShare = DEFAULT_FEE * 1 / REPORTING_PERIOD;
        vm.prank(bystander);
        multiverse.resolve(child1, openQueryId);
        assertEq(child1Rep.balanceOf(bystander), resolverShare + TIP);
        assertEq(_totalTips(child1), 0);
        // The record keeps its anchored clock (descendants find it by that) but never stored the inherited tips.
        (,, uint48 genesisForkTime,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        assertEq(_resolutionIn(child1, openQueryId).queryCreateTime, genesisForkTime);
        assertEq(_resolutionIn(child1, openQueryId).tips, 0);
        assertEq(_resolutionIn(child1, openQueryId).outcome, multiverse.INVALID());
    }

    /// @dev Two fork levels. The open query is tipped in the genesis and again in child1, which forks later on
    ///      another query; a second open query is tipped in the genesis only and never touched in child1. The
    ///      grandchild inherits child1's complete tips for the first and reads past child1 to the genesis for
    ///      the second. The first query restarts at child1's fork, not the genesis's: by then the genesis-anchored
    ///      window has long expired.
    function test_Fork_GrandchildInheritsNearestRecordAndRestartsAtParentFork() public {
        uint256 tippedTwiceId = _createDefaultQuery();
        uint256 untouchedId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, tippedTwiceId, TIP);
        _tip(GENESIS_UID, tipper, untouchedId, 2 ether);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        _fundChild(child1, tipper, 100 ether);
        _tip(child1, tipper, tippedTwiceId, ANOTHER_TIP);

        // child1 forks well past the genesis-anchored window, on a query of its own.
        vm.warp(vm.getBlockTimestamp() + 2 * REPORTING_PERIOD);
        _fundChild(child1, user, 1000 ether);
        uint256 nestedQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _escalateToFork(child1, nestedQueryId, user, user);
        (,, uint48 child1ForkTime,,,,,,,,,,,) = multiverse.universes(child1);
        assertEq(_totalTips(child1), TIP + ANOTHER_TIP + 2 ether);

        uint248 grandchild = _spawn(child1, OUTCOME_A);
        assertEq(_totalTips(grandchild), TIP + ANOTHER_TIP + 2 ether);
        assertEq(multiverse.getTips(grandchild, tippedTwiceId), TIP + ANOTHER_TIP);
        assertEq(multiverse.getTips(grandchild, untouchedId), 2 ether);

        // Reportable right away: the window restarted at child1's fork.
        ILituusRep grandchildRep = _fundChild(grandchild, challenger, 100 ether);
        uint256 stake = multiverse.getNextRequiredStake(grandchild, tippedTwiceId, OUTCOME_B);
        vm.prank(challenger);
        multiverse.report(grandchild, tippedTwiceId, OUTCOME_B);
        assertEq(_resolutionIn(grandchild, tippedTwiceId).queryCreateTime, child1ForkTime);
        assertEq(_resolutionIn(grandchild, tippedTwiceId).tips, TIP + ANOTHER_TIP);

        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);
        uint256 challengerBefore = grandchildRep.balanceOf(challenger);
        vm.prank(bystander);
        multiverse.resolve(grandchild, tippedTwiceId);
        assertEq(grandchildRep.balanceOf(challenger), challengerBefore + stake + TIP + ANOTHER_TIP);
    }

    /// @dev A mirrored native Zoltar fork has no forking Lituus query: the whole tip aggregate carries.
    function test_Fork_MirroredZoltarForkCarriesTips() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));
        vm.prank(bystander);
        multiverse.mirrorZoltarFork(GENESIS_UID);
        assertEq(_totalTips(GENESIS_UID), TIP);

        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_totalTips(child), TIP);
        assertEq(multiverse.getTips(child, openQueryId), TIP);
    }

    /* ========================================== FORK: FORKING QUERY ========================================== */

    /// @dev The forking query's tips leave the aggregate in the fork tx, so no child inherits them as a pool.
    ///      Every child pays the full tips to the first reporter of its own outcome, from the parked balance —
    ///      even with a zero fee share (the ladder runs in the creation block). A child whose outcome nobody
    ///      reported pays nothing. An open tipped query alongside proves the payout is a fresh draw: each child
    ///      still holds exactly its fee and tip pools after paying its reporter, and the parent's record keeps
    ///      the tips for the next spawn.
    function test_ForkingQuery_EachChildPaysFullTipsToItsFirstReporter() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, ANOTHER_TIP);
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _escalateToFork(GENESIS_UID, queryId, user, challenger);
        assertEq(_totalTips(GENESIS_UID), ANOTHER_TIP);

        uint248 childAId = _childId(GENESIS_UID, OUTCOME_A);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, childAId, queryId, 0, TIP);
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        uint248 childC = _spawn(GENESIS_UID, OUTCOME_C);

        assertEq(multiverse.repTokenOf(childA).balanceOf(user), TIP);
        assertEq(multiverse.repTokenOf(childB).balanceOf(challenger), TIP);
        assertEq(multiverse.repTokenOf(childC).balanceOf(user), 0);
        assertEq(multiverse.repTokenOf(childC).balanceOf(challenger), 0);
        // The parent's record still holds the tips: every spawn reads them.
        assertEq(_resolution(queryId).tips, TIP);

        uint248[3] memory children = [childA, childB, childC];
        for (uint256 i = 0; i < children.length; ++i) {
            // Only the open query's tips carry as a pool.
            assertEq(_totalTips(children[i]), ANOTHER_TIP);
            assertEq(multiverse.getTips(children[i], openQueryId), ANOTHER_TIP);
            // The child holds exactly its pools: the reporter's tips were not taken out of them.
            assertEq(
                multiverse.repTokenOf(children[i]).balanceOf(address(multiverse)),
                _totalQueryFees(children[i]) + _totalTips(children[i])
            );
        }
    }

    /// @dev Tipped in the genesis and again in child1, then the forking query of child1: each grandchild pays
    ///      both tips to the first reporter of its outcome.
    function test_ForkingQuery_TippedInChildPaysAllTipsInGrandchildren() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        _fundChild(child1, tipper, 100 ether);
        _tip(child1, tipper, queryId, ANOTHER_TIP);

        _fundChild(child1, user, 1000 ether);
        _fundChild(child1, challenger, 1000 ether);
        _escalateToFork(child1, queryId, user, challenger);
        assertEq(_totalTips(child1), 0);

        uint248 grandchildA = _spawn(child1, OUTCOME_A);
        uint248 grandchildB = _spawn(child1, OUTCOME_B);
        assertEq(multiverse.repTokenOf(grandchildA).balanceOf(user), TIP + ANOTHER_TIP);
        assertEq(multiverse.repTokenOf(grandchildB).balanceOf(challenger), TIP + ANOTHER_TIP);
    }

    /// @dev A first report 18 hours in earns a quarter of the fee, 36 hours in a half, so each child's reporter is
    ///      paid both a fee share and the tips out of one draw, and the event splits the child shares between them.
    function test_ForkingQuery_RewardSplitsFeeShareAndTips() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        // The first rung lands 18 hours in, the next 36 hours in, every rung inside the appeal window.
        _escalateToFork(GENESIS_UID, queryId, user, challenger, 18 hours);

        uint248 childAId = _childId(GENESIS_UID, OUTCOME_A);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, childAId, queryId, DEFAULT_FEE / 4, TIP);
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);

        uint248 childBId = _childId(GENESIS_UID, OUTCOME_B);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(challenger, childBId, queryId, DEFAULT_FEE / 2, TIP);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);

        assertEq(multiverse.repTokenOf(childA).balanceOf(user), DEFAULT_FEE / 4 + TIP);
        assertEq(multiverse.repTokenOf(childB).balanceOf(challenger), DEFAULT_FEE / 2 + TIP);
    }

    /// @dev A query created in one child is not inherited by its sibling: neither tippable nor readable there.
    function test_Tip_RevertsOnSiblingQuery() public {
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 child2 = _spawn(GENESIS_UID, OUTCOME_B);
        _fundChild(child1, user, 100 ether);
        uint256 siblingQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _fundChild(child2, tipper, 100 ether);

        vm.expectRevert(Multiverse.QueryNotInherited.selector);
        _tip(child2, tipper, siblingQueryId, TIP);
        vm.expectRevert(Multiverse.QueryNotInherited.selector);
        multiverse.getTips(child2, siblingQueryId);
    }

    function test_GetTips_Reverts() public {
        uint256 queryId = _createDefaultQuery();
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.getTips(GENESIS_UID + 1, queryId);
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.getTips(GENESIS_UID, queryId + 1);
    }

    /// @dev A forked universe pays no tips — its children do — so it reads zero for the open query and for the
    ///      forking query alike, while each child reads what it will pay.
    function test_GetTips_ZeroInForkedUniverse() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        uint256 forkQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, forkQueryId, ANOTHER_TIP);
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);

        assertEq(multiverse.getTips(GENESIS_UID, openQueryId), 0);
        assertEq(multiverse.getTips(GENESIS_UID, forkQueryId), 0);

        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(multiverse.getTips(child1, openQueryId), TIP);
        // The forking query is resolved in the child at spawn.
        assertEq(multiverse.getTips(child1, forkQueryId), 0);
    }

    /// @dev The tips follow the first reporter of the winning outcome, not the first reporter overall: the
    ///      challenger opens on B, the user answers A, and A wins.
    function test_Payout_FirstReporterOverallOnLosingOutcomeGetsNoTips() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _report(challenger, queryId, OUTCOME_B);
        _report(user, queryId, OUTCOME_A);
        _warpPastAppealWindow(queryId);

        uint256 userBefore = genesisRep.balanceOf(user);
        uint256 challengerBefore = genesisRep.balanceOf(challenger);
        vm.expectEmit(true, true, true, true, address(multiverse));
        // The user's first report on A landed in the creation block: zero fee share, the full tips.
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0, TIP);
        assertEq(_resolve(bystander, queryId), OUTCOME_A);

        assertEq(genesisRep.balanceOf(user), userBefore + TIP);
        assertEq(genesisRep.balanceOf(challenger), challengerBefore);
    }

    /// @dev A query resolved INVALID on its first touch in a child is resolved for that child's descendants: the
    ///      resolve anchored the child's record, so the grandchild's walk stops at it instead of reaching the
    ///      genesis's open record. Neither the query nor its tips come back.
    function test_Fork_FirstTouchInvalidResolveClosesQueryForDescendants() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);

        vm.warp(vm.getBlockTimestamp() + REPORTING_PERIOD + 1);
        vm.prank(bystander);
        multiverse.resolve(child1, openQueryId);
        assertEq(multiverse.getOutcome(child1, openQueryId), multiverse.INVALID());

        // child1 forks on a query of its own.
        _fundChild(child1, user, 1000 ether);
        uint256 nestedQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _escalateToFork(child1, nestedQueryId, user, user);
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        _fundChild(grandchild, tipper, 100 ether);
        _fundChild(grandchild, challenger, 100 ether);

        assertEq(multiverse.getOutcome(grandchild, openQueryId), multiverse.INVALID());
        assertEq(multiverse.getTips(grandchild, openQueryId), 0);
        // The genesis's tips were paid in child1 and left child1's pool: none carried into the grandchild.
        assertEq(_totalTips(grandchild), 0);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        _tip(grandchild, tipper, openQueryId, TIP);
        vm.prank(challenger);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.report(grandchild, openQueryId, OUTCOME_B);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.resolve(grandchild, openQueryId);
    }

    /// @dev The Zoltar counterpart forked natively, but the fork is not mirrored yet: the universe is still
    ///      Active, so a tip lands. The mirror then parks it with the rest of the pot, and the child carries it.
    function test_Fork_TipBetweenNativeZoltarForkAndMirrorCarries() public {
        uint256 openQueryId = _createDefaultQuery();
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        assertEq(_totalTips(GENESIS_UID), TIP);

        vm.prank(bystander);
        multiverse.mirrorZoltarFork(GENESIS_UID);
        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_totalTips(child), TIP);
        assertEq(multiverse.getTips(child, openQueryId), TIP);
    }

    /// @dev resolve() pays the tips and then, in the same tx, mirrors the native Zoltar fork, which parks what is
    ///      left. The resolver was paid before the pot moved, and nothing of the paid tips carries into a child.
    function test_Fork_ResolvePaysTipsThenMirrorsNativeFork() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _warpPastReportingWindow(queryId);
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));

        uint256 resolverShare = DEFAULT_FEE * 1 / REPORTING_PERIOD;
        uint256 bystanderBefore = genesisRep.balanceOf(bystander);
        vm.prank(bystander);
        multiverse.resolve(GENESIS_UID, queryId);

        assertEq(genesisRep.balanceOf(bystander), bystanderBefore + resolverShare + TIP);
        assertEq(uint8(_universeState(GENESIS_UID)), uint8(Multiverse.UniverseState.Migration));
        assertEq(_totalTips(GENESIS_UID), 0);
        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_totalTips(child), 0);
    }
}
