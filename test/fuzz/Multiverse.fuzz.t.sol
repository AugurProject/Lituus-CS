// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IReputationToken } from "src/interfaces/IReputationToken.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { MockZoltarQuestionData } from "src/mock/MockZoltarQuestionData.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

/// @notice Property-based tests for createQuery. The fuzzer throws random inputs at the assumptions.
contract MultiverseFuzzTest is Test {
    // Nonzero on purpose: catches code paths that wrongly assume the genesis universe lives at id 0.
    uint248 internal constant GENESIS_UID = 42;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    uint256 internal constant USER_REP_BALANCE = 1000 ether;

    MockERC20 internal underlying;
    MockZoltarQuestionData internal zoltarQuestionData;
    MockZoltar internal zoltar;
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;

    address internal user = makeAddr("user");

    function setUp() public {
        underlying = new MockERC20("Underlying", "U");
        zoltarQuestionData = new MockZoltarQuestionData();
        zoltar = new MockZoltar(IReputationToken(address(underlying)), zoltarQuestionData);
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (ILituusRep repToken,,,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        underlying.mint(user, USER_REP_BALANCE);
        vm.startPrank(user);
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, USER_REP_BALANCE);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.stopPrank();
    }

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

    /// @dev Creates a default 3-outcome query as `user` and returns its id.
    function _createQuery() internal returns (uint256 queryId) {
        queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", 3);
    }

    /// @dev Property: every outcome in the valid set (1..numberOfOutcomes and INVALID) is accepted
    /// as a first report and stored as given, at a stake equal to the query fee.
    function testFuzz_Report_ValidOutcomes(uint8 outcome) public {
        // 1..3 are the query's outcomes; map the extra bucket to the INVALID marker (255).
        outcome = uint8(bound(uint256(outcome), 1, 4));
        if (outcome == 4) outcome = multiverse.INVALID();
        uint256 queryId = _createQuery();

        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, outcome);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].reportedOutcome, outcome);
        assertEq(stakes[0].amount, DEFAULT_FEE);
    }

    /// @dev Property: a first report any time up to and including the deadline succeeds.
    function testFuzz_Report_WithinReportingWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.THREE_DAYS());
        uint256 queryId = _createQuery();

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        assertEq(multiverse.getStakes(GENESIS_UID, queryId).length, 1);
    }

    /// @dev Property: a first report any time past the deadline always reverts.
    function testFuzz_Report_RevertsAfterReportingWindow(uint256 delay) public {
        delay = bound(delay, multiverse.THREE_DAYS() + 1, 365 days);
        uint256 queryId = _createQuery();

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryExpired.selector);
        multiverse.report(GENESIS_UID, queryId, 1);
    }

    /// @dev Property: each escalation doubles the previous stake and the contract holds
    /// the creation fee plus every stake.
    function testFuzz_Report_EscalationDoubles(uint8 rounds) public {
        rounds = uint8(bound(uint256(rounds), 1, 5));
        uint256 queryId = _createQuery();

        for (uint256 i = 0; i < rounds; i++) {
            vm.prank(user);
            multiverse.report(GENESIS_UID, queryId, i % 2 == 0 ? 1 : 2);
        }

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, rounds);
        uint256 totalStaked;
        for (uint256 i = 0; i < rounds; i++) {
            assertEq(stakes[i].amount, DEFAULT_FEE * (2 ** i));
            totalStaked += stakes[i].amount;
        }
        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + totalStaked);
    }

    /// @dev Property: an escalation any time up to and including the appeal deadline succeeds.
    function testFuzz_Report_WithinAppealWindow(uint256 delay) public {
        delay = bound(delay, 0, multiverse.ONE_DAY());
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 2);

        assertEq(multiverse.getStakes(GENESIS_UID, queryId).length, 2);
    }

    /// @dev Property: an escalation any time past the appeal deadline always reverts.
    function testFuzz_Report_RevertsAfterAppealWindow(uint256 delay) public {
        delay = bound(delay, multiverse.ONE_DAY() + 1, 365 days);
        uint256 queryId = _createQuery();
        vm.prank(user);
        multiverse.report(GENESIS_UID, queryId, 1);

        vm.warp(block.timestamp + delay);
        vm.prank(user);
        vm.expectRevert(Multiverse.AppealPeriodOver.selector);
        multiverse.report(GENESIS_UID, queryId, 2);
    }
}
