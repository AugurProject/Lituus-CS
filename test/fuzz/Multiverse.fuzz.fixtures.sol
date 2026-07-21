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

/// @notice Shared fixtures for the Multiverse fuzz test suites.
/// @dev Fuzz suites inherit this contract instead of duplicating deployment and funding logic.
abstract contract MultiverseFuzzFixtures is Test {
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
    address internal reporter = makeAddr("reporter");
    // The resolver is deliberately never funded: resolving costs nothing, so its balance isolates
    // exactly what resolve() pays the caller.
    address internal resolver = makeAddr("resolver");

    function setUp() public virtual {
        underlying = new MockERC20("Underlying", "U");
        zoltarQuestionData = new MockZoltarQuestionData();
        zoltar = new MockZoltar(IReputationToken(address(underlying)), zoltarQuestionData);
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (ILituusRep repToken,,,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        _fundWithRep(user, USER_REP_BALANCE);
        _fundWithRep(reporter, USER_REP_BALANCE);
    }

    /// @dev Mint underlying, wrap into REP, approve from the account to the multiverse.
    function _fundWithRep(address account, uint256 amount) internal {
        underlying.mint(account, amount);
        vm.startPrank(account);
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, amount);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Creates a default 3-outcome query as `user` and returns its id.
    function _createQuery() internal returns (uint256 queryId) {
        queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", 3);
    }
}
