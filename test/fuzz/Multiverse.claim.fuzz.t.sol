// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for claim/claimMultiple over escalation ladders of fuzzed depth
///         and fee.
/// @dev Ladders are built same-block (see _buildLadder), so the first report's fee-reward ramp is
///      exactly zero and settlement math is isolated: everything the contract pays out comes from
///      claim(). Fee and rounds bounds keep the largest stake (fee * 2^(rounds-1)) below half the
///      fork threshold (this suite's supply 2000e18 -> threshold 100e18), so no stake ever clamps
///      to fork level, and keep every actor's cumulative stakes within USER_REP_BALANCE.
contract MultiverseClaimFuzzTest is MultiverseFuzzFixtures {
    uint256 internal constant MIN_ROUNDS = 2;
    uint256 internal constant MAX_ROUNDS = 8;
    uint256 internal constant MAX_LADDER_FEE = 0.3 ether;

    /// @dev Property: for any ladder, every winning stake claims at least its stake back, the
    /// winners together drain exactly winnerStaked + totalDistributable (up to one wei of
    /// rounding dust per winner), and the contract retains exactly the fee plus the loser burn
    /// (plus that dust) — REP is conserved through settlement. The fee is fully retained because
    /// the first reporter's ramp is exactly zero (same-block report).
    function testFuzz_Claim_Conservation(uint256 rounds, uint256 fee) public {
        rounds = bound(rounds, MIN_ROUNDS, MAX_ROUNDS);
        fee = bound(fee, 1, MAX_LADDER_FEE);
        feeCtl.setFee(fee);

        uint256 queryId = _buildLadder(rounds);
        // The charged fee as stored (equals the base at the genesis-neutral point; read it rather
        // than assume the demand modifier).
        (,, fee,) = multiverse.queries(queryId);
        vm.warp(vm.getBlockTimestamp() + multiverse.ONE_DAY() + 1);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        (, uint8 outcome, uint96 totalDistributable, uint96 winnerStaked) =
            multiverse.queryResolutions(GENESIS_UID, queryId);
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);

        // Recompute the frozen totals independently from the stakes.
        uint256 totalStaked;
        uint256 expectedWinnerStaked;
        for (uint256 i = 0; i < stakes.length; i++) {
            totalStaked += stakes[i].amount;
            if (stakes[i].reportedOutcome == outcome) expectedWinnerStaked += stakes[i].amount;
        }
        uint256 losers = totalStaked - expectedWinnerStaked;
        assertEq(winnerStaked, expectedWinnerStaked);
        assertEq(totalDistributable, losers - losers / 5); // BURN_DIVIDER = 5

        // Every winner claims; each payout is at least the stake itself.
        uint256 sumPayouts;
        uint256 winnersCount;
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].reportedOutcome != outcome) continue;
            winnersCount++;

            address owner = stakes[i].reporter;
            uint256 ownerBalanceBefore = genesisRep.balanceOf(owner);
            vm.prank(owner);
            multiverse.claim(GENESIS_UID, queryId, i);
            uint256 payout = genesisRep.balanceOf(owner) - ownerBalanceBefore;

            assertGe(payout, stakes[i].amount);
            sumPayouts += payout;
        }

        // Winners drain winnerStaked + totalDistributable, modulo < 1 wei of floor dust each.
        // winnersCount is the number of winners, so the total dust is < winnersCount wei.
        assertLe(sumPayouts, uint256(winnerStaked) + uint256(totalDistributable));
        assertGe(sumPayouts + winnersCount, uint256(winnerStaked) + uint256(totalDistributable));

        // Conservation: deposits were fee + totalStaked, the ramp paid the first reporter zero
        // (same-block report), so the residual is the fee + the loser burn + the claim dust.
        uint256 residual = genesisRep.balanceOf(address(multiverse));
        assertEq(residual, fee + totalStaked - sumPayouts);
        assertGe(residual, fee + losers / 5);
        assertLe(residual, fee + losers / 5 + winnersCount);
    }

    /// @dev Property: claiming any winning stake a second time always reverts StakeAlreadyClaimed,
    /// for any ladder shape and any winning stake in it.
    function testFuzz_Claim_DoubleClaimAlwaysReverts(uint256 rounds, uint256 indexSeed) public {
        rounds = bound(rounds, MIN_ROUNDS, MAX_ROUNDS);
        // Keep the deepest rung (fee * 2^7) below half the fork threshold; DEFAULT_FEE would clamp.
        feeCtl.setFee(MAX_LADDER_FEE);

        uint256 queryId = _buildLadder(rounds);
        vm.warp(vm.getBlockTimestamp() + multiverse.ONE_DAY() + 1);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        // Winning stakes sit at every second index ending at the last one (alternating outcomes,
        // last outcome wins): pick one of them.
        uint256 winnersCount = (rounds + 1) / 2;
        uint256 stakeIndex = (rounds - 1) - 2 * bound(indexSeed, 0, winnersCount - 1);
        address owner = multiverse.getStakes(GENESIS_UID, queryId)[stakeIndex].reporter;

        vm.prank(owner);
        multiverse.claim(GENESIS_UID, queryId, stakeIndex);

        vm.expectRevert(Multiverse.StakeAlreadyClaimed.selector);
        vm.prank(owner);
        multiverse.claim(GENESIS_UID, queryId, stakeIndex);
    }

    /// @dev Property: a claimMultiple batch of one actor's winning stakes pays exactly the sum of
    /// the individual claim() payouts (the frozen-totals formula per stake) in a single transfer,
    /// and settles every stake in the batch.
    function testFuzz_ClaimMultiple_MatchesExpectedPayouts(uint256 rounds) public {
        rounds = bound(rounds, MIN_ROUNDS, MAX_ROUNDS);
        // Keep the fee below half the fork threshold; DEFAULT_FEE would clamp.
        feeCtl.setFee(MAX_LADDER_FEE);

        uint256 queryId = _buildLadder(rounds);
        vm.warp(vm.getBlockTimestamp() + multiverse.ONE_DAY() + 1);
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        // The winning outcome's stakes all belong to one actor (reporters alternate with outcomes):
        // the last stake's reporter owns every winning stake.
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        address winner = stakes[rounds - 1].reporter;
        uint256 winnersCount = (rounds + 1) / 2;

        uint256[] memory queryIds = new uint256[](winnersCount);
        uint256[] memory stakeIndices = new uint256[](winnersCount);
        uint256 expectedTotal;
        for (uint256 i = 0; i < winnersCount; i++) {
            uint256 stakeIndex = (rounds - 1) - 2 * i;
            queryIds[i] = queryId;
            stakeIndices[i] = stakeIndex;
            expectedTotal += _expectedPayout(queryId, stakeIndex);
        }

        uint256 winnerBalanceBefore = genesisRep.balanceOf(winner);
        vm.prank(winner);
        multiverse.claimMultiple(GENESIS_UID, queryIds, stakeIndices);

        assertEq(genesisRep.balanceOf(winner), winnerBalanceBefore + expectedTotal);
        for (uint256 i = 0; i < winnersCount; i++) {
            assertEq(multiverse.getStakes(GENESIS_UID, queryId)[stakeIndices[i]].amount, 0);
        }
    }
}
