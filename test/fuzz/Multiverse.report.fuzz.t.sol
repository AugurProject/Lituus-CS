// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for report. The fuzzer throws random inputs at the assumptions.
contract MultiverseReportFuzzTest is MultiverseFuzzFixtures {
    /// @dev Property: every outcome in the valid set (1..numberOfOutcomes and INVALID) is accepted
    /// as a first report and stored as given, at a stake equal to the query fee.
    function testFuzz_Report_ValidOutcomes(uint8 outcome) public {
        // 1..3 are the query's outcomes; map the extra bucket to the INVALID marker (255).
        outcome = uint8(bound(uint256(outcome), 1, 4));
        if (outcome == 4) outcome = multiverse.INVALID();
        uint256 queryId = _createQuery();

        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, outcome);

        ResolutionView memory r = _resolution(queryId);
        assertEq(r.stakeCount, 1);
        assertEq(r.lastReportedOutcome, outcome);
        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, user, outcome), DEFAULT_FEE);
    }

    /// @dev Property: a first report any time up to and including the deadline succeeds.
    function testFuzz_Report_WithinReportingWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.THREE_DAYS());
        uint256 queryId = _createQuery();

        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        assertEq(_resolution(queryId).stakeCount, 1);
    }

    /// @dev Property: a first report any time past the deadline always reverts.
    function testFuzz_Report_RevertsAfterReportingWindow(uint256 delay) public {
        delay = bound(delay, multiverse.THREE_DAYS() + 1, 365 days);
        uint256 queryId = _createQuery();

        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryExpired.selector);
        multiverse.report(GENESIS_UID, queryId, 1);
    }

    /// @dev Property: the first stake never differs from the query fee by more than a factor of
    /// sqrt(2), and always divides the per-outcome cap evenly. The fee range starts well above the
    /// point where the halving steps stop dividing the cap exactly, and ends at the quarter-cap
    /// bound so the fee itself is what gets rounded.
    function testFuzz_Report_FirstStakeWithinSqrtTwoOfFee(uint256 fee) public {
        uint256 cap = _capWrep();
        fee = bound(fee, 1e13, cap / multiverse.FIRST_STAKE_CAP_DIVISOR());
        feeCtl.setFee(fee);

        uint256 queryId = _createQuery();
        (,, uint256 chargedFee,) = multiverse.queries(queryId);
        uint256 firstStake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, 1);

        // Both directions of the bound, squared to avoid a square root: stake^2 <= 2 * fee^2 and
        // fee^2 <= 2 * stake^2.
        assertLe(firstStake * firstStake, 2 * chargedFee * chargedFee);
        assertLe(chargedFee * chargedFee, 2 * firstStake * firstStake);
        assertEq(cap % firstStake, 0);
    }

    /// @dev Property: after every escalation the outcome just staked on holds exactly twice the total
    /// of every other outcome (the ladder never reaches the cap at these depths), and the contract
    /// holds the creation fee plus every stake.
    function testFuzz_Report_EscalationKeepsLeaderAtDoubleTheRest(uint8 rounds) public {
        rounds = uint8(bound(uint256(rounds), 1, 5));
        uint256 queryId = _createQuery();

        uint256 totalStaked;
        for (uint256 i = 0; i < rounds; i++) {
            uint8 outcome = i % 2 == 0 ? 1 : 2;
            uint256 stake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, outcome);
            vm.prank(user);
            multiverse.report(GENESIS_UID, queryId, outcome);
            totalStaked += stake;

            uint256 onOutcome = multiverse.getOutcomeStakes(GENESIS_UID, queryId, outcome).totalOutcomeStaked;
            if (i == 0) assertEq(stake, DEFAULT_FEE);
            else assertEq(onOutcome, 2 * (totalStaked - onOutcome));
        }

        assertEq(_resolution(queryId).stakeCount, rounds);
        assertEq(_resolution(queryId).totalStaked, totalStaked);
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + totalStaked);
    }

    /// @dev Property: an escalation any time up to and including the appeal deadline succeeds.
    function testFuzz_Report_WithinAppealWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.ONE_DAY());
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 2);

        assertEq(_resolution(queryId).stakeCount, 2);
    }

    /// @dev Property: an escalation any time past the appeal deadline always reverts.
    function testFuzz_Report_RevertsAfterAppealWindow(uint256 delay) public {
        delay = bound(delay, multiverse.ONE_DAY() + 1, 365 days);
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(vm.getBlockTimestamp() + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.AppealPeriodOver.selector);
        multiverse.report(GENESIS_UID, queryId, 2);
    }
}
