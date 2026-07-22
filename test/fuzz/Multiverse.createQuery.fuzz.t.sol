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

    /// @dev Property: the charged fee is the controller fee capped at half the fork threshold, and
    /// the stored fee, contract holdings, and payer balance always match the charged amount.
    function testFuzz_CreateQuery_VaryingFee(uint256 fee) public {
        // Any base fee is accepted and the final fee is clamped to at most half the fork threshold.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        fee = bound(fee, 1, type(uint128).max);
        feeCtl.setFee(fee);
        uint256 chargedFee = fee > cap ? cap : fee;
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", 3);

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, chargedFee);
        assertLe(storedFee, cap);
        assertEq(genesisRep.balanceOf(address(multiverse)), chargedFee);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - chargedFee);
    }
}
