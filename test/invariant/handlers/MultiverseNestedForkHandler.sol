// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MultiverseHelpers } from "src/libraries/MultiverseHelpers.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { UniverseReader, UniverseView } from "../../utils/UniverseReader.sol";

/// @notice Handler for stateful fuzzing of tips across a nested fork: tipping and resolving the tracked queries in
///         child1, forking child1, spawning its children, and tipping and resolving the same queries there.
/// @dev    The invariant test hands over a child1 that inherited tipped queries from a forked genesis, plus one
///         query created in child1. Nobody reports the tracked queries: each is tipped while its window is open
///         and resolved INVALID once it expired, which pays its resolver every tip it is owed. Every action
///         guards its own preconditions and no-ops instead of reverting, so the suite runs with
///         `fail_on_revert = true`: a payout the tip aggregate could not cover would fail the run. Time is
///         tracked in `ghostNow` and only moved via `vm.warp`: with via-ir the optimizer may cache
///         `block.timestamp`, so it is never re-read after a warp.
contract MultiverseNestedForkHandler is CommonBase, StdCheats, StdUtils {
    // Per-call time-advance ceiling: two of these cross a reporting window.
    uint256 internal constant MAX_TIME_ADVANCE = 2 days;
    // Per-call tip ceiling: about what child1 inherited.
    uint256 internal constant MAX_TIP = 3 ether;
    // What both sides of child1's forking ladder need at most: an outcome's cap, with room to spare.
    uint256 internal constant LADDER_BALANCE = 70 ether;
    // The grandchild wREP each actor gets at a spawn, wrapped from the Zoltar level, to tip with.
    uint256 internal constant GRANDCHILD_FUNDING = 50 ether;
    string internal constant QUESTION = "John Doe's pet?[CAT,DOG,SHARK]";
    uint8 internal constant NUMBER_OF_OUTCOMES = 3;
    uint256 public constant INVALID_OUTCOME = type(uint256).max;

    Multiverse public immutable MULTIVERSE;
    MockZoltar public immutable ZOLTAR;
    uint248 public immutable CHILD1;

    address[] internal actors;
    // The tipped queries followed through child1's fork: those inherited from the genesis, then one of child1's.
    uint256[] internal queryIds;
    // The outcome set of child1's forking query: 1..3 and INVALID.
    uint256[] internal outcomes;

    uint256 public ghostNow;
    // When each tracked query became reportable in child1.
    mapping(uint256 queryId => uint256) public ghostClockInChild1;
    mapping(uint256 queryId => bool) public ghostResolvedInChild1;
    // child1's fork: when it happened, the aggregate child1 held going into it (the forking query's tips
    // included), its tip cap (0.1% of the wREP wrapped in it), the forking query's tips, and what each query
    // still open was owed there.
    bool public ghostChild1Forked;
    uint256 public ghostChild1ForkTime;
    uint256 public ghostHeldAtChild1Fork;
    uint256 public ghostCapAtChild1Fork;
    uint256 public ghostForkTipAtChild1Fork;
    mapping(uint256 queryId => uint256) public ghostOwedAtChild1Fork;
    mapping(uint256 outcome => bool) public ghostSpawned;
    mapping(uint256 outcome => mapping(uint256 queryId => bool)) public ghostResolvedInGrandchild;

    constructor(
        Multiverse multiverse_,
        MockZoltar zoltar_,
        uint248 child1_,
        uint256[] memory queryIds_,
        uint256[] memory clocksInChild1_,
        address[] memory actors_
    ) {
        MULTIVERSE = multiverse_;
        ZOLTAR = zoltar_;
        CHILD1 = child1_;
        queryIds = queryIds_;
        for (uint256 i = 0; i < queryIds_.length; ++i) {
            ghostClockInChild1[queryIds_[i]] = clocksInChild1_[i];
        }
        actors = actors_;
        outcomes = [1, 2, 3, INVALID_OUTCOME];
        ghostNow = block.timestamp;
    }

    function queriesLength() external view returns (uint256) {
        return queryIds.length;
    }

    function queryAt(uint256 index) external view returns (uint256) {
        return queryIds[index];
    }

    function outcomesLength() external view returns (uint256) {
        return outcomes.length;
    }

    function outcomeAt(uint256 index) external view returns (uint256) {
        return outcomes[index];
    }

    function grandchildOf(uint256 outcome) public view returns (uint248) {
        return ZOLTAR.getChildUniverseId(CHILD1, outcome);
    }

    /// @notice Move time forward by a bounded amount.
    function warp(uint256 seed) external {
        ghostNow += bound(seed, 0, MAX_TIME_ADVANCE);
        vm.warp(ghostNow);
    }

    /// @notice Tip a random tracked query in child1, as a random actor. No-ops once child1 forked, once the query
    ///         was resolved there or its window there closed.
    function tipInChild1(uint256 actorSeed, uint256 querySeed, uint256 amountSeed) external {
        if (ghostChild1Forked) return;
        uint256 queryId = queryIds[bound(querySeed, 0, queryIds.length - 1)];
        if (ghostResolvedInChild1[queryId]) return;
        if (ghostNow > ghostClockInChild1[queryId] + MULTIVERSE.REPORTING_PERIOD()) return;
        _tip(CHILD1, actorSeed, queryId, amountSeed);
    }

    /// @notice Resolve a random tracked query in child1 once its window there expired: nobody reported it, so it
    ///         resolves INVALID and pays the resolver. No-ops once child1 forked or the query was resolved.
    function resolveInChild1(uint256 actorSeed, uint256 querySeed) external {
        if (ghostChild1Forked) return;
        uint256 queryId = queryIds[bound(querySeed, 0, queryIds.length - 1)];
        if (ghostResolvedInChild1[queryId]) return;
        uint256 deadline = ghostClockInChild1[queryId] + MULTIVERSE.REPORTING_PERIOD();
        if (ghostNow <= deadline) return;
        _resolveExpired(CHILD1, actorSeed, queryId, deadline);
        ghostResolvedInChild1[queryId] = true;
    }

    /// @notice Fork child1, once, on a fresh query two actors escalate to the cap in one block. actors[2] tips it
    ///         a random amount first, zero included, so its tips share child1's cap with the tracked queries'.
    ///         Pins what child1 held, its tip cap, the forking query's tips and what each tracked query still open
    ///         was owed there, for the fork and its children to be checked against.
    function forkChild1(uint256 forkTipSeed) external {
        if (ghostChild1Forked) return;
        ILituusRep repToken = MULTIVERSE.repTokenOf(CHILD1);
        if (repToken.balanceOf(actors[0]) < LADDER_BALANCE || repToken.balanceOf(actors[1]) < LADDER_BALANCE) return;

        for (uint256 i = 0; i < queryIds.length; ++i) {
            ghostOwedAtChild1Fork[queryIds[i]] = MULTIVERSE.getTips(CHILD1, queryIds[i]);
        }
        // The forking query's fee, its tip and the ladder's stakes only move wREP around: the supply the fork tx
        // measures the cap on is the supply now.
        ghostCapAtChild1Fork = repToken.totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;

        uint256 forkQueryId = MULTIVERSE.queryCount();
        vm.startPrank(actors[0]);
        repToken.approve(address(MULTIVERSE), type(uint256).max);
        MULTIVERSE.createQuery(CHILD1, QUESTION, NUMBER_OF_OUTCOMES);
        vm.stopPrank();
        uint256 tipperBalance = repToken.balanceOf(actors[2]);
        uint256 forkTip = bound(forkTipSeed, 0, tipperBalance < MAX_TIP ? tipperBalance : MAX_TIP);
        if (forkTip != 0) {
            vm.startPrank(actors[2]);
            repToken.approve(address(MULTIVERSE), forkTip);
            MULTIVERSE.tip(CHILD1, forkQueryId, forkTip);
            vm.stopPrank();
        }
        ghostForkTipAtChild1Fork = forkTip;
        ghostHeldAtChild1Fork = UniverseReader.read(MULTIVERSE, CHILD1).totalTips;
        vm.prank(actors[1]);
        repToken.approve(address(MULTIVERSE), type(uint256).max);
        for (uint256 i = 0;; ++i) {
            vm.prank(actors[i % 2]);
            MULTIVERSE.report(CHILD1, forkQueryId, i % 2 == 0 ? 1 : 2);
            if (UniverseReader.read(MULTIVERSE, CHILD1).universeState == Multiverse.UniverseState.Migration) break;
        }
        ghostChild1Forked = true;
        ghostChild1ForkTime = ghostNow;
    }

    /// @notice Spawn the child of a random outcome of child1's fork. Each tracked query must be owed there what
    ///         child1 owed it, cut by carried / held, and the forking query's first reporter of the outcome must
    ///         be paid its tips cut the same way. The grandchild's aggregate must be what child1 carries less those
    ///         tips. The actors get some of its wREP, wrapped from the Zoltar level, to tip with.
    function spawnGrandchild(uint256 outcomeSeed) external {
        if (!ghostChild1Forked) return;
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (ghostSpawned[outcome]) return;

        MULTIVERSE.spawnChildUniverse(CHILD1, outcome);
        ghostSpawned[outcome] = true;

        uint248 grandchild = grandchildOf(outcome);
        UniverseView memory child1 = UniverseReader.read(MULTIVERSE, CHILD1);
        uint256 forkCut =
            child1.totalTips == 0 ? 0 : Math.mulDiv(ghostForkTipAtChild1Fork, child1.carriedTips, child1.totalTips);
        require(
            UniverseReader.read(MULTIVERSE, grandchild).totalTips == child1.carriedTips - forkCut,
            "spawn: grandchild aggregate differs from what child1 carries less the forking query's tips"
        );
        // actors[0] reported outcome 1 first and actors[1] outcome 2, in the forking query's creation block: no fee
        // share, so the reporter's whole balance in the new vault is the cut tips. Nobody reported 3 or INVALID.
        if (outcome == 1 || outcome == 2) {
            require(
                MULTIVERSE.repTokenOf(grandchild).balanceOf(actors[outcome - 1]) == forkCut,
                "spawn: forking query's reporter not paid its cut tips"
            );
        }
        for (uint256 i = 0; i < queryIds.length; ++i) {
            uint256 queryId = queryIds[i];
            uint256 expected = ghostResolvedInChild1[queryId]
                ? 0
                : Math.mulDiv(ghostOwedAtChild1Fork[queryId], child1.carriedTips, child1.totalTips);
            require(MULTIVERSE.getTips(grandchild, queryId) == expected, "spawn: carried tips are not the cut ones");
        }

        ILituusRep repToken = MULTIVERSE.repTokenOf(grandchild);
        MockERC20 zoltarRep = MockERC20(address(ZOLTAR.childRepTokens(grandchild)));
        for (uint256 a = 0; a < actors.length; ++a) {
            zoltarRep.mint(actors[a], GRANDCHILD_FUNDING);
            vm.startPrank(actors[a]);
            zoltarRep.approve(address(repToken), GRANDCHILD_FUNDING);
            MULTIVERSE.wrap(grandchild, GRANDCHILD_FUNDING, 0);
            vm.stopPrank();
        }
    }

    /// @notice Tip a random tracked query in a random spawned grandchild. No-ops once the query was resolved
    ///         there or in child1, or its window there closed (it restarted at child1's fork).
    function tipInGrandchild(uint256 actorSeed, uint256 outcomeSeed, uint256 querySeed, uint256 amountSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        uint256 queryId = queryIds[bound(querySeed, 0, queryIds.length - 1)];
        if (ghostResolvedInChild1[queryId] || ghostResolvedInGrandchild[outcome][queryId]) return;
        if (ghostNow > ghostChild1ForkTime + MULTIVERSE.REPORTING_PERIOD()) return;
        _tip(grandchildOf(outcome), actorSeed, queryId, amountSeed);
    }

    /// @notice Resolve a random tracked query in a random spawned grandchild once its window there expired.
    function resolveInGrandchild(uint256 actorSeed, uint256 outcomeSeed, uint256 querySeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        uint256 queryId = queryIds[bound(querySeed, 0, queryIds.length - 1)];
        if (ghostResolvedInChild1[queryId] || ghostResolvedInGrandchild[outcome][queryId]) return;
        uint256 deadline = ghostChild1ForkTime + MULTIVERSE.REPORTING_PERIOD();
        if (ghostNow <= deadline) return;
        _resolveExpired(grandchildOf(outcome), actorSeed, queryId, deadline);
        ghostResolvedInGrandchild[outcome][queryId] = true;
    }

    /// @dev Tips `queryId` in `universeId` as a random actor holding that universe's wREP: the query is owed the
    ///      tip on top of what it was owed, and the aggregate grows by it.
    function _tip(uint248 universeId, uint256 actorSeed, uint256 queryId, uint256 amountSeed) internal {
        ILituusRep repToken = MULTIVERSE.repTokenOf(universeId);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = repToken.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance < MAX_TIP ? balance : MAX_TIP);
        uint256 owedBefore = MULTIVERSE.getTips(universeId, queryId);
        uint256 aggregateBefore = UniverseReader.read(MULTIVERSE, universeId).totalTips;

        vm.startPrank(actor);
        repToken.approve(address(MULTIVERSE), amount);
        MULTIVERSE.tip(universeId, queryId, amount);
        vm.stopPrank();

        require(MULTIVERSE.getTips(universeId, queryId) == owedBefore + amount, "tip: the query is not owed the tip");
        require(
            UniverseReader.read(MULTIVERSE, universeId).totalTips == aggregateBefore + amount,
            "tip: the aggregate did not grow by the tip"
        );
    }

    /// @dev Resolves the expired, unreported `queryId` in `universeId` as a random actor: the resolver gets the
    ///      fee share ramped from the deadline plus every tip the query was owed, in full, out of the aggregate.
    function _resolveExpired(uint248 universeId, uint256 actorSeed, uint256 queryId, uint256 deadline) internal {
        ILituusRep repToken = MULTIVERSE.repTokenOf(universeId);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 tips = MULTIVERSE.getTips(universeId, queryId);
        uint256 aggregateBefore = UniverseReader.read(MULTIVERSE, universeId).totalTips;
        (,, uint256 fee,,) = MULTIVERSE.queries(queryId);
        uint256 period = MULTIVERSE.REPORTING_PERIOD();
        uint256 elapsed = ghostNow - deadline;
        uint256 feeShare = elapsed >= period ? fee : fee * elapsed / period;

        uint256 balanceBefore = repToken.balanceOf(actor);
        vm.prank(actor);
        MULTIVERSE.resolve(universeId, queryId);

        require(
            repToken.balanceOf(actor) - balanceBefore == feeShare + tips,
            "resolve: the resolver is not paid the fee share plus the tips owed"
        );
        require(
            UniverseReader.read(MULTIVERSE, universeId).totalTips == aggregateBefore - tips,
            "resolve: the aggregate did not drop by the tips paid"
        );
        require(MULTIVERSE.getTips(universeId, queryId) == 0, "resolve: tips still owed");
    }
}
