// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { Multiverse } from "src/Multiverse.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IQueryToken } from "src/interfaces/IQueryToken.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";

/// @notice Handler for stateful fuzzing of a forked universe: spawning children, migrating wallet wREP and
///         query tokens, settling the forking query's stakes and the other queries' stakes into the children,
///         redeeming query tokens where they landed, tipping, reporting and resolving the carried query in the
///         children, moving time, and resolving the fork.
/// @dev    The invariant test forks the genesis on a query the actors staked on, next to a query resolved
///         before the fork and one left open, before handing over to the runner. Every action guards its
///         own preconditions (window, state, child spawned, balance, stake left) and no-ops instead of
///         reverting, so the suite can run with `fail_on_revert = true`. Time is tracked in `ghostNow` and
///         only moved via `vm.warp`: with via-ir the optimizer may cache `block.timestamp`, so it is never
///         re-read after a warp. The parent's rate is above 1 (a resolution burned before the fork) and
///         frozen since, so votes are kept in assets, record checks in shares, and payouts are checked
///         through the same two conversions the contract makes.
contract MultiverseForkHandler is CommonBase, StdCheats, StdUtils {
    // Per-call time-advance ceiling: a few of these cross the MIGRATION_DURATION within one run.
    uint256 internal constant MAX_TIME_ADVANCE = 10 days;
    // Smallest wallet migration: with the rate above 1, dust rounds to zero child shares and the wrap reverts.
    uint256 internal constant MIN_MIGRATION = 1 gwei;
    // What a redeemed child query token is spent on.
    string internal constant QUESTION = "John Doe's pet?[CAT,DOG,SHARK]";
    uint8 internal constant NUMBER_OF_OUTCOMES = 3;

    Multiverse public immutable MULTIVERSE;
    QueryTokenizer public immutable TOKENIZER;
    MockZoltar public immutable ZOLTAR;
    ILituusRep public immutable REP;
    uint248 public immutable GENESIS_UID;
    uint256 public immutable FORK_QUERY_ID;
    uint256 public immutable RESOLVED_QUERY_ID;
    uint256 public immutable OPEN_QUERY_ID;
    // Left unreported and tipped at the fork: its tips carry into every child as the child's tip pool.
    uint256 public immutable TIPPED_QUERY_ID;
    uint256 public constant INVALID_OUTCOME = type(uint256).max;

    address[] internal actors;
    // The forking query's outcome set: 1..3 and INVALID.
    uint256[] internal outcomes;

    // Ghost variables, observable from invariants. Votes are in assets, like the contract's counters; what
    // left each record is in shares, like the records.
    uint256 public ghostWalletMigrated;
    uint256 public ghostPrincipalClaimed;
    uint256 public ghostStakeVotes;
    uint256 public ghostForkStakesClaimed;
    uint256 public ghostResolvedStakesClaimed;
    uint256 public ghostOpenStakesRefunded;
    uint256 public ghostNow;
    bool public ghostResolved;
    uint248 public ghostWinner;
    mapping(uint256 outcome => bool) public ghostSpawned;
    mapping(uint256 outcome => uint256) public ghostMigratedInto;
    // Query tokens: whole tokens that left the parent and what they took out of its pool (parent shares), per
    // child what arrived in its pool and what redemptions paid out of it (child shares), tokens redeemed.
    uint256 public ghostTokensMigrated;
    uint256 public ghostParentPoolMigrated;
    uint256 public ghostTokensRedeemed;
    mapping(uint256 outcome => uint256) public ghostTokensMigratedInto;
    mapping(uint256 outcome => uint256) public ghostChildPoolIn;
    mapping(uint256 outcome => uint256) public ghostChildPoolOut;
    // Tips: per child, the tip pool its spawn copied in (child shares), the tips placed on the carried query
    // there, and whether that query was resolved there.
    mapping(uint256 outcome => uint256) public ghostTipsCopied;
    mapping(uint256 outcome => uint256) public ghostChildTips;
    mapping(uint256 outcome => bool) public ghostTippedResolved;
    // The carried query's first (and only) report in a child: who placed it, when, and the stake it took.
    mapping(uint256 outcome => address) public ghostChildReporter;
    mapping(uint256 outcome => uint256) public ghostChildReportTime;
    mapping(uint256 outcome => uint256) public ghostChildStake;

    constructor(
        Multiverse multiverse_,
        QueryTokenizer tokenizer_,
        MockZoltar zoltar_,
        ILituusRep rep_,
        uint248 genesisUid_,
        uint256 forkQueryId_,
        uint256 resolvedQueryId_,
        uint256 openQueryId_,
        uint256 tippedQueryId_,
        address[] memory actors_
    ) {
        MULTIVERSE = multiverse_;
        TOKENIZER = tokenizer_;
        ZOLTAR = zoltar_;
        REP = rep_;
        GENESIS_UID = genesisUid_;
        FORK_QUERY_ID = forkQueryId_;
        RESOLVED_QUERY_ID = resolvedQueryId_;
        OPEN_QUERY_ID = openQueryId_;
        TIPPED_QUERY_ID = tippedQueryId_;
        actors = actors_;
        outcomes = [1, 2, 3, INVALID_OUTCOME];
        ghostNow = block.timestamp;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function outcomesLength() external view returns (uint256) {
        return outcomes.length;
    }

    function outcomeAt(uint256 index) external view returns (uint256) {
        return outcomes[index];
    }

    function childOf(uint256 outcome) public view returns (uint248) {
        return ZOLTAR.getChildUniverseId(GENESIS_UID, outcome);
    }

    function _forkTime() internal view returns (uint48 forkTime) {
        (,, forkTime,,,,,,,,,,,) = MULTIVERSE.universes(GENESIS_UID);
    }

    /// @dev The genesis has no parent, so its migration window is exactly MIGRATION_DURATION from the fork.
    function _windowOpen() internal view returns (bool) {
        return ghostNow < uint256(_forkTime()) + MULTIVERSE.MIGRATION_DURATION();
    }

    /// @dev The child wREP a payout of `parentShares` turns into, through the contract's two conversions.
    function _childSharesFor(ILituusRep childRep, uint256 parentShares) internal view returns (uint256) {
        return childRep.convertToShares(REP.convertToAssets(parentShares));
    }

    /// @notice Move time forward by a bounded amount.
    function warp(uint256 seed) external {
        ghostNow += bound(seed, 0, MAX_TIME_ADVANCE);
        vm.warp(ghostNow);
    }

    /// @dev The tips a query holds in a universe's record, in that universe's shares.
    function _recordTips(uint248 universeId, uint256 queryId) internal view returns (uint128 tips) {
        (,,,,,,,,, tips) = MULTIVERSE.queryResolutions(universeId, queryId);
    }

    function _totalTips(uint248 universeId) internal view returns (uint128 totalTips) {
        (,,,,,,,,,,,,, totalTips) = MULTIVERSE.universes(universeId);
    }

    /// @dev The fee share the forking query's first reporter of `outcome` earned: the ramp over the reporting
    ///      window, from the query's clock to that reporter's first stake.
    function _forkReporterFeeShare(uint256 outcome) internal view returns (uint256) {
        (,, uint256 fee,,) = MULTIVERSE.queries(FORK_QUERY_ID);
        (uint48 queryCreateTime,,,,,,,,,) = MULTIVERSE.queryResolutions(GENESIS_UID, FORK_QUERY_ID);
        uint256 elapsed =
            MULTIVERSE.getOutcomeStakes(GENESIS_UID, FORK_QUERY_ID, outcome).firstReportTime - queryCreateTime;
        uint256 period = MULTIVERSE.REPORTING_PERIOD();
        return elapsed >= period ? fee : fee * elapsed / period;
    }

    /// @notice Spawn the child of a random outcome. No-ops once spawned, after the window, or after
    ///         the fork resolved.
    /// @dev    The spawn pays the forking query's first reporter of the outcome its fee share and the full tips,
    ///         drawn fresh from the parked balance (nobody, for an outcome nobody staked on), and copies the
    ///         parent's tip pool, which holds only the carried query's tips, into the child.
    function spawn(uint256 outcomeSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (ghostSpawned[outcome] || ghostResolved || !_windowOpen()) return;

        MULTIVERSE.spawnChildUniverse(GENESIS_UID, outcome);
        ghostSpawned[outcome] = true;

        uint248 childId = childOf(outcome);
        ILituusRep childRep = MULTIVERSE.repTokenOf(childId);
        address reporter = MULTIVERSE.getOutcomeStakes(GENESIS_UID, FORK_QUERY_ID, outcome).firstReporter;
        if (reporter != address(0)) {
            // A brand-new vault: the reporter's whole balance is the spawn payout.
            uint256 expected =
                _childSharesFor(childRep, _forkReporterFeeShare(outcome) + _recordTips(GENESIS_UID, FORK_QUERY_ID));
            require(childRep.balanceOf(reporter) == expected, "spawn: fork reporter paid other than fee share + tips");
        }

        uint256 copied = _totalTips(childId);
        require(copied <= _totalTips(GENESIS_UID), "spawn: child tip pool above the parent's");
        ghostTipsCopied[outcome] = copied;
    }

    /// @notice Tip the carried query in a random spawned child, as a random actor holding that child's wREP.
    ///         No-ops once the query's window there closed (it restarted at the fork) or it was resolved there.
    function tipInChild(uint256 actorSeed, uint256 outcomeSeed, uint256 amountSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome] || ghostTippedResolved[outcome]) return;
        // Tipping closes with the first report.
        if (ghostChildReporter[outcome] != address(0)) return;
        if (ghostNow > uint256(_forkTime()) + MULTIVERSE.REPORTING_PERIOD()) return;
        uint248 childId = childOf(outcome);
        ILituusRep childRep = MULTIVERSE.repTokenOf(childId);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = childRep.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);

        vm.startPrank(actor);
        childRep.approve(address(MULTIVERSE), amount);
        MULTIVERSE.tip(childId, TIPPED_QUERY_ID, amount);
        vm.stopPrank();

        ghostChildTips[outcome] += amount;
    }

    /// @notice Place the carried query's first report in a random spawned child, as a random actor holding that
    ///         child's wREP, on a random outcome. No-ops once reported or resolved there, after its window there
    ///         closed, or when the actor cannot afford the stake. The report must keep the record's tips: the
    ///         carried ones plus those placed there, whether a tip anchored the record first or this report does.
    function reportTippedInChild(uint256 actorSeed, uint256 outcomeSeed, uint256 choiceSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome] || ghostTippedResolved[outcome]) return;
        if (ghostChildReporter[outcome] != address(0)) return;
        if (ghostNow > uint256(_forkTime()) + MULTIVERSE.REPORTING_PERIOD()) return;
        uint248 childId = childOf(outcome);
        ILituusRep childRep = MULTIVERSE.repTokenOf(childId);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 choice = bound(choiceSeed, 1, NUMBER_OF_OUTCOMES);
        uint256 stake = MULTIVERSE.getNextRequiredStake(childId, TIPPED_QUERY_ID, choice);
        if (childRep.balanceOf(actor) < stake) return;

        vm.startPrank(actor);
        childRep.approve(address(MULTIVERSE), stake);
        MULTIVERSE.report(childId, TIPPED_QUERY_ID, choice);
        vm.stopPrank();

        require(
            _recordTips(childId, TIPPED_QUERY_ID)
                == _recordTips(GENESIS_UID, TIPPED_QUERY_ID) + ghostChildTips[outcome],
            "reportTippedInChild: record lost tips"
        );
        ghostChildReporter[outcome] = actor;
        ghostChildReportTime[outcome] = ghostNow;
        ghostChildStake[outcome] = stake;
    }

    /// @notice Resolve the carried query in a random spawned child, as a random actor. Reported: once the appeal
    ///         window passed, the sole reporter gets the stake back, the fee share ramped from the query's clock
    ///         to the report, and every tip the child pays (the carried ones and those placed there); the
    ///         resolver gets nothing. Unreported: once the window expired, it resolves INVALID and the resolver
    ///         gets the fee share ramped from the deadline plus every tip.
    function resolveTippedInChild(uint256 actorSeed, uint256 outcomeSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome] || ghostTippedResolved[outcome]) return;
        uint256 period = MULTIVERSE.REPORTING_PERIOD();
        uint256 clock = uint256(_forkTime());
        address reporter = ghostChildReporter[outcome];
        if (reporter == address(0)
                ? ghostNow <= clock + period
                : ghostNow <= ghostChildReportTime[outcome] + MULTIVERSE.APPEAL_PERIOD()) {
            return;
        }
        uint248 childId = childOf(outcome);
        ILituusRep childRep = MULTIVERSE.repTokenOf(childId);
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        (,, uint256 fee,,) = MULTIVERSE.queries(TIPPED_QUERY_ID);
        uint256 elapsed = reporter == address(0) ? ghostNow - (clock + period) : ghostChildReportTime[outcome] - clock;
        uint256 feeShare = elapsed >= period ? fee : fee * elapsed / period;
        uint256 tips = _recordTips(GENESIS_UID, TIPPED_QUERY_ID) + ghostChildTips[outcome];
        address recipient = reporter == address(0) ? actor : reporter;
        uint256 expected = feeShare + tips + (reporter == address(0) ? 0 : ghostChildStake[outcome]);

        uint256 recipientBefore = childRep.balanceOf(recipient);
        uint256 actorBefore = childRep.balanceOf(actor);
        vm.prank(actor);
        MULTIVERSE.resolve(childId, TIPPED_QUERY_ID);

        require(childRep.balanceOf(recipient) - recipientBefore == expected, "resolveTippedInChild: payout mismatch");
        if (actor != recipient) {
            require(childRep.balanceOf(actor) == actorBefore, "resolveTippedInChild: resolver paid");
        }
        ghostTippedResolved[outcome] = true;
    }

    /// @notice Migrate a random slice of a random actor's wallet wREP into a random spawned child. Once
    ///         the window closed or the fork resolved the migration must be rejected.
    function migrate(uint256 actorSeed, uint256 outcomeSeed, uint256 amountSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = REP.balanceOf(actor);
        if (balance < MIN_MIGRATION) return;
        uint256 shares = bound(amountSeed, MIN_MIGRATION, balance);
        if (ghostResolved || !_windowOpen()) {
            vm.prank(actor);
            try MULTIVERSE.migrate(GENESIS_UID, outcome, shares) {
                revert("migrate: landed after the migration window");
            } catch { }
            return;
        }

        vm.prank(actor);
        MULTIVERSE.migrate(GENESIS_UID, outcome, shares);

        uint256 assets = REP.convertToAssets(shares);
        ghostWalletMigrated += assets;
        ghostMigratedInto[outcome] += assets;
    }

    /// @notice Claim a random actor's stake on the forking query, on a random outcome, into that outcome's
    ///         child. Once the window closed or the fork resolved the claim must be rejected: it is a
    ///         counted vote.
    function migrateStake(uint256 actorSeed, uint256 outcomeSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 amount = MULTIVERSE.getUserStake(GENESIS_UID, FORK_QUERY_ID, actor, outcome);
        if (amount == 0) return;
        if (ghostResolved || !_windowOpen()) {
            vm.prank(actor);
            try MULTIVERSE.migrateStake(GENESIS_UID, FORK_QUERY_ID, outcome, outcome) {
                revert("migrateStake: landed after the migration window");
            } catch { }
            return;
        }

        ILituusRep childRep = MULTIVERSE.repTokenOf(childOf(outcome));
        uint256 balanceBefore = childRep.balanceOf(actor);
        vm.prank(actor);
        MULTIVERSE.migrateStake(GENESIS_UID, FORK_QUERY_ID, outcome, outcome);

        // A winner never gets less than its stake back, and the stake is settled.
        require(
            childRep.balanceOf(actor) - balanceBefore >= _childSharesFor(childRep, amount),
            "migrateStake: paid below the stake"
        );
        require(MULTIVERSE.getUserStake(GENESIS_UID, FORK_QUERY_ID, actor, outcome) == 0, "migrateStake: not settled");

        uint256 principal = REP.convertToAssets(amount);
        ghostPrincipalClaimed += principal;
        ghostForkStakesClaimed += amount;
        ghostMigratedInto[outcome] += principal;
    }

    /// @notice Claim a random actor's stake on the query resolved before the fork into a random spawned
    ///         child. Only the winning outcome's stake is paid, with the payout claim() would have made;
    ///         the whole payout votes. Rejected like every lane once the window closed or the fork resolved.
    function migrateResolvedStake(uint256 actorSeed, uint256 outcomeSeed, uint256 childSeed) external {
        uint256 childOutcome = outcomes[bound(childSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[childOutcome]) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        uint256 amount = MULTIVERSE.getUserStake(GENESIS_UID, RESOLVED_QUERY_ID, actor, outcome);
        if (amount == 0) return;
        (,,, uint96 totalStaked,,,, uint256 winner,,) = MULTIVERSE.queryResolutions(GENESIS_UID, RESOLVED_QUERY_ID);
        if (ghostResolved || !_windowOpen() || outcome != winner) {
            vm.prank(actor);
            try MULTIVERSE.migrateStake(GENESIS_UID, RESOLVED_QUERY_ID, outcome, childOutcome) {
                revert("migrateResolvedStake: paid a loser or landed after the migration window");
            } catch { }
            return;
        }

        uint256 winnerStaked = MULTIVERSE.getOutcomeStakes(GENESIS_UID, RESOLVED_QUERY_ID, winner).totalOutcomeStaked;
        uint256 losers = uint256(totalStaked) - winnerStaked;
        uint256 payout = amount + amount * (losers - losers / MULTIVERSE.BURN_DIVIDER()) / winnerStaked;

        ILituusRep childRep = MULTIVERSE.repTokenOf(childOf(childOutcome));
        uint256 balanceBefore = childRep.balanceOf(actor);
        vm.prank(actor);
        MULTIVERSE.migrateStake(GENESIS_UID, RESOLVED_QUERY_ID, outcome, childOutcome);

        require(
            childRep.balanceOf(actor) - balanceBefore == _childSharesFor(childRep, payout),
            "migrateResolvedStake: payout differs from claim()"
        );
        require(
            MULTIVERSE.getUserStake(GENESIS_UID, RESOLVED_QUERY_ID, actor, outcome) == 0,
            "migrateResolvedStake: not settled"
        );

        uint256 vote = REP.convertToAssets(payout);
        ghostStakeVotes += vote;
        ghostResolvedStakesClaimed += amount;
        ghostMigratedInto[childOutcome] += vote;
    }

    /// @notice Refund a random actor's stake on the query left open at the fork into a random spawned child:
    ///         the stake comes back as it was and votes with its amount. Rejected like every lane once the
    ///         window closed or the fork resolved.
    function migrateRefund(uint256 actorSeed, uint256 outcomeSeed, uint256 childSeed) external {
        uint256 childOutcome = outcomes[bound(childSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[childOutcome]) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        uint256 amount = MULTIVERSE.getUserStake(GENESIS_UID, OPEN_QUERY_ID, actor, outcome);
        if (amount == 0) return;
        if (ghostResolved || !_windowOpen()) {
            vm.prank(actor);
            try MULTIVERSE.migrateStake(GENESIS_UID, OPEN_QUERY_ID, outcome, childOutcome) {
                revert("migrateRefund: landed after the migration window");
            } catch { }
            return;
        }

        ILituusRep childRep = MULTIVERSE.repTokenOf(childOf(childOutcome));
        uint256 balanceBefore = childRep.balanceOf(actor);
        vm.prank(actor);
        MULTIVERSE.migrateStake(GENESIS_UID, OPEN_QUERY_ID, outcome, childOutcome);

        require(
            childRep.balanceOf(actor) - balanceBefore == _childSharesFor(childRep, amount),
            "migrateRefund: refund differs from the stake"
        );
        require(MULTIVERSE.getUserStake(GENESIS_UID, OPEN_QUERY_ID, actor, outcome) == 0, "migrateRefund: not settled");

        uint256 vote = REP.convertToAssets(amount);
        ghostStakeVotes += vote;
        ghostOpenStakesRefunded += amount;
        ghostMigratedInto[childOutcome] += vote;
    }

    /// @notice Migrate some of a random actor's genesis query tokens into a random spawned child. The pool
    ///         share they take along is a wallet migration out of the tokenizer, counted like one. Rejected
    ///         like every counted lane once the window closed or the fork resolved.
    function migrateQueryTokens(uint256 actorSeed, uint256 outcomeSeed, uint256 amountSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        IQueryToken parentToken = TOKENIZER.token(GENESIS_UID);
        uint256 oneQuery = TOKENIZER.ONE_QUERY();
        uint256 held = parentToken.balanceOf(actor) / oneQuery;
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        if (ghostResolved || !_windowOpen()) {
            vm.prank(actor);
            try TOKENIZER.migrate(GENESIS_UID, outcome, amount) {
                revert("migrateQueryTokens: landed after the migration window");
            } catch { }
            return;
        }

        uint248 childId = childOf(outcome);
        uint256 migratedRep = TOKENIZER.pooledRep(GENESIS_UID) * amount / (parentToken.totalSupply() / oneQuery);
        uint256 childPoolBefore = TOKENIZER.pooledRep(childId);
        vm.prank(actor);
        TOKENIZER.migrate(GENESIS_UID, outcome, amount);

        // The child pool grows by the share converted through the two vaults, and the child tokens are minted.
        uint256 arrived = TOKENIZER.pooledRep(childId) - childPoolBefore;
        require(
            arrived == _childSharesFor(MULTIVERSE.repTokenOf(childId), migratedRep),
            "migrateQueryTokens: child pool differs from the share"
        );

        uint256 assets = REP.convertToAssets(migratedRep);
        ghostWalletMigrated += assets;
        ghostMigratedInto[outcome] += assets;
        ghostTokensMigrated += amount;
        ghostParentPoolMigrated += migratedRep;
        ghostTokensMigratedInto[outcome] += amount;
        ghostChildPoolIn[outcome] += arrived;
    }

    /// @notice Redeem one of a random actor's child query tokens into a query in that child, at that pool's
    ///         average. The children stay Active throughout, so this lane never closes.
    function redeemChildToken(uint256 actorSeed, uint256 outcomeSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        uint248 childId = childOf(outcome);
        IQueryToken childToken = TOKENIZER.token(childId);
        if (address(childToken) == address(0)) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 oneQuery = TOKENIZER.ONE_QUERY();
        if (childToken.balanceOf(actor) < oneQuery) return;

        uint256 price = TOKENIZER.pooledRep(childId) / (childToken.totalSupply() / oneQuery);
        vm.prank(actor);
        TOKENIZER.redeem(childId, QUESTION, NUMBER_OF_OUTCOMES);

        ghostTokensRedeemed += 1;
        ghostChildPoolOut[outcome] += price;
    }

    /// @notice Resolve the fork once the window closed. No-ops before that or if already resolved.
    function advance() external {
        if (ghostResolved || _windowOpen()) return;

        MULTIVERSE.advanceForkState(GENESIS_UID);

        ghostResolved = true;
        (,,,,, ghostWinner,,,,,,,,) = MULTIVERSE.universes(GENESIS_UID);
    }
}
