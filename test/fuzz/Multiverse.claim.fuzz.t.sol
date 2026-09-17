// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for claim/claimMultiple over escalation ladders of fuzzed depth
///         and fee.
/// @dev Ladders are built same-block (see _buildLadder), so the first report's fee-reward ramp is
///      exactly zero and settlement math is isolated: everything the contract pays out comes from
///      claim(). Outcomes alternate and so do the actors, so every stake on the winning outcome
///      belongs to one actor and that actor's single claim drains the winner side exactly. The fee
///      bound keeps the leading outcome's total (128 times the first stake after MAX_ROUNDS rounds)
///      below the per-outcome cap of this suite's supply (3200e18 -> cap 32e18), so no stake ever
///      lands on the cap, and keeps every actor's cumulative stakes within USER_REP_BALANCE.
contract MultiverseClaimFuzzTest is MultiverseFuzzFixtures {
    uint256 internal constant MIN_ROUNDS = 2;
    uint256 internal constant MAX_ROUNDS = 8;
    uint256 internal constant MAX_LADDER_FEE = 0.1 ether;

    /// @dev Builds a same-block ladder like _buildLadder while adding up what each outcome and the
    ///      whole query received, from the stake required before each report, so the totals the
    ///      contract records can be checked against an independent sum.
    function _buildTrackedLadder(uint256 rounds)
        internal
        returns (uint256 queryId, uint256 totalStaked, uint256 stakedOnOne, uint256 stakedOnTwo)
    {
        queryId = _createQuery();
        for (uint256 i = 0; i < rounds; i++) {
            uint8 outcome = i % 2 == 0 ? 1 : 2;
            uint256 stake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, outcome);
            vm.prank(i % 2 == 0 ? user : reporter);
            multiverse.report(GENESIS_UID, queryId, outcome);
            totalStaked += stake;
            if (outcome == 1) stakedOnOne += stake;
            else stakedOnTwo += stake;
        }
    }

    /// @dev The actor owning every stake on the winning outcome of a ladder of `rounds` rounds: the last
    ///      reporter, since reporters alternate with outcomes and the last outcome wins.
    function _winnerOf(uint256 rounds) internal view returns (address) {
        return (rounds - 1) % 2 == 0 ? user : reporter;
    }

    /// @dev Property: for any ladder, the recorded totals match an independent sum of the stakes, the
    /// single winner's claim drains exactly the winner side plus the distributable losing stakes, and
    /// the whole profit (the loser burn plus the full fee, since the first reporter's ramp is exactly
    /// zero on a same-block report) is destroyed from the supply at resolve. The query settles to a
    /// zero residual: REP is conserved through settlement.
    function testFuzz_Claim_Conservation(uint256 rounds, uint256 fee) public {
        rounds = bound(rounds, MIN_ROUNDS, MAX_ROUNDS);
        fee = bound(fee, 1, MAX_LADDER_FEE);
        feeCtl.setFee(fee);

        (uint256 queryId, uint256 totalStaked, uint256 stakedOnOne, uint256 stakedOnTwo) = _buildTrackedLadder(rounds);
        vm.warp(vm.getBlockTimestamp() + multiverse.ONE_DAY() + 1);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        ResolutionView memory r = _resolution(queryId);
        uint256 winnerStaked = r.outcome == 1 ? stakedOnOne : stakedOnTwo;
        uint256 losers = totalStaked - winnerStaked;
        assertEq(r.totalStaked, totalStaked);
        assertEq(multiverse.getOutcomeStakes(GENESIS_UID, queryId, r.outcome).totalOutcomeStaked, winnerStaked);

        address winner = _winnerOf(rounds);
        uint256 winnerBalanceBefore = genesisRep.balanceOf(winner);
        vm.prank(winner);
        multiverse.claim(GENESIS_UID, queryId);
        uint256 payout = genesisRep.balanceOf(winner) - winnerBalanceBefore;

        // One claimant holds the whole winner side, so the pro-rata share is exact: no floor dust.
        assertEq(payout, winnerStaked + (losers - losers / 5)); // BURN_DIVIDER = 5

        // Conservation: deposits were fee + totalStaked, resolve destroyed the whole profit (the full
        // fee, as the same-block ramp paid the reporter zero, plus losers / 5), and the claim took the
        // rest.
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
    }

    /// @dev Property: claiming a second time always reverts NothingToClaim, for any ladder shape, and
    /// so does the losing actor's claim.
    function testFuzz_Claim_DoubleClaimAlwaysReverts(uint256 rounds) public {
        rounds = bound(rounds, MIN_ROUNDS, MAX_ROUNDS);
        feeCtl.setFee(MAX_LADDER_FEE);

        uint256 queryId = _buildLadder(rounds);
        vm.warp(vm.getBlockTimestamp() + multiverse.ONE_DAY() + 1);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        address winner = _winnerOf(rounds);
        address loser = winner == user ? reporter : user;

        vm.prank(winner);
        multiverse.claim(GENESIS_UID, queryId);

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(winner);
        multiverse.claim(GENESIS_UID, queryId);

        vm.expectRevert(Multiverse.NothingToClaim.selector);
        vm.prank(loser);
        multiverse.claim(GENESIS_UID, queryId);
    }

    /// @dev Property: a claimMultiple batch over several resolved queries pays exactly the sum of the
    /// individual claim() payouts in a single transfer, and settles the stake on every query in the
    /// batch.
    function testFuzz_ClaimMultiple_MatchesExpectedPayouts(uint256 rounds, uint256 queryCount) public {
        rounds = bound(rounds, MIN_ROUNDS, MAX_ROUNDS);
        queryCount = bound(queryCount, 1, 3);
        feeCtl.setFee(MAX_LADDER_FEE);

        // Same depth for every ladder, so the same actor wins all of them.
        uint256[] memory queryIds = new uint256[](queryCount);
        for (uint256 i = 0; i < queryCount; i++) {
            queryIds[i] = _buildLadder(rounds);
        }
        vm.warp(vm.getBlockTimestamp() + multiverse.ONE_DAY() + 1);
        for (uint256 i = 0; i < queryCount; i++) {
            vm.prank(resolver);
            multiverse.resolve(GENESIS_UID, queryIds[i]);
        }

        address winner = _winnerOf(rounds);
        uint256 expectedTotal;
        for (uint256 i = 0; i < queryCount; i++) {
            expectedTotal += _expectedPayout(queryIds[i], winner);
        }

        uint256 winnerBalanceBefore = genesisRep.balanceOf(winner);
        vm.prank(winner);
        multiverse.claimMultiple(GENESIS_UID, queryIds);

        assertEq(genesisRep.balanceOf(winner), winnerBalanceBefore + expectedTotal);
        for (uint256 i = 0; i < queryCount; i++) {
            uint8 outcome = _resolution(queryIds[i]).outcome;
            assertEq(multiverse.getUserStake(GENESIS_UID, queryIds[i], winner, outcome), 0);
        }
    }
}
