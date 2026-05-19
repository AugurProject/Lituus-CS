// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { Counter } from "src/Counter.sol";

/// @notice Handler for stateful fuzzing. Wraps Counter calls with bounded inputs.
/// @dev    The invariant runner picks random functions from this contract.
///         Ghost variables track call counts for visibility.
contract CounterHandler is CommonBase, StdCheats, StdUtils {
    Counter public immutable COUNTER;
    address public immutable OWNER;

    // Ghost variables, observable from invariants.
    uint256 public ghostIncrements;
    uint256 public ghostSets;
    uint256 public ghostResets;

    constructor(Counter counter_, address owner_) {
        COUNTER = counter_;
        OWNER = owner_;
    }

    /// @notice Increment via a non-owner caller; skip if already at the cap.
    function increment(address caller) external {
        vm.assume(caller != address(0));
        if (COUNTER.number() >= COUNTER.MAX_NUMBER()) return;

        vm.prank(caller);
        COUNTER.increment();
        ++ghostIncrements;
    }

    /// @notice Set within the valid range via a non-owner caller.
    function setNumber(address caller, uint256 x) external {
        vm.assume(caller != address(0));
        x = bound(x, 0, COUNTER.MAX_NUMBER());

        vm.prank(caller);
        COUNTER.setNumber(x);
        ++ghostSets;
    }

    /// @notice Reset must come from the owner.
    function reset() external {
        vm.prank(OWNER);
        COUNTER.reset();
        ++ghostResets;
    }
}
