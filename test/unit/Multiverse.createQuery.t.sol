// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

contract MultiverseCreateQueryTest is MultiverseFixtures {
    /*//////////////////////////////////////////////////////////////
                              CREATE QUERY
    //////////////////////////////////////////////////////////////*/
    function test_CreateQuery_HappyPath() public {
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        uint256 queryId = _createDefaultQuery();

        assertEq(queryId, 0);
        assertEq(multiverse.queryCount(), 1);

        (uint8 numberOfOutcomes, uint248 originUniverse, uint256 fee, string memory question) =
            multiverse.queries(queryId);
        assertEq(numberOfOutcomes, DEFAULT_NUMBER_OF_OUTCOMES);
        assertEq(originUniverse, GENESIS_UID);
        assertEq(fee, DEFAULT_FEE);
        assertEq(question, DEFAULT_QUESTION);

        (uint48 queryCreateTime, uint8 outcome) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(queryCreateTime, uint48(block.timestamp));
        assertEq(outcome, multiverse.UNRESOLVED());

        assertEq(genesisRep.balanceOf(address(multiverse)), DEFAULT_FEE);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - DEFAULT_FEE);
    }

    function test_CreateQuery_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryCreated(user, 0, GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        _createDefaultQuery();
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

    function test_CreateQuery_MultipleQueries() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q0", 3);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q1", 4);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q2", 5);

        assertEq(multiverse.queryCount(), 3);

        (uint8 n0,,, string memory q0) = multiverse.queries(0);
        (uint8 n1,,, string memory q1) = multiverse.queries(1);
        (uint8 n2,,, string memory q2) = multiverse.queries(2);

        assertEq(n0, 3);
        assertEq(q0, "q0");
        assertEq(n1, 4);
        assertEq(q1, "q1");
        assertEq(n2, 5);
        assertEq(q2, "q2");
    }

    function test_CreateQuery_DifferentCallers() public {
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "by user", 3);

        vm.prank(bystander);
        multiverse.createQuery(GENESIS_UID, "by bystander", 4);

        assertEq(multiverse.queryCount(), 2);

        (uint8 n0, uint248 u0,, string memory q0) = multiverse.queries(0);
        (uint8 n1, uint248 u1,, string memory q1) = multiverse.queries(1);
        assertEq(n0, 3);
        assertEq(u0, GENESIS_UID);
        assertEq(q0, "by user");
        assertEq(n1, 4);
        assertEq(u1, GENESIS_UID);
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

    function test_RevertWhen_QuestionTooLong() public {
        // One byte over the limit is the shortest question that must revert.
        bytes memory tooLong = new bytes(uint256(multiverse.MAX_QUERY_LENGTH()) + 1);
        for (uint256 i = 0; i < tooLong.length; i++) {
            tooLong[i] = "a";
        }
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryTooLong.selector);
        multiverse.createQuery(GENESIS_UID, string(tooLong), 3);
    }

    function test_RevertWhen_ZeroFee() public {
        feeCtl.setFee(0);
        vm.prank(user);
        vm.expectRevert(Multiverse.ZeroFee.selector);
        multiverse.createQuery(GENESIS_UID, "free", 3);
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
