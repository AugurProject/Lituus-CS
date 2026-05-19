// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { Counter } from "src/Counter.sol";

/// @notice Deterministic, hand-crafted scenarios. The bedrock layer.
contract CounterUnitTest is Test {
    Counter internal counter;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    event Incremented(address indexed by, uint256 newValue);
    event NumberSet(address indexed by, uint256 newValue);
    event Reset(address indexed by);

    function setUp() public {
        counter = new Counter(owner);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_InitialNumberIsZero() public view {
        assertEq(counter.number(), 0);
    }

    function test_OwnerIsSetCorrectly() public view {
        assertEq(counter.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                              INCREMENT
    //////////////////////////////////////////////////////////////*/

    function test_Increment_EmitsEvent() public {
        vm.expectEmit({ checkTopic1: true, checkTopic2: false, checkTopic3: false, checkData: true });
        emit Incremented(user, 1);

        vm.prank(user);
        counter.increment();

        assertEq(counter.number(), 1);
    }

    function test_RevertWhen_IncrementAtMax() public {
        counter.setNumber(counter.MAX_NUMBER());

        vm.expectRevert(Counter.CounterOverflow.selector);
        counter.increment();
    }

    /*//////////////////////////////////////////////////////////////
                              SET NUMBER
    //////////////////////////////////////////////////////////////*/

    function test_SetNumber_AnyoneCanCall() public {
        vm.prank(user);
        counter.setNumber(42);
        assertEq(counter.number(), 42);
    }

    function test_RevertWhen_SetNumberOverflows() public {
        // Compute the offending value BEFORE vm.expectRevert; otherwise the
        // view call to MAX_NUMBER() consumes the expectRevert cheatcode.
        uint256 tooBig = counter.MAX_NUMBER() + 1;

        vm.expectRevert(Counter.CounterOverflow.selector);
        counter.setNumber(tooBig);
    }

    /*//////////////////////////////////////////////////////////////
                                RESET
    //////////////////////////////////////////////////////////////*/

    function test_Reset_OwnerSucceeds() public {
        vm.prank(user);
        counter.setNumber(100);

        vm.prank(owner);
        counter.reset();

        assertEq(counter.number(), 0);
    }

    function test_RevertWhen_NonOwnerResets() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        counter.reset();
    }
}
