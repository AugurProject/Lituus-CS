// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Vm } from "forge-std/Vm.sol";

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @dev Expected payouts are asserted as hand-computed literals (with the derivation and the code
///      constants spelled out in a comment) instead of being re-derived from the contract's own
///      constants: if a constant or a formula in the code is wrong, a test recomputing with the
///      same inputs would be wrong in the same way and still pass.
contract MultiverseResolveTest is MultiverseFixtures {
    /*//////////////////////////////////////////////////////////////
                    RESOLVE - INVALID (NO-REPORT) PATH
    //////////////////////////////////////////////////////////////*/
    function test_Resolve_Invalid_HappyPath() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        // Resolve 36 hours past the reporting deadline: the resolver reward ramp is at its midpoint.
        vm.warp(START_TIME + 3 days + 36 hours);
        uint8 outcome = _resolve(user, queryId);

        // The INVALID marker is 255 in the contract.
        assertEq(outcome, 255);
        assertEq(outcome, multiverse.INVALID());

        // the payment should be half of the query fee (half of the time passed)
        // fee = 1 ether, elapsed past the deadline = 36 hours (129600 s), THREE_DAYS = 3 days (259200 s)
        // resolverPay = fee * elapsed / THREE_DAYS = 1e18 * 129600 / 259200 = 0.5e18
        // The other half of the fee is the query's profit, burned at resolve.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 0.5 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - 1 ether);
    }

    function test_Resolve_Invalid_EmitsEvents() public {
        uint256 queryId = _createDefaultQuery();

        vm.warp(START_TIME + 3 days + 36 hours);

        // resolverPay = 1e18 / 2 = 0.5e18 (see happy path); INVALID = 255.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ResolverRewardPaid(user, GENESIS_UID, queryId, 0.5 ether);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryResolved(user, GENESIS_UID, queryId, 255);

        vm.prank(user);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_Resolve_Invalid_ResolverRewardJustAfterDeadline() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        // One second past the deadline: the earliest resolvable moment, ramp share almost zero.
        vm.warp(START_TIME + 3 days + 1);
        _resolve(user, queryId);

        // resolverPay is small but nonzero
        uint256 userBalanceAfter = genesisRep.balanceOf(user);
        assertGt(userBalanceAfter, userBalanceBefore);
        assertLt(userBalanceAfter, userBalanceBefore + 0.0001 ether);
    }

    function test_Resolve_Invalid_ResolverRewardMidRamp() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.warp(START_TIME + 3 days + 36 hours);
        _resolve(user, queryId);

        // resolverPay = 1e18 / 2 = 0.5e18
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 0.5 ether);
    }

    function test_Resolve_Invalid_ResolverRewardFullAtRampEnd() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        // Exactly three days past the deadline: elapsed == THREE_DAYS hits the `>=` cap branch.
        vm.warp(START_TIME + 3 days + 3 days);
        _resolve(user, queryId);

        // resolverPay = full fee = 1 ether
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1 ether);
    }

    function test_Resolve_Invalid_ResolverRewardCappedForever() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        // Long after the ramp ended the reward stays the whole fee — there is no deadline.
        vm.warp(START_TIME + 3 days + 30 days);
        _resolve(user, queryId);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1 ether);
    }

    function test_Resolve_Invalid_ResolverPayScalesWithFee() public {
        // A non-1-ether fee on purpose: 1 ether equals the contract's SCALE constant (1e18), so a
        // formula that confused the query fee with SCALE would still pass every 1-ether test.
        feeCtl.setFee(4 ether);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);
        vm.warp(START_TIME + 3 days + 36 hours);
        _resolve(bystander, queryId);

        // resolverPay = fee * elapsed / THREE_DAYS = 4e18 * 129600 / 259200 = 2e18
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore + 2 ether);
    }

    function test_Resolve_Invalid_Permissionless() public {
        // Resolving the query as INVALID after expiration.
        // Resolving is permissionless: a bystander who never touched the query earns the reward.
        uint256 queryId = _createDefaultQuery();
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        vm.warp(START_TIME + 3 days + 36 hours);
        _resolve(bystander, queryId);

        // resolverPay = 1e18 / 2 = 0.5e18
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore + 0.5 ether);
    }

    function test_Resolve_Invalid_StoredTotalsStayZero() public {
        uint256 queryId = _createExpiredQuery();
        _resolve(user, queryId);

        // No stakes ever landed, so nothing is claimable: the escalation totals stay zero.
        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(totalDistributable, 0);
        assertEq(winnerStaked, 0);
    }

    function test_Resolve_Invalid_BalanceConservation() public {
        uint256 supplyBefore = genesisRep.totalSupply();
        uint256 queryId = _createDefaultQuery();

        vm.warp(START_TIME + 3 days + 36 hours);
        _resolve(bystander, queryId);

        // The contract held only the 1 ether of query fee; it pays the 0.5 ether of resolver share
        // and burns the 0.5 ether remainder as the query's profit, leaving nothing behind.
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
        assertEq(genesisRep.totalSupply(), supplyBefore - 0.5 ether);
    }

    function test_Resolve_Invalid_BlocksLaterReport() public {
        uint256 queryId = _createExpiredQuery();
        _resolve(user, queryId);

        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), 255);

        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    /*//////////////////////////////////////////////////////////////
                RESOLVE - ESCALATION PATH, SINGLE STAKE
    //////////////////////////////////////////////////////////////*/
    function test_Resolve_SingleStake_HappyPath() public {
        uint256 queryId = _createDefaultQuery();

        // Report 36 hours into the reporting window: the reporter reward ramp is at its midpoint.
        vm.warp(START_TIME + 36 hours);
        _report(user, queryId, OUTCOME_A);
        _warpPastAppealWindow(queryId);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        uint8 outcome = _resolve(bystander, queryId);
        assertEq(outcome, OUTCOME_A);

        // The sole stake is auto-settled at resolution (amount == 0 is the settled flag).
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[0].amount, 0);

        // reporterPay is half the query fee (half of the time passed)
        // reporterPay = fee * elapsed / THREE_DAYS = 1e18 * 129600 / 259200 = 0.5e18;
        // the reporter also gets the 1 ether stake back in the same transfer -> 1.5 ether total.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1.5 ether);
        // The resolver of a reported query earns nothing — the fee reward is the reporter's.
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore);
    }

    function test_Resolve_SingleStake_EmitsAllEvents() public {
        uint256 queryId = _createDefaultQuery();

        vm.warp(START_TIME + 36 hours);
        _report(user, queryId, OUTCOME_A);
        _warpPastAppealWindow(queryId);

        // reporterPay = 1e18 / 2 = 0.5e18; StakeClaimed carries only the stake refund
        // (1 ether), so the fee reward is not added to the claim payouts.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0.5 ether);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeClaimed(user, GENESIS_UID, queryId, 0, 1 ether);
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryResolved(bystander, GENESIS_UID, queryId, OUTCOME_A);

        vm.prank(bystander);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_Resolve_SingleStake_Invalid() public {
        // A staked INVALID resolves through the escalation branch, unlike the no-report INVALID path:
        // the stake is settled and refunded.
        uint256 queryId = _createDefaultQuery();
        vm.warp(START_TIME + 36 hours);
        _report(user, queryId, multiverse.INVALID());
        _warpPastAppealWindow(queryId);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        uint8 outcome = _resolve(bystander, queryId);

        assertEq(outcome, 255);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[0].amount, 0);
        // Reported after creation, so reporterPay = 0.5 ether; the reporter gets the stake back too.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1.5 ether);
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore);
    }

    function test_Resolve_SingleStake_StoredTotals() public {
        uint256 queryId = _createResolvableReportedQuery(OUTCOME_A);
        _resolve(user, queryId);

        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        // The single stake equals the query fee (1 ether); there are no losing stakes.
        assertEq(winnerStaked, 1 ether);
        assertEq(totalDistributable, 0);
    }

    function test_Resolve_ReporterPay_ZeroAtCreation() public {
        // Report in the creation block: zero elapsed time earns a zero fee share.
        uint256 queryId = _createResolvableReportedQuery(OUTCOME_A);
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0);

        _resolve(bystander, queryId);

        // Only the 1 ether stake refund.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1 ether);
    }

    function test_Resolve_ReporterPay_MidWindow() public {
        uint256 queryId = _createDefaultQuery();

        vm.warp(START_TIME + 36 hours);
        _report(user, queryId, OUTCOME_A);
        _warpPastAppealWindow(queryId);

        // reporterPay = fee * elapsed / THREE_DAYS = 1e18 / 2 = 0.5e18
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0.5 ether);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        _resolve(bystander, queryId);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1.5 ether);
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore);
    }

    function test_Resolve_ReporterPay_FullAtWindowEnd() public {
        uint256 queryId = _createDefaultQuery();

        // Exactly at the reporting deadline the query is still reportable (strict `<`), and
        // elapsed == THREE_DAYS hits the `>=` cap branch: the reward is the whole fee.
        vm.warp(START_TIME + 3 days);
        _report(user, queryId, OUTCOME_A);
        _warpPastAppealWindow(queryId);

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 1 ether);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        _resolve(bystander, queryId);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 2 ether);
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                RESOLVE - ESCALATION PATH, MULTI-STAKE
    //////////////////////////////////////////////////////////////*/
    function test_Resolve_Ladder_LastOutcomeWins() public {
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, OUTCOME_A); // stake 0: 1 ether at creation
        vm.warp(START_TIME + 18 hours);
        _report(bystander, queryId, OUTCOME_B); // stake 1: 2 ether, 18h after creation
        _warpPastAppealWindow(queryId);

        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        // The winning outcome's first stake landed 18 hours after creation: 1/4 of the ramp elapsed
        // reporterPay = fee * elapsed / THREE_DAYS = 1e18 / 4 = 1e18 * 64800 / 259200 = 0.25e18
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(bystander, GENESIS_UID, queryId, 0.25 ether);

        uint8 outcome = _resolve(challenger, queryId);
        assertEq(outcome, OUTCOME_B);

        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        // Only the 2 ether escalation stake is on the winning outcome.
        assertEq(winnerStaked, 2 ether);
        // Losers staked 1 ether, BURN_DIVIDER = 5 (20% burn): 1e18 - 1e18 / 5 = 0.8e18
        assertEq(totalDistributable, 0.8 ether);

        // Multi-stake: the fee reward leaves the contract and the whole profit is destroyed:
        // 0.2 ether of loser burn (1 ether of losing stakes / BURN_DIVIDER) plus the 0.75 ether
        // fee remainder. The stakes await claim().
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore + 0.25 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - 1.2 ether);

        uint256 bystanderBalanceBeforeClaim = genesisRep.balanceOf(bystander);
        uint256 multiverseBalanceBeforeClaim = genesisRep.balanceOf(address(multiverse));

        // Claim winning stake (index 1): 2 ether stake + 0.8 ether distributable losers share.
        vm.prank(bystander);
        multiverse.claim(GENESIS_UID, queryId, 1);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[1].amount, 0);
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBeforeClaim + 2.8 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBeforeClaim - 2.8 ether);
    }

    function test_Resolve_Ladder_FirstWinningReporterGetsFee() public {
        uint256 queryId = _createDefaultQuery();
        vm.warp(START_TIME + 18 hours); // 1/4 of the ramp elapsed
        _report(user, queryId, OUTCOME_A); // stake 0: 1 ether
        vm.warp(START_TIME + 30 hours);
        _report(bystander, queryId, OUTCOME_B); // stake 1: 2 ether
        vm.warp(START_TIME + 42 hours);
        _report(challenger, queryId, OUTCOME_A); // stake 2: 4 ether
        _warpPastAppealWindow(queryId);

        // The fee reward goes to the FIRST reporter of the winning outcome (user, not challenger),
        // ramped from user's stake time: reporterPay = 1e18 * 1/4 = 0.25e18
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0.25 ether);

        uint256 userBalanceBeforeResolve = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBeforeResolve = genesisRep.balanceOf(address(multiverse));

        uint8 outcome = _resolve(bystander, queryId);
        assertEq(outcome, OUTCOME_A);

        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        // Stakes on the winning outcome: 1 + 4 ether.
        assertEq(winnerStaked, 5 ether);
        // Losers staked 2 ether, BURN_DIVIDER = 5: 2e18 - 2e18 / 5 = 1.6e18
        assertEq(totalDistributable, 1.6 ether);

        // Multi-stake: the reporter reward leaves the contract and the whole profit is destroyed
        // at resolve: 0.4 ether of loser burn (2 ether of losing stakes / BURN_DIVIDER) plus the
        // 0.75 ether fee remainder.
        assertEq(genesisRep.balanceOf(user), userBalanceBeforeResolve + 0.25 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBeforeResolve - 1.4 ether);

        uint256 userBalanceBeforeClaim = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBeforeUserClaim = genesisRep.balanceOf(address(multiverse));

        // User claims winning stake index 0: 1 ether + (1/5 * 1.6 ether) = 1.32 ether.
        vm.prank(user);
        multiverse.claim(GENESIS_UID, queryId, 0);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[0].amount, 0);
        assertEq(genesisRep.balanceOf(user), userBalanceBeforeClaim + 1.32 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBeforeUserClaim - 1.32 ether);

        uint256 challengerBalanceBeforeClaim = genesisRep.balanceOf(challenger);
        uint256 multiverseBalanceBeforeChallengerClaim = genesisRep.balanceOf(address(multiverse));

        // Challenger claims winning stake index 2: 4 ether + (4/5 * 1.6 ether) = 5.28 ether.
        vm.prank(challenger);
        multiverse.claim(GENESIS_UID, queryId, 2);

        stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[2].amount, 0);
        assertEq(genesisRep.balanceOf(challenger), challengerBalanceBeforeClaim + 5.28 ether);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBeforeChallengerClaim - 5.28 ether);
    }

    function test_Resolve_Ladder_RewardGoesToEarliestOfManyWinningStakes() public {
        uint256 queryId = _createDefaultQuery();
        vm.warp(START_TIME + 18 hours); // 1/4 of the ramp elapsed
        _report(user, queryId, OUTCOME_A); // stake 0: 1 ether — the earliest winning stake
        vm.warp(START_TIME + 30 hours);
        _report(bystander, queryId, OUTCOME_B); // stake 1: 2 ether
        vm.warp(START_TIME + 42 hours);
        _report(challenger, queryId, OUTCOME_A); // stake 2: 4 ether — repeats the winning outcome
        vm.warp(START_TIME + 54 hours);
        _report(bystander, queryId, OUTCOME_B); // stake 3: 8 ether
        vm.warp(START_TIME + 66 hours);
        _report(user, queryId, OUTCOME_A); // stake 4: 16 ether — the winning last stake
        _warpPastAppealWindow(queryId);

        // Three stakes placed on the winning outcome (indices 0, 2, 4). The fee reward must go to the
        // earliest of them (user's stake 0, 18 hours in, 1/4 fee) and must not be overwritten by the later
        // repeats — neither challenger's stake 2 nor the ramp time of user's own stake 4 (+66h,
        // which would pay 11/12 of the fee instead):
        // reporterPay = fee * elapsed / THREE_DAYS = 1e18 * 1/4 = 0.25e18
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0.25 ether);

        uint8 outcome = _resolve(bystander, queryId);
        assertEq(outcome, OUTCOME_A);

        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        // Stakes on the winning outcome: 1 + 4 + 16 ether.
        assertEq(winnerStaked, 21 ether);
        // Losers staked 2 + 8 = 10 ether, BURN_DIVIDER = 5 (20% burn): 10e18 - 10e18 / 5 = 8e18
        assertEq(totalDistributable, 8 ether);
    }

    function test_Resolve_Ladder_PayoutsScaleWithFee() public {
        // A non-1-ether fee on purpose: 1 ether equals the contract's SCALE constant (1e18), so a
        // formula that confused the query fee with SCALE would still pass every 1-ether test.
        feeCtl.setFee(4 ether);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        _report(user, queryId, OUTCOME_A); // stake 0: 4 ether at creation
        vm.warp(START_TIME + 18 hours);
        _report(bystander, queryId, OUTCOME_B); // stake 1: 8 ether, 18h after creation
        _warpPastAppealWindow(queryId);

        // reporterPay = fee * elapsed / THREE_DAYS = 4e18 * 64800 / 259200 = 1e18
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(bystander, GENESIS_UID, queryId, 1 ether);

        uint8 outcome = _resolve(challenger, queryId);
        assertEq(outcome, OUTCOME_B);

        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        // Only the 8 ether escalation stake is on the winning outcome.
        assertEq(winnerStaked, 8 ether);
        // Losers staked 4 ether, BURN_DIVIDER = 5 (20% burn): 4e18 - 4e18 / 5 = 3.2e18
        assertEq(totalDistributable, 3.2 ether);
    }

    function test_Resolve_Ladder_ReporterPayCappedPastWindow() public {
        uint256 queryId = _createDefaultQuery();
        vm.warp(START_TIME + 3 days - 1 hours);
        _report(user, queryId, OUTCOME_A);
        // The escalation lands past the 3-day reporting window but within the appeal window.
        vm.warp(START_TIME + 3 days + 19 hours);
        _report(bystander, queryId, OUTCOME_B);
        _warpPastAppealWindow(queryId);

        // The winning stake landed 3 days + 19 hours after creation — past the ramp end, so the
        // reward is capped at the whole 1 ether fee instead of fee * elapsed / THREE_DAYS.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(bystander, GENESIS_UID, queryId, 1 ether);

        _resolve(user, queryId);
    }

    function test_Resolve_Ladder_InvalidWins() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(bystander, queryId, multiverse.INVALID());
        _warpPastAppealWindow(queryId);

        uint8 outcome = _resolve(user, queryId);
        assertEq(outcome, 255);

        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        // Only the 2 ether INVALID stake won; losers staked 1 ether: 1e18 - 1e18 / 5 = 0.8e18
        assertEq(winnerStaked, 2 ether);
        assertEq(totalDistributable, 0.8 ether);
    }

    function test_Resolve_Ladder_StakesNotSettled() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(bystander, queryId, OUTCOME_B);
        _warpPastAppealWindow(queryId);

        _resolve(user, queryId);

        // With more than one stake nothing is auto-settled: every amount is untouched until claim().
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[0].amount, 1 ether);
        assertEq(stakes[1].amount, 2 ether);
    }

    function test_Resolve_Ladder_EmitsEvents() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(bystander, queryId, OUTCOME_B);
        _warpPastAppealWindow(queryId);

        vm.recordLogs();
        vm.prank(challenger);
        multiverse.resolve(GENESIS_UID, queryId);

        // A multi-stake resolution emits the reward and resolution events but never StakeClaimed —
        // settlement is deferred to claim().
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawReporterRewardPaid;
        bool sawQueryResolved;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != Multiverse.StakeClaimed.selector);
            if (topic == Multiverse.ReporterRewardPaid.selector) sawReporterRewardPaid = true;
            if (topic == Multiverse.QueryResolved.selector) sawQueryResolved = true;
        }
        assertTrue(sawReporterRewardPaid);
        assertTrue(sawQueryResolved);
    }

    function test_Resolve_Ladder_BalanceConservation() public {
        uint256 supplyBefore = genesisRep.totalSupply();
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, OUTCOME_A);
        // The second stake lands 18 hours after the first, so the reporter reward is 1/4 of the query fee.
        vm.warp(START_TIME + 18 hours);
        _report(bystander, queryId, OUTCOME_B);
        _warpPastAppealWindow(queryId);

        // The contract holds the creation fee plus both stakes: 1 + 1 + 2 = 4 ether.
        assertEq(genesisRep.balanceOf(address(multiverse)), 4 ether);

        _resolve(challenger, queryId);

        // The 0.25 ether reporter reward left the contract (1e18 * 64800 / 259200) and the whole
        // profit was destroyed: 0.2 ether of loser burn (1 ether of losing stakes / BURN_DIVIDER)
        // plus the 0.75 ether fee remainder. Only the stakes stay held until claim().
        assertEq(genesisRep.balanceOf(address(multiverse)), 2.8 ether);
        assertEq(genesisRep.totalSupply(), supplyBefore - 0.95 ether);
    }

    function test_Resolve_NearThresholdLadder() public {
        // A ladder that stopped one step from the fork level (its last stake is exactly half the
        // fork threshold; the next report would be the fork trigger) is still an ordinary
        // escalation once the appeal window passes: the fork threshold was never met, so the
        // query resolves to the last outcome and winners settle through claim() as usual.
        (uint256 queryId, uint256 forkThreshold) = _createNearThresholdLadder();
        _warpPastAppealWindow(queryId);

        uint8 outcome = _resolve(challenger, queryId);
        assertEq(outcome, OUTCOME_A);

        // Hand-computed literals: fixture supply = 3000e18 (three actors x 1000e18), so the
        // threshold t = 3000e18 / 20 = 150e18 and the ladder is t/8 (user, A) = 18.75e18,
        // t/4 (challenger, B) = 37.5e18, t/2 (bystander, A) = 75e18. Losers = 37.5e18,
        // burn = 37.5e18 / 5 = 7.5e18, distributable = 30e18; winnerStaked = 93.75e18.
        assertEq(forkThreshold, 150 ether);
        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(winnerStaked, 93.75 ether);
        assertEq(totalDistributable, 30 ether);

        // Both winning stakes settle normally:
        // payout(stake 0) = 18.75e18 + 18.75e18 * 30e18 / 93.75e18 = 24.75e18
        // payout(stake 2) = 75e18 + 75e18 * 30e18 / 93.75e18 = 99e18
        assertEq(_claim(user, queryId, 0), 24.75 ether);
        assertEq(_claim(bystander, queryId, 2), 99 ether);
    }

    /*//////////////////////////////////////////////////////////////
                RESOLVE - TIMING BOUNDARIES & MISC
    //////////////////////////////////////////////////////////////*/
    function test_Resolve_AtEarliestMomentAfterReportingWindow() public {
        uint256 queryId = _createDefaultQuery();

        // Literal offset on purpose: THREE_DAYS in the contract must equal 3 days (259200 s).
        vm.warp(START_TIME + 3 days + 1);
        uint8 outcome = _resolve(user, queryId);
        assertEq(outcome, 255);
        assertEq(outcome, multiverse.INVALID());
    }

    function test_Resolve_AtEarliestMomentAfterAppealWindow() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A); // stake placed at START_TIME

        // Literal offset on purpose: ONE_DAY in the contract must equal 1 day (86400 s).
        vm.warp(START_TIME + 1 days + 1);
        uint8 outcome = _resolve(user, queryId);
        assertEq(outcome, OUTCOME_A);
    }

    function test_Resolve_AppealClockRollsFromLastStake() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A); // stake 0 at START_TIME
        vm.warp(START_TIME + 20 hours);
        _report(bystander, queryId, OUTCOME_B); // stake 1 at +20h

        // Past the first stake's appeal day but within the last stake's window: not resolvable.
        vm.warp(START_TIME + 1 days + 1);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);

        // Past the last stake's window it resolves to the last outcome.
        vm.warp(START_TIME + 20 hours + 1 days + 1);
        uint8 outcome = _resolve(user, queryId);
        assertEq(outcome, OUTCOME_B);
    }

    function test_Report_RevertWhen_AppealExpiredButReportingWindowStillOpen() public {
        uint256 queryId = _createDefaultQuery();

        // First report lands 12h from query creation.
        vm.warp(START_TIME + 12 hours);
        _report(user, queryId, OUTCOME_A);

        // Now we're past that report's 1-day appeal window, but still within the reporting window.
        vm.warp(START_TIME + 1 days + 12 hours + 1);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.AppealPeriodOver.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);

        // Resolution is already allowed and must keep the first reported outcome.
        uint8 outcome = _resolve(challenger, queryId);
        assertEq(outcome, OUTCOME_A);
    }

    function test_Resolve_IndependentQueries() public {
        uint256 queryId0 = _createDefaultQuery();
        uint256 queryId1 = _createDefaultQuery();
        _report(user, queryId0, OUTCOME_A);

        vm.warp(START_TIME + 1 days + 1);
        _resolve(bystander, queryId0);

        // The second query is untouched: unresolved and still reportable (its 3-day window is open).
        (, uint8 outcome1,,) = multiverse.queryResolutions(GENESIS_UID, queryId1);
        assertEq(outcome1, multiverse.UNRESOLVED());
        assertEq(multiverse.getOutcome(GENESIS_UID, queryId1), multiverse.UNRESOLVED());
        vm.expectEmit(true, true, true, false, address(multiverse));
        emit Multiverse.QueryReported(challenger, GENESIS_UID, queryId1, OUTCOME_B, 0);
        _report(challenger, queryId1, OUTCOME_B);
    }

    function test_Resolve_FeeSnapshotUsed() public {
        uint256 queryId = _createDefaultQuery();
        // A fee change after creation must not affect this query's payouts.
        feeCtl.setFee(7 ether);
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.warp(START_TIME + 6 days); // full resolver ramp
        _resolve(user, queryId);

        // The full-ramp resolver share equals the 1 ether fee stored on the query at creation,
        // not the controller's current 7 ether.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          RESOLVE - REVERTS
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_UniverseDoesNotExist() public {
        // Universe id 1 was never initialized (genesis lives at GENESIS_UID).
        uint256 queryId = _createExpiredQuery();
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.resolve(1, queryId);
    }

    function test_RevertWhen_QueryDoesNotExist() public {
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.resolve(GENESIS_UID, 999);
    }

    function test_RevertWhen_FreshQueryNotReady() public {
        // Unreported and still inside the reporting window: neither branch applies.
        uint256 queryId = _createDefaultQuery();
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_RevertWhen_ExactlyAtReportingDeadline() public {
        uint256 queryId = _createDefaultQuery();

        // The expiry check is strict `<`: exactly at the deadline the query is still reportable,
        // so it cannot be resolved INVALID yet.
        vm.warp(START_TIME + 3 days);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_RevertWhen_AppealWindowActive() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        vm.warp(START_TIME + 12 hours);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_RevertWhen_ExactlyAtAppealDeadline() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A); // stake placed at START_TIME

        // The appeal check is strict `<`: exactly ONE_DAY after the stake it is still appealable,
        // so it cannot be resolved yet.
        vm.warp(START_TIME + 1 days);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_RevertWhen_AlreadyResolved_InvalidByExpiration() public {
        uint256 queryId = _createExpiredQuery();
        _resolve(user, queryId);

        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    function test_RevertWhen_AlreadyResolved_Escalation() public {
        uint256 queryId = _createResolvableReportedQuery(OUTCOME_A);
        _resolve(user, queryId);

        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }
}
