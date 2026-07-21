// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for resolve. The fuzzer throws random inputs at the assumptions.
contract MultiverseResolveFuzzTest is MultiverseFuzzFixtures {
    /*//////////////////////////////////////////////////////////////
                    INVALID (NO-REPORT / EXPIRY) PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: an unreported query resolves to INVALID at any moment past the reporting
    /// window, and the resolver earns the fee share ramping from 0 at the deadline to the whole
    /// fee three days later, capped there forever after.
    function testFuzz_Resolve_Invalid_AfterWindow(uint256 pastDeadline) public {
        pastDeadline = bound(pastDeadline, 1, 365 days);
        uint256 queryId = _createQuery();

        vm.warp(block.timestamp + multiverse.THREE_DAYS() + pastDeadline);
        uint256 resolverBalanceBefore = genesisRep.balanceOf(user);
        vm.prank(user);
        multiverse.resolve(GENESIS_UID, queryId);

        (, uint8 outcome,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(outcome, multiverse.INVALID());

        uint256 expectedPay = pastDeadline >= multiverse.THREE_DAYS()
            ? DEFAULT_FEE
            : DEFAULT_FEE * pastDeadline / multiverse.THREE_DAYS();
        assertEq(genesisRep.balanceOf(user) - resolverBalanceBefore, expectedPay);
    }

    /// @dev Property: an unreported query is never resolvable up to and including the reporting
    /// deadline (the check is strict: exactly at the deadline is still too early).
    function testFuzz_Resolve_Invalid_RevertsWithinWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.THREE_DAYS());
        uint256 queryId = _createQuery();

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    /// @dev Property: the resolver reward scales with the query fee across the whole valid fee
    /// range, using the same ramp share for a fixed moment past the deadline.
    function testFuzz_Resolve_Invalid_RewardScalesWithFee(uint256 fee, uint256 pastDeadline) public {
        // The fee doubles as the first bond, so createQuery accepts fees below half the fork threshold.
        fee = bound(fee, 1, zoltar.getForkThreshold(GENESIS_UID) / 2 - 1);
        pastDeadline = bound(pastDeadline, 1, multiverse.THREE_DAYS());
        feeCtl.setFee(fee);
        uint256 queryId = _createQuery();
        (,, uint256 chargedFee,) = multiverse.queries(queryId);

        vm.warp(block.timestamp + multiverse.THREE_DAYS() + pastDeadline);
        uint256 resolverBalanceBefore = genesisRep.balanceOf(user);
        vm.prank(user);
        multiverse.resolve(GENESIS_UID, queryId);

        uint256 expectedPay =
            pastDeadline >= multiverse.THREE_DAYS() ? chargedFee : chargedFee * pastDeadline / multiverse.THREE_DAYS();
        assertEq(genesisRep.balanceOf(user) - resolverBalanceBefore, expectedPay);
    }

    /*//////////////////////////////////////////////////////////////
                UNDISPUTED (SINGLE-STAKE) RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Property: a query with a single report resolves to the reported outcome once the appeal
    /// window passes, whatever the outcome (any valid one, including INVALID) and whenever the
    /// report landed within the reporting window. Three distinct actors: `user` creates, `reporter`
    /// reports, `resolver` resolves. The sole reporter is settled in one transfer (the bond back
    /// plus the reward ramping with the report's delay since creation); the creator's fee is spent
    /// and the resolver earns nothing on this path (unlike the no-report INVALID path).
    function testFuzz_Resolve_SingleStake_RampAndSettlement(uint8 outcome, uint256 reportDelay, uint256 resolveDelay)
        public
    {
        // 1..3 are the query's outcomes; map the extra bucket to the INVALID marker (255).
        outcome = uint8(bound(uint256(outcome), 1, 4));
        if (outcome == 4) outcome = multiverse.INVALID();
        reportDelay = bound(reportDelay, 0, multiverse.THREE_DAYS());
        resolveDelay = bound(resolveDelay, multiverse.ONE_DAY() + 1, 365 days);
        uint256 creatorBalanceBefore = genesisRep.balanceOf(user);
        uint256 reporterBalanceBefore = genesisRep.balanceOf(reporter);
        uint256 queryId = _createQuery();

        // Track time locally: with via-ir the optimizer may cache block.timestamp across vm.warp.
        uint256 time = block.timestamp;
        time += reportDelay;
        vm.warp(time);
        vm.prank(reporter);
        multiverse.report(GENESIS_UID, queryId, outcome);

        time += resolveDelay;
        vm.warp(time);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        (, uint8 resolvedOutcome,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(resolvedOutcome, outcome);
        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), outcome);

        // The creator's fee is spent for good; the reporter's bond (== fee) came back with the
        // reward ramping over the reporting window; the resolver earns nothing here; the multiverse
        // keeps the unrewarded fee remainder (burn of profit is still TODO in the contract).
        uint256 expectedReward = DEFAULT_FEE * reportDelay / multiverse.THREE_DAYS();
        assertEq(genesisRep.balanceOf(user), creatorBalanceBefore - DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(reporter), reporterBalanceBefore + expectedReward);
        assertEq(genesisRep.balanceOf(resolver), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE - expectedReward);

        // The sole stake is settled at resolution (amount zeroed), nothing left to claim.
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].amount, 0);
    }

    /// @dev Property: a reported query is never resolvable up to and including the appeal deadline
    /// (the check is strict: exactly at the deadline is still too early).
    function testFuzz_Resolve_SingleStake_RevertsWithinAppealWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.ONE_DAY());
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryNotReadyToResolve.selector);
        multiverse.resolve(GENESIS_UID, queryId);
    }

    /// @dev Property: the single-stake settlement (bond refund + ramped reward) scales with the
    /// query fee across the whole valid fee range, with each phase driven by a distinct actor:
    /// `user` creates, `reporter` reports, `resolver` resolves.
    function testFuzz_Resolve_SingleStake_FeeScales(uint256 fee, uint256 reportDelay) public {
        fee = bound(fee, 1, zoltar.getForkThreshold(GENESIS_UID) / 2 - 1);
        reportDelay = bound(reportDelay, 0, multiverse.THREE_DAYS());
        feeCtl.setFee(fee);
        uint256 creatorBalanceBefore = genesisRep.balanceOf(user);
        uint256 reporterBalanceBefore = genesisRep.balanceOf(reporter);
        uint256 queryId = _createQuery();
        (,, uint256 chargedFee,) = multiverse.queries(queryId);

        uint256 time = block.timestamp;
        time += reportDelay;
        vm.warp(time);
        vm.prank(reporter);
        multiverse.report(GENESIS_UID, queryId, 1);

        time += multiverse.ONE_DAY() + 1;
        vm.warp(time);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        // The creator paid the fee, the reporter netted the ramped reward (bond refunded), and the
        // resolver earned nothing on this path. Whatever the reward didn't hand out stays in the
        // multiverse (burn of profit is still TODO in the contract), so it keeps exactly
        // fee - reward.
        uint256 expectedReward = chargedFee * reportDelay / multiverse.THREE_DAYS();
        assertEq(genesisRep.balanceOf(user), creatorBalanceBefore - chargedFee);
        assertEq(genesisRep.balanceOf(reporter), reporterBalanceBefore + expectedReward);
        assertEq(genesisRep.balanceOf(resolver), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), chargedFee - expectedReward);
    }
}
