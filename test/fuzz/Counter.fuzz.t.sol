// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { Counter } from "src/Counter.sol";

/// @notice Property-based tests. The fuzzer throws random inputs at the assumptions.
contract CounterFuzzTest is Test {
    Counter internal counter;
    address internal owner = makeAddr("owner");

    function setUp() public {
        counter = new Counter(owner);
    }

    /// @dev Property: any value in valid range round-trips through `setNumber`.
    function testFuzz_SetNumber_ValidRange(uint256 x) public {
        x = bound(x, 0, counter.MAX_NUMBER());

        counter.setNumber(x);

        assertEq(counter.number(), x);
    }

    /// @dev Property: any value above MAX_NUMBER must revert with CounterOverflow.
    function testFuzz_SetNumber_RevertsAboveMax(uint256 x) public {
        x = bound(x, counter.MAX_NUMBER() + 1, type(uint256).max);

        vm.expectRevert(Counter.CounterOverflow.selector);
        counter.setNumber(x);
    }

    /// @dev Property: N successive increments produce `number == N`.
    function testFuzz_Increment_NTimes(uint8 n) public {
        for (uint256 i = 0; i < n; ++i) {
            counter.increment();
        }
        assertEq(counter.number(), n);
    }

    /// @dev Property: only `owner` can reset, regardless of caller.
    function testFuzz_Reset_OnlyOwner(address caller) public {
        vm.assume(caller != owner);
        counter.setNumber(1);

        vm.prank(caller);
        vm.expectRevert();
        counter.reset();

        assertEq(counter.number(), 1);
    }
}
