// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { LituusRep } from "src/LituusRep.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IReputationToken } from "src/interfaces/IReputationToken.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

contract MultiverseUnitTest is Test {
    uint248 internal constant GENESIS_UID = 0;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    uint256 internal constant USER_REP_BALANCE = 1000 ether;

    MockERC20 internal underlying;
    MockZoltar internal zoltar;
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;

    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");

    event QueryCreated(uint256 indexed queryId, uint248 indexed universeId, string question, uint16 numberOfOutcomes);

    function setUp() public {
        underlying = new MockERC20("Underlying", "U");
        zoltar = new MockZoltar(IReputationToken(address(underlying)));
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);
        (ILituusRep repToken,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        underlying.mint(user, USER_REP_BALANCE);

        vm.startPrank(user);
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, USER_REP_BALANCE);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ZoltarIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(IZoltar(address(0)), GENESIS_UID, feeCtl);
    }

    function test_RevertWhen_QueryFeeControllerIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(zoltar, GENESIS_UID, IQueryFeeController(address(0)));
    }

    function test_GenesisUniverseInitialized() public view {
        (
            ILituusRep repToken,
            Multiverse.ForkState forkState,
            uint248 parent,
            uint248 favoriteChild,
            uint248 heir,
            bytes32 history,
            uint256 forkQuery,
            uint256 supplyBeforeFork,
            address queryTokenizer
        ) = multiverse.universes(GENESIS_UID);

        assertTrue(address(repToken) != address(0));
        assertEq(uint8(forkState), uint8(Multiverse.ForkState.NotForking));
        assertEq(parent, 0);
        assertEq(favoriteChild, 0);
        assertEq(heir, 0);
        assertEq(history, bytes32(0));
        assertEq(forkQuery, 0);
        assertEq(supplyBeforeFork, 0);
        assertEq(queryTokenizer, address(0));
    }

    function test_GenesisRepTokenWrapsZoltarRep() public view {
        assertEq(address(LituusRep(address(genesisRep)).UNDERLYING_TOKEN()), address(underlying));
    }

    function test_ImmutablesStored() public view {
        assertEq(address(multiverse.ZOLTAR()), address(zoltar));
        assertEq(address(multiverse.QUERY_FEE_CONTROLLER()), address(feeCtl));
    }

    /*//////////////////////////////////////////////////////////////
                                WRAP
    //////////////////////////////////////////////////////////////*/

    function test_Wrap_TransfersUnderlyingAndMintsLituusRep() public {
        uint256 amount = 5 ether;
        underlying.mint(user, amount);

        uint256 underlyingBefore = underlying.balanceOf(user);
        uint256 repBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.wrap(GENESIS_UID, amount);

        assertEq(underlying.balanceOf(user), underlyingBefore - amount);
        assertEq(genesisRep.balanceOf(user), repBefore + amount);
    }

    function test_RevertWhen_WrapOnUnknownUniverse() public {
        vm.expectRevert();
        vm.prank(user);
        multiverse.wrap(99, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                UNWRAP
    //////////////////////////////////////////////////////////////*/

    function test_Unwrap_BurnsLituusRepAndReturnsUnderlying() public {
        uint256 amount = 5 ether;

        uint256 underlyingBefore = underlying.balanceOf(user);
        uint256 repBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.unwrap(GENESIS_UID, amount);

        assertEq(underlying.balanceOf(user), underlyingBefore + amount);
        assertEq(genesisRep.balanceOf(user), repBefore - amount);
    }

    function test_RevertWhen_UnwrapOnUnknownUniverse() public {
        vm.expectRevert();
        vm.prank(user);
        multiverse.unwrap(99, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE QUERY: SUCCESS
    //////////////////////////////////////////////////////////////*/

    function test_CreateQuery_GenesisUniverse_Succeeds() public {
        uint256 multiverseRepBefore = genesisRep.balanceOf(address(multiverse));
        uint256 userRepBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);

        assertEq(multiverse.queryCount(), 1);

        (uint48 createTime, uint16 numberOfOutcomes, uint248 originUniverse, uint256 fee) = _readQueryHeader(0);
        assertEq(createTime, uint48(block.timestamp));
        assertEq(numberOfOutcomes, 3);
        assertEq(originUniverse, GENESIS_UID);
        assertEq(fee, DEFAULT_FEE);

        assertEq(multiverse.getOutcome(GENESIS_UID, 0), multiverse.NO_REPORT());
        assertEq(multiverse.getOutcomeData(GENESIS_UID, 0).totalStake, 0);

        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseRepBefore + DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(user), userRepBefore - DEFAULT_FEE);
    }

    function test_CreateQuery_EmitsEvent() public {
        vm.expectEmit({ checkTopic1: true, checkTopic2: true, checkTopic3: false, checkData: true });
        emit QueryCreated(0, GENESIS_UID, "Q?", 3);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);
    }

    function test_CreateQuery_QueryCountIncrements() public {
        vm.startPrank(user);
        multiverse.createQuery(GENESIS_UID, "Q1?", 3);
        multiverse.createQuery(GENESIS_UID, "Q2?", 3);
        vm.stopPrank();

        assertEq(multiverse.queryCount(), 2);
    }

    function test_CreateQuery_BoundaryOutcomes_3() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);

        (, uint16 numberOfOutcomes,,) = _readQueryHeader(0);
        assertEq(numberOfOutcomes, 3);
    }

    function test_CreateQuery_BoundaryOutcomes_253() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 253);

        (, uint16 numberOfOutcomes,,) = _readQueryHeader(0);
        assertEq(numberOfOutcomes, 253);
    }

    function test_CreateQuery_FeeZero_Succeeds() public {
        feeCtl.setFee(0);
        uint256 multiverseRepBefore = genesisRep.balanceOf(address(multiverse));

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);

        (,,, uint256 fee) = _readQueryHeader(0);
        assertEq(fee, 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseRepBefore);
    }

    function test_CreateQuery_FeeReadFromController() public {
        feeCtl.setFee(42);
        uint256 multiverseRepBefore = genesisRep.balanceOf(address(multiverse));
        uint256 userRepBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);

        (,,, uint256 fee) = _readQueryHeader(0);
        assertEq(fee, 42);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseRepBefore + 42);
        assertEq(genesisRep.balanceOf(user), userRepBefore - 42);
    }

    /*//////////////////////////////////////////////////////////////
                         CREATE QUERY: REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_UniverseDoesNotExist() public {
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        vm.prank(user);
        multiverse.createQuery(99, "Q?", 3);
    }

    function test_RevertWhen_NumberOfOutcomesIsZero() public {
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 0);
    }

    function test_RevertWhen_NumberOfOutcomesIsOne() public {
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 1);
    }

    function test_RevertWhen_NumberOfOutcomesIsTwo() public {
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 2);
    }

    function test_RevertWhen_NumberOfOutcomesExceedsMax() public {
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 254);
    }

    function test_RevertWhen_UserHasInsufficientRepBalance() public {
        vm.prank(attacker);
        genesisRep.approve(address(multiverse), type(uint256).max);

        vm.expectRevert();
        vm.prank(attacker);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);
    }

    function test_RevertWhen_UserDidNotApproveMultiverse() public {
        vm.prank(user);
        genesisRep.approve(address(multiverse), 0);

        vm.expectRevert();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "Q?", 3);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _readQueryHeader(uint256 queryId)
        internal
        view
        returns (uint48 createTime, uint16 numberOfOutcomes, uint248 originUniverse, uint256 fee)
    {
        (createTime, numberOfOutcomes, originUniverse, fee,) = multiverse.queries(queryId);
    }
}
