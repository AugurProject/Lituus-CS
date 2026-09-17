// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

contract MultiverseReportTest is MultiverseFixtures {
    /*//////////////////////////////////////////////////////////////
                        REPORT - FIRST REPORT
    //////////////////////////////////////////////////////////////*/
    function test_Report_HappyPath() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        _report(user, queryId, OUTCOME_A);

        ResolutionView memory r = _resolution(queryId);
        assertEq(r.stakeCount, 1);
        assertEq(r.lastReportedOutcome, OUTCOME_A);
        assertEq(r.lastStakeTime, uint48(vm.getBlockTimestamp()));
        Multiverse.OutcomeStakes memory outcomeStakes = multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(outcomeStakes.firstReporter, user);
        assertEq(outcomeStakes.firstReportTime, uint48(vm.getBlockTimestamp()));
        // The first stake equals the query fee.
        assertEq(outcomeStakes.totalOutcomeStaked, DEFAULT_FEE);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore - DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore + DEFAULT_FEE);

        // Reporting alone does not resolve the query.
        assertEq(_resolution(queryId).outcome, multiverse.UNRESOLVED());
    }

    function test_Report_Invalid() public {
        uint256 queryId = _createDefaultQuery();

        _report(user, queryId, multiverse.INVALID());

        assertEq(_resolution(queryId).lastReportedOutcome, multiverse.INVALID());
    }

    function test_Report_MinOutcome() public {
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, 1);
    }

    function test_Report_MaxOutcome() public {
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    function test_Report_InCreationBlock() public {
        // Zero elapsed time: reporting in the same block the query was created in is allowed.
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, OUTCOME_A);
    }

    function test_Report_AtReportingDeadline() public {
        uint256 queryId = _createDefaultQuery();
        uint48 queryCreateTime = _resolution(queryId).queryCreateTime;

        // The window check is strict `<`, so exactly THREE_DAYS after creation is still reportable.
        vm.warp(queryCreateTime + multiverse.THREE_DAYS());
        _report(user, queryId, OUTCOME_A);
    }

    function test_Report_ByNonCreator() public {
        // Reporting is permissionless: the reporter does not have to be the query creator.
        uint256 queryId = _createDefaultQuery();
        _report(bystander, queryId, OUTCOME_A);
    }

    function test_Report_EmitsEvent() public {
        uint256 queryId = _createDefaultQuery();

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryReported(user, GENESIS_UID, queryId, OUTCOME_A, DEFAULT_FEE);

        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    function test_Report_EmitsEventForInvalid() public {
        // INVALID (255) is the special outcome encoding; pin its event shape explicitly.
        uint256 queryId = _createDefaultQuery();
        uint8 invalid = multiverse.INVALID();

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryReported(user, GENESIS_UID, queryId, invalid, DEFAULT_FEE);

        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, invalid);
    }

    function test_Report_FirstStakeIsFeeRoundedToStep() public {
        // The first stake is the query fee rounded to the nearest step of the cap grid (cap 32 ether:
        // steps 8, 4, 2, ...). A 5 ether fee sits between 4 and 8, below their geometric mean
        // (4 * sqrt(2) = 5.66), so it rounds down to 4.
        uint256 fee = 5 ether;
        uint256 firstStake = 4 ether;
        feeCtl.setFee(fee);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(requiredStake, firstStake);

        _report(user, queryId, OUTCOME_A);

        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), firstStake);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - firstStake);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore + firstStake);
    }

    function test_Report_FeeSnapshotAtCreation() public {
        uint256 queryId = _createDefaultQuery();
        // A fee change after creation must not affect this query: the first stake is the fee
        // stored on the query, not the controller's current fee.
        feeCtl.setFee(7 ether);

        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(requiredStake, DEFAULT_FEE);

        _report(user, queryId, OUTCOME_A);

        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), DEFAULT_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                        REPORT - ESCALATION
    //////////////////////////////////////////////////////////////*/
    function test_Report_Escalation_ChallengerStakesTwiceTheFirst() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        _report(bystander, queryId, OUTCOME_B);

        assertEq(_resolution(queryId).stakeCount, 2);
        // The first outcome's side is untouched by the escalation.
        Multiverse.OutcomeStakes memory sideA = multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(sideA.firstReporter, user);
        assertEq(sideA.totalOutcomeStaked, DEFAULT_FEE);
        // The second side is the escalation.
        Multiverse.OutcomeStakes memory sideB = multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B);
        assertEq(sideB.firstReporter, bystander);
        assertEq(_resolution(queryId).lastReportedOutcome, OUTCOME_B);
        assertEq(sideB.totalOutcomeStaked, 2 * DEFAULT_FEE);
    }

    function test_Report_Escalation_Chain() public {
        uint256 queryId = _createDefaultQuery();

        address[] memory reporters = new address[](5);
        uint8[] memory outcomes = new uint8[](5);
        for (uint256 i = 0; i < 5; i++) {
            reporters[i] = i % 2 == 0 ? user : bystander;
            outcomes[i] = i % 2 == 0 ? OUTCOME_A : OUTCOME_B;
        }
        _escalateChain(queryId, reporters, outcomes);

        assertEq(_resolution(queryId).stakeCount, 5);
        uint256 totalStaked = _resolution(queryId).totalStaked;
        // Contract holds the creation fee plus every stake.
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + totalStaked);
    }

    function test_Report_Escalation_AtAppealDeadline() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        // The appeal check is strict `<`, so exactly ONE_DAY after the last stake is still open.
        vm.warp(_resolution(queryId).lastStakeTime + multiverse.ONE_DAY());
        _report(bystander, queryId, OUTCOME_B);
    }

    function test_Report_Escalation_SameBlock() public {
        // An escalation in the same block as the previous report is allowed: only the outcome
        // must differ. The two stakes share a timestamp but differ in outcome and amount.
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(bystander, queryId, OUTCOME_B);

        ResolutionView memory r = _resolution(queryId);
        assertEq(r.stakeCount, 2);
        assertEq(r.lastReportedOutcome, OUTCOME_B);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A).firstReportTime, r.lastStakeTime);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A).totalOutcomeStaked, DEFAULT_FEE);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B).totalOutcomeStaked, 2 * DEFAULT_FEE);
    }

    function test_Report_Escalation_SameReporterAllowed() public {
        // Only the outcome must differ; an address may escalate against its own report.
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(user, queryId, OUTCOME_B);
    }

    function test_Report_Escalation_ToInvalid() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(bystander, queryId, multiverse.INVALID());
    }

    function test_Report_Escalation_FromInvalid() public {
        uint256 queryId = _createReportedQuery(multiverse.INVALID());
        _report(bystander, queryId, OUTCOME_A);
    }

    function test_Report_Escalation_ThroughInvalid() public {
        // INVALID is an ordinary ladder step: a valid outcome can escalate to INVALID and be
        // escalated away from it, with the stake rule uninterrupted (B lands at twice A + INVALID).
        uint256 queryId = _createDefaultQuery();

        address[] memory reporters = new address[](3);
        uint8[] memory outcomes = new uint8[](3);
        (reporters[0], reporters[1], reporters[2]) = (user, bystander, challenger);
        (outcomes[0], outcomes[1], outcomes[2]) = (OUTCOME_A, multiverse.INVALID(), OUTCOME_B);
        _escalateChain(queryId, reporters, outcomes);

        assertEq(_resolution(queryId).stakeCount, 3);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A).totalOutcomeStaked, DEFAULT_FEE);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, multiverse.INVALID()).totalOutcomeStaked, 2 * DEFAULT_FEE);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B).totalOutcomeStaked, 6 * DEFAULT_FEE);
    }

    function test_Report_Escalation_AfterReportingWindow() public {
        uint256 queryId = _createDefaultQuery();
        uint48 queryCreateTime = _resolution(queryId).queryCreateTime;

        // First report lands near the end of the 3-day reporting window
        uint256 firstReportTime = queryCreateTime + multiverse.THREE_DAYS() - 1 hours;
        vm.warp(firstReportTime);
        _report(user, queryId, OUTCOME_A);

        // The escalation lands after the reporting window has passed. Only the appeal
        // window governs escalations.
        uint256 escalationTime = firstReportTime + 20 hours;
        assertGt(escalationTime, queryCreateTime + multiverse.THREE_DAYS());
        vm.warp(escalationTime);
        _report(bystander, queryId, OUTCOME_B);
    }

    function test_Report_AppealWindowRollsFromLastStake() public {
        uint256 queryId = _createDefaultQuery();
        uint48 queryCreateTime = _resolution(queryId).queryCreateTime;

        // Place the first stake near the end of the reporting window so the query is already
        // older than three days by the time of the last stake.
        uint256 firstStakeTime = queryCreateTime + multiverse.THREE_DAYS() - 1 hours;
        vm.warp(firstStakeTime);
        _report(user, queryId, OUTCOME_A);

        uint256 secondStakeTime = firstStakeTime + 20 hours;
        vm.warp(secondStakeTime);
        _report(bystander, queryId, OUTCOME_B);

        // The appeal window is measured from the last stake only: a report exactly ONE_DAY after
        // the second stake succeeds even though the first stake is now almost two days old.
        uint256 lastStakeTime = secondStakeTime + multiverse.ONE_DAY();
        assertGt(lastStakeTime, queryCreateTime + multiverse.THREE_DAYS());
        vm.warp(lastStakeTime);
        _report(challenger, queryId, OUTCOME_A);
    }

    function test_Report_QueryCreateTimeUnchanged() public {
        uint256 queryId = _createDefaultQuery();
        uint48 createTimeBefore = _resolution(queryId).queryCreateTime;

        address[] memory reporters = new address[](3);
        uint8[] memory outcomes = new uint8[](3);
        (reporters[0], reporters[1], reporters[2]) = (user, bystander, user);
        (outcomes[0], outcomes[1], outcomes[2]) = (OUTCOME_A, OUTCOME_B, OUTCOME_A);
        _escalateChain(queryId, reporters, outcomes);

        // Reports never re-trigger the queryCreateTime initialization.
        uint48 createTimeAfter = _resolution(queryId).queryCreateTime;
        assertEq(createTimeAfter, createTimeBefore);
        assertEq(createTimeAfter, uint48(START_TIME));
    }

    function test_Report_IndependentQueries() public {
        uint256 queryId0 = _createDefaultQuery();
        uint256 queryId1 = _createDefaultQuery();

        _report(user, queryId0, OUTCOME_A);
        _report(bystander, queryId0, OUTCOME_B);

        // The untouched query still has an empty ladder and a first-report stake requirement.
        // The second query costs more than the first one because the first one already raised
        // the demand modifier, but its slightly higher fee still rounds to the same grid step.
        assertEq(_resolution(queryId1).stakeCount, 0);
        (,, uint256 fee1,) = multiverse.queries(queryId1);
        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId1, OUTCOME_A);
        assertGt(fee1, DEFAULT_FEE);
        assertEq(requiredStake, DEFAULT_FEE);
    }

    function test_Report_EscalationEmitsEvent() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryReported(bystander, GENESIS_UID, queryId, OUTCOME_B, 2 * DEFAULT_FEE);

        vm.prank(bystander);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT - MULTI-ACTOR SCENARIOS
    //////////////////////////////////////////////////////////////*/
    function test_Report_ThreeReportersEscalation() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);
        uint256 challengerBalanceBefore = genesisRep.balanceOf(challenger);

        address[] memory reporters = new address[](3);
        uint8[] memory outcomes = new uint8[](3);
        (reporters[0], reporters[1], reporters[2]) = (user, bystander, challenger);
        (outcomes[0], outcomes[1], outcomes[2]) = (OUTCOME_A, OUTCOME_B, OUTCOME_A);
        _escalateChain(queryId, reporters, outcomes);

        assertEq(_resolution(queryId).stakeCount, 3);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A).firstReporter, user);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B).firstReporter, bystander);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), DEFAULT_FEE);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, bystander, OUTCOME_B), 2 * DEFAULT_FEE);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, challenger, OUTCOME_A), 3 * DEFAULT_FEE);

        // Each actor paid exactly their own stake.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore - 2 * DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(challenger), challengerBalanceBefore - 3 * DEFAULT_FEE);
    }

    function test_Report_ReporterReturnsToLadder() public {
        uint256 queryId = _createDefaultQuery();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);

        // The same address may hold multiple consecutive and non-consecutive stakes on one query.
        address[] memory reporters = new address[](4);
        uint8[] memory outcomes = new uint8[](4);
        (reporters[0], reporters[1], reporters[2], reporters[3]) = (user, user, bystander, user);
        (outcomes[0], outcomes[1], outcomes[2], outcomes[3]) = (OUTCOME_A, OUTCOME_B, OUTCOME_A, OUTCOME_B);
        _escalateChain(queryId, reporters, outcomes);

        assertEq(_resolution(queryId).stakeCount, 4);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A).firstReporter, user);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B).firstReporter, user);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - 9 * DEFAULT_FEE); // 1x + 2x + 6x
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore - 3 * DEFAULT_FEE);
    }

    function test_Report_LongLadderMixedActors() public {
        uint256 queryId = _createDefaultQuery();

        // Five consecutive stakes rotating all actors, with varied gaps inside every appeal window.
        address[5] memory reporters = [user, bystander, challenger, user, bystander];
        uint8[5] memory outcomes = [OUTCOME_A, OUTCOME_B, OUTCOME_A, OUTCOME_B, OUTCOME_A];
        uint256[5] memory gaps = [uint256(2 hours), 23 hours, 6 hours, 20 hours, 12 hours];
        uint48[5] memory stakeTimes;
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(vm.getBlockTimestamp() + gaps[i]);
            stakeTimes[i] = uint48(vm.getBlockTimestamp());
            _report(reporters[i], queryId, outcomes[i]);
        }

        ResolutionView memory r = _resolution(queryId);
        assertEq(r.stakeCount, 5);
        assertEq(r.lastStakeTime, stakeTimes[4]);
        assertEq(r.lastReportedOutcome, outcomes[4]);
        uint256 totalStaked = r.totalStaked;

        // A holds 1 + 3 + 12 = 16 and B 2 + 6 = 8: the next stake on B must bring it to twice A.
        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_B);
        assertEq(requiredStake, 24 * DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + totalStaked);
    }

    function test_Report_TwoQueriesInterleavedLadders() public {
        uint256 queryId0 = _createDefaultQuery();
        uint256 queryId1 = _createDefaultQuery();

        // Interleaved escalations: each query's ladder and appeal clock advance independently.
        _report(user, queryId0, OUTCOME_A);
        _report(bystander, queryId1, OUTCOME_B);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _report(challenger, queryId0, OUTCOME_B);
        _report(user, queryId1, OUTCOME_A);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        _report(bystander, queryId0, OUTCOME_A);

        // Each query's ladder runs from its own first stake. The second query's fee is higher than
        // the base fee (the first one already raised the demand modifier) but rounds to the same
        // grid step, so both ladders start at DEFAULT_FEE.
        (,, uint256 fee1,) = multiverse.queries(queryId1);
        assertGt(fee1, DEFAULT_FEE);
        ResolutionView memory r0 = _resolution(queryId0);
        ResolutionView memory r1 = _resolution(queryId1);
        assertEq(r0.stakeCount, 3);
        assertEq(r1.stakeCount, 2);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId0, bystander, OUTCOME_A), 3 * DEFAULT_FEE);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId1, user, OUTCOME_A), 2 * DEFAULT_FEE);
        // The appeal clocks differ: query 0 was escalated 6 hours after query 1's last stake.
        assertGt(r0.lastStakeTime, r1.lastStakeTime);

        // Query 0: A holds 4, B holds 2, the next stake on B is 2 * 6 - 3 * 2 = 6. Query 1: B holds 1,
        // A holds 2, the next stake on B is 2 * 3 - 3 * 1 = 3.
        uint256 requiredStake0 = multiverse.getNextRequiredStake(GENESIS_UID, queryId0, OUTCOME_B);
        uint256 requiredStake1 = multiverse.getNextRequiredStake(GENESIS_UID, queryId1, OUTCOME_B);
        assertEq(requiredStake0, 6 * DEFAULT_FEE);
        assertEq(requiredStake1, 3 * DEFAULT_FEE);
    }

    function test_Report_LadderBalanceConservation() public {
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 bystanderBalanceBefore = genesisRep.balanceOf(bystander);
        uint256 challengerBalanceBefore = genesisRep.balanceOf(challenger);
        uint256 supplyBefore = genesisRep.totalSupply();

        uint256 queryId = _createDefaultQuery();
        address[] memory reporters = new address[](4);
        uint8[] memory outcomes = new uint8[](4);
        (reporters[0], reporters[1], reporters[2], reporters[3]) = (user, bystander, challenger, bystander);
        (outcomes[0], outcomes[1], outcomes[2], outcomes[3]) = (OUTCOME_A, OUTCOME_B, OUTCOME_A, OUTCOME_B);
        _escalateChain(queryId, reporters, outcomes);

        // Everything the actors paid (creation fee + stakes 1+2+3+6) is held by the multiverse;
        // reporting neither mints nor burns REP.
        uint256 actorsPaid = (userBalanceBefore - genesisRep.balanceOf(user))
            + (bystanderBalanceBefore - genesisRep.balanceOf(bystander))
            + (challengerBalanceBefore - genesisRep.balanceOf(challenger));
        assertEq(actorsPaid, 13 * DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(address(multiverse)), actorsPaid);
        assertEq(genesisRep.totalSupply(), supplyBefore);
    }

    /*//////////////////////////////////////////////////////////////
                          REPORT - REVERTS
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_UniverseDoesNotExist() public {
        // Universe id 1 was never initialized (genesis lives at GENESIS_UID).
        uint256 queryId = _createDefaultQuery();
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.report(1, queryId, OUTCOME_A);
    }

    function test_RevertWhen_QueryDoesNotExist() public {
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.report(GENESIS_UID, 999, OUTCOME_A);
    }

    function test_RevertWhen_OutcomeUnresolved() public {
        // Outcome 0 is the UNRESOLVED marker and can never be reported.
        uint256 queryId = _createDefaultQuery();
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.report(GENESIS_UID, queryId, 0);
    }

    function test_RevertWhen_OutcomeAboveRange() public {
        uint256 queryId = _createDefaultQuery();
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.report(GENESIS_UID, queryId, DEFAULT_NUMBER_OF_OUTCOMES + 1);
    }

    function test_RevertWhen_OutcomeBelowInvalidMarker() public {
        // 254 is above the query's outcome range but is not the INVALID marker (255).
        uint256 queryId = _createDefaultQuery();
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidOutcome.selector);
        multiverse.report(GENESIS_UID, queryId, 254);
    }

    function test_RevertWhen_ReportingWindowExpired() public {
        uint256 queryId = _createDefaultQuery();
        uint48 queryCreateTime = _resolution(queryId).queryCreateTime;

        // One second past the deadline is the earliest moment a first report must revert.
        vm.warp(queryCreateTime + multiverse.THREE_DAYS() + 1);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryExpired.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    function test_RevertWhen_SameOutcomeAsPrevious() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.CannotStakeOnOutcome.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    function test_RevertWhen_AppealPeriodOver() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        // One second past the appeal deadline is the earliest moment an escalation must revert.
        vm.warp(_resolution(queryId).lastStakeTime + multiverse.ONE_DAY() + 1);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.AppealPeriodOver.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);
    }

    function test_RevertWhen_QueryAlreadyResolved() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        vm.warp(_resolution(queryId).lastStakeTime + multiverse.ONE_DAY() + 1);
        multiverse.resolve(GENESIS_UID, queryId);

        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);
    }

    function test_RevertWhen_ResolvedInvalidByExpiry() public {
        // The other resolve path: no report ever landed and the reporting window expired.
        uint256 queryId = _createDefaultQuery();
        uint48 queryCreateTime = _resolution(queryId).queryCreateTime;

        vm.warp(queryCreateTime + multiverse.THREE_DAYS() + 1);
        multiverse.resolve(GENESIS_UID, queryId);

        vm.prank(user);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    function test_RevertWhen_InsufficientAllowance() public {
        uint256 queryId = _createDefaultQuery();
        address noAllowance = makeAddr("noAllowance");
        // Fund with REP but do NOT approve the multiverse to spend it.
        underlying.mint(noAllowance, USER_REP_BALANCE);
        vm.startPrank(noAllowance);
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, USER_REP_BALANCE, 0);
        vm.expectRevert();
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientBalance() public {
        uint256 queryId = _createDefaultQuery();
        address noBalance = makeAddr("noBalance");
        // Approve the multiverse but never acquire any REP.
        vm.startPrank(noBalance);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.expectRevert();
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REPORT - CAP BOUNDARY
    //////////////////////////////////////////////////////////////*/
    function test_Report_OneOutcomeAtCapIsOrdinary() public {
        // A ladder with one outcome sitting exactly at the per-outcome cap is still an ordinary
        // escalation: the cap counter reads one, the next stake on the other outcome is bounded by the
        // cap (it would need 2 * 48 - 3 * 16 = 48 to double the rest, but only 16 fits), and placing
        // it brings that outcome to the cap too.
        (uint256 queryId, uint256 cap) = _createLadderToCap();

        assertEq(_resolution(queryId).stakeCount, 6);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B).totalOutcomeStaked, cap);

        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(requiredStake, cap / 2);
    }

    function test_Report_TwoOutcomesAtCapReachTheForkLevel() public {
        // The full ladder: stakes 1, 2, 3, 6, 12, 24 bring B to the cap, and the closing stake of 16
        // brings A there too. Both sides then hold exactly 1% of the REP supply and the pot is the 2%
        // that the fork is sized against.
        (uint256 queryId, uint256 cap) = _createLadderToCap();
        assertEq(_resolution(queryId).noOfOutcomesAtCap, 1);

        _report(challenger, queryId, OUTCOME_A);

        ResolutionView memory r = _resolution(queryId);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A).totalOutcomeStaked, cap);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_B).totalOutcomeStaked, cap);
        assertEq(r.noOfOutcomesAtCap, 2);
        assertEq(r.stakeCount, 7);

        // The pot is exactly two per-outcome caps, i.e. 2% of the universe's REP supply.
        assertEq(r.totalStaked, 2 * cap);
        assertEq(r.totalStaked, 2 * zoltar.getUniverseTheoreticalSupply(GENESIS_UID) / 100);
    }

    function test_Report_LateOutcomePaysTwiceThePot() public {
        // An outcome joining a ladder late is priced like any other: it must reach twice the total of
        // everything staked so far. After A (1) and B (2) the pot is 3, so the first stake on C is 6,
        // and C leads with twice the rest.
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, OUTCOME_A);
        _report(challenger, queryId, OUTCOME_B);

        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_C);
        assertEq(requiredStake, 6 * DEFAULT_FEE);

        _report(bystander, queryId, OUTCOME_C);

        ResolutionView memory r = _resolution(queryId);
        assertEq(r.lastReportedOutcome, OUTCOME_C);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_C).totalOutcomeStaked, 6 * DEFAULT_FEE);
        assertEq(r.totalStaked, 9 * DEFAULT_FEE);
    }

    function test_Report_LateOutcomeBoundedByCap() public {
        // The same rule bounded by the cap: with A at 16 and B at the cap of 32, twice the pot would be
        // 96, so a late outcome pays the cap instead and lands there in one stake.
        (uint256 queryId, uint256 cap) = _createLadderToCap();

        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_C);
        assertEq(requiredStake, cap);

        _report(challenger, queryId, OUTCOME_C);

        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_C).totalOutcomeStaked, cap);
        assertEq(_resolution(queryId).noOfOutcomesAtCap, 2);
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT - CAP SNAPSHOT
    //////////////////////////////////////////////////////////////*/
    function test_Report_CapFrozenAtFirstReport() public {
        // The cap is read once, at the first report, and the whole ladder is measured against it. A burn
        // from any other query raises the vault rate, which lowers what 1% of the REP supply is worth in
        // shares: the live cap moves, the open ladder does not.
        uint256 queryId = _createDefaultQuery();
        _report(user, queryId, OUTCOME_A);

        uint256 frozenCap = _resolution(queryId).cap;
        uint256 liveCapBefore = _capWrep();
        assertEq(frozenCap, liveCapBefore);

        // A second query opens with a single stake, so resolving it pays no reporter ramp (the report
        // lands in the creation block) and burns its whole fee.
        uint256 otherQueryId = _createDefaultQuery();
        _report(bystander, otherQueryId, OUTCOME_A);

        // Keep the first ladder's appeal window open across the burn.
        vm.warp(START_TIME + 20 hours);
        _report(challenger, queryId, OUTCOME_B);
        uint256 requiredBefore = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);

        vm.warp(START_TIME + 1 days + 1);
        _resolve(user, otherQueryId);
        assertGt(genesisRep.rate(), 1 ether);

        assertLt(_capWrep(), liveCapBefore);
        assertEq(_resolution(queryId).cap, frozenCap);
        assertEq(multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A), requiredBefore);

        // And the stake the ladder actually takes is still the one the frozen cap implies.
        _report(user, queryId, OUTCOME_A);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), DEFAULT_FEE + requiredBefore);
    }

    function test_Report_CapReadAtFirstReportNotAtCreation() public {
        // The snapshot is taken when the ladder opens, not when the query is created: a burn in between
        // is reflected in the cap the query ends up with.
        uint256 queryId = _createDefaultQuery();
        uint256 capAtCreation = _capWrep();

        _createResolvedLadder();
        uint256 capAfterBurn = _capWrep();
        assertLt(capAfterBurn, capAtCreation);

        _report(user, queryId, OUTCOME_A);
        assertEq(_resolution(queryId).cap, capAfterBurn);
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT - FIRST STAKE ROUNDING
    //////////////////////////////////////////////////////////////*/
    function test_Report_FirstStakeRoundsDownBelowTheGeometricMean() public {
        // The first stake is the fee rounded to the nearest step of the cap grid, nearest in ratio rather
        // than in distance: the boundary between the 4 and 8 steps is their geometric mean, 4 * sqrt(2).
        // At the boundary itself the fee still rounds down, and the reporter is charged the 4 step.
        uint256 boundary = 5_656_854_249_492_380_195; // floor(4e18 * sqrt(2))

        feeCtl.setFee(boundary);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A), 4 ether);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        _report(user, queryId, OUTCOME_A);

        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), 4 ether);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - 4 ether);
    }

    function test_Report_FirstStakeRoundsUpAboveTheGeometricMean() public {
        // One wei past the boundary the same fee rounds up instead, and the reporter is charged the 8
        // step: the two tests together pin the boundary to a single wei.
        uint256 boundary = 5_656_854_249_492_380_195;

        feeCtl.setFee(boundary + 1);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A), 8 ether);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        _report(user, queryId, OUTCOME_A);

        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), 8 ether);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - 8 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          REPORT - GETTERS
    //////////////////////////////////////////////////////////////*/
    function test_GetNextRequiredStake_FirstReport() public {
        uint256 queryId = _createDefaultQuery();

        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(requiredStake, DEFAULT_FEE);
    }

    function test_GetNextRequiredStake_SecondStakeIsTwiceTheFirst() public {
        uint256 queryId = _createDefaultQuery();

        uint256 firstStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(firstStake, DEFAULT_FEE);

        _report(user, queryId, OUTCOME_A);

        uint256 secondStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_B);
        assertEq(secondStake, DEFAULT_FEE * 2);
    }

    function test_GetNextRequiredStake_EscalationSequence() public {
        // Alternating A/B from a fee on the grid: each stake brings its outcome to twice the rest, so the
        // required stakes run 1, 2, 3, 6 (A 1 -> B 2 -> A 4 -> B 8).
        uint256 queryId = _createDefaultQuery();
        uint256[4] memory expectedStakes = [uint256(1 ether), 2 ether, 3 ether, 6 ether];

        for (uint256 i = 0; i < 4; i++) {
            uint8 outcome = i % 2 == 0 ? OUTCOME_A : OUTCOME_B;
            uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, outcome);
            assertEq(requiredStake, expectedStakes[i]);
            _report(i % 2 == 0 ? user : bystander, queryId, outcome);
        }
    }

    function test_GetNextRequiredStake_FirstStakeBoundedByCapFraction() public {
        // A fee accepted by createQuery (below half the fork threshold) but above a quarter of the
        // per-outcome cap is bounded to that quarter before rounding: a large fee never opens a
        // ladder within two rounds of the cap. Cap 32 ether: the bound is 8 ether, already a step.
        uint256 cap = _capWrep();
        uint256 fee = _forkThresholdWrep() / 3;
        assertGt(fee, cap / multiverse.FIRST_STAKE_CAP_DIVISOR());
        feeCtl.setFee(fee);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        uint256 firstStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(firstStake, 8 ether);
        _report(user, queryId, OUTCOME_A);

        // The appeal brings the challenger to twice the first stake.
        uint256 requiredStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_B);
        assertEq(requiredStake, 16 ether);
    }

    function test_GetNextRequiredStake_RevertsInvalidUniverse() public {
        // A valid query, so the universe check is the one that fires.
        uint256 queryId = _createDefaultQuery();
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.getNextRequiredStake(1, queryId, OUTCOME_A);
    }

    function test_GetNextRequiredStake_RevertsNonexistentQuery() public {
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.getNextRequiredStake(GENESIS_UID, 999, OUTCOME_A);
    }

    function test_GetOutcomeStakes_EmptyForFreshQuery() public {
        // An existing query with no stakes yet reads as an empty side.
        uint256 queryId = _createDefaultQuery();
        Multiverse.OutcomeStakes memory side = multiverse.getOutcomeStakes(GENESIS_UID, queryId, OUTCOME_A);
        assertEq(side.totalOutcomeStaked, 0);
        assertEq(side.firstReporter, address(0));
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, OUTCOME_A), 0);
    }

    function test_GetOutcomeStakes_RevertsNonexistentQuery() public {
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.getOutcomeStakes(GENESIS_UID, 999, OUTCOME_A);
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.getUserStake(GENESIS_UID, 999, user, OUTCOME_A);
    }
}
