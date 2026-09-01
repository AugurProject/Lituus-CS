// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { QueryTokenizerFixtures } from "./QueryTokenizer.fixtures.sol";

/// @notice The Multiverse surface the QueryTokenizer depends on: createQueryFromTokenizer and
///         getMintPricing.
contract MultiverseTokenizerTest is QueryTokenizerFixtures {
    /*//////////////////////////////////////////////////////////////
                      CREATE QUERY FROM TOKENIZER
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_CreateQueryFromTokenizer_NotTokenizer() public {
        vm.prank(user);
        vm.expectRevert(Multiverse.OnlyQueryTokenizer.selector);
        multiverse.createQueryFromTokenizer(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES, 1 ether, user);
    }

    function test_RevertWhen_CreateQueryFromTokenizer_UniverseNotExisting() public {
        vm.prank(address(tokenizer));
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.createQueryFromTokenizer(
            GENESIS_UID + 1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES, 1 ether, user
        );
    }

    function test_RevertWhen_CreateQueryFromTokenizer_TooFewOutcomes() public {
        vm.prank(address(tokenizer));
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQueryFromTokenizer(GENESIS_UID, DEFAULT_QUESTION, 1, 1 ether, user);
    }

    function test_RevertWhen_CreateQueryFromTokenizer_TooManyOutcomes() public {
        vm.prank(address(tokenizer));
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQueryFromTokenizer(GENESIS_UID, DEFAULT_QUESTION, 255, 1 ether, user);
    }

    function test_RevertWhen_CreateQueryFromTokenizer_QueryTooLong() public {
        string memory tooLong = string(new bytes(uint256(multiverse.MAX_QUERY_LENGTH()) + 1));

        vm.prank(address(tokenizer));
        vm.expectRevert(Multiverse.QueryTooLong.selector);
        multiverse.createQueryFromTokenizer(GENESIS_UID, tooLong, DEFAULT_NUMBER_OF_OUTCOMES, 1 ether, user);
    }

    function test_RevertWhen_CreateQueryFromTokenizer_ZeroFee() public {
        vm.prank(address(tokenizer));
        vm.expectRevert(Multiverse.ZeroFee.selector);
        multiverse.createQueryFromTokenizer(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES, 0, user);
    }

    function test_CreateQueryFromTokenizer_RecordsQueryWithoutPullingRep() public {
        // Push model: the fee is expected to have been transferred beforehand, so the call itself
        // must record the query verbatim and move no REP.
        uint256 queryId = multiverse.queryCount();
        uint256 multiverseRepBefore = genesisRep.balanceOf(address(multiverse));

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryCreated(bystander, queryId, GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.prank(address(tokenizer));
        multiverse.createQueryFromTokenizer(
            GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES, 5 ether, bystander
        );

        assertEq(multiverse.queryCount(), queryId + 1);
        (uint8 numberOfOutcomes, uint248 originUniverse, uint256 fee, string memory question) =
            multiverse.queries(queryId);
        assertEq(numberOfOutcomes, DEFAULT_NUMBER_OF_OUTCOMES);
        assertEq(originUniverse, GENESIS_UID);
        assertEq(fee, 5 ether);
        assertEq(question, DEFAULT_QUESTION);

        (uint48 queryCreateTime, uint8 outcome,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(queryCreateTime, uint48(vm.getBlockTimestamp()));
        assertEq(outcome, multiverse.UNRESOLVED());

        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseRepBefore);
    }

    function test_CreateQueryFromTokenizer_FeeStoredVerbatimAboveCap() public {
        // Direct queries cap the fee at half the fork threshold; the tokenizer path must not.
        uint256 fee = HALF_FORK_THRESHOLD + 5 ether;

        vm.prank(address(tokenizer));
        multiverse.createQueryFromTokenizer(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES, fee, user);

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, fee);
    }

    function test_CreateQueryFromTokenizer_SharesQueryCounterWithDirectPath() public {
        // Interleaved direct and tokenizer creations share the same counter: sequential ids,
        // each record intact.
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "direct-0", 2);

        vm.prank(address(tokenizer));
        multiverse.createQueryFromTokenizer(GENESIS_UID, "tokenizer-1", 4, 2 ether, bystander);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "direct-2", 5);

        assertEq(multiverse.queryCount(), 3);
        (uint8 outcomes0,,, string memory question0) = multiverse.queries(0);
        (uint8 outcomes1,, uint256 fee1, string memory question1) = multiverse.queries(1);
        (uint8 outcomes2,,, string memory question2) = multiverse.queries(2);
        assertEq(question0, "direct-0");
        assertEq(outcomes0, 2);
        assertEq(question1, "tokenizer-1");
        assertEq(outcomes1, 4);
        assertEq(fee1, 2 ether);
        assertEq(question2, "direct-2");
        assertEq(outcomes2, 5);
    }

    function test_CreateQueryFromTokenizer_CountsDemandVolume() public {
        uint256 previewBefore = _previewUncappedFee();

        vm.prank(address(tokenizer));
        multiverse.createQueryFromTokenizer(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES, 1 ether, user);

        assertGt(_previewUncappedFee(), previewBefore);
    }

    /*//////////////////////////////////////////////////////////////
                       DIRECT CREATE QUERY FEE CAP
    //////////////////////////////////////////////////////////////*/
    function test_CreateQuery_CapsFeeAtHalfForkThreshold() public {
        // Regression for the cap semantics this branch relies on: the direct path still caps.
        feeCtl.setFee(100 ether); // preview 100 > cap 75

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, HALF_FORK_THRESHOLD);
    }

    /*//////////////////////////////////////////////////////////////
                          GET MINT PRICING
    //////////////////////////////////////////////////////////////*/
    function test_GetMintPricing_FeeMatchesChargedFee() public {
        // Same block, below the cap: the preview equals exactly what createQuery then charges.
        uint256 preview = _previewUncappedFee();

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        (,, uint256 chargedFee,) = multiverse.queries(0);
        assertEq(chargedFee, preview);

        // Idle two windows plus a partial-window offset: the view must catch the 60-day cache up
        // in memory (only the mutating path persists it) and interpolate the partial window —
        // parity must survive a stale cache.
        vm.warp(vm.getBlockTimestamp() + 2 * multiverse.THREE_DAYS() + 1 days);
        preview = _previewUncappedFee();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        (,, chargedFee,) = multiverse.queries(1);
        assertEq(chargedFee, preview);

        // Idle past 20 windows: the cache roll switches to the full recompute branch.
        vm.warp(vm.getBlockTimestamp() + 21 * multiverse.THREE_DAYS() + 36 hours);
        preview = _previewUncappedFee();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        (,, chargedFee,) = multiverse.queries(2);
        assertEq(chargedFee, preview);
    }

    function test_GetMintPricing_FeeIsUncappedAndCapIsHalfThreshold() public {
        feeCtl.setFee(100 ether);

        // Clean state: demand modifier is exactly 1.0, so the uncapped fee is the raw base fee,
        // above the cap direct queries would apply; the returned cap is half the fork threshold
        // and the repToken is the universe's wREP.
        (uint256 uncappedFee, uint256 queryFeeCap, ILituusRep repToken) = multiverse.getMintPricing(GENESIS_UID);
        assertEq(uncappedFee, 100 ether);
        assertGt(uncappedFee, HALF_FORK_THRESHOLD);
        assertEq(queryFeeCap, HALF_FORK_THRESHOLD);
        assertEq(address(repToken), address(genesisRep));
    }

    function test_GetMintPricing_HasNoSideEffects() public view {
        uint256 first = _previewUncappedFee();
        uint256 second = _previewUncappedFee();
        uint256 third = _previewUncappedFee();

        assertEq(first, second);
        assertEq(second, third);
    }

    function test_RevertWhen_GetMintPricing_UniverseNotExisting() public {
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.getMintPricing(GENESIS_UID + 1);
    }
}
