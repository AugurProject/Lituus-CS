// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test, console } from "forge-std/Test.sol";

import { Counter } from "src/Counter.sol";
import { CounterHandler } from "./handlers/CounterHandler.sol";

/// @notice Stateful fuzzing. Random sequences of handler calls must never
///         violate the global invariants below.
contract CounterInvariantTest is Test {
    Counter internal counter;
    CounterHandler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() public {
        counter = new Counter(owner);
        handler = new CounterHandler(counter, owner);

        // Direct the fuzzer at the handler only, keeps inputs bounded.
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The counter must never exceed its declared cap.
    function invariant_NeverExceedsMax() public view {
        assertLe(counter.number(), counter.MAX_NUMBER());
    }

    /// @dev Owner is set at construction and is immutable thereafter.
    function invariant_OwnerImmutable() public view {
        assertEq(counter.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                              CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    /// @dev Diagnostic-only, prints handler call counts. Run with `-vv`.
    function invariant_CallSummary() public view {
        console.log("increments :", handler.ghostIncrements());
        console.log("sets       :", handler.ghostSets());
        console.log("resets     :", handler.ghostResets());
    }
}
