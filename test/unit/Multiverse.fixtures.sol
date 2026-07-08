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
    uint248 internal constant GENESIS_UID = 0;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    uint256 internal constant USER_REP_BALANCE = 1000 ether;
    uint8 internal constant DEFAULT_NUMBER_OF_OUTCOMES = 3;
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

        // Fund user and bystander with REP once, as fixture setup.
        _fundWithRep(user, USER_REP_BALANCE);
        _fundWithRep(bystander, USER_REP_BALANCE);
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
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }
}
