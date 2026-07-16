// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { QueryFeeController } from "src/QueryFeeController.sol";

/// @notice Unit suite for the QueryFeeController hill-climb.
/// @dev The controller is push-model (profits arrive as arguments), so the whole suite runs standalone:
///      the multiverse is just a pranked address, no Multiverse deployment needed. Expected fees are
///      hardcoded values computed independently of the contract's math.
contract QueryFeeControllerTest is Test {
    uint248 internal constant GENESIS_UID = 42;
    uint248 internal constant OTHER_UID = 77;
    uint256 internal constant START_TIME = 1_000_000;
    // Pinned to the controller's INITIAL_BASE_FEE; asserted in the constructor test.
    uint256 internal constant INITIAL_FEE = 10 ether;

    QueryFeeController internal controller;

    address internal multiverse = makeAddr("multiverse");
    address internal fakeMultiverse = makeAddr("fakeMultiverse");

    function setUp() public virtual {
        vm.warp(START_TIME);

        controller = new QueryFeeController(GENESIS_UID);
        controller.setMultiverse(multiverse);
    }

    /// @dev Steps the clock past the monthly gate and pushes profits as the multiverse.
    function _changeBaseFeeAfterAMonth(uint256 currentProfit, uint256 lastProfit) internal {
        vm.warp(block.timestamp + controller.THIRTY_DAYS() + 1);
        vm.prank(multiverse);
        controller.changeBaseFee(GENESIS_UID, currentProfit, lastProfit);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function test_Constructor_SeedsGenesisFeeState() public view {
        (uint128 baseFee, bool increased, uint48 timeFeeLastChanged) = controller.feeStates(GENESIS_UID);

        assertEq(baseFee, uint128(INITIAL_FEE));
        assertEq(increased, false);
        assertEq(timeFeeLastChanged, uint48(START_TIME));
        assertEq(controller.getQueryFee(GENESIS_UID), INITIAL_FEE);
    }

    function test_Constructor_OtherUniversesUnseeded() public view {
        assertEq(controller.getQueryFee(OTHER_UID), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             SET MULTIVERSE
    //////////////////////////////////////////////////////////////*/
    function test_SetMultiverse_OnlyOnce() public {
        vm.expectRevert(QueryFeeController.CannotSet.selector);
        controller.setMultiverse(fakeMultiverse);
    }

    function test_SetMultiverse_OnlyDeployer() public {
        QueryFeeController fresh = new QueryFeeController(GENESIS_UID);

        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.CannotSet.selector);
        fresh.setMultiverse(fakeMultiverse);
    }

    /*//////////////////////////////////////////////////////////////
                             CHANGE BASE FEE
    //////////////////////////////////////////////////////////////*/
    function test_ChangeBaseFee_OnlyMultiverse() public {
        vm.warp(block.timestamp + controller.THIRTY_DAYS() + 1);

        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.OnlyMultiverse.selector);
        controller.changeBaseFee(GENESIS_UID, 1, 0);
    }

    function test_ChangeBaseFee_RevertsInsideMonthlyWindow() public {
        // Exactly the 30-day boundary is still gated; the window opens strictly after it.
        vm.warp(block.timestamp + controller.THIRTY_DAYS());

        vm.prank(multiverse);
        vm.expectRevert(QueryFeeController.InvalidTimeWindow.selector);
        controller.changeBaseFee(GENESIS_UID, 1, 0);
    }

    function test_ChangeBaseFee_ImprovedProfit_KeepsStoredDirection() public {
        // Direction starts false (= cut). Improved profit keeps the stored direction, so the first
        // move with improving profit is a cut: 10 / 1.1 (exact integer form below).
        _changeBaseFeeAfterAMonth(2, 1);

        assertEq(controller.getQueryFee(GENESIS_UID), INITIAL_FEE * controller.SCALE() / controller.FEE_RATE());
        // Hand-derived anchor: 10e18 * 1e18 / 1.1e18 = 9090909090909090909 wei (floored).
        assertEq(controller.getQueryFee(GENESIS_UID), 9_090_909_090_909_090_909);
    }

    function test_ChangeBaseFee_NonImprovedProfit_ReversesDirection() public {
        _changeBaseFeeAfterAMonth(0, 1); // current <= last: flip false -> true -> raise

        assertEq(controller.getQueryFee(GENESIS_UID), INITIAL_FEE * controller.FEE_RATE() / controller.SCALE());
        assertEq(controller.getQueryFee(GENESIS_UID), 11 ether); // 10 * 1.1, hand-checked

        (, bool increased,) = controller.feeStates(GENESIS_UID);
        assertEq(increased, true);
    }

    function test_ChangeBaseFee_EqualProfitsCountAsNonImproved() public {
        _changeBaseFeeAfterAMonth(5, 5); // equal: flip false -> true -> raise

        (, bool increased,) = controller.feeStates(GENESIS_UID);
        assertEq(increased, true);
        assertEq(controller.getQueryFee(GENESIS_UID), 11 ether); // 10 * 1.1, hand-checked
    }

    function test_ChangeBaseFee_RaiseThenCutReturnsExactly() public {
        _changeBaseFeeAfterAMonth(0, 1); // flip -> raise: x1.1 -> 11
        _changeBaseFeeAfterAMonth(0, 1); // did not improve -> flip -> cut: /1.1

        // The two directions are exact inverses: an up-down oscillation lands back on the initial
        // base fee with no drift. Hand-checked: 11e18 * 1e18 / 1.1e18 = 10e18 exactly.
        assertEq(controller.getQueryFee(GENESIS_UID), 10 ether);
    }

    function test_ChangeBaseFee_ImprovingProfitsCompound() public {
        _changeBaseFeeAfterAMonth(0, 1); // flip -> raise
        _changeBaseFeeAfterAMonth(2, 1); // improved -> keep raising

        // Hand-checked: 10 * 1.1 = 11; 11 * 1.1 = 12.1.
        assertEq(controller.getQueryFee(GENESIS_UID), 12.1 ether);
    }

    function test_ChangeBaseFee_UpdatesTimeAndEmits() public {
        uint256 callTime = block.timestamp + controller.THIRTY_DAYS() + 1;

        vm.warp(callTime);
        vm.expectEmit(true, true, true, true, address(controller));
        // Hand-checked event args: 10 ether -> 11 ether (10 * 1.1).
        emit QueryFeeController.BaseQueryFeeUpdated(GENESIS_UID, 10 ether, 11 ether, uint48(callTime));

        vm.prank(multiverse);
        controller.changeBaseFee(GENESIS_UID, 0, 1);

        (,, uint48 timeFeeLastChanged) = controller.feeStates(GENESIS_UID);
        assertEq(timeFeeLastChanged, uint48(callTime));

        // The fresh timestamp re-arms the monthly gate.
        vm.prank(multiverse);
        vm.expectRevert(QueryFeeController.InvalidTimeWindow.selector);
        controller.changeBaseFee(GENESIS_UID, 0, 1);
    }
}
