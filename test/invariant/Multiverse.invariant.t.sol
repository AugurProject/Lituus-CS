// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test, console } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IReputationToken } from "src/interfaces/IReputationToken.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { MockZoltarQuestionData } from "src/mock/MockZoltarQuestionData.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";
import { MultiverseHandler } from "./handlers/MultiverseHandler.sol";

/// @notice Stateful fuzzing of createQuery. Random sequences of handler calls must never
///         violate the global invariants below.
contract MultiverseInvariantTest is Test {
    uint248 internal constant GENESIS_UID = 0;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    // Large REP balance for the handler so cumulative fees never exhaust it during a run.
    uint256 internal constant HANDLER_REP_BALANCE = 1e40;

    MockERC20 internal underlying;
    MockZoltarQuestionData internal zoltarQuestionData;
    MockZoltar internal zoltar;
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;
    MultiverseHandler internal handler;

    function setUp() public {
        underlying = new MockERC20("Underlying", "U");
        zoltarQuestionData = new MockZoltarQuestionData();
        zoltar = new MockZoltar(IReputationToken(address(underlying)), zoltarQuestionData);
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (ILituusRep repToken,,,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        handler = new MultiverseHandler(multiverse, feeCtl, genesisRep, GENESIS_UID);

        // Fund the handler with REP and approve the multiverse to pull query fees.
        underlying.mint(address(handler), HANDLER_REP_BALANCE);
        vm.startPrank(address(handler));
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, HANDLER_REP_BALANCE);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.stopPrank();

        // Direct the fuzzer at the handler only, keeps inputs bounded.
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev queryCount equals the number of successful createQuery calls.
    function invariant_QueryCountMatchesGhost() public view {
        assertEq(multiverse.queryCount(), handler.ghostQueriesCreated());
    }

    /// @dev The REP held by the multiverse equals the sum of every fee charged.
    function invariant_RepBalanceMatchesFees() public view {
        assertEq(genesisRep.balanceOf(address(multiverse)), handler.ghostTotalFees());
    }

    /// @dev Every created query has a valid outcome count and origin universe.
    function invariant_QueryRecordsWellFormed() public view {
        uint256 count = multiverse.queryCount();
        for (uint256 i = 0; i < count; ++i) {
            (uint8 numberOfOutcomes, uint248 originUniverse,,) = multiverse.queries(i);
            assertGe(numberOfOutcomes, multiverse.MIN_OUTCOMES());
            assertLe(numberOfOutcomes, multiverse.MAX_OUTCOMES());
            assertEq(originUniverse, GENESIS_UID);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CALL SUMMARY
    //////////////////////////////////////////////////////////////*/

    /// @dev Diagnostic-only, prints handler call counts. Run with `-vv`.
    function invariant_CallSummary() public view {
        console.log("queriesCreated :", handler.ghostQueriesCreated());
        console.log("totalFees      :", handler.ghostTotalFees());
    }
}
