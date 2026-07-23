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
///      1e18 (user, A), 2e18 (challenger, B), 4e18 (bystander, A); outcome A wins, so:
///        winnerStaked      = 1e18 + 4e18 = 5e18
///        totalLoserStakes  = 2e18
///        loserBurn         = 2e18 / BURN_DIVIDER(5) = 0.4e18
///        totalDistributable = 2e18 - 0.4e18 = 1.6e18
///        payout(stake 0)   = 1e18 + 1e18 * 1.6e18 / 5e18 = 1.32e18
///        payout(stake 2)   = 4e18 + 4e18 * 1.6e18 / 5e18 = 5.28e18
///      The first report lands 18 hours after creation, so the fee reward push-paid to `user` at
///      resolution is exactly a quarter of the fee: fee * 18h / THREE_DAYS = 0.25e18.
contract MultiverseClaimTest is MultiverseFixtures {
    event Transfer(address indexed from, address indexed to, uint256 value);

    /*//////////////////////////////////////////////////////////////
                          CLAIM - HAPPY PATHS
    //////////////////////////////////////////////////////////////*/
    function test_Claim_WinnerGetsStakePlusShare() public {
        uint256 queryId = _createResolvedLadder();

        // Ladder totals frozen at resolution (derivation in the contract-level comment).
        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(totalDistributable, 1.6 ether);
        assertEq(winnerStaked, 5 ether);

        // stake 2 (bystander, 4e18 on the winning outcome): 4e18 + 4e18 * 1.6e18 / 5e18 = 5.28e18.
        uint256 payout = _claim(bystander, queryId, 2);
        assertEq(payout, 5.28 ether);
    }

    function test_Claim_EachWinnerGetsProRataShare() public {
        uint256 queryId = _createResolvedLadder();

        // Two winning stakes on outcome A: 1e18 (user) and 4e18 (bystander); each gets its stake
        // plus a share of the 1.6e18 distributable proportional to its stake.
        uint256 userPayout = _claim(user, queryId, 0);
        uint256 bystanderPayout = _claim(bystander, queryId, 2);

        assertEq(userPayout, 1.32 ether);
        assertEq(bystanderPayout, 5.28 ether);
        // Together the winners drain exactly winnerStaked + totalDistributable = 6.6e18.
        assertEq(userPayout + bystanderPayout, 6.6 ether);
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
        uint256 payout = _claim(user, queryId, 0);
        assertEq(payout, 1.32 ether);
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
        uint256 payout = _claim(challenger, queryId, 1);
        assertEq(payout, 2.8 ether);
    }

    function test_Claim_BalanceConservation() public {
        uint256 queryId = _createResolvedLadder();
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        _claim(user, queryId, 0);
        _claim(bystander, queryId, 2);

        // After every winner has claimed, the query's residual in the contract is exactly the
        // profit computed at resolution: loserBurn + (fee - reporterPay) = 0.4e18 + 0.75e18.
        // 6.6 ether was paid out to the winners (5 ether winnerStaked + 1.6 ether totalDistributable).
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - 6.6 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), 1.15 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM - REVERT PATHS
    //////////////////////////////////////////////////////////////*/
    function test_Claim_RevertWhen_QueryNotResolved() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        vm.expectRevert(Multiverse.QueryNotResolved.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId, 0);
    }

    function test_Claim_RevertWhen_NotStakeOwner() public {
        uint256 queryId = _createResolvedLadder();

        // stake 0 belongs to user; challenger cannot claim it.
        vm.expectRevert(Multiverse.NotStakeOwner.selector);
        vm.prank(challenger);
        multiverse.claim(GENESIS_UID, queryId, 0);
    }

    function test_Claim_RevertWhen_NotAWinningStake() public {
        uint256 queryId = _createResolvedLadder();

        // stake 1 is challenger's own, but it backed the losing outcome B.
        vm.expectRevert(Multiverse.NotAWinningStake.selector);
        vm.prank(challenger);
        multiverse.claim(GENESIS_UID, queryId, 1);
    }

    function test_Claim_RevertWhen_AlreadyClaimed() public {
        uint256 queryId = _createResolvedLadder();
        _claim(user, queryId, 0);

        vm.expectRevert(Multiverse.StakeAlreadyClaimed.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId, 0);
    }

    function test_Claim_RevertWhen_SingleStakeAutoSettledInResolve() public {
        // A single-stake query is settled inside resolve() (bond refund + fee reward in one
        // transfer); the zeroed amount must block a second payout through claim().
        uint256 queryId = _createResolvableReportedQuery(OUTCOME_A);
        _resolve(bystander, queryId);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[0].amount, 0);

        vm.expectRevert(Multiverse.StakeAlreadyClaimed.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId, 0);
    }

    function test_Claim_RevertWhen_StakeIndexOutOfBounds() public {
        uint256 queryId = _createResolvedLadder();

        // One past the last stake: index out of bounds
        vm.expectRevert(Multiverse.InvalidStakeIndex.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId, 3);
    }

    function test_Claim_RevertWhen_NoStakesExist() public {
        // A query resolved INVALID by expiry has an empty stakes array: any index is out of bounds.
        uint256 queryId = _createExpiredQuery();
        _resolve(bystander, queryId);

        vm.expectRevert(Multiverse.InvalidStakeIndex.selector);
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM MULTIPLE
    //////////////////////////////////////////////////////////////*/
    function test_ClaimMultiple_TwoQueriesSingleTransfer() public {
        uint256 queryId1 = _createResolvedLadder();
        uint256 queryId2 = _createResolvedLadder();

        // bystander holds the winning stake 2 on both ladders. The first query is the canonical
        // ladder, so its payout is the pinned 5.28e18 literal; only the second query's fee is
        // dynamic (the first query moved the demand curve), so its expectation must come from
        // the frozen totals rather than a literal.
        uint256 payout1 = 5.28 ether;
        uint256 payout2 = _expectedPayout(queryId2, 2);
        uint256 expectedTotal = payout1 + payout2;

        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId1;
        queryIds[1] = queryId2;
        uint256[] memory stakeIndices = new uint256[](2);
        stakeIndices[0] = 2;
        stakeIndices[1] = 2;

        // One StakeClaimed event per entry, then a single aggregate transfer.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeClaimed(bystander, GENESIS_UID, queryId1, 2, payout1);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeClaimed(bystander, GENESIS_UID, queryId2, 2, payout2);
        vm.expectEmit(true, true, false, true, address(genesisRep));
        emit Transfer(address(multiverse), bystander, expectedTotal);
        vm.prank(bystander);
        multiverse.claimMultiple(GENESIS_UID, queryIds, stakeIndices);

        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore + expectedTotal);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - expectedTotal);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId1)[2].amount, 0);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId2)[2].amount, 0);
    }

    function test_ClaimMultiple_MatchesIndividualClaims() public {
        // A single-entry batch must pay exactly what an individual claim() pays: 1.32e18 for
        // stake 0 — the same literal the individual-claim tests pin.
        uint256 queryId = _createResolvedLadder();

        uint256[] memory queryIds = new uint256[](1);
        queryIds[0] = queryId;
        uint256[] memory stakeIndices = new uint256[](1);
        stakeIndices[0] = 0;

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, queryIds, stakeIndices);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1.32 ether);
    }

    function test_ClaimMultiple_RevertWhen_EmptyBatch() public {
        vm.expectRevert(Multiverse.InvalidClaimBatch.selector);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, new uint256[](0), new uint256[](0));
    }

    function test_ClaimMultiple_RevertWhen_LengthMismatch() public {
        uint256 queryId = _createResolvedLadder();

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId;
        queryIds[1] = queryId;
        uint256[] memory stakeIndices = new uint256[](1);
        stakeIndices[0] = 0;

        vm.expectRevert(Multiverse.InvalidClaimBatch.selector);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, queryIds, stakeIndices);
    }

    function test_ClaimMultiple_RevertWhen_DuplicateEntry() public {
        // A repeated (queryId, stakeIndex) pair: the first occurrence zeroes the amount, so the
        // second reverts StakeAlreadyClaimed and the whole batch (including the first entry's
        // payout) is rolled back.
        uint256 queryId = _createResolvedLadder();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId;
        queryIds[1] = queryId;
        uint256[] memory stakeIndices = new uint256[](2);
        stakeIndices[0] = 0;
        stakeIndices[1] = 0;

        vm.expectRevert(Multiverse.StakeAlreadyClaimed.selector);
        vm.prank(user);
        multiverse.claimMultiple(GENESIS_UID, queryIds, stakeIndices);

        // Atomicity: nothing was paid and the stake is still claimable.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[0].amount, 1 ether);
    }

    function test_ClaimMultiple_RevertWhen_BatchContainsForeignStake() public {
        // One bad entry poisons the batch: bystander's winning stake 2 plus challenger's stake 1.
        uint256 queryId = _createResolvedLadder();
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        uint256[] memory queryIds = new uint256[](2);
        queryIds[0] = queryId;
        queryIds[1] = queryId;
        uint256[] memory stakeIndices = new uint256[](2);
        stakeIndices[0] = 2;
        stakeIndices[1] = 1;

        vm.expectRevert(Multiverse.NotStakeOwner.selector);
        vm.prank(bystander);
        multiverse.claimMultiple(GENESIS_UID, queryIds, stakeIndices);

        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[2].amount, 4 ether);
    }
}
