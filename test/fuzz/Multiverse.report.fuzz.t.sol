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

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].reportedOutcome, outcome);
        assertEq(stakes[0].amount, DEFAULT_FEE);
    }

    /// @dev Property: a first report any time up to and including the deadline succeeds.
    function testFuzz_Report_WithinReportingWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.THREE_DAYS());
        uint256 queryId = _createQuery();

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        assertEq(multiverse.getStakes(GENESIS_UID, queryId).length, 1);
    }

    /// @dev Property: a first report any time past the deadline always reverts.
    function testFuzz_Report_RevertsAfterReportingWindow(uint256 delay) public {
        delay = bound(delay, multiverse.THREE_DAYS() + 1, 365 days);
        uint256 queryId = _createQuery();

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryExpired.selector);
        multiverse.report(GENESIS_UID, queryId, 1);
    }

    /// @dev Property: each escalation doubles the previous stake and the contract holds
    /// the creation fee plus every stake.
    function testFuzz_Report_EscalationDoubles(uint8 rounds) public {
        rounds = uint8(bound(uint256(rounds), 1, 5));
        uint256 queryId = _createQuery();

        for (uint256 i = 0; i < rounds; i++) {
            vm.prank(user);
            multiverse.report(GENESIS_UID, queryId, i % 2 == 0 ? 1 : 2);
        }

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, rounds);
        uint256 totalStaked;
        for (uint256 i = 0; i < rounds; i++) {
            assertEq(stakes[i].amount, DEFAULT_FEE << i);
            totalStaked += stakes[i].amount;
        }
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + totalStaked);
    }

    /// @dev Property: an escalation any time up to and including the appeal deadline succeeds.
    function testFuzz_Report_WithinAppealWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.ONE_DAY());
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 2);

        assertEq(multiverse.getStakes(GENESIS_UID, queryId).length, 2);
    }

    /// @dev Property: an escalation any time past the appeal deadline always reverts.
    function testFuzz_Report_RevertsAfterAppealWindow(uint256 delay) public {
        delay = bound(delay, multiverse.ONE_DAY() + 1, 365 days);
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.AppealPeriodOver.selector);
        multiverse.report(GENESIS_UID, queryId, 2);
    }
}
