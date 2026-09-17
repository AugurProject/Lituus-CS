// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @dev Expected payouts are asserted as hand-computed literals (with the derivation and the code
///      constants spelled out in a comment) instead of being re-derived from the contract's own
///      constants: if a constant or a formula in the code is wrong, a test recomputing with the
///      same inputs would be wrong in the same way and still pass.
///
///      The canonical resolved ladder (see _createResolvedLadder) prices at fee = 1e18 with stakes
///      1e18 (user, A), 2e18 (challenger, B), 3e18 (bystander, A); outcome A wins, so:
///        winnerStaked      = 1e18 + 3e18 = 4e18
///        totalLoserStakes  = 2e18
///        loserBurn         = 2e18 / BURN_DIVIDER(5) = 0.4e18
///        totalDistributable = 2e18 - 0.4e18 = 1.6e18
///        payout(user)      = 1e18 + 1e18 * 1.6e18 / 4e18 = 1.4e18
///        payout(bystander) = 3e18 + 3e18 * 1.6e18 / 4e18 = 4.2e18
///      The first report lands 18 hours after creation, so the fee reward push-paid to `user` at
///      resolution is exactly a quarter of the fee: fee * 18h / THREE_DAYS = 0.25e18.
contract MultiverseClaimTest is MultiverseFixtures {
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev The settlement totals of a resolved query as claim() derives them: the winning outcome's
    ///      stake total and the losing stakes minus the burn cut.
    function _settlementTotals(uint256 queryId)
        internal
        view
        returns (uint256 totalDistributable, uint256 winnerStaked)
    {
        ResolutionView memory r = _resolution(queryId);
        winnerStaked = multiverse.getOutcomeStakes(GENESIS_UID, queryId, r.outcome).totalOutcomeStaked;
        uint256 totalLoserStakes = uint256(r.totalStaked) - winnerStaked;
        totalDistributable = totalLoserStakes - totalLoserStakes / multiverse.BURN_DIVIDER();
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM - HAPPY PATHS
    //////////////////////////////////////////////////////////////*/
    function test_Claim_WinnerGetsStakePlusShare() public {
        uint256 queryId = _createResolvedLadder();

        // Ladder totals frozen at resolution (derivation in the contract-level comment).
        (uint256 totalDistributable, uint256 winnerStaked) = _settlementTotals(queryId);
        assertEq(totalDistributable, 1.6 ether);
        assertEq(winnerStaked, 4 ether);

        // bystander (3e18 on the winning outcome): 3e18 + 3e18 * 1.6e18 / 4e18 = 4.2e18.
        uint256 payout = _claim(bystander, queryId);
        assertEq(payout, 4.2 ether);
    }

    function test_Claim_EachWinnerGetsProRataShare() public {
        uint256 queryId = _createResolvedLadder();

        // Two winning stakes on outcome A: 1e18 (user) and 3e18 (bystander); each gets its stake
        // plus a share of the 1.6e18 distributable proportional to its stake.
        uint256 userPayout = _claim(user, queryId);
        uint256 bystanderPayout = _claim(bystander, queryId);

        assertEq(userPayout, 1.4 ether);
        assertEq(bystanderPayout, 4.2 ether);
        // Together the winners drain exactly winnerStaked + totalDistributable = 5.6e18.
        assertEq(userPayout + bystanderPayout, 5.6 ether);
    }

    function test_Claim_FirstWinningReporterStillClaimsBond() public {
        // The reporter reward is push-paid to the first winning reporter during resolve(); their BOND
        // (stake + share) is not — it must come through claim(), and must not include the reporter payout.
        // The canonical ladder, unresolved, so the reward can be observed at resolution.
        uint256 queryId = _createReportedLadder();

        // Resolve pays `user` (first reporter of the winning outcome A) the ramped fee share only:
        // fee * 18h / THREE_DAYS = 1e18 / 4 = 0.25e18.
        uint256 userBalanceBeforeResolve = genesisRep.balanceOf(user);
        _resolve(bystander, queryId);
        assertEq(genesisRep.balanceOf(user), userBalanceBeforeResolve + 0.25 ether);

        // The bond payout arrives only via claim, and matches the stake formula exactly.
        uint256 payout = _claim(user, queryId);
        assertEq(payout, 1.4 ether);
    }

    function test_Claim_InvalidOutcomeStakeIsClaimable() public {
        // INVALID (255) is a stakeable outcome like any other: when it wins the escalation, its
        // stakes settle through claim() with the same formula.
        uint256 queryId = _createDefaultQuery();

        address[] memory reporters = new address[](2);
        reporters[0] = user;
        reporters[1] = challenger;
        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = OUTCOME_A;
        outcomes[1] = multiverse.INVALID();
        _escalateChain(queryId, reporters, outcomes);
        _warpPastAppealWindow(queryId);
        assertEq(_resolve(user, queryId), multiverse.INVALID());

        // stakes: 1e18 (user, A, loses), 2e18 (challenger, INVALID, wins);
        // burn = 1e18 / 5 = 0.2e18, distributable = 0.8e18,
        // payout = 2e18 + 2e18 * 0.8e18 / 2e18 = 2.8e18.
        uint256 payout = _claim(challenger, queryId);
        assertEq(payout, 2.8 ether);
    }

    function test_Claim_BalanceConservation() public {
        uint256 queryId = _createResolvedLadder();
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        _claim(user, queryId);
        _claim(bystander, queryId);

        // The whole profit (0.4e18 loser burn + 0.75e18 fee remainder) was destroyed at resolve,
        // so after every winner has claimed the query leaves nothing behind: the contract paid
        // 5.6 ether to the winners (4 ether winnerStaked + 1.6 ether totalDistributable) and holds
        // zero residual.
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - 5.6 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM - REVERT PATHS
    //////////////////////////////////////////////////////////////*/
    function test_Claim_RevertWhen_QueryNotResolved() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        vm.expectRevert(Multiverse.QueryNotResolved.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId);
    }

    function test_Claim_RevertWhen_NoStakeOnWinningOutcome() public {
        uint256 queryId = _createResolvedLadder();

        // challenger staked only on the losing outcome B: nothing to claim on A.
        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(challenger);
        multiverse.claim(GENESIS_UID, queryId);
    }

    function test_Claim_RevertWhen_NeverStaked() public {
        uint256 queryId = _createResolvedLadder();

        // An address that never reported on the query has nothing to claim.
        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(makeAddr("stranger"));
        multiverse.claim(GENESIS_UID, queryId);
    }

    function test_Claim_RevertWhen_AlreadyClaimed() public {
        uint256 queryId = _createResolvedLadder();
        _claim(user, queryId);

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId);
    }

    function test_Claim_RevertWhen_SingleStakeAutoSettledInResolve() public {
        // A single-stake query is settled inside resolve() (bond refund + fee reward in one
        // transfer); the zeroed amount must block a second payout through claim().
        uint256 queryId = _createResolvableReportedQuery(OUTCOME_A);
        _resolve(bystander, queryId);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), 0);

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId);
    }

    function test_Claim_RevertWhen_NoStakesExist() public {
        // A query resolved INVALID by expiry has no stakes at all: nobody has anything to claim.
        uint256 queryId = _createExpiredQuery();
        _resolve(bystander, queryId);

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MULTIPLE
    //////////////////////////////////////////////////////////////*/
    function test_ClaimMultiple_TwoQueriesSingleTransfer() public {
        uint256 queryId1 = _createResolvedLadder();
        uint256 queryId2 = _createResolvedLadder();

        // bystander holds the winning stake on both ladders. The first query is the canonical
        // ladder, so its payout is the pinned 4.2e18 literal; only the second query's fee is
        // dynamic (the first query moved the demand curve), so its expectation must come from
        // the per-outcome totals rather than a literal.
        uint256 payout1 = 4.2 ether;
        uint256 payout2 = _expectedPayout(queryId2, bystander);
        uint256 expectedTotal = payout1 + payout2;

        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId1;
        queryIds[1] = queryId2;

        // One StakeClaimed event per entry, then a single aggregate transfer.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeClaimed(bystander, GENESIS_UID, queryId1, payout1);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeClaimed(bystander, GENESIS_UID, queryId2, payout2);
        vm.expectEmit(true, true, false, true, address(genesisRep));
        emit Transfer(address(multiverse), bystander, expectedTotal);
        vm.prank(bystander);
        multiverse.claimMultiple(GENESIS_UID, queryIds);

        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore + expectedTotal);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - expectedTotal);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId1, bystander, OUTCOME_A), 0);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId2, bystander, OUTCOME_A), 0);
    }

    function test_ClaimMultiple_MatchesIndividualClaims() public {
        // A single-entry batch must pay exactly what an individual claim() pays: 1.4e18 for
        // user's stake — the same literal the individual-claim tests pin.
        uint256 queryId = _createResolvedLadder();

        uint256[] memory queryIds = new uint256[](1);
        queryIds[0] = queryId;

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, queryIds);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1.4 ether);
    }

    function test_ClaimMultiple_RevertWhen_EmptyBatch() public {
        vm.expectRevert(Multiverse.InvalidClaimBatch.selector);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, new uint256[](0));
    }

    function test_ClaimMultiple_RevertWhen_DuplicateEntry() public {
        // A repeated queryId: the first occurrence zeroes the stake, so the second reverts
        // NothingToClaim and the whole batch (including the first entry's payout) is rolled back.
        uint256 queryId = _createResolvedLadder();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId;
        queryIds[1] = queryId;

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, queryIds);

        // Atomicity: nothing was paid and the stake is still claimable.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), 1 ether);
    }

    function test_ClaimMultiple_RevertWhen_BatchContainsForeignStake() public {
        // One bad entry poisons the batch: bystander wins the first ladder but holds nothing on the
        // second query's winning outcome.
        uint256 queryId = _createResolvedLadder();
        uint256 lostQueryId = _createReportedQuery(OUTCOME_A);
        _report(challenger, lostQueryId, OUTCOME_B);
        _warpPastAppealWindow(lostQueryId);
        _resolve(user, lostQueryId);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId;
        queryIds[1] = lostQueryId;

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(bystander);
        multiverse.claimMultiple(GENESIS_UID, queryIds);

        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, bystander, OUTCOME_A), 3 ether);
    }
}
