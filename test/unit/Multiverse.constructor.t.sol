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
            Multiverse.UniverseState universeState,
            uint48 forkTime,
            uint16 forkDepth,
            bool isCanonical,
            uint248 parent,
            uint248 favoriteChild,
            uint248 heir,
            bytes32 history,
            uint256 forkQuery,
            uint256 supplyBeforeFork,
            address queryTokenizer,
            uint8 forkOutcome,
            bool isLituusFork
        ) = newMultiverse.universes(GENESIS_UID);

        assertTrue(address(repToken) != address(0));
        assertEq(uint8(universeState), uint8(Multiverse.UniverseState.Active));
        assertEq(forkTime, uint48(block.timestamp));
        assertEq(forkDepth, 0);
        assertTrue(isCanonical);
        assertEq(parent, 0);
        assertEq(favoriteChild, 0);
        assertEq(heir, 0);
        assertEq(history, bytes32(0));
        assertEq(forkQuery, 0);
        assertEq(supplyBeforeFork, expectedSupply);
        assertEq(queryTokenizer, address(0));
        assertEq(forkOutcome, 0);
        assertFalse(isLituusFork);
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
}
