// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { QueryFeeController } from "src/QueryFeeController.sol";

/// @notice Unit suite for the QueryFeeController hill-climb.
/// @dev The controller's only caller is the Multiverse, so the whole suite runs standalone: the multiverse is a
///      pranked address that records profits and asks for the monthly step, no Multiverse deployment needed.
///      Profit is booked an hour into a chosen 3-day window and a step is taken an hour into a window too, so a
///      month is the ten windows before it with the boundary window split at a 1/72 fraction, which only ever
///      touches an empty window in these schedules. A step ten windows after the last one is exactly 30 days
///      later, inside the monthly gate, so a follow-up step sits an hour further in. The first step of a universe
///      compares against the bootstrap baseline (BOOT_PROFIT per pre-genesis window, ten of them: 200 REP).
///      Expected fees are hardcoded values computed independently of the contract's math.
contract QueryFeeControllerTest is Test {
    uint248 internal constant GENESIS_UID = 42;
    uint248 internal constant OTHER_UID = 77;
    uint256 internal constant START_TIME = 1_000_000;
    // Pinned to the controller's INITIAL_BASE_FEE; asserted in the constructor test.
    uint256 internal constant INITIAL_FEE = 10 ether;
    // The bootstrap baseline a first step reads as last month's profit: ten BOOT_PROFIT windows.
    uint256 internal constant BOOT_MONTH = 200 ether;

    QueryFeeController internal controller;

    address internal multiverse = makeAddr("multiverse");
    address internal fakeMultiverse = makeAddr("fakeMultiverse");

    function setUp() public virtual {
        vm.warp(START_TIME);

        controller = new QueryFeeController(GENESIS_UID, multiverse);
    }

    /// @dev Warps to `elapsed` seconds into window `windowId` (windows are anchored at the deploy time, START_TIME).
    function _warpToWindow(uint256 windowId, uint256 elapsed) internal {
        vm.warp(START_TIME + windowId * controller.THREE_DAYS() + elapsed);
    }

    /// @dev Books `amount` of profit for `universeId` an hour into window `windowId`, as the multiverse.
    function _recordProfitAt(uint248 universeId, uint256 windowId, uint256 amount) internal {
        _warpToWindow(windowId, 1 hours);
        vm.prank(multiverse);
        controller.recordProfit(universeId, amount);
    }

    /// @dev Takes the monthly step `elapsed` into window `windowId`, as the multiverse.
    function _updateBaseFeeAt(uint248 universeId, uint256 windowId, uint256 elapsed) internal {
        _warpToWindow(windowId, elapsed);
        vm.prank(multiverse);
        controller.updateBaseFee(universeId);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function test_Constructor_SeedsGenesisFeeState() public view {
        (uint128 baseFee, bool increased, uint48 timeFeeLastChanged, uint32 lastWindowId, uint40 sixtyDayVolume) =
            controller.feeStates(GENESIS_UID);

        assertEq(baseFee, uint128(INITIAL_FEE));
        assertEq(increased, false);
        assertEq(timeFeeLastChanged, uint48(START_TIME));
        assertEq(lastWindowId, 0);
        assertEq(sixtyDayVolume, 0);
        assertEq(controller.getQueryFee(GENESIS_UID), INITIAL_FEE);
        assertEq(controller.GENESIS_TIMESTAMP(), START_TIME);
        assertEq(controller.MULTIVERSE(), multiverse);
    }

    function test_RevertWhen_Constructor_MultiverseIsZero() public {
        vm.expectRevert(QueryFeeController.ZeroAddress.selector);
        new QueryFeeController(GENESIS_UID, address(0));
    }

    function test_Constructor_OtherUniversesUnseeded() public view {
        assertEq(controller.getQueryFee(OTHER_UID), 0);
    }

    function test_Constructor_BootProfitIsTwiceTheInitialBaseFee() public view {
        assertEq(controller.BOOT_PROFIT(), 2 * controller.INITIAL_BASE_FEE());
        assertEq(10 * controller.BOOT_PROFIT(), BOOT_MONTH);
    }

    /*//////////////////////////////////////////////////////////////
                          MULTIVERSE-ONLY ENTRIES
    //////////////////////////////////////////////////////////////*/
    function test_ChargeQuery_OnlyMultiverse() public {
        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.OnlyMultiverse.selector);
        controller.chargeQuery(GENESIS_UID);
    }

    function test_RecordQuery_OnlyMultiverse() public {
        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.OnlyMultiverse.selector);
        controller.recordQuery(GENESIS_UID);
    }

    function test_RecordProfit_OnlyMultiverse() public {
        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.OnlyMultiverse.selector);
        controller.recordProfit(GENESIS_UID, 1 ether);
    }

    function test_SeedChild_OnlyMultiverse() public {
        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.OnlyMultiverse.selector);
        controller.seedChild(GENESIS_UID, OTHER_UID, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                         CHARGE AND RECORD QUERY
    //////////////////////////////////////////////////////////////*/
    function test_ChargeQuery_ReturnsThePreviewAndCountsAfterPricing() public {
        // At genesis the modifier is neutral: the charge is the base fee, exactly what the preview said. The
        // query enters its bucket only after being priced, so the next preview is higher.
        uint256 preview = controller.previewFee(GENESIS_UID);
        assertEq(preview, INITIAL_FEE);

        vm.prank(multiverse);
        uint256 fee = controller.chargeQuery(GENESIS_UID);

        assertEq(fee, preview);
        (, uint128 volume) = controller.threeDayInfo(GENESIS_UID, 0);
        assertEq(volume, 1);
        assertGt(controller.previewFee(GENESIS_UID), fee);
    }

    function test_RecordQuery_CountsLikeChargeQuery() public {
        // Priced or not, a query is one count in the current bucket, and both paths roll the cache to the
        // current window first: the preview after a recordQuery is the preview after a chargeQuery.
        _warpToWindow(3, 1 hours);

        uint256 snapshot = vm.snapshotState();
        vm.prank(multiverse);
        controller.chargeQuery(GENESIS_UID);
        uint256 previewAfterCharge = controller.previewFee(GENESIS_UID);
        (,,, uint32 lastWindowAfterCharge,) = controller.feeStates(GENESIS_UID);
        vm.revertToState(snapshot);

        vm.prank(multiverse);
        controller.recordQuery(GENESIS_UID);

        assertEq(controller.previewFee(GENESIS_UID), previewAfterCharge);
        (, uint128 volume) = controller.threeDayInfo(GENESIS_UID, 3);
        assertEq(volume, 1);
        (,,, uint32 lastWindowId,) = controller.feeStates(GENESIS_UID);
        assertEq(lastWindowId, 3);
        assertEq(lastWindowId, lastWindowAfterCharge);
    }

    /*//////////////////////////////////////////////////////////////
                             RECORD PROFIT
    //////////////////////////////////////////////////////////////*/
    function test_RecordProfit_BooksIntoTheCurrentWindow() public {
        _recordProfitAt(GENESIS_UID, 5, 3 ether);
        _recordProfitAt(GENESIS_UID, 5, 4 ether);

        (uint128 profit, uint128 volume) = controller.threeDayInfo(GENESIS_UID, 5);
        assertEq(profit, 7 ether);
        assertEq(volume, 0);
        (profit,) = controller.threeDayInfo(GENESIS_UID, 4);
        assertEq(profit, 0);
        (profit,) = controller.threeDayInfo(GENESIS_UID, 6);
        assertEq(profit, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             UPDATE BASE FEE
    //////////////////////////////////////////////////////////////*/
    function test_UpdateBaseFee_OnlyMultiverse() public {
        vm.warp(block.timestamp + controller.THIRTY_DAYS() + 1);

        vm.prank(fakeMultiverse);
        vm.expectRevert(QueryFeeController.OnlyMultiverse.selector);
        controller.updateBaseFee(GENESIS_UID);
    }

    function test_UpdateBaseFee_RevertsInsideMonthlyWindow() public {
        // Exactly the 30-day boundary is still gated; the window opens strictly after it.
        vm.warp(block.timestamp + controller.THIRTY_DAYS());

        vm.prank(multiverse);
        vm.expectRevert(QueryFeeController.InvalidTimeWindow.selector);
        controller.updateBaseFee(GENESIS_UID);
    }

    function test_UpdateBaseFee_ImprovedProfit_KeepsStoredDirection() public {
        // Direction starts false (= cut). A first month that beats the bootstrap baseline keeps the stored
        // direction, so the first move with improving profit is a cut: 10 / 1.1 (exact integer form below).
        _recordProfitAt(GENESIS_UID, 5, BOOT_MONTH + 100 ether);
        _updateBaseFeeAt(GENESIS_UID, 10, 1 hours);

        assertEq(controller.getQueryFee(GENESIS_UID), INITIAL_FEE * controller.SCALE() / controller.FEE_RATE());
        // Hand-derived anchor: 10e18 * 1e18 / 1.1e18 = 9090909090909090909 wei (floored).
        assertEq(controller.getQueryFee(GENESIS_UID), 9_090_909_090_909_090_909);
    }

    function test_UpdateBaseFee_NonImprovedProfit_ReversesDirection() public {
        // An empty first month against the bootstrap baseline: current <= last, flip false -> true -> raise.
        _updateBaseFeeAt(GENESIS_UID, 10, 1 hours);

        assertEq(controller.getQueryFee(GENESIS_UID), INITIAL_FEE * controller.FEE_RATE() / controller.SCALE());
        assertEq(controller.getQueryFee(GENESIS_UID), 11 ether); // 10 * 1.1, hand-checked

        (, bool increased,,,) = controller.feeStates(GENESIS_UID);
        assertEq(increased, true);
    }

    function test_UpdateBaseFee_EqualProfitsCountAsNonImproved() public {
        // The same profit in each of two real months (windows 5 and 15, read at window 20 so no bootstrap term
        // enters): equal, flip false -> true -> raise.
        _recordProfitAt(GENESIS_UID, 5, 5 ether);
        _recordProfitAt(GENESIS_UID, 15, 5 ether);
        _updateBaseFeeAt(GENESIS_UID, 20, 1 hours);

        (, bool increased,,,) = controller.feeStates(GENESIS_UID);
        assertEq(increased, true);
        assertEq(controller.getQueryFee(GENESIS_UID), 11 ether); // 10 * 1.1, hand-checked
    }

    function test_UpdateBaseFee_RaiseThenCutReturnsExactly() public {
        _updateBaseFeeAt(GENESIS_UID, 10, 1 hours); // empty month vs bootstrap: flip -> raise: x1.1 -> 11
        _updateBaseFeeAt(GENESIS_UID, 20, 2 hours); // two empty real months: did not improve -> flip -> cut: /1.1

        // The two directions are exact inverses: an up-down oscillation lands back on the initial
        // base fee with no drift. Hand-checked: 11e18 * 1e18 / 1.1e18 = 10e18 exactly.
        assertEq(controller.getQueryFee(GENESIS_UID), 10 ether);
    }

    function test_UpdateBaseFee_ImprovingProfitsCompound() public {
        _updateBaseFeeAt(GENESIS_UID, 10, 1 hours); // flip -> raise
        _recordProfitAt(GENESIS_UID, 15, 2 ether);
        _updateBaseFeeAt(GENESIS_UID, 20, 2 hours); // 2 > 0: improved -> keep raising

        // Hand-checked: 10 * 1.1 = 11; 11 * 1.1 = 12.1.
        assertEq(controller.getQueryFee(GENESIS_UID), 12.1 ether);
    }

    function test_UpdateBaseFee_UpdatesTimeAndEmits() public {
        uint256 callTime = block.timestamp + controller.THIRTY_DAYS() + 1;

        vm.warp(callTime);
        vm.expectEmit(true, true, true, true, address(controller));
        // Hand-checked event args: 10 ether -> 11 ether (10 * 1.1).
        emit QueryFeeController.BaseQueryFeeUpdated(GENESIS_UID, 10 ether, 11 ether, uint48(callTime));

        vm.prank(multiverse);
        controller.updateBaseFee(GENESIS_UID);

        (,, uint48 timeFeeLastChanged,,) = controller.feeStates(GENESIS_UID);
        assertEq(timeFeeLastChanged, uint48(callTime));

        // The fresh timestamp re-arms the monthly gate.
        vm.prank(multiverse);
        vm.expectRevert(QueryFeeController.InvalidTimeWindow.selector);
        controller.updateBaseFee(GENESIS_UID);
    }

    /*//////////////////////////////////////////////////////////////
                               SEED CHILD
    //////////////////////////////////////////////////////////////*/
    function test_SeedChild_InheritsBaseFeeAndHillClimbDirection() public {
        // The parent's first step is a raise (empty month vs bootstrap): base 11, direction true.
        _updateBaseFeeAt(GENESIS_UID, 10, 1 hours);
        uint256 spawnTime = block.timestamp;

        vm.prank(multiverse);
        controller.seedChild(GENESIS_UID, OTHER_UID, spawnTime);

        (uint128 baseFee, bool increased, uint48 timeFeeLastChanged, uint32 lastWindowId, uint40 sixtyDayVolume) =
            controller.feeStates(OTHER_UID);
        assertEq(baseFee, 11 ether);
        assertEq(increased, true);
        assertEq(timeFeeLastChanged, uint48(spawnTime));
        assertEq(lastWindowId, 10);
        assertEq(sixtyDayVolume, 0);

        // The child's first step continues the parent's climb: its own month beats the inherited (empty) one, so
        // the inherited raise is kept and the fee rises again. A direction reset to false would have cut it to 10.
        _recordProfitAt(OTHER_UID, 15, 2 ether);
        _updateBaseFeeAt(OTHER_UID, 20, 2 hours);

        assertEq(controller.getQueryFee(OTHER_UID), 12.1 ether); // 11 * 1.1, hand-checked
    }

    function test_RevertWhen_SeedChild_AlreadySeeded() public {
        vm.prank(multiverse);
        controller.seedChild(GENESIS_UID, OTHER_UID, block.timestamp);

        // A seeded universe is never reseeded, and neither is the genesis.
        vm.prank(multiverse);
        vm.expectRevert(QueryFeeController.CannotSet.selector);
        controller.seedChild(GENESIS_UID, OTHER_UID, block.timestamp);
        vm.prank(multiverse);
        vm.expectRevert(QueryFeeController.CannotSet.selector);
        controller.seedChild(OTHER_UID, GENESIS_UID, block.timestamp);
    }
}
