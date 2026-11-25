// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { MultiverseHelpers } from "src/libraries/MultiverseHelpers.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";
import { MultiverseNestedForkHandler } from "./handlers/MultiverseNestedForkHandler.sol";
import { UniverseView } from "../utils/UniverseReader.sol";

/// @notice Stateful fuzzing of tips across two fork levels: random sequences of tips and resolutions in a child
///         of a forked genesis, that child's own fork, and tips and resolutions in its children must keep every
///         tip aggregate above what its queries are owed.
/// @dev The genesis is forked in setUp at a rate above 1, with three queries tipped uneven amounts that together
///      exceed its tip cap, so its fork cuts them. child1 is spawned and funded so that its own cap, 0.1% of its
///      supply, sits just above the tips it inherited: its fork carries them whole if nothing more is tipped
///      there, and a tip placed in child1 takes its aggregate above the cap, so its fork cuts every tip a second
///      time. child1 forks on a query of its own tipped a random amount, which shares child1's cap with the
///      others and is paid to its reporters at the spawns. A query created in child1 is tracked next to the three
///      inherited ones. The handler does the rest; the genesis-fork suite covers migration, stakes and query
///      tokens.
contract MultiverseNestedForkInvariantTest is MultiverseDeployFixture {
    uint256 internal constant ACTOR_REP_BALANCE = 1000 ether;
    uint256 internal constant ACTOR_COUNT = 3;
    // What each actor wraps into child1 from the Zoltar level: enough for its forking ladder and for tips, and
    // sized so that 0.1% of child1's supply lands just above the tips it inherited.
    uint256 internal constant CHILD_FUNDING = 1000 ether;
    // The rounding of the cuts leaves at most a wei per tipped query less one at a fork, on top of the dust the
    // fork inherited: 2 wei in child1 (three queries cut by the genesis fork), 6 in its children (those 2, and
    // five queries cut by child1's fork: the four tracked ones and the forking query).
    uint256 internal constant CHILD1_DUST = 2;
    uint256 internal constant GRANDCHILD_DUST = 6;

    MultiverseNestedForkHandler internal handler;
    address[] internal actors;
    uint248 internal child1;
    uint256 internal heldAtGenesisFork;
    uint256 internal carriedAtGenesisFork;

    /// @dev The actors' balances plus a 200 ether pool remainder, like the functional suites.
    function _genesisSupply() internal pure override returns (uint256) {
        return ACTOR_COUNT * ACTOR_REP_BALANCE + 200 ether;
    }

    function setUp() public override {
        super.setUp();

        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
            _fundWithRep(actors[i], ACTOR_REP_BALANCE);
        }
        // An uneven burn: the rate is above 1 from here on, and nothing converts evenly.
        _burnShares(genesisRep, actors[2], 7 ether + 1);

        // Three queries nobody reports, tipped uneven amounts that add up to more than the genesis's tip cap.
        uint256[3] memory tips = [
            uint256(1.123_456_789_012_345_678 ether), 2.345_678_901_234_567_891 ether, 0.987_654_321_098_765_432 ether
        ];
        uint256[] memory queryIds = new uint256[](4);
        uint256[] memory clocksInChild1 = new uint256[](4);
        for (uint256 i = 0; i < 3; ++i) {
            queryIds[i] = multiverse.queryCount();
            vm.prank(actors[0]);
            multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
            vm.prank(actors[1]);
            multiverse.tip(GENESIS_UID, queryIds[i], tips[i]);
            heldAtGenesisFork += tips[i];
        }

        // The genesis forks on a fresh query, in this block: the inherited queries restart here in child1.
        uint256 forkQueryId = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _escalateToFork(GENESIS_UID, forkQueryId, actors[0], actors[1]);
        carriedAtGenesisFork = _universe(GENESIS_UID).carriedTips;
        assertLt(carriedAtGenesisFork, heldAtGenesisFork, "fixture: the genesis fork must cut the tips");

        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        child1 = _childId(GENESIS_UID, OUTCOME_A);
        assertEq(_universe(child1).totalTips, carriedAtGenesisFork);
        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            _wrapFromZoltar(child1, actors[i], CHILD_FUNDING);
        }
        // Both sides of child1's cap are then in reach: about 0.006 REP of new tips take its aggregate above it.
        uint256 child1Cap = multiverse.repTokenOf(child1).totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;
        assertGt(child1Cap, carriedAtGenesisFork, "fixture: child1's cap must be above the tips it inherited");
        assertLt(child1Cap - carriedAtGenesisFork, 0.01 ether, "fixture: child1's cap must be just above them");

        // One query of child1's own, tracked with the inherited ones.
        queryIds[3] = multiverse.queryCount();
        vm.prank(actors[0]);
        multiverse.createQuery(child1, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        for (uint256 i = 0; i < 4; ++i) {
            clocksInChild1[i] = vm.getBlockTimestamp();
        }

        handler = new MultiverseNestedForkHandler(multiverse, zoltar, child1, queryIds, clocksInChild1, actors);
        targetContract(address(handler));
    }

    /// @dev What the tracked queries are owed in `universeId`, all together.
    function _tipsOwedIn(uint248 universeId) internal view returns (uint256 owed) {
        for (uint256 i = 0; i < handler.queriesLength(); ++i) {
            owed += multiverse.getTips(universeId, handler.queryAt(i));
        }
    }

    /// @dev An Active universe's aggregate covers the tips its queries are owed, exceeds them by no more than
    ///      `dust`, and is held by the Multiverse next to the fee aggregate and nothing else: the fees here are
    ///      whole REP, which every copy carries exactly, and nobody stakes on the tracked queries.
    function _assertAggregateCoversTheTipsOwed(uint248 universeId, uint256 dust) internal view {
        UniverseView memory universe = _universe(universeId);
        uint256 owed = _tipsOwedIn(universeId);
        assertLe(owed, universe.totalTips);
        assertLe(universe.totalTips - owed, dust);
        assertEq(
            universe.repToken.balanceOf(address(multiverse)), uint256(universe.totalTips) + universe.totalQueryFees
        );
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev While child1 is Active, the tips its queries are owed never exceed its aggregate.
    function invariant_Child1AggregateCoversTheTipsOwed() public view {
        if (handler.ghostChild1Forked()) return;
        _assertAggregateCoversTheTipsOwed(child1, CHILD1_DUST);
    }

    /// @dev The same in every spawned child of child1, two fork levels below the genesis.
    function invariant_GrandchildAggregatesCoverTheTipsOwed() public view {
        for (uint256 i = 0; i < handler.outcomesLength(); ++i) {
            uint256 outcome = handler.outcomeAt(i);
            if (!handler.ghostSpawned(outcome)) continue;
            _assertAggregateCoversTheTipsOwed(handler.grandchildOf(outcome), GRANDCHILD_DUST);
        }
    }

    /// @dev A forked universe's tips are frozen: its aggregate stays what it held at the fork. It carries that
    ///      aggregate up to its cap, 0.1% of the wREP wrapped in it at the fork, less the wei the rounding to
    ///      whole child shares can take. The cap has no floor: child1 carries no more than its own cap allows,
    ///      whatever it inherited.
    function invariant_ForksCarryWhatTheyHeldUpToTheirCap() public view {
        UniverseView memory genesis = _universe(GENESIS_UID);
        assertEq(genesis.totalTips, heldAtGenesisFork);
        assertEq(genesis.carriedTips, carriedAtGenesisFork);

        UniverseView memory forked = _universe(child1);
        if (!handler.ghostChild1Forked()) {
            assertEq(forked.carriedTips, 0);
            return;
        }
        assertEq(forked.totalTips, handler.ghostHeldAtChild1Fork());
        uint256 cap = handler.ghostCapAtChild1Fork();
        uint256 underCap = forked.totalTips < cap ? forked.totalTips : cap;
        assertLe(forked.carriedTips, underCap);
        assertGe(uint256(forked.carriedTips) + 1, underCap);
        // A forked universe owes nothing itself.
        assertEq(_tipsOwedIn(child1), 0);
    }
}
