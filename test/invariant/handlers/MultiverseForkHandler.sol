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
///         redeeming query tokens where they landed, moving time, and resolving the fork.
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

    constructor(
        Multiverse multiverse_,
        QueryTokenizer tokenizer_,
        MockZoltar zoltar_,
        ILituusRep rep_,
        uint248 genesisUid_,
        uint256 forkQueryId_,
        uint256 resolvedQueryId_,
        uint256 openQueryId_,
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
        (,, forkTime,,,,,,,,,,) = MULTIVERSE.universes(GENESIS_UID);
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

    /// @notice Spawn the child of a random outcome. No-ops once spawned, after the window, or after
    ///         the fork resolved.
    function spawn(uint256 outcomeSeed) external {
        uint256 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (ghostSpawned[outcome] || ghostResolved || !_windowOpen()) return;

        MULTIVERSE.spawnChildUniverse(GENESIS_UID, outcome);
        ghostSpawned[outcome] = true;
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
        (,,, uint96 totalStaked,,,, uint256 winner,) = MULTIVERSE.queryResolutions(GENESIS_UID, RESOLVED_QUERY_ID);
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
        (,,,,, ghostWinner,,,,,,,) = MULTIVERSE.universes(GENESIS_UID);
    }
}
