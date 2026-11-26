// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MultiverseHelpers } from "src/libraries/MultiverseHelpers.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @notice Reporter tips: placing them, paying them to the first correct reporter or the resolver of an
///         unreported query, and carrying them through forks.
contract MultiverseTipsTest is MultiverseFixtures {
    // Small enough to cross every fork in the carry tests whole: a fork caps the tips its children carry at 0.1%
    // of the universe's wREP (3.1 REP in the genesis here, about 1.1 REP in a child funded with 1,100).
    uint256 internal constant TIP = 0.5 ether;
    uint256 internal constant ANOTHER_TIP = 0.3 ether;

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

    /// @dev Moves a universe's rate off where it stands: `user` creates a query there, nobody reports it, and an
    ///      hour past its window `bystander` resolves it INVALID, which burns the fee the resolver did not earn.
    function _burnFeeIn(uint248 universeId) internal {
        uint256 expiredId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(universeId, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.warp(vm.getBlockTimestamp() + REPORTING_PERIOD + 1 hours);
        vm.prank(bystander);
        multiverse.resolve(universeId, expiredId);
    }

    /// @dev Lets a query that became reportable in this block expire unreported and its resolver's fee share ramp
    ///      up to the whole fee. The ramp starts at the reporting deadline and takes as long as the reporting
    ///      window, so that is two reporting periods from now.
    function _warpPastResolverFeeRamp() internal {
        vm.warp(vm.getBlockTimestamp() + 2 * REPORTING_PERIOD);
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
        assertEq(_universe(GENESIS_UID).totalTips, TIP + ANOTHER_TIP);
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
        assertEq(_universe(GENESIS_UID).totalTips, 0);
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
        assertEq(_universe(GENESIS_UID).totalTips, 0);

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
    ///      from the deadline (halfway up here, so half the fee).
    function test_Payout_ResolverOfExpiredQueryGetsFullTips() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        // Half a reporting period past the deadline.
        vm.warp(vm.getBlockTimestamp() + REPORTING_PERIOD + REPORTING_PERIOD / 2);

        uint256 resolverShare = DEFAULT_FEE / 2;
        uint256 bystanderBefore = genesisRep.balanceOf(bystander);
        uint256 supplyBefore = genesisRep.totalSupply();

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ResolverRewardPaid(bystander, GENESIS_UID, queryId, resolverShare, TIP);
        assertEq(_resolve(bystander, queryId), multiverse.INVALID());

        assertEq(genesisRep.balanceOf(bystander), bystanderBefore + resolverShare + TIP);
        assertEq(_resolution(queryId).tips, 0);
        assertEq(genesisRep.totalSupply(), supplyBefore - (DEFAULT_FEE - resolverShare));
        assertEq(_universe(GENESIS_UID).totalTips, 0);
    }

    /* ========================================== FORK: OTHER QUERIES ========================================== */

    /// @dev An open query's tips are copied into every child; a tip placed in one child stays there.
    function test_Fork_TipsCarryIntoEveryChildAndStayLocal() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        _forkGenesis();
        // The forking query had no tips: the aggregate is the open query's, and the children carry it whole.
        assertEq(_universe(GENESIS_UID).totalTips, TIP);
        assertEq(_universe(GENESIS_UID).carriedTips, TIP);

        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 child2 = _spawn(GENESIS_UID, OUTCOME_B);
        assertEq(_universe(child1).totalTips, TIP);
        assertEq(_universe(child2).totalTips, TIP);
        assertEq(multiverse.getTips(child1, openQueryId), TIP);

        // First touch by tip: stores the inherited tips plus the new one.
        _fundChild(child1, tipper, 100 ether);
        _tip(child1, tipper, openQueryId, ANOTHER_TIP);
        assertEq(_resolutionIn(child1, openQueryId).tips, TIP + ANOTHER_TIP);
        assertEq(_universe(child1).totalTips, TIP + ANOTHER_TIP);
        // The sibling is untouched.
        assertEq(multiverse.getTips(child2, openQueryId), TIP);
        assertEq(_universe(child2).totalTips, TIP);
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
        assertEq(_universe(child1).totalTips, 0);
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
        assertEq(_universe(child1).totalTips, allTips);
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
        assertEq(_universe(child1).totalTips, 0);
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

        _warpPastResolverFeeRamp();
        vm.prank(bystander);
        multiverse.resolve(child1, openQueryId);
        assertEq(child1Rep.balanceOf(bystander), DEFAULT_FEE + TIP);
        assertEq(_universe(child1).totalTips, 0);
        // The record keeps its anchored clock (descendants find it by that) but never stored the inherited tips.
        uint48 genesisForkTime = _universe(GENESIS_UID).forkTime;
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
        _tip(GENESIS_UID, tipper, untouchedId, 0.2 ether);
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
        uint48 child1ForkTime = _universe(child1).forkTime;
        assertEq(_universe(child1).carriedTips, TIP + ANOTHER_TIP + 0.2 ether);

        uint248 grandchild = _spawn(child1, OUTCOME_A);
        assertEq(_universe(grandchild).totalTips, TIP + ANOTHER_TIP + 0.2 ether);
        assertEq(multiverse.getTips(grandchild, tippedTwiceId), TIP + ANOTHER_TIP);
        assertEq(multiverse.getTips(grandchild, untouchedId), 0.2 ether);

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
        assertEq(_universe(GENESIS_UID).carriedTips, TIP);

        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_universe(child).totalTips, TIP);
        assertEq(multiverse.getTips(child, openQueryId), TIP);
    }

    /* ========================================== FORK: FORKING QUERY ========================================== */

    /// @dev The forking query's tips stay in the aggregate the fork carries. Under the cap nothing is cut: every
    ///      child pays the full tips to the first reporter of its own outcome out of what it draws — even with a
    ///      zero fee share (the ladder runs in the creation block) — and keeps the rest as its pool. A child whose
    ///      outcome nobody reported pays nothing and keeps only its pool. An open tipped query alongside shows
    ///      each child still holds exactly its fee and tip pools after paying its reporter, and the parent's
    ///      record keeps the tips for the next spawn.
    function test_ForkingQuery_EachChildPaysFullTipsToItsFirstReporter() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, ANOTHER_TIP);
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _escalateToFork(GENESIS_UID, queryId, user, challenger);
        assertEq(_universe(GENESIS_UID).totalTips, TIP + ANOTHER_TIP);
        assertEq(_universe(GENESIS_UID).carriedTips, TIP + ANOTHER_TIP);

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
            // Only the open query's tips are left as a pool, also where nobody was paid.
            assertEq(_universe(children[i]).totalTips, ANOTHER_TIP);
            assertEq(multiverse.getTips(children[i], openQueryId), ANOTHER_TIP);
            // The child holds exactly its pools: the reporter's tips were not taken out of them.
            assertEq(
                multiverse.repTokenOf(children[i]).balanceOf(address(multiverse)),
                _universe(children[i]).totalQueryFees + _universe(children[i]).totalTips
            );
        }
    }

    /// @dev Tipped in the genesis and again in child1, then the forking query of child1: each grandchild pays
    ///      both tips to the first reporter of its outcome. They are under child1's cap, so nothing is cut.
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
        assertEq(_universe(child1).totalTips, TIP + ANOTHER_TIP);
        assertEq(_universe(child1).carriedTips, TIP + ANOTHER_TIP);

        uint248 grandchildA = _spawn(child1, OUTCOME_A);
        uint248 grandchildB = _spawn(child1, OUTCOME_B);
        assertEq(multiverse.repTokenOf(grandchildA).balanceOf(user), TIP + ANOTHER_TIP);
        assertEq(multiverse.repTokenOf(grandchildB).balanceOf(challenger), TIP + ANOTHER_TIP);
        // The reporter took all the carried tips: nothing is left as a pool.
        assertEq(_universe(grandchildA).totalTips, 0);
        assertEq(_universe(grandchildB).totalTips, 0);
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
        assertEq(_universe(grandchild).totalTips, 0);
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
        assertEq(_universe(GENESIS_UID).totalTips, TIP);

        vm.prank(bystander);
        multiverse.mirrorZoltarFork(GENESIS_UID);
        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_universe(child).totalTips, TIP);
        assertEq(multiverse.getTips(child, openQueryId), TIP);
    }

    /// @dev resolve() pays the tips and then, in the same tx, mirrors the native Zoltar fork, which parks what is
    ///      left. The resolver was paid before the pot moved, and nothing of the paid tips carries into a child.
    function test_Fork_ResolvePaysTipsThenMirrorsNativeFork() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        _warpPastResolverFeeRamp();
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));

        uint256 bystanderBefore = genesisRep.balanceOf(bystander);
        vm.prank(bystander);
        multiverse.resolve(GENESIS_UID, queryId);

        assertEq(genesisRep.balanceOf(bystander), bystanderBefore + DEFAULT_FEE + TIP);
        assertEq(uint8(_universeState(GENESIS_UID)), uint8(Multiverse.UniverseState.Migration));
        assertEq(_universe(GENESIS_UID).totalTips, 0);
        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_universe(child).totalTips, 0);
    }

    /* ======================================== FORK: TIP CAP, NESTED ========================================= */

    /// @dev The tip cap a fork of `universeId` applies: 0.1% of the wREP wrapped in it, in shares. The fork tx reads
    ///      it before the pot leaves, so the stakes, fees and tips the Multiverse holds count. Read it after the
    ///      universe's last wrap and before its fork: queries, tips and stakes only move wREP around.
    function _tipCap(uint248 universeId) internal view returns (uint256) {
        return multiverse.repTokenOf(universeId).totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;
    }

    /// @dev Forks a child universe on a fresh, untipped query of its own, escalated by `user` on both sides. Wraps
    ///      nothing, so a cap read before it holds: the caller funds `user` in the child beforehand.
    function _forkOnFreshQuery(uint248 universeId) internal {
        uint256 forkQueryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(universeId, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _escalateToFork(universeId, forkQueryId, user, user);
    }

    /// @dev Forks the genesis and then its outcome-1 child natively, at the Zoltar level, with Lituus seeing
    ///      neither. The lineage can then be replayed here one level at a time (mirror, spawn, mirror, spawn)
    ///      with nobody migrating in between.
    function _forkTwoLevelsNatively() internal returns (uint248 child1) {
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));
        child1 = _childId(GENESIS_UID, 1);
        zoltar.deployChild(GENESIS_UID, 1);
        MockERC20(address(zoltar.childRepTokens(child1))).mint(address(this), zoltar.getForkThreshold(child1));
        zoltar.forkUniverse(child1, _createZoltarCategoricalQuestion(2));
    }

    /// @dev The TipsCapped events among the logs recorded since vm.recordLogs(): how many there were, and the
    ///      amounts of the last one.
    function _recordedTipsCapped()
        internal
        view
        returns (uint256 count, uint256 tips, uint256 carried, uint256 donated)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != Multiverse.TipsCapped.selector) continue;
            ++count;
            (tips, carried, donated) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
    }

    /// @dev Capital arrives in child1 before it forks: the tipper and `user` (who forks it) get child1 wREP, and a
    ///      holder wraps 5,000 REP, standing in for the migrated capital. That lifts child1's cap above the
    ///      genesis's.
    function _fundChild1(uint248 child1) internal {
        _fundChild(child1, tipper, 100 ether);
        _fundChild(child1, user, 1000 ether);
        _fundChild(child1, makeAddr("holder"), 5000 ether);
    }

    /// @dev Tips two genesis queries at 3/2 and 1/2 of the genesis cap, so the pool is twice the cap, forks the
    ///      genesis (every carried tip is halved) and spawns child1. The genesis holds 3,100 wREP (the three
    ///      actors' 1,000 each and the tipper's 100), so the cap is 3.1 REP.
    function _tipAndForkGenesis()
        internal
        returns (uint248 child1, uint256 untouchedId, uint256 untouchedTip, uint256 touchedId, uint256 touchedTip)
    {
        uint256 genesisCap = _tipCap(GENESIS_UID);
        assertEq(genesisCap, 3.1 ether, "fixture: 3,100 wREP wrapped in the genesis");
        untouchedId = _createDefaultQuery();
        touchedId = _createDefaultQuery();
        untouchedTip = genesisCap * 3 / 2;
        touchedTip = genesisCap / 2;
        _tip(GENESIS_UID, tipper, untouchedId, untouchedTip);
        _tip(GENESIS_UID, tipper, touchedId, touchedTip);
        _forkGenesis();
        child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(_universe(child1).totalTips, genesisCap);
        assertEq(multiverse.getTips(child1, untouchedId), untouchedTip / 2);
        assertEq(multiverse.getTips(child1, touchedId), touchedTip / 2);
    }

    /// @dev Two capped forks in one line, genesis -> child1 -> grandchild, each cutting the carried tips in half.
    ///      A record holds tips already cut by the forks above it, and a read applies the cut of every fork
    ///      between the nearest record and the reading universe, the record holder's own fork included:
    ///      - a query untouched since the genesis is cut by both forks, to a quarter;
    ///      - a query touched in child1 was cut by the genesis fork at that first touch, and child1's fork cuts its
    ///        record in half on the read;
    ///      - a query created in child1 never crossed the genesis fork, so only child1's fork cuts it.
    ///      The grandchild owes no more than it carries. A single factor copied down the line keeps only
    ///      child1's cut, so the untouched query would read half its tip and the grandchild would owe more than
    ///      it holds.
    function test_TipCap_TwoCappedForksCompound() public {
        (uint248 child1, uint256 untouchedId, uint256 untouchedTip, uint256 touchedId, uint256 touchedTip) =
            _tipAndForkGenesis();
        _fundChild1(child1);

        // child1 inherited the query with its tips halved by the genesis fork. A new tip is the query's first
        // touch in child1: the record created there stores the inherited tips plus the new one.
        uint256 inheritedTip = touchedTip / 2;
        uint256 childTip = 0.5 ether;
        _tip(child1, tipper, touchedId, childTip);
        uint256 touchedRecord = inheritedTip + childTip;
        assertEq(_resolutionIn(child1, touchedId).tips, touchedRecord);

        // A query created in child1 never crossed the genesis fork: nothing cuts its tips in child1. Its tip brings
        // child1's pool to twice child1's cap, so child1's fork halves every carried tip again.
        uint256 localId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        uint256 child1Cap = _tipCap(child1);
        uint256 localTip = 2 * child1Cap - _universe(child1).totalTips;
        _tip(child1, tipper, localId, localTip);
        assertEq(multiverse.getTips(child1, localId), localTip);
        assertEq(_universe(child1).totalTips, 2 * child1Cap);

        _forkOnFreshQuery(child1);
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        assertEq(_universe(grandchild).totalTips, child1Cap);
        uint256 untouchedRead = multiverse.getTips(grandchild, untouchedId);
        uint256 touchedRead = multiverse.getTips(grandchild, touchedId);
        uint256 localRead = multiverse.getTips(grandchild, localId);
        assertEq(untouchedRead, untouchedTip / 4); // both forks
        assertEq(touchedRead, touchedRecord / 2); // child1's fork, on child1's record
        assertEq(localRead, localTip / 2); // child1's fork only
        // The grandchild owes no more than it carries, short by rounding at most.
        assertLe(untouchedRead + touchedRead + localRead, child1Cap);
        assertApproxEqAbs(untouchedRead + touchedRead + localRead, child1Cap, 2);

        // The payout matches the read: the reporter of the untouched query gets the twice-cut tips.
        ILituusRep grandchildRep = _fundChild(grandchild, challenger, 100 ether);
        uint256 stake = multiverse.getNextRequiredStake(grandchild, untouchedId, OUTCOME_B);
        vm.prank(challenger);
        multiverse.report(grandchild, untouchedId, OUTCOME_B);
        assertEq(_resolutionIn(grandchild, untouchedId).tips, untouchedRead);
        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);
        uint256 challengerBefore = grandchildRep.balanceOf(challenger);
        vm.prank(bystander);
        multiverse.resolve(grandchild, untouchedId);
        // Reported in child1's fork block: zero fee share, so the gain is exactly stake + tips.
        assertEq(grandchildRep.balanceOf(challenger), challengerBefore + stake + untouchedRead);
        assertEq(_universe(grandchild).totalTips, child1Cap - untouchedRead);
    }

    /// @dev Only the upper fork is capped. The genesis halves the carried tips. child1's pool stays under child1's
    ///      own cap, so child1's fork cuts nothing. The grandchild reads every child1 record in full. Only the query
    ///      untouched since the genesis still shows the genesis cut, which it took crossing that fork. The reads
    ///      add up to exactly what the grandchild carries. A factor copied down the line would carry the genesis
    ///      cut past child1's fork. It would halve child1's records a second time and strand the difference in
    ///      the grandchild.
    function test_TipCap_OnlyUpperForkCapped_LowerForkCarriesInFull() public {
        (uint248 child1, uint256 untouchedId, uint256 untouchedTip, uint256 touchedId, uint256 touchedTip) =
            _tipAndForkGenesis();
        _fundChild1(child1);

        // The touched query gets a new tip in child1, on top of the tips it inherited halved by the genesis fork.
        // A query created in child1 is tipped there too.
        uint256 inheritedTip = touchedTip / 2;
        uint256 childTip = 0.5 ether;
        _tip(child1, tipper, touchedId, childTip);
        uint256 touchedRecord = inheritedTip + childTip;
        assertEq(_resolutionIn(child1, touchedId).tips, touchedRecord);
        uint256 localId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        uint256 localTip = 1 ether;
        _tip(child1, tipper, localId, localTip);
        assertEq(multiverse.getTips(child1, localId), localTip);
        // child1's pool stays under its cap: child1's fork cuts nothing.
        uint256 child1Pool = _universe(child1).totalTips;
        assertLt(child1Pool, _tipCap(child1));

        _forkOnFreshQuery(child1);
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        assertEq(_universe(grandchild).totalTips, child1Pool);
        uint256 untouchedRead = multiverse.getTips(grandchild, untouchedId);
        uint256 touchedRead = multiverse.getTips(grandchild, touchedId);
        uint256 localRead = multiverse.getTips(grandchild, localId);
        assertEq(untouchedRead, untouchedTip / 2); // the genesis cut only
        assertEq(touchedRead, touchedRecord); // child1's record, uncut
        assertEq(localRead, localTip); // child1's record, uncut
        // Nothing the grandchild carries is stranded.
        assertEq(untouchedRead + touchedRead + localRead, child1Pool);

        // The payout matches the read: the touched query's reporter gets child1's record in full.
        ILituusRep grandchildRep = _fundChild(grandchild, challenger, 100 ether);
        uint256 stake = multiverse.getNextRequiredStake(grandchild, touchedId, OUTCOME_B);
        vm.prank(challenger);
        multiverse.report(grandchild, touchedId, OUTCOME_B);
        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);
        uint256 challengerBefore = grandchildRep.balanceOf(challenger);
        vm.prank(bystander);
        multiverse.resolve(grandchild, touchedId);
        // Reported in child1's fork block: zero fee share, so the gain is exactly stake + tips.
        assertEq(grandchildRep.balanceOf(challenger), challengerBefore + stake + touchedRecord);
    }

    /* ======================================= FORK: TIP CAP, ONE FORK ======================================== */

    /// @dev Two open queries tipped 4 and 2 REP against a 3.1 REP cap (3,100 wREP wrapped). The fork keeps 3.1 for
    ///      its children and each query is cut by 3.1 / 6, rounded down. The fixture's tokenizer has no query
    ///      tokens, so nothing is donated: the 2.9 REP excess is parked with the pot and no child draws it.
    function test_TipCap_AboveTheCap_EveryTipCutAndExcessLeftParked() public {
        uint256 firstId = _createDefaultQuery();
        uint256 secondId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, firstId, 4 ether);
        _tip(GENESIS_UID, tipper, secondId, 2 ether);
        (uint256 forkQueryId,) = _createLadderToCap();
        assertEq(_tipCap(GENESIS_UID), 3.1 ether, "fixture: 3,100 wREP wrapped in the genesis");

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.TipsCapped(GENESIS_UID, 6 ether, 3.1 ether, 0);
        vm.prank(user);
        multiverse.report(GENESIS_UID, forkQueryId, OUTCOME_A);
        assertEq(uint8(_universeState(GENESIS_UID)), uint8(Multiverse.UniverseState.Migration));

        assertEq(_universe(GENESIS_UID).carriedTips, 3.1 ether);
        assertEq(_universe(GENESIS_UID).totalTips, 6 ether);
        // The records keep the tips as placed: the cut applies where a child reads them.
        assertEq(_resolution(firstId).tips, 4 ether);
        assertEq(_resolution(secondId).tips, 2 ether);
        // Nothing went to the tokenizer, and the whole pot left the vault, the excess with it.
        assertEq(genesisRep.balanceOf(address(queryTokenizerStub)), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);

        uint248[2] memory children = [_spawn(GENESIS_UID, OUTCOME_A), _spawn(GENESIS_UID, OUTCOME_B)];
        uint256[2] memory childOutcomes = [OUTCOME_A, OUTCOME_B];
        for (uint256 i = 0; i < children.length; ++i) {
            assertEq(_universe(children[i]).totalTips, 3.1 ether);
            // 4 x 3.1 / 6 and 2 x 3.1 / 6, rounded down: a wei of the pool is owed to nobody.
            assertEq(multiverse.getTips(children[i], firstId), 2_066_666_666_666_666_666);
            assertEq(multiverse.getTips(children[i], secondId), 1_033_333_333_333_333_333);
            // The child drew its fee pool (the two open queries' fees) and its capped tip pool from the parked
            // balance, and holds exactly those: the forking query had no tips and its reporters earned no fee
            // share (a same-block ladder). The excess stays parked.
            assertEq(
                zoltar.splitPerChild(address(multiverse), GENESIS_UID, childOutcomes[i]), 2 * DEFAULT_FEE + 3.1 ether
            );
            assertEq(
                multiverse.repTokenOf(children[i]).balanceOf(address(multiverse)),
                _universe(children[i]).totalQueryFees + _universe(children[i]).totalTips
            );
        }

        // The cut tips are what a child pays: the resolver of the expired first query gets them, next to the fee.
        ILituusRep childRep = multiverse.repTokenOf(children[0]);
        _warpPastResolverFeeRamp();
        vm.prank(bystander);
        multiverse.resolve(children[0], firstId);
        assertEq(childRep.balanceOf(bystander), DEFAULT_FEE + 2_066_666_666_666_666_666);
        assertEq(_universe(children[0]).totalTips, 3.1 ether - 2_066_666_666_666_666_666);
    }

    /// @dev Tips an open query `openTip` and the forking query `forkTip` against the 3.1 REP cap, and forks the
    ///      genesis on the forking query in its creation block, so its reporters earn no fee share.
    function _forkWithTips(uint256 forkTip, uint256 openTip) internal returns (uint256 forkQueryId, uint256 openId) {
        if (openTip != 0) {
            openId = _createDefaultQuery();
            _tip(GENESIS_UID, tipper, openId, openTip);
        }
        forkQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, forkQueryId, forkTip);
        assertEq(_tipCap(GENESIS_UID), 3.1 ether, "fixture: 3,100 wREP wrapped in the genesis");
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);
    }

    /// @dev The forking query's tips are under the same cap as the open queries'. 21 REP on it and 10 REP on an
    ///      open query make 31 REP, ten times the 3.1 REP cap, so the fork carries a tenth of every tip:
    ///      - each child pays the forking query's 2.1 REP to the first reporter of its outcome;
    ///      - the other 1 REP of the 3.1 is the child's pool, exactly the open query's cut tips;
    ///      - a child whose outcome nobody reported pays nobody, keeps the same pool and draws nothing more.
    function test_TipCap_ForkingQueryTipsShareTheCap() public {
        vm.recordLogs();
        (uint256 forkQueryId, uint256 openQueryId) = _forkWithTips(21 ether, 10 ether);
        (uint256 count, uint256 tips, uint256 carried, uint256 donated) = _recordedTipsCapped();
        assertEq(count, 1);
        assertEq(tips, 31 ether);
        assertEq(carried, 3.1 ether);
        assertEq(donated, 0);
        assertEq(_universe(GENESIS_UID).totalTips, 31 ether);
        assertEq(_universe(GENESIS_UID).carriedTips, 3.1 ether);
        // The record keeps what was tipped: every spawn cuts it.
        assertEq(_resolution(forkQueryId).tips, 21 ether);

        // A tenth of each tip. The child keeps the rest of the 3.1 REP.
        uint256 forkCut = 2.1 ether;
        uint256 openCut = 1 ether;
        uint256 childPool = 1 ether;

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, _childId(GENESIS_UID, OUTCOME_A), forkQueryId, 0, forkCut);
        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        uint248 childInvalid = _spawn(GENESIS_UID, MultiverseHelpers.INVALID);
        assertEq(multiverse.repTokenOf(childA).balanceOf(user), forkCut);
        assertEq(multiverse.repTokenOf(childB).balanceOf(challenger), forkCut);

        uint248[3] memory children = [childA, childB, childInvalid];
        for (uint256 i = 0; i < children.length; ++i) {
            assertEq(_universe(children[i]).totalTips, childPool);
            assertEq(multiverse.getTips(children[i], openQueryId), openCut);
            assertEq(
                multiverse.repTokenOf(children[i]).balanceOf(address(multiverse)),
                _universe(children[i]).totalQueryFees + childPool
            );
        }
        // At a rate of 1 the draws are the amounts themselves: the fee pool and all the carried tips where the
        // reporter was paid, the fee pool and the child's pool where nobody reported.
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A), DEFAULT_FEE + 3.1 ether);
        assertEq(
            zoltar.splitPerChild(address(multiverse), GENESIS_UID, MultiverseHelpers.INVALID), DEFAULT_FEE + childPool
        );
    }

    /// @dev Only the forking query is tipped, 100 REP: it alone fills the cap. Each reporter gets the whole
    ///      3.1 REP the fork carries, and no child keeps a pool.
    function test_TipCap_OnlyTheForkingQueryTipped_ItsReporterGetsTheCap() public {
        (uint256 forkQueryId,) = _forkWithTips(100 ether, 0);
        assertEq(_universe(GENESIS_UID).totalTips, 100 ether);
        assertEq(_universe(GENESIS_UID).carriedTips, 3.1 ether);

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 childInvalid = _spawn(GENESIS_UID, MultiverseHelpers.INVALID);
        assertEq(multiverse.repTokenOf(childA).balanceOf(user), 3.1 ether);
        assertEq(_universe(childA).totalTips, 0);
        assertEq(_universe(childInvalid).totalTips, 0);
        // Nobody reported INVALID: the child draws nothing of the tips, and with no open query there is no fee
        // pool either.
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, MultiverseHelpers.INVALID), 0);
        assertEq(_resolution(forkQueryId).tips, 100 ether);
        // The child draws the whole 3.1 REP the fork carries (reporter tips), and nothing more.
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A), 3.1 ether);
    }

    /// @dev The share works both ways: open tips dilute the forking query's. 2 REP on it next to 98 REP on an open
    ///      query keep 2 x 3.1 / 100 = 0.062 REP for its reporter, and the open query 3.038 REP.
    function test_TipCap_OpenTipsDiluteTheForkingTip() public {
        (, uint256 openQueryId) = _forkWithTips(2 ether, 98 ether);

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(multiverse.repTokenOf(childA).balanceOf(user), 0.062 ether);
        assertEq(_universe(childA).totalTips, 3.038 ether);
        assertEq(multiverse.getTips(childA, openQueryId), 3.038 ether);
    }

    /// @dev At a rate off 1, with a ramped fee share, the spawn makes one draw for the carried tips, rounded up,
    ///      and the fee share, rounded down. The vault mints the tips whole: the child keeps its pool to the wei
    ///      and the reporter gets the forking query's cut tips to the wei. The fee share can come out a wei above
    ///      what converting it alone would give, never above the share earned. The two tips add up to 2 REP,
    ///      split unevenly.
    function test_ForkingQuery_OneDrawPaysTheCutTipsExactlyAtARateOffOne() public {
        _burnFeeIn(GENESIS_UID);
        assertGt(genesisRep.rate(), 1 ether);
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, 0.765_432_109_876_543_211 ether);
        uint256 forkQueryId = _createDefaultQuery();
        uint256 forkTip = 1.234_567_890_123_456_789 ether;
        _tip(GENESIS_UID, tipper, forkQueryId, forkTip);
        // The first rung lands 18 hours in: a quarter of the fee.
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger, 18 hours);
        uint256 held = _universe(GENESIS_UID).totalTips;
        uint256 carried = _universe(GENESIS_UID).carriedTips;
        assertEq(held, 2 ether);
        uint256 forkCut = Math.mulDiv(forkTip, carried, held);
        uint256 feeShare = DEFAULT_FEE / 4;
        // The child copies the fee aggregate less the forking query's fee, which goes to its reporter.
        uint256 feePool = _universe(GENESIS_UID).totalQueryFees - DEFAULT_FEE;

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(
            zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A),
            genesisRep.convertToAssets(feePool) + genesisRep.convertToAssetsUp(carried)
                + genesisRep.convertToAssets(feeShare)
        );
        ILituusRep childRep = multiverse.repTokenOf(childA);
        assertEq(_universe(childA).totalTips, carried - forkCut);
        uint256 feeShares = childRep.balanceOf(user) - forkCut;
        assertGe(feeShares, childRep.convertToShares(genesisRep.convertToAssets(feeShare)));
        assertLe(feeShares, feeShare);
        // The Multiverse holds exactly the child's pools: the reporter's payment came out of the draw whole.
        assertEq(
            childRep.balanceOf(address(multiverse)), _universe(childA).totalQueryFees + _universe(childA).totalTips
        );
        assertLe(multiverse.getTips(childA, openQueryId), _universe(childA).totalTips);
    }

    /// @dev A mirrored native Zoltar fork caps its tips the same way: it has no forking Lituus query, so every
    ///      tip is an open query's.
    function test_TipCap_MirroredForkCapsToo() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, 4 ether);
        _forkZoltarNatively(_createZoltarCategoricalQuestion(2));
        assertEq(_tipCap(GENESIS_UID), 3.1 ether, "fixture: 3,100 wREP wrapped in the genesis");

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.TipsCapped(GENESIS_UID, 4 ether, 3.1 ether, 0);
        vm.prank(bystander);
        multiverse.mirrorZoltarFork(GENESIS_UID);
        assertEq(_universe(GENESIS_UID).totalTips, 4 ether);
        assertEq(_universe(GENESIS_UID).carriedTips, 3.1 ether);

        uint248 child = _spawn(GENESIS_UID, 1);
        assertEq(_universe(child).totalTips, 3.1 ether);
        assertEq(multiverse.getTips(child, openQueryId), 3.1 ether);
    }

    /* ===================================== FORK: TIP CAP, FRESH CHILD ====================================== */

    /// @dev The cap has no floor: it is 0.1% of the wREP wrapped in the forking universe, in a new universe too. A
    ///      child that forks before any REP has migrated into it holds little more in its vault than its own fee
    ///      and tip aggregates, so the tips it inherited are cut about a thousandfold, although its parent's fork
    ///      carried them whole. That loss is accepted. Here a Zoltar lineage two forks deep is replayed in one
    ///      block: 0.5 REP of tips cross the genesis fork whole, and child1's fork carries 0.0015 REP of them.
    function test_TipCap_FreshChildFork_CutsTheInheritedTipsToItsOwnCap() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, TIP);
        uint248 child1 = _forkTwoLevelsNatively();

        multiverse.mirrorZoltarFork(GENESIS_UID);
        _spawn(GENESIS_UID, 1);
        // child1 inherited the tips whole. Its vault holds the open query's fee and those tips, nothing else, so
        // its cap is 0.1% of 1.5 REP.
        assertEq(_universe(child1).totalTips, TIP);
        assertEq(multiverse.repTokenOf(child1).totalSupply(), DEFAULT_FEE + TIP);
        uint256 child1Cap = _tipCap(child1);
        assertEq(child1Cap, 0.0015 ether);

        // The fixture's tokenizer has no query tokens, so nothing is donated: the excess stays parked.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.TipsCapped(child1, TIP, child1Cap, 0);
        multiverse.mirrorZoltarFork(child1);
        assertEq(_universe(child1).totalTips, TIP);
        assertEq(_universe(child1).carriedTips, child1Cap);

        uint248 grandchild = _spawn(child1, 2);
        assertEq(_universe(grandchild).totalTips, child1Cap);
        assertEq(multiverse.getTips(grandchild, openQueryId), child1Cap);
    }

    /// @dev Pins a known lever: the cap is measured on the wREP supply as it stands in the fork tx. A holder who
    ///      unwraps before the fork lowers it, which cuts tips that were under the cap, and loses nothing by it:
    ///      wrapping stays open on a forked universe, so the holder wraps back and migrates as usual.
    function test_TipCap_UnwrappingBeforeTheForkLowersTheCap() public {
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, 2.5 ether);
        assertEq(_tipCap(GENESIS_UID), 3.1 ether, "fixture: 3,100 wREP wrapped in the genesis");

        uint256 unwrapped = 900 ether;
        vm.prank(bystander);
        multiverse.unwrap(GENESIS_UID, unwrapped, 0);
        assertEq(_tipCap(GENESIS_UID), 2.2 ether);
        _forkGenesis();
        assertEq(_universe(GENESIS_UID).totalTips, 2.5 ether);
        assertEq(_universe(GENESIS_UID).carriedTips, 2.2 ether);

        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(multiverse.getTips(child1, openQueryId), 2.2 ether);

        vm.startPrank(bystander);
        multiverse.wrap(GENESIS_UID, unwrapped, 0);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, unwrapped);
        vm.stopPrank();
        assertEq(multiverse.repTokenOf(child1).balanceOf(bystander), unwrapped);
    }

    /* ========================================== TIPS CAPPED EVENT =========================================== */

    /// @dev The event reports what the children carry, not the cap: a wei under it where the cap does not convert
    ///      evenly at the universe's rate.
    function test_TipsCapped_ReportsTheCarriedPoolAWeiUnderTheCap() public {
        _burnFeeIn(GENESIS_UID);
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, 5 ether);
        uint256 cap = _tipCap(GENESIS_UID);
        assertTrue(mulmod(cap, genesisRep.rate(), 1 ether) != 0, "fixture: the cap must not divide evenly at the rate");

        vm.recordLogs();
        _forkGenesis();
        (uint256 count, uint256 tips, uint256 carried, uint256 donated) = _recordedTipsCapped();
        assertEq(count, 1);
        assertEq(tips, 5 ether);
        assertEq(carried, cap - 1);
        assertEq(carried, _universe(GENESIS_UID).carriedTips);
        assertEq(donated, 0);
    }

    /// @dev Under the cap, the rounding to whole child shares still takes a wei off the pool. That is a cut too:
    ///      every tip is cut with it, so the event is emitted.
    function test_TipsCapped_EmittedForARoundingOnlyCut() public {
        _burnFeeIn(GENESIS_UID);
        uint256 queryId = _createDefaultQuery();
        uint256 tip = 1.234_567_890_123_456_789 ether;
        _tip(GENESIS_UID, tipper, queryId, tip);
        assertLt(tip, _tipCap(GENESIS_UID));

        vm.recordLogs();
        _forkGenesis();
        (uint256 count, uint256 tips, uint256 carried, uint256 donated) = _recordedTipsCapped();
        assertEq(count, 1);
        assertEq(tips, tip);
        assertEq(carried, tip - 1);
        assertEq(donated, 0);
    }

    /// @dev A fork that carries its tips whole emits nothing: under the cap at a rate of 1, or at any rate with an
    ///      amount that converts evenly.
    function test_TipsCapped_NotEmittedWhenTheTipsCarryWhole() public {
        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, TIP);
        vm.recordLogs();
        _forkGenesis();
        (uint256 count,,,) = _recordedTipsCapped();
        assertEq(count, 0);
        assertEq(_universe(GENESIS_UID).carriedTips, TIP);

        // One level down the rate is off 1, and a whole REP still converts evenly.
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        _fundChild1(child1);
        _tip(child1, tipper, queryId, 1 ether - TIP);
        _burnFeeIn(child1);
        assertGt(multiverse.repTokenOf(child1).rate(), 1 ether);
        vm.recordLogs();
        _forkOnFreshQuery(child1);
        (count,,,) = _recordedTipsCapped();
        assertEq(count, 0);
        assertEq(_universe(child1).carriedTips, 1 ether);
    }

    /* ========================================= FORK: TIP ROUNDING =========================================== */

    /// @dev Under the cap a tip crosses a fork together with its pool, and both lose the same wei. A child's pool
    ///      is a copy made through the parent's rate (shares to REP and back), which comes out a wei short when
    ///      the tips do not divide evenly at that rate. The fork rounds the pool it carries down to that amount
    ///      and cuts the tip by the same ratio, so the tip owed and the pool stay equal: a wei less in the child,
    ///      two in the grandchild. The reporter in the grandchild is paid everything the record holds, and that
    ///      empties the pool to the wei.
    function test_TipCopy_PoolAndTipLoseTheSameWeiPerForkLevel() public {
        _burnFeeIn(GENESIS_UID);
        uint256 rate = genesisRep.rate();
        assertGt(rate, 1 ether);

        uint256 queryId = _createDefaultQuery();
        uint256 tip = 1.234_567_890_123_456_789 ether;
        // This tip leaves a remainder, twice.
        assertTrue(mulmod(tip, rate, 1 ether) != 0, "fixture: the tip must not divide evenly at the rate");
        assertTrue(mulmod(tip - 1, rate, 1 ether) != 0, "fixture: nor the tip less a wei");
        _tip(GENESIS_UID, tipper, queryId, tip);
        assertLt(tip, _tipCap(GENESIS_UID));
        _forkGenesis();
        // Under the cap, but the pool does not convert evenly: the genesis carries it less a wei.
        assertEq(_universe(GENESIS_UID).totalTips, tip);
        assertEq(_universe(GENESIS_UID).carriedTips, tip - 1);
        // The record keeps the tip as placed: the cut applies where a child reads it.
        assertEq(_resolution(queryId).tips, tip);

        // One level down: the child holds exactly what the genesis carried, and owes exactly that.
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(_universe(child1).totalTips, tip - 1);
        assertEq(multiverse.getTips(child1, queryId), tip - 1);

        _fundChild1(child1);
        assertLt(_universe(child1).totalTips, _tipCap(child1));
        _forkOnFreshQuery(child1);
        assertEq(_universe(child1).totalTips, tip - 1);
        assertEq(_universe(child1).carriedTips, tip - 2);

        // Two levels down: two wei less, in the pool and in the tip owed alike.
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        assertEq(_universe(grandchild).totalTips, tip - 2);
        assertEq(multiverse.getTips(grandchild, queryId), tip - 2);

        // The first report stores what the query is owed, which is what the pool holds.
        ILituusRep grandchildRep = _fundChild(grandchild, challenger, 100 ether);
        uint256 stake = multiverse.getNextRequiredStake(grandchild, queryId, OUTCOME_B);
        vm.prank(challenger);
        multiverse.report(grandchild, queryId, OUTCOME_B);
        assertEq(_resolutionIn(grandchild, queryId).tips, tip - 2);
        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);
        uint256 challengerBefore = grandchildRep.balanceOf(challenger);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(challenger, grandchild, queryId, 0, tip - 2);
        vm.prank(bystander);
        multiverse.resolve(grandchild, queryId);
        // Reported in child1's fork block: zero fee share, so the gain is exactly stake + tips.
        assertEq(grandchildRep.balanceOf(challenger), challengerBefore + stake + tip - 2);
        assertEq(_universe(grandchild).totalTips, 0);
        assertEq(_resolutionIn(grandchild, queryId).tips, 0);
        // The stake went back, the fee was burned whole and the tips were paid in full: nothing is left.
        assertEq(grandchildRep.balanceOf(address(multiverse)), 0);
    }

    /// @dev With more than one tipped query the rounding leaves dust in the pool, never a shortage. Two queries
    ///      are tipped under the cap at a rate where nothing divides evenly. Each fork carries the pool less a
    ///      wei and cuts every tip by that ratio, which takes a wei off each of the two. So the pool loses one
    ///      wei per level and the tips owed lose two: the pool is a wei above the tips owed in the child and two
    ///      in the grandchild. Both queries are paid in full there and the two wei stay in the pool, owed to
    ///      nobody. A child draws no more REP for its pool than the pot holds for the tips.
    function test_TipCopy_DustAccumulatesInThePool() public {
        _burnFeeIn(GENESIS_UID);
        uint256 rate = genesisRep.rate();
        assertGt(rate, 1 ether);

        uint256[2] memory ids = [_createDefaultQuery(), _createDefaultQuery()];
        uint256[2] memory tips = [uint256(1.234_567_890_123_456_789 ether), 0.987_654_321_098_765_432 ether];
        uint256 pool = tips[0] + tips[1];
        assertTrue(mulmod(pool, rate, 1 ether) != 0, "fixture: the pool must not divide evenly at the rate");
        assertTrue(mulmod(pool - 1, rate, 1 ether) != 0, "fixture: nor the pool less a wei");
        _tip(GENESIS_UID, tipper, ids[0], tips[0]);
        _tip(GENESIS_UID, tipper, ids[1], tips[1]);
        assertLt(pool, _tipCap(GENESIS_UID));
        _forkGenesis();
        assertEq(_universe(GENESIS_UID).totalTips, pool);
        assertEq(_universe(GENESIS_UID).carriedTips, pool - 1);

        // One level down: the pool lost a wei and each tip lost a wei. One wei of dust.
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(_universe(child1).totalTips, pool - 1);
        assertEq(multiverse.getTips(child1, ids[0]), tips[0] - 1);
        assertEq(multiverse.getTips(child1, ids[1]), tips[1] - 1);
        // The child drew its fee pool (the two open queries' fees) and its tip pool from the parked balance. The
        // REP for the tip pool is rounded up, and still within what the pot holds for the tips.
        uint256 drawnForTips = zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A)
            - genesisRep.convertToAssets(2 * DEFAULT_FEE);
        assertEq(drawnForTips, genesisRep.convertToAssetsUp(pool - 1));
        assertLe(drawnForTips, genesisRep.convertToAssets(pool));

        _fundChild1(child1);
        assertLt(_universe(child1).totalTips, _tipCap(child1));
        _forkOnFreshQuery(child1);
        assertEq(_universe(child1).totalTips, pool - 1);
        assertEq(_universe(child1).carriedTips, pool - 2);

        // Two levels down: another wei off the pool and off each tip. Two wei of dust.
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        assertEq(_universe(grandchild).totalTips, pool - 2);
        assertEq(multiverse.getTips(grandchild, ids[0]), tips[0] - 2);
        assertEq(multiverse.getTips(grandchild, ids[1]), tips[1] - 2);

        // Both queries expire unreported and pay their resolver in full: the fee plus the tips owed.
        ILituusRep grandchildRep = multiverse.repTokenOf(grandchild);
        _warpPastResolverFeeRamp();
        for (uint256 i = 0; i < 2; ++i) {
            uint256 resolverBefore = grandchildRep.balanceOf(bystander);
            vm.prank(bystander);
            multiverse.resolve(grandchild, ids[i]);
            assertEq(grandchildRep.balanceOf(bystander) - resolverBefore, DEFAULT_FEE + tips[i] - 2);
        }
        // The dust: two wei nobody is owed. The fees were paid out whole, so it is all the Multiverse still holds
        // there.
        assertEq(_universe(grandchild).totalTips, 2);
        assertEq(grandchildRep.balanceOf(address(multiverse)), 2);
    }

    /// @dev A capped fork whose cap does not convert evenly at the rate. One query holds all the tips, so its cut
    ///      tips are the whole pool the children carry. The fork rounds the capped pool down to what a child's
    ///      vault mints for it, a wei under the cap here, and cuts the query's tips to that same amount. The
    ///      child owes exactly what it holds and pays it in full. Cut to the cap itself, the query would be owed
    ///      a wei more than the child's pool.
    function test_TipCap_CappedFork_PoolCoversTheCutTips() public {
        _burnFeeIn(GENESIS_UID);
        uint256 rate = genesisRep.rate();
        assertGt(rate, 1 ether);

        uint256 queryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, queryId, 5 ether);
        uint256 cap = _tipCap(GENESIS_UID);
        assertLt(cap, 5 ether, "fixture: the fork must be capped");
        assertTrue(mulmod(cap, rate, 1 ether) != 0, "fixture: the cap must not divide evenly at the rate");
        _forkGenesis();
        assertEq(_universe(GENESIS_UID).totalTips, 5 ether);
        // The cap, rounded down to what a child's vault mints for it.
        assertEq(_universe(GENESIS_UID).carriedTips, cap - 1);

        // The child's pool is exactly that, and so are the query's tips: 5 x (cap - 1) / 5.
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(_universe(child1).totalTips, cap - 1);
        assertEq(multiverse.getTips(child1, queryId), cap - 1);

        // The first report stores what the query is owed: the whole pool, and no more.
        ILituusRep child1Rep = _fundChild(child1, challenger, 100 ether);
        uint256 stake = multiverse.getNextRequiredStake(child1, queryId, OUTCOME_B);
        vm.prank(challenger);
        multiverse.report(child1, queryId, OUTCOME_B);
        assertEq(_resolutionIn(child1, queryId).tips, cap - 1);
        assertEq(_universe(child1).totalTips, cap - 1);

        vm.warp(vm.getBlockTimestamp() + APPEAL_PERIOD + 1);
        uint256 challengerBefore = child1Rep.balanceOf(challenger);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(challenger, child1, queryId, 0, cap - 1);
        vm.prank(bystander);
        multiverse.resolve(child1, queryId);
        // Reported in the genesis fork block: zero fee share, so the gain is exactly stake + tips.
        assertEq(child1Rep.balanceOf(challenger), challengerBefore + stake + cap - 1);
        assertEq(_universe(child1).totalTips, 0);
        assertEq(_resolutionIn(child1, queryId).tips, 0);
        // The stake went back, the fee was burned whole and the tips were paid in full: nothing is left.
        assertEq(child1Rep.balanceOf(address(multiverse)), 0);
    }

    /// @dev Two capped forks in one line with nothing dividing evenly: three queries tipped odd amounts, the rate
    ///      off 1 at both levels, and one query tipped again in child1 so the records sit at two levels. Every
    ///      fork rounds the pool it carries down to what a child's vault mints for it, and every cut rounds
    ///      down. The errors add up over the two levels, always on the pool's side:
    ///      - a child's pool is exactly the pool its parent carried;
    ///      - a query reads what it was owed one level up, cut by carried / pool and rounded down, once per fork
    ///        in the order the forks happened: at most 2 wei under its exact share, never over it;
    ///      - the tips owed never exceed the pool, and the pool exceeds them by at most 2 wei per level (a wei
    ///        per query, less one).
    ///      Every query is paid in full, and the dust the cuts left stays in the pool.
    function test_TipCap_NestedCappedForks_RoundingErrorsAccumulate() public {
        _burnFeeIn(GENESIS_UID);
        uint256[3] memory ids = [_createDefaultQuery(), _createDefaultQuery(), _createDefaultQuery()];
        uint256[3] memory tips = [
            uint256(1.123_456_789_012_345_678 ether), 2.345_678_901_234_567_891 ether, 0.987_654_321_098_765_432 ether
        ];
        for (uint256 i = 0; i < 3; ++i) {
            _tip(GENESIS_UID, tipper, ids[i], tips[i]);
        }
        uint256 pool1 = tips[0] + tips[1] + tips[2];
        uint256 cap1 = _tipCap(GENESIS_UID);
        assertGt(pool1, cap1, "fixture: the genesis fork must be capped");
        _forkGenesis();
        assertEq(_universe(GENESIS_UID).totalTips, pool1);
        // The genesis carries the cap, rounded down to what a child's vault mints for it: a wei less here.
        uint256 carried1 = _universe(GENESIS_UID).carriedTips;
        assertEq(carried1, genesisRep.convertToShares(genesisRep.convertToAssets(cap1)));
        assertEq(carried1, cap1 - 1, "fixture: the cap must not convert evenly at the genesis rate");

        // One level down: the child holds what the genesis carried, and each query is cut by carried1 / pool1.
        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        uint256 ledger1 = _universe(child1).totalTips;
        assertEq(ledger1, carried1);
        uint256[3] memory owed1;
        uint256 sum1;
        for (uint256 i = 0; i < 3; ++i) {
            owed1[i] = multiverse.getTips(child1, ids[i]);
            assertEq(owed1[i], Math.mulDiv(tips[i], carried1, pool1));
            sum1 += owed1[i];
        }
        assertLe(sum1, ledger1);
        assertLe(ledger1 - sum1, 2);

        // child1: the second query is tipped again, the rate moves again, and its fork is capped too.
        _fundChild(child1, tipper, 100 ether);
        _fundChild(child1, user, 1000 ether);
        uint256 childTip = 0.777_777_777_777_777_777 ether;
        _tip(child1, tipper, ids[1], childTip);
        assertEq(_resolutionIn(child1, ids[1]).tips, owed1[1] + childTip);
        _burnFeeIn(child1);
        ILituusRep child1Rep = multiverse.repTokenOf(child1);
        assertGt(child1Rep.rate(), genesisRep.rate());
        uint256 pool2 = _universe(child1).totalTips;
        assertEq(pool2, ledger1 + childTip);
        uint256 cap2 = _tipCap(child1);
        assertGt(pool2, cap2, "fixture: child1's fork must be capped");
        _forkOnFreshQuery(child1);
        assertEq(_universe(child1).totalTips, pool2);
        uint256 carried2 = _universe(child1).carriedTips;
        assertEq(carried2, child1Rep.convertToShares(child1Rep.convertToAssets(cap2)));

        // Two levels down: the grandchild holds what child1 carried, and what child1 owed each query is cut by
        // carried2 / pool2. For the untouched queries that is the genesis cut first, then child1's.
        uint248 grandchild = _spawn(child1, OUTCOME_A);
        uint256 ledger2 = _universe(grandchild).totalTips;
        assertEq(ledger2, carried2);
        uint256[3] memory owedInChild1 = [owed1[0], owed1[1] + childTip, owed1[2]];
        uint256[3] memory owed2;
        uint256 sum2;
        for (uint256 i = 0; i < 3; ++i) {
            owed2[i] = multiverse.getTips(grandchild, ids[i]);
            assertEq(owed2[i], Math.mulDiv(owedInChild1[i], carried2, pool2));
            sum2 += owed2[i];
        }
        // The order of the cuts shows in a wei: cutting an untouched query by child1's ratio first would give
        // another amount.
        assertTrue(
            Math.mulDiv(Math.mulDiv(tips[0], carried2, pool2), carried1, pool1) != owed2[0]
                || Math.mulDiv(Math.mulDiv(tips[2], carried2, pool2), carried1, pool1) != owed2[2],
            "fixture: the two orders must differ for an untouched query"
        );

        // Against the exact shares, over the common denominator pool1 x pool2: the untouched queries'
        // tips x carried1 x carried2, the touched one's (tips x carried1 + childTip x pool1) x carried2.
        uint256 denominator = pool1 * pool2;
        uint256[3] memory exactNumerators = [
            tips[0] * carried1 * carried2,
            (tips[1] * carried1 + childTip * pool1) * carried2,
            tips[2] * carried1 * carried2
        ];
        for (uint256 i = 0; i < 3; ++i) {
            assertLe(owed2[i] * denominator, exactNumerators[i]);
            assertGt((owed2[i] + 2) * denominator, exactNumerators[i]);
        }
        // Never short. The dust of both levels is in the pool.
        assertLe(sum2, ledger2);
        uint256 dust = ledger2 - sum2;
        assertGt(dust, 0, "fixture: the cuts must leave dust");
        assertLe(dust, 4);

        // Every query pays out in full: each expires unreported and its resolver gets the fee plus the tips owed.
        ILituusRep grandchildRep = multiverse.repTokenOf(grandchild);
        _warpPastResolverFeeRamp();
        for (uint256 i = 0; i < 3; ++i) {
            uint256 resolverBefore = grandchildRep.balanceOf(bystander);
            vm.prank(bystander);
            multiverse.resolve(grandchild, ids[i]);
            assertEq(grandchildRep.balanceOf(bystander) - resolverBefore, DEFAULT_FEE + owed2[i]);
        }
        assertEq(_universe(grandchild).totalTips, dust);
        // The fees were paid out whole, so all the Multiverse still holds there is the dust the cuts left in the
        // pool.
        assertEq(grandchildRep.balanceOf(address(multiverse)), dust);
    }

    /// @dev A tip pool of one wei makes no child share at a rate above 1: a vault mints nothing for it and would
    ///      revert, blocking every child of the fork for good, the pool being frozen in the forked parent. The
    ///      fork rounds the pool it carries down to what a child's vault mints, so here it carries nothing and
    ///      the wei stays parked with the pot. The child spawns, owes the query no tips and holds none.
    function test_Fork_LeavesAOneWeiTipPoolParked() public {
        _burnFeeIn(GENESIS_UID);
        assertGt(genesisRep.rate(), 1 ether);
        uint256 openQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, openQueryId, 1);
        _forkGenesis();
        assertEq(_universe(GENESIS_UID).totalTips, 1);
        assertEq(_universe(GENESIS_UID).carriedTips, 0);

        uint248 child1 = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(_universe(child1).totalTips, 0);
        assertEq(multiverse.getTips(child1, openQueryId), 0);
        // Only the open query's fee pool was drawn for the child.
        assertEq(
            zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A), genesisRep.convertToAssets(DEFAULT_FEE)
        );

        // The query still resolves there: its resolver gets the fee and no tips.
        ILituusRep child1Rep = multiverse.repTokenOf(child1);
        _warpPastResolverFeeRamp();
        vm.prank(bystander);
        multiverse.resolve(child1, openQueryId);
        assertEq(child1Rep.balanceOf(bystander), DEFAULT_FEE);
    }

    /// @dev The same for the forking query's reporter. Tipped one wei and first reported in its creation block
    ///      (no fee share), the query holds the whole one-wei pool, which makes no child share at a rate above 1.
    ///      The fork rounds it away, so the spawn draws and pays nothing rather than reverting: a revert would
    ///      keep the child of that outcome from ever existing.
    function test_Spawn_LeavesAOneWeiForkingTipParked() public {
        _burnFeeIn(GENESIS_UID);
        assertGt(genesisRep.rate(), 1 ether);
        uint256 forkQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, forkQueryId, 1);
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);
        assertEq(_resolution(forkQueryId).tips, 1);
        assertEq(_universe(GENESIS_UID).carriedTips, 0);

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        uint248 childB = _spawn(GENESIS_UID, OUTCOME_B);
        assertEq(multiverse.repTokenOf(childA).balanceOf(user), 0);
        assertEq(multiverse.repTokenOf(childB).balanceOf(challenger), 0);
        // No other query was open, so nothing at all was drawn for either child.
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A), 0);
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_B), 0);
        assertEq(multiverse.getOutcome(childA, forkQueryId), OUTCOME_A);
        assertEq(multiverse.getOutcome(childB, forkQueryId), OUTCOME_B);
    }

    /// @dev Two wei make a share at any rate: a child's vault opens at the parent's rate, so two wei of the
    ///      parent's wREP are worth at least two wei of REP. At this rate they are two wei of REP, which make one
    ///      child share: the fork carries one share, and the forking query, holding the whole pool, takes it.
    ///      The spawn draws the two wei of REP that mint it.
    function test_Spawn_PaysATwoWeiForkingTip() public {
        _burnFeeIn(GENESIS_UID);
        assertGt(genesisRep.rate(), 1 ether);
        uint256 forkQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, forkQueryId, 2);
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);
        assertEq(_universe(GENESIS_UID).carriedTips, 1);

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A), 2);
        assertEq(multiverse.repTokenOf(childA).balanceOf(user), 1);
    }

    /// @dev At a rate of exactly 1 a single wei makes a child share. The fork carries it, as it carries any pool
    ///      a child's vault mints whole, and the spawn pays it: the forking query's tips are drawn with the
    ///      carried pool, which never skips an amount.
    function test_Spawn_PaysAOneWeiForkingTipAtARateOfOne() public {
        assertEq(genesisRep.rate(), 1 ether);
        uint256 forkQueryId = _createDefaultQuery();
        _tip(GENESIS_UID, tipper, forkQueryId, 1);
        _escalateToFork(GENESIS_UID, forkQueryId, user, challenger);
        assertEq(_universe(GENESIS_UID).carriedTips, 1);

        uint248 childA = _spawn(GENESIS_UID, OUTCOME_A);
        assertEq(multiverse.repTokenOf(childA).balanceOf(user), 1);
        assertEq(zoltar.splitPerChild(address(multiverse), GENESIS_UID, OUTCOME_A), 1);
        assertEq(multiverse.getOutcome(childA, forkQueryId), OUTCOME_A);
    }
}
