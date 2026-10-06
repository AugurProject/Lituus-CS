// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";

/// @notice Handler for stateful fuzzing of a forked universe: spawning children, migrating wallet wREP,
///         claiming the forking query's stakes into the children, moving time, and resolving the fork.
/// @dev    The invariant test forks the genesis on a query the actors staked on before handing over to
///         the runner. Every action guards its own preconditions (window, state, child spawned,
///         balance, stake left) and no-ops instead of reverting, so the suite can run with
///         `fail_on_revert = true`. Time is tracked in `ghostNow` and only moved via `vm.warp`: with
///         via-ir the optimizer may cache `block.timestamp`, so it is never re-read after a warp.
///         The vault rate is 1 throughout (nothing ever burns in the parent after the fork and the
///         children never resolve anything here), so parent shares, child shares and REP coincide.
contract MultiverseForkHandler is CommonBase, StdCheats, StdUtils {
    // Per-call time-advance ceiling: a few of these cross the 60-day window within one run.
    uint256 internal constant MAX_TIME_ADVANCE = 10 days;

    Multiverse public immutable MULTIVERSE;
    MockZoltar public immutable ZOLTAR;
    ILituusRep public immutable REP;
    uint248 public immutable GENESIS_UID;
    uint256 public immutable FORK_QUERY_ID;
    uint8 public constant INVALID_OUTCOME = 255;

    address[] internal actors;
    // The forking query's outcome set: 1..3 and INVALID.
    uint8[] internal outcomes;

    // Ghost variables, observable from invariants.
    uint256 public ghostWalletMigrated;
    uint256 public ghostPrincipalClaimed;
    uint256 public ghostNow;
    bool public ghostResolved;
    uint248 public ghostWinner;
    mapping(uint8 outcome => bool) public ghostSpawned;
    mapping(uint8 outcome => uint256) public ghostMigratedInto;

    constructor(
        Multiverse multiverse_,
        MockZoltar zoltar_,
        ILituusRep rep_,
        uint248 genesisUid_,
        uint256 forkQueryId_,
        address[] memory actors_
    ) {
        MULTIVERSE = multiverse_;
        ZOLTAR = zoltar_;
        REP = rep_;
        GENESIS_UID = genesisUid_;
        FORK_QUERY_ID = forkQueryId_;
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

    function outcomeAt(uint256 index) external view returns (uint8) {
        return outcomes[index];
    }

    function childOf(uint8 outcome) public view returns (uint248) {
        return ZOLTAR.getChildUniverseId(GENESIS_UID, outcome);
    }

    function _forkTime() internal view returns (uint48 forkTime) {
        (,, forkTime,,,,,,,,,,) = MULTIVERSE.universes(GENESIS_UID);
    }

    /// @dev The genesis has no parent, so its migration window is exactly 60 days from the fork.
    function _windowOpen() internal view returns (bool) {
        return ghostNow < uint256(_forkTime()) + MULTIVERSE.SIXTY_DAYS();
    }

    /// @notice Move time forward by a bounded amount.
    function warp(uint256 seed) external {
        ghostNow += bound(seed, 0, MAX_TIME_ADVANCE);
        vm.warp(ghostNow);
    }

    /// @notice Spawn the child of a random outcome. No-ops once spawned, after the window, or after
    ///         the fork resolved.
    function spawn(uint256 outcomeSeed) external {
        uint8 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (ghostSpawned[outcome] || ghostResolved || !_windowOpen()) return;

        MULTIVERSE.spawnChildUniverse(GENESIS_UID, outcome);
        ghostSpawned[outcome] = true;
    }

    /// @notice Migrate a random slice of a random actor's wallet wREP into a random spawned child. Once
    ///         the window closed or the fork resolved the migration must be rejected.
    function migrate(uint256 actorSeed, uint256 outcomeSeed, uint256 amountSeed) external {
        uint8 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
        if (!ghostSpawned[outcome]) return;
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 balance = REP.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = bound(amountSeed, 1, balance);
        if (ghostResolved || !_windowOpen()) {
            vm.prank(actor);
            try MULTIVERSE.migrate(GENESIS_UID, outcome, shares) {
                revert("migrate: landed after the migration window");
            } catch { }
            return;
        }

        vm.prank(actor);
        MULTIVERSE.migrate(GENESIS_UID, outcome, shares);

        ghostWalletMigrated += shares;
        ghostMigratedInto[outcome] += shares;
    }

    /// @notice Claim a random actor's stake on a random outcome into that outcome's child. Once the
    ///         window closed or the fork resolved the claim must be rejected: it is a counted vote.
    function migrateStake(uint256 actorSeed, uint256 outcomeSeed) external {
        uint8 outcome = outcomes[bound(outcomeSeed, 0, outcomes.length - 1)];
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
        require(childRep.balanceOf(actor) - balanceBefore >= amount, "migrateStake: paid below the stake");
        require(MULTIVERSE.getUserStake(GENESIS_UID, FORK_QUERY_ID, actor, outcome) == 0, "migrateStake: not settled");

        ghostPrincipalClaimed += amount;
        ghostMigratedInto[outcome] += amount;
    }

    /// @notice Resolve the fork once the window closed. No-ops before that or if already resolved.
    function advance() external {
        if (ghostResolved || _windowOpen()) return;

        MULTIVERSE.advanceForkState(GENESIS_UID);

        ghostResolved = true;
        (,,,,, ghostWinner,,,,,,,) = MULTIVERSE.universes(GENESIS_UID);
    }
}
