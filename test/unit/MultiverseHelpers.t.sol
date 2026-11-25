// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test, stdError } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseHelpers } from "src/libraries/MultiverseHelpers.sol";

/// @dev Runs the library's aggregate bookkeeping on a universe of its own, so the aggregates can be set to
///      values the Multiverse never reaches.
contract ConsumeHarness {
    Multiverse.Universe internal universe;

    function setAggregates(uint128 totalQueryFees, uint128 totalTips) external {
        universe.totalQueryFees = totalQueryFees;
        universe.totalTips = totalTips;
    }

    function consume(uint256 fee, uint256 tips) external {
        MultiverseHelpers._consumeQueryFeeAndTips(universe, fee, tips);
    }

    function aggregates() external view returns (uint128 totalQueryFees, uint128 totalTips) {
        return (universe.totalQueryFees, universe.totalTips);
    }
}

/// @notice The bookkeeping of a universe's fee and tip aggregates when a query's fee and tips are consumed.
contract MultiverseHelpersTest is Test {
    ConsumeHarness internal harness;

    function setUp() public {
        harness = new ConsumeHarness();
    }

    function test_Consume_TakesTheFeeAndTheTipsOffTheAggregates() public {
        harness.setAggregates(5 ether, 3 ether);
        harness.consume(2 ether, 1 ether);
        (uint128 totalQueryFees, uint128 totalTips) = harness.aggregates();
        assertEq(totalQueryFees, 3 ether);
        assertEq(totalTips, 2 ether);
    }

    /// @dev A child's fee aggregate can trail the nominal fees by dust, so the fee side stops at zero.
    function test_Consume_TheFeeSaturatesAtZero() public {
        harness.setAggregates(1 ether, 3 ether);
        harness.consume(1 ether + 1, 0);
        (uint128 totalQueryFees, uint128 totalTips) = harness.aggregates();
        assertEq(totalQueryFees, 0);
        assertEq(totalTips, 3 ether);
    }

    /// @dev The tips a universe owes never exceed its aggregate. If they ever did, paying them must fail, not
    ///      clamp the aggregate to zero and take the difference out of other balances unnoticed.
    function test_RevertWhen_Consume_TheTipsExceedTheAggregate() public {
        harness.setAggregates(1 ether, 3 ether);
        vm.expectRevert(stdError.arithmeticError);
        harness.consume(0, 3 ether + 1);

        // The whole aggregate can still be paid out.
        harness.consume(0, 3 ether);
        (, uint128 totalTips) = harness.aggregates();
        assertEq(totalTips, 0);
    }
}
