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

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].reporter, user);
        assertEq(stakes[0].time, uint48(vm.getBlockTimestamp()));
        assertEq(stakes[0].reportedOutcome, OUTCOME_A);
        // The first stake equals the query fee.
        assertEq(stakes[0].amount, DEFAULT_FEE);

        assertEq(genesisRep.balanceOf(user), userBalanceBefore - DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore + DEFAULT_FEE);

        // Reporting alone does not resolve the query.
        (, uint8 outcome,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(outcome, multiverse.UNRESOLVED());
    }

    function test_Report_Invalid() public {
        uint256 queryId = _createDefaultQuery();

        _report(user, queryId, multiverse.INVALID());

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes[0].reportedOutcome, multiverse.INVALID());
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
        (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);

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

    function test_Report_FirstStakeEqualsFee() public {
        uint256 fee = 5 ether;
        feeCtl.setFee(fee);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, fee);

        _report(user, queryId, OUTCOME_A);

        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[0].amount, fee);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - fee);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore + fee);
    }

    function test_Report_FeeSnapshotAtCreation() public {
        uint256 queryId = _createDefaultQuery();
        // A fee change after creation must not affect this query: the first stake is the fee
        // stored on the query, not the controller's current fee.
        feeCtl.setFee(7 ether);

        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, DEFAULT_FEE);

        _report(user, queryId, OUTCOME_A);

        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[0].amount, DEFAULT_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                        REPORT - ESCALATION
    //////////////////////////////////////////////////////////////*/
    function test_Report_Escalation_DoublesStake() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);

        _report(bystander, queryId, OUTCOME_B);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 2);
        // The first record is untouched by the escalation.
        assertEq(stakes[0].reporter, user);
        assertEq(stakes[0].reportedOutcome, OUTCOME_A);
        assertEq(stakes[0].amount, DEFAULT_FEE);
        // The second record is the escalation.
        assertEq(stakes[1].reporter, bystander);
        assertEq(stakes[1].reportedOutcome, OUTCOME_B);
        assertEq(stakes[1].amount, 2 * DEFAULT_FEE);
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

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 5);
        uint256 totalStaked;
        for (uint256 i = 0; i < 5; i++) {
            assertEq(stakes[i].amount, DEFAULT_FEE << i);
            totalStaked += stakes[i].amount;
        }
        // Contract holds the creation fee plus every stake.
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + totalStaked);
    }

    function test_Report_Escalation_AtAppealDeadline() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);

        // The appeal check is strict `<`, so exactly ONE_DAY after the last stake is still open.
        vm.warp(stakes[0].time + multiverse.ONE_DAY());
        _report(bystander, queryId, OUTCOME_B);
    }

    function test_Report_Escalation_SameBlock() public {
        // An escalation in the same block as the previous report is allowed: only the outcome
        // must differ. The two stakes share a timestamp but differ in outcome and amount.
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        _report(bystander, queryId, OUTCOME_B);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 2);
        assertEq(stakes[0].time, stakes[1].time);
        assertEq(stakes[0].reportedOutcome, OUTCOME_A);
        assertEq(stakes[1].reportedOutcome, OUTCOME_B);
        assertEq(stakes[0].amount, DEFAULT_FEE);
        assertEq(stakes[1].amount, 2 * DEFAULT_FEE);
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
        // escalated away from it, with the doubling uninterrupted.
        uint256 queryId = _createDefaultQuery();

        address[] memory reporters = new address[](3);
        uint8[] memory outcomes = new uint8[](3);
        (reporters[0], reporters[1], reporters[2]) = (user, bystander, challenger);
        (outcomes[0], outcomes[1], outcomes[2]) = (OUTCOME_A, multiverse.INVALID(), OUTCOME_B);
        _escalateChain(queryId, reporters, outcomes);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 3);
        assertEq(stakes[1].reportedOutcome, multiverse.INVALID());
        assertEq(stakes[0].amount, DEFAULT_FEE);
        assertEq(stakes[1].amount, 2 * DEFAULT_FEE);
        assertEq(stakes[2].amount, 4 * DEFAULT_FEE);
    }

    function test_Report_Escalation_AfterReportingWindow() public {
        uint256 queryId = _createDefaultQuery();
        (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);

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
        (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);

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
        (uint48 createTimeBefore,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);

        address[] memory reporters = new address[](3);
        uint8[] memory outcomes = new uint8[](3);
        (reporters[0], reporters[1], reporters[2]) = (user, bystander, user);
        (outcomes[0], outcomes[1], outcomes[2]) = (OUTCOME_A, OUTCOME_B, OUTCOME_A);
        _escalateChain(queryId, reporters, outcomes);

        // Reports never re-trigger the queryCreateTime initialization.
        (uint48 createTimeAfter,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
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
        // the demand modifier.
        assertEq(multiverse.getStakes(GENESIS_UID, queryId1).length, 0);
        (,, uint256 fee1,) = multiverse.queries(queryId1);
        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId1);
        assertEq(requiredStake, fee1);
        assertGt(fee1, DEFAULT_FEE);
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

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 3);
        assertEq(stakes[0].reporter, reporters[0]);
        assertEq(stakes[1].reporter, reporters[1]);
        assertEq(stakes[2].reporter, reporters[2]);
        assertEq(stakes[0].reportedOutcome, outcomes[0]);
        assertEq(stakes[1].reportedOutcome, outcomes[1]);
        assertEq(stakes[2].reportedOutcome, outcomes[2]);
        assertEq(stakes[0].amount, DEFAULT_FEE);
        assertEq(stakes[1].amount, 2 * DEFAULT_FEE);
        assertEq(stakes[2].amount, 4 * DEFAULT_FEE);

        // Each actor paid exactly their own stake.
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore - 2 * DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(challenger), challengerBalanceBefore - 4 * DEFAULT_FEE);
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

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 4);
        assertEq(stakes[0].reporter, user);
        assertEq(stakes[1].reporter, user);
        assertEq(stakes[3].reporter, user);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - 11 * DEFAULT_FEE); // 1x + 2x + 8x
        assertEq(genesisRep.balanceOf(bystander), bystanderBalanceBefore - 4 * DEFAULT_FEE);
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

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 5);
        uint256 totalStaked;
        for (uint256 i = 0; i < 5; i++) {
            assertEq(stakes[i].reporter, reporters[i]);
            assertEq(stakes[i].time, stakeTimes[i]);
            assertEq(stakes[i].reportedOutcome, outcomes[i]);
            assertEq(stakes[i].amount, DEFAULT_FEE << i);
            totalStaked += stakes[i].amount;
        }

        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, 32 * DEFAULT_FEE);
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

        // Each query's ladder doubles from its own stored fee (the second query's fee is higher
        // than the base fee because the first one already raised the demand modifier).
        (,, uint256 fee0,) = multiverse.queries(queryId0);
        (,, uint256 fee1,) = multiverse.queries(queryId1);
        Multiverse.Stake[] memory stakes0 = multiverse.getStakes(GENESIS_UID, queryId0);
        Multiverse.Stake[] memory stakes1 = multiverse.getStakes(GENESIS_UID, queryId1);
        assertEq(stakes0.length, 3);
        assertEq(stakes1.length, 2);
        assertEq(stakes0[2].amount, 4 * fee0);
        assertEq(stakes1[1].amount, 2 * fee1);
        // The appeal clocks differ: query 0 was escalated 6 hours after query 1's last stake.
        assertGt(stakes0[2].time, stakes1[1].time);

        (uint256 requiredStake0,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId0);
        (uint256 requiredStake1,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId1);
        assertEq(requiredStake0, 8 * fee0);
        assertEq(requiredStake1, 4 * fee1);
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

        // Everything the actors paid (creation fee + stakes 1+2+4+8) is held by the multiverse;
        // reporting neither mints nor burns REP.
        uint256 actorsPaid = (userBalanceBefore - genesisRep.balanceOf(user))
            + (bystanderBalanceBefore - genesisRep.balanceOf(bystander))
            + (challengerBalanceBefore - genesisRep.balanceOf(challenger));
        assertEq(actorsPaid, 16 * DEFAULT_FEE);
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
        (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);

        // One second past the deadline is the earliest moment a first report must revert.
        vm.warp(queryCreateTime + multiverse.THREE_DAYS() + 1);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryExpired.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    function test_RevertWhen_SameOutcomeAsPrevious() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.OutcomeSameAsPrevious.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_A);
    }

    function test_RevertWhen_AppealPeriodOver() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);

        // One second past the appeal deadline is the earliest moment an escalation must revert.
        vm.warp(stakes[0].time + multiverse.ONE_DAY() + 1);
        vm.prank(bystander);
        vm.expectRevert(Multiverse.AppealPeriodOver.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);
    }

    function test_RevertWhen_QueryAlreadyResolved() public {
        uint256 queryId = _createReportedQuery(OUTCOME_A);
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);

        vm.warp(stakes[0].time + multiverse.ONE_DAY() + 1);
        multiverse.resolve(GENESIS_UID, queryId);

        vm.prank(bystander);
        vm.expectRevert(Multiverse.QueryAlreadyResolved.selector);
        multiverse.report(GENESIS_UID, queryId, OUTCOME_B);
    }

    function test_RevertWhen_ResolvedInvalidByExpiry() public {
        // The other resolve path: no report ever landed and the reporting window expired.
        uint256 queryId = _createDefaultQuery();
        (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);

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
        multiverse.wrap(GENESIS_UID, USER_REP_BALANCE);
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
                    REPORT - FORK-THRESHOLD BOUNDARY
    //////////////////////////////////////////////////////////////*/
    function test_Report_ExactHalfThresholdStakeIsOrdinary() public {
        // The stake rule clamps only stakes strictly ABOVE half the threshold: a stake of exactly
        // half must land as an ordinary stake (the report-side pin of the `>` boundary; the
        // capped-fee suite pins the same boundary through the view only), and its doubling is
        // exactly the full threshold — the ladder is now one step from the fork level.
        (uint256 queryId, uint256 forkThreshold) = _createNearThresholdLadder();

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 3);
        assertEq(stakes[2].amount, forkThreshold / 2);

        (uint256 requiredStake, uint256 threshold) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, forkThreshold);
        assertEq(threshold, forkThreshold);
    }

    /*//////////////////////////////////////////////////////////////
                          REPORT - GETTERS
    //////////////////////////////////////////////////////////////*/
    function test_GetNextRequiredStake_FirstReport() public {
        uint256 queryId = _createDefaultQuery();

        (uint256 requiredStake, uint256 forkThreshold) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, DEFAULT_FEE);
        assertEq(forkThreshold, zoltar.getForkThreshold(GENESIS_UID));
    }

    function test_GetNextRequiredStake_SecondStakeDoubles() public {
        uint256 queryId = _createDefaultQuery();

        (uint256 firstStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(firstStake, DEFAULT_FEE);

        _report(user, queryId, OUTCOME_A);

        (uint256 secondStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(secondStake, DEFAULT_FEE * 2);
    }

    function test_GetNextRequiredStake_EscalationDoubling() public {
        uint256 queryId = _createDefaultQuery();

        for (uint256 i = 0; i < 4; i++) {
            (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
            assertEq(requiredStake, DEFAULT_FEE << i);
            _report(i % 2 == 0 ? user : bystander, queryId, i % 2 == 0 ? OUTCOME_A : OUTCOME_B);
        }
    }

    function test_GetNextRequiredStake_ClampsToThreshold() public {
        uint256 forkThreshold = zoltar.getForkThreshold(GENESIS_UID);
        // Pick a fee below half the threshold (accepted by createQuery, not clamped as a first
        // stake) whose doubling reaches half the threshold.
        uint256 fee = forkThreshold / 3;
        feeCtl.setFee(fee);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", DEFAULT_NUMBER_OF_OUTCOMES);

        (uint256 firstStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(firstStake, fee);
        _report(user, queryId, OUTCOME_A);

        // The doubled stake reaches half the threshold, so it is clamped up to the full threshold.
        // TODO: the limit might be reconsidered
        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, forkThreshold);
    }

    function test_GetNextRequiredStake_RevertsInvalidUniverse() public {
        // A valid query, so the universe check is the one that fires.
        uint256 queryId = _createDefaultQuery();
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.getNextRequiredStake(1, queryId);
    }

    function test_GetNextRequiredStake_RevertsNonexistentQuery() public {
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.getNextRequiredStake(GENESIS_UID, 999);
    }

    function test_GetStakes_EmptyForFreshQuery() public {
        // An existing query with no stakes yet reads as an empty array.
        uint256 queryId = _createDefaultQuery();
        assertEq(multiverse.getStakes(GENESIS_UID, queryId).length, 0);
    }

    function test_GetStakes_RevertsNonexistentQuery() public {
        vm.expectRevert(Multiverse.InvalidQuery.selector);
        multiverse.getStakes(GENESIS_UID, 999);
    }
}
