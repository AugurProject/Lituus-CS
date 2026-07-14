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

/// @notice Shared fixtures for the Multiverse unit test suites.
/// @dev Test files inherit this contract instead of duplicating deployment and funding logic.
///      Currently provides a basic deploy fixture (`setUp`) and a query creation fixture
///      (`_createDefaultQuery`); fixtures for other cases will be added as the suites grow.
abstract contract MultiverseFixtures is Test {
    // Nonzero on purpose: Lituus universe ids mirror Zoltar universe ids, and a nonzero genesis
    // catches any code path that wrongly assumes the genesis universe lives at id 0.
    uint248 internal constant GENESIS_UID = 42;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    uint256 internal constant USER_REP_BALANCE = 1000 ether;
    uint8 internal constant DEFAULT_NUMBER_OF_OUTCOMES = 3;
    // Readable outcome pair for escalation ping-pong (both valid for the default query).
    uint8 internal constant OUTCOME_A = 1;
    uint8 internal constant OUTCOME_B = 2;
    string internal constant DEFAULT_QUESTION = "John Doe's pet?[CAT,DOG,SHARK]";
    // Fixed timestamp so queryCreateTime / forkTime assertions are deterministic.
    uint256 internal constant START_TIME = 1_000_000;

    MockERC20 internal underlying;
    MockZoltarQuestionData internal zoltarQuestionData;
    MockZoltar internal zoltar;
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;

    address internal user = makeAddr("user");
    address internal bystander = makeAddr("bystander");
    address internal challenger = makeAddr("challenger");

    /// @dev Basic deploy fixture: mocks + Multiverse deployed at START_TIME, actors funded with REP.
    function setUp() public virtual {
        vm.warp(START_TIME);

        underlying = new MockERC20("Underlying", "U");
        zoltarQuestionData = new MockZoltarQuestionData();
        zoltar = new MockZoltar(IReputationToken(address(underlying)), zoltarQuestionData);
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (ILituusRep repToken,,,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        // Fund the actors with REP once, as fixture setup.
        _fundWithRep(user, USER_REP_BALANCE);
        _fundWithRep(bystander, USER_REP_BALANCE);
        _fundWithRep(challenger, USER_REP_BALANCE);
    }

    /// @dev Mint underlying, wrap into REP, approve from the user to the multiverse.
    function _fundWithRep(address account, uint256 amount) internal {
        underlying.mint(account, amount);
        vm.startPrank(account);
        underlying.approve(address(genesisRep), type(uint256).max);
        genesisRep.approve(address(multiverse), type(uint256).max);
        multiverse.wrap(GENESIS_UID, amount);
        vm.stopPrank();
    }

    /// @dev Query creation fixture: `user` creates a default query in the genesis universe.
    /// @return queryId The id of the created query.
    function _createDefaultQuery() internal returns (uint256 queryId) {
        queryId = multiverse.queryCount();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));
        uint256 queryCountBefore = multiverse.queryCount();

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(multiverse.queryCount(), queryCountBefore + 1);
        assertGt(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore);
        assertLt(genesisRep.balanceOf(user), userBalanceBefore);
    }

    /// @dev Report fixture: `reporter` reports `outcome` on `queryId` in the genesis universe,
    ///      asserting the stake recording (record appended with exact fields) and the REP movement
    ///      (reporter pays exactly the required stake, the multiverse receives it).
    function _report(address reporter, uint256 queryId, uint8 outcome) internal {
        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        uint256 reporterBalanceBefore = genesisRep.balanceOf(reporter);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));
        uint256 stakeCountBefore = multiverse.getStakes(GENESIS_UID, queryId).length;

        vm.prank(reporter);
        multiverse.report(GENESIS_UID, queryId, outcome);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, stakeCountBefore + 1);
        Multiverse.Stake memory newStake = stakes[stakes.length - 1];
        assertEq(newStake.reporter, reporter);
        assertEq(newStake.time, uint48(block.timestamp));
        assertEq(newStake.reportedOutcome, outcome);
        assertEq(newStake.amount, requiredStake);
        assertEq(genesisRep.balanceOf(reporter), reporterBalanceBefore - requiredStake);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore + requiredStake);
    }

    /// @dev Reported query fixture: `user` creates a default query and places the first report on it.
    /// @return queryId The id of the created and reported query.
    function _createReportedQuery(uint8 outcome) internal returns (uint256 queryId) {
        queryId = _createDefaultQuery();
        _report(user, queryId, outcome);
    }

    /// @dev Escalation ladder fixture: each reporter in turn reports their outcome on `queryId`,
    ///      12 hours after the previous step — within the first-report window and every appeal window.
    ///      Tracks time in a local variable: with via-ir the optimizer may cache `block.timestamp`
    ///      across `vm.warp`, so re-reading it after a warp is unreliable.
    function _escalateChain(uint256 queryId, address[] memory reporters, uint8[] memory outcomes) internal {
        assertEq(reporters.length, outcomes.length, "escalateChain: length mismatch");
        uint256 time = block.timestamp;
        for (uint256 i = 0; i < reporters.length; i++) {
            time += 12 hours;
            vm.warp(time);
            _report(reporters[i], queryId, outcomes[i]);

            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
            assertEq(stakes.length, i + 1);
        }
    }
}
