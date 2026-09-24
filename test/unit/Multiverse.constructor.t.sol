// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { LituusRep } from "src/LituusRep.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

contract MultiverseConstructorTest is MultiverseFixtures {
    function test_RevertWhen_ZoltarIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(IZoltar(address(0)), GENESIS_UID, feeCtl, queryTokenizerStub);
    }

    function test_RevertWhen_QueryFeeControllerIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(zoltar, GENESIS_UID, IQueryFeeController(address(0)), queryTokenizerStub);
    }

    function test_RevertWhen_QueryTokenizerIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(zoltar, GENESIS_UID, feeCtl, address(0));
    }

    function test_Constructor_SetsImmutables() public {
        uint256 deployTime = START_TIME + 5 days;
        vm.warp(deployTime);
        Multiverse newMultiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl, queryTokenizerStub);

        assertEq(address(newMultiverse.ZOLTAR()), address(zoltar));
        assertEq(newMultiverse.GENESIS_UNIVERSE_ID(), GENESIS_UID);
        assertEq(address(newMultiverse.QUERY_FEE_CONTROLLER()), address(feeCtl));
        assertEq(newMultiverse.GENESIS_TIMESTAMP(), deployTime);
        assertEq(address(newMultiverse.QUERY_TOKENIZER()), address(queryTokenizerStub));
    }

    function test_Constructor_InitializesGenesisUniverse() public {
        Multiverse newMultiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl, queryTokenizerStub);

        (
            ILituusRep repToken,
            Multiverse.UniverseState universeState,
            uint48 forkTime,
            bool isCanonical,
            uint248 parent,
            uint248 favoriteChild,
            bool isLituusFork,
            uint128 totalMigratedIn,
            uint128 maxMigratedOut,
            uint256 forkQuery,
            uint256 totalMigratedOut,
            uint256 totalQueryFees,
            uint256 unmigratedSupply
        ) = newMultiverse.universes(GENESIS_UID);

        assertTrue(address(repToken) != address(0));
        assertEq(uint8(universeState), uint8(Multiverse.UniverseState.Active));
        // forkTime = the moment the universe's own fork split it; 0 until the genesis forks.
        assertEq(forkTime, 0);
        assertTrue(isCanonical);
        assertEq(parent, 0);
        assertEq(favoriteChild, 0);
        assertFalse(isLituusFork);
        assertEq(totalMigratedIn, 0);
        assertEq(maxMigratedOut, 0);
        assertEq(forkQuery, 0);
        // totalMigratedOut stays 0 until the universe forks and migration begins.
        assertEq(totalMigratedOut, 0);
        // No queries yet, no parked pot.
        assertEq(totalQueryFees, 0);
        assertEq(unmigratedSupply, 0);
        // The canonical timeline starts at the genesis.
        assertEq(newMultiverse.canonicalHeir(), GENESIS_UID);
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
        assertEq(multiverse.UNRESOLVED(), 0);
        assertEq(multiverse.INVALID(), 255);
        assertEq(multiverse.THREE_DAYS(), 3 days);
        assertEq(multiverse.ONE_DAY(), 1 days);
        assertEq(multiverse.BURN_DIVIDER(), 5);
    }
}
