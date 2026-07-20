// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFuzzFixtures } from "./Multiverse.fuzz.fixtures.sol";

/// @notice Property-based tests for createQuery. The fuzzer throws random inputs at the assumptions.
contract MultiverseCreateQueryFuzzTest is MultiverseFuzzFixtures {
    /// @dev Property: any outcome count in [MIN_OUTCOMES, MAX_OUTCOMES] is stored as given.
    function testFuzz_CreateQuery_ValidOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), multiverse.MIN_OUTCOMES(), multiverse.MAX_OUTCOMES()));

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", n);

        (uint8 numberOfOutcomes,,,) = multiverse.queries(0);
        assertEq(numberOfOutcomes, n);
        assertEq(multiverse.queryCount(), 1);
    }

    /// @dev Property: outcome counts below MIN_OUTCOMES always revert.
    function testFuzz_CreateQuery_RevertsLowOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), 0, uint256(multiverse.MIN_OUTCOMES()) - 1));

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", n);
    }

    /// @dev Property: outcome counts above MAX_OUTCOMES always revert.
    /// This test is added for clarity but has only one input value (255) that is above MAX_OUTCOMES.
    /// It might become useful if MAX_OUTCOMES is ever changed to a lower value.
    function testFuzz_CreateQuery_RevertsHighOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), uint256(multiverse.MAX_OUTCOMES()) + 1, 255));

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", n);
    }

    /// @dev Property: the exact fee reported by the controller is charged and stored.
    function testFuzz_CreateQuery_VaryingFee(uint256 fee) public {
        // Fees at or above half the fork threshold are rejected by createQuery (FeeAboveForkThreshold),
        // matching the stake clamp in _requiredStakeAmountAndForkThreshold, so the valid range tops
        // out just below that.
        fee = bound(fee, 1, zoltar.getForkThreshold(GENESIS_UID) / 2 - 1);
        feeCtl.setFee(fee);
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", 3);

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, fee);
        assertEq(genesisRep.balanceOf(address(multiverse)), fee);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - fee);
    }
}
