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
    // Fixed timestamp so queryCreateTime / forkTime assertions are deterministic.
    uint256 internal constant START_TIME = 1_000_000;

    MockERC20 internal underlying;
    MockZoltar internal zoltar;
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;

    address internal user = makeAddr("user");
    address internal bystander = makeAddr("bystander");

    function setUp() public {
        vm.warp(START_TIME);

        underlying = new MockERC20("Underlying", "U");
        zoltar = new MockZoltar(IReputationToken(address(underlying)));
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (ILituusRep repToken,,,,,,,,,) = multiverse.universes(GENESIS_UID);
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

    function test_Constructor_SetsImmutables() public {
        uint256 deployTime = START_TIME + 5 days;
        vm.warp(deployTime);
        Multiverse newMultiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        assertEq(address(newMultiverse.ZOLTAR()), address(zoltar));
        assertEq(address(newMultiverse.QUERY_FEE_CONTROLLER()), address(feeCtl));
        assertEq(newMultiverse.GENESIS_TIMESTAMP(), deployTime);
    }

    function test_Constructor_InitializesGenesisUniverse() public {
        // supplyBeforeFork is captured at deploy time from the theoretical supply. Deploy a
        // new instance so the captured value equals the current live reading.
        uint256 expectedSupply = zoltar.getUniverseTheoreticalSupply(GENESIS_UID);
        Multiverse newMultiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (
            ILituusRep repToken,
            Multiverse.ForkState forkState,
            uint48 forkTime,
            uint248 parent,
            uint248 favoriteChild,
            uint248 heir,
            bytes32 history,
            uint256 forkQuery,
            uint256 supplyBeforeFork,
            address queryTokenizer
        ) = newMultiverse.universes(GENESIS_UID);

        assertTrue(address(repToken) != address(0));
        assertEq(uint8(forkState), uint8(Multiverse.ForkState.NotForking));
        assertEq(forkTime, uint48(block.timestamp));
        assertEq(parent, 0);
        assertEq(favoriteChild, 0);
        assertEq(heir, 0);
        assertEq(history, bytes32(0));
        assertEq(forkQuery, 0);
        assertEq(supplyBeforeFork, expectedSupply);
        assertEq(queryTokenizer, address(0));
    }

    function test_Constructor_DeploysRepToken() public view {
        LituusRep rep = LituusRep(address(genesisRep));
        assertEq(rep.name(), "Lituus Reputation Token");
        assertEq(rep.symbol(), "REP0");
        assertEq(rep.owner(), address(multiverse));
        assertEq(address(rep.UNDERLYING_TOKEN()), address(underlying));
    }

    function test_Constructor_Constants() public view {
        assertEq(multiverse.MAX_OUTCOMES(), 254);
        assertEq(multiverse.MIN_OUTCOMES(), 2);
        assertEq(multiverse.MAX_FORK_OUTCOMES(), 2);
        assertEq(multiverse.UNRESOLVED(), 0);
        assertEq(multiverse.INVALID(), 255);
        assertEq(multiverse.THREE_DAYS(), 3 days);
        assertEq(multiverse.ONE_DAY(), 1 days);
        assertEq(multiverse.BURN_DIVIDER(), 5);
    }

    /*//////////////////////////////////////////////////////////////
                              CREATE QUERY
    //////////////////////////////////////////////////////////////*/
    function test_CreateQuery_HappyPath() public {
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        string memory inputQuestion = "John Doe's pet?[CAT,DOG,SHARK]";

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, inputQuestion, 3);

        assertEq(multiverse.queryCount(), 1);

        (uint8 numberOfOutcomes, uint248 originUniverse, uint256 fee, string memory question) = multiverse.queries(0);
        assertEq(numberOfOutcomes, 3);
        assertEq(originUniverse, GENESIS_UID);
        assertEq(fee, DEFAULT_FEE);
        assertEq(question, inputQuestion);

        (uint48 queryCreateTime, uint8 outcome) = multiverse.queryResolutions(GENESIS_UID, 0);
        assertEq(queryCreateTime, uint48(block.timestamp));
        assertEq(outcome, multiverse.UNRESOLVED());

        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - DEFAULT_FEE);
    }

    function test_CreateQuery_EmitsEvent() public {
        string memory inputQuestion = "John Doe's pet?[CAT,DOG,SHARK]";
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryCreated(user, 0, GENESIS_UID, inputQuestion, 3);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, inputQuestion, 3);
    }

    function test_CreateQuery_MinOutcomes() public {
        string memory inputQuestion = "Does John Doe have a pet?[YES,NO]";
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, inputQuestion, 2);

        (uint8 numberOfOutcomes,,,) = multiverse.queries(0);
        assertEq(numberOfOutcomes, 2);
    }

    function test_CreateQuery_MaxOutcomes() public {
        uint8 max = multiverse.MAX_OUTCOMES();
        string memory inputQuestion = "max";
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, inputQuestion, max);

        (uint8 numberOfOutcomes,,,) = multiverse.queries(0);
        assertEq(numberOfOutcomes, max);
    }

    function test_CreateQuery_ZeroFee() public {
        feeCtl.setFee(0);
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "free", 3);

        (,, uint256 fee,) = multiverse.queries(0);
        assertEq(fee, 0);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
    }

    function test_CreateQuery_MultipleQueries() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q0", 3);

        feeCtl.setFee(2 ether);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q1", 4);

        feeCtl.setFee(3 ether);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q2", 5);

        assertEq(multiverse.queryCount(), 3);

        (uint8 n0,, uint256 f0, string memory q0) = multiverse.queries(0);
        (uint8 n1,, uint256 f1, string memory q1) = multiverse.queries(1);
        (uint8 n2,, uint256 f2, string memory q2) = multiverse.queries(2);

        assertEq(n0, 3);
        assertEq(f0, DEFAULT_FEE);
        assertEq(q0, "q0");
        assertEq(n1, 4);
        assertEq(f1, 2 ether);
        assertEq(q1, "q1");
        assertEq(n2, 5);
        assertEq(f2, 3 ether);
        assertEq(q2, "q2");

        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE + 2 ether + 3 ether);
    }

    function test_CreateQuery_DifferentCallers() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "by user", 3);

        vm.prank(bystander);
        multiverse.createQuery(GENESIS_UID, "by bystander", 4);

        assertEq(multiverse.queryCount(), 2);

        (uint8 n0, uint248 u0, uint256 f0, string memory q0) = multiverse.queries(0);
        (uint8 n1, uint248 u1, uint256 f1, string memory q1) = multiverse.queries(1);
        assertEq(n0, 3);
        assertEq(u0, GENESIS_UID);
        assertEq(f0, DEFAULT_FEE);
        assertEq(q0, "by user");
        assertEq(n1, 4);
        assertEq(u1, GENESIS_UID);
        assertEq(f1, DEFAULT_FEE);
        assertEq(q1, "by bystander");
    }

    // No validation for empty question strings is intentional.
    function test_CreateQuery_EmptyQuestion() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "", 3);

        (,,, string memory question) = multiverse.queries(0);
        assertEq(question, "");
    }

    function test_CreateQuery_LongQuestion() public {
        string memory long = string.concat(
            "aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt uuu vvv www xxx yyy zzz ",
            "aab aac aad aae aaf aag aah aai aaj aak aal aam aan aao aap aaq aar aas aat aau aav aaw aax aay aaz ",
            "aba abb abc abd abe abf abg abh abi abj abk abl abm abn abo abp abq abr abs abt abu abv abw abx aby abz ",
            "aca acb acc acd ace acf acg ach aci acj ack acl acm acn aco acp acq acr acs act acu acv acw acx acy acz ",
            "ada adb adc add ade adf adg adh adi adj adk adl adm adn ado adp adq adr ads adt adu adv adw adx ady adz ",
            "aea aeb aec aed aee aef aeg aeh aei aej aek ael aem aen aeo aep aeq aer aes aet aeu aev aew aex aey aez ",
            "afa afb afc afd afe aff afg afh afi afj afk afl afm afn afo afp afq afr afs aft afu afv afw afx afy afz ",
            "aga agb agc agd age agf agg agh agi agj agk agl agm agn ago agp agq agr ags agt agu agv agw agx agy agz ",
            "aha ahb ahc ahd ahe ahf ahg ahh ahi ahj ahk ahl ahm ahn aho ahp ahq ahr ahs aht ahu ahv ahw ahx ahy ahz ",
            "aia aib aic aid aie aif aig aih"
        );

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, long, 3);

        (,,, string memory question) = multiverse.queries(0);
        assertEq(question, long);
    }

    /*//////////////////////////////////////////////////////////////
                        CREATE QUERY - REVERTS
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_OutcomesZero() public {
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", 0);
    }

    function test_RevertWhen_OutcomesOne() public {
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", 1);
    }

    function test_RevertWhen_OutcomesAboveMax() public {
        // 255 == INVALID and is the only value above MAX_OUTCOMES (254).
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", 255);
    }

    function test_RevertWhen_InvalidUniverse() public {
        // Universe id 1 was never initialized (repToken == address(0)).
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.createQuery(1, "q", 3);
    }

    function test_RevertWhen_InsufficientAllowance() public {
        address noAllowance = makeAddr("noAllowance");
        // Fund with REP but do NOT approve the multiverse to spend it.
        underlying.mint(noAllowance, USER_REP_BALANCE);
        vm.startPrank(noAllowance);
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, USER_REP_BALANCE);
        vm.expectRevert();
        multiverse.createQuery(GENESIS_UID, "q", 3);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientBalance() public {
        address noBalance = makeAddr("noBalance");
        // Approve the multiverse but never acquire any REP.
        vm.startPrank(noBalance);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.expectRevert();
        multiverse.createQuery(GENESIS_UID, "q", 3);
        vm.stopPrank();
    }
}
