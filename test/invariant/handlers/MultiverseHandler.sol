// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

/// @notice Handler for stateful fuzzing of createQuery, report, resolve, and claim. Wraps calls
///         with bounded inputs.
/// @dev    The invariant runner picks random functions from this contract. The handler holds
///         REP and is the query creator; reports, resolves, and claims come from a bounded set of
///         funded actors. Infeasible actions (no queries yet, window expired or still open,
///         fork-level stake, unaffordable stake, nothing claimable) return early instead of
///         reverting; the profiles run with `fail_on_revert = true`, so any revert that slips
///         past the guards fails the run by design.
///         Stake fields are ghosted per stake at report time (amount, reporter, outcome):
///         settlement zeroes `stake.amount` in storage, so invariants compare against the ghosts
///         and treat a zeroed amount as valid only for a settled (ghostClaimed) stake.
///         Payout AMOUNTS are measured as observed balance deltas (the same convention as
///         ghostTotalFees) rather than recomputed, so the invariants stay independent from the
///         contract's payout math — but each settlement action checks the payout against
///         formula-independent bounds (recipient identity, fee ceiling, stake floor/ladder
///         ceiling), so a mispay cannot be silently absorbed into the ghosts.
///         Time is tracked in `ghostNow` and only moved via `vm.warp`: with via-ir the optimizer
///         may cache `block.timestamp`, so it is never re-read after a warp.
contract MultiverseHandler is CommonBase, StdCheats, StdUtils {
    // Fee bounds. The floor keeps the charged fee nonzero so that it doesn't
    // trip ZeroFee. The ceiling keeps ladders long (~11 doublings to the fork clamp) while
    // cumulative fees stay negligible against the handler's balance.
    uint256 internal constant MIN_FEE = 1e3;
    uint256 internal constant MAX_FEE = 1e21;
    // Per-call time-advance ceiling: two appeal windows, so runs explore both live and
    // expired reporting/appeal windows without instantly killing every query.
    uint256 internal constant MAX_TIME_ADVANCE = 2 days;

    Multiverse public immutable MULTIVERSE;
    MockQueryFeeController public immutable FEE_CTL;
    ILituusRep public immutable REP;
    uint248 public immutable GENESIS_UID;

    // Reporters/resolvers/claimants the handler pranks as; funded and approved by the invariant test.
    address[] internal actors;

    // Ghost variables, observable from invariants.
    uint256 public ghostQueriesCreated;
    uint256 public ghostTotalFees;
    uint256 public ghostTotalStaked;
    uint256 public ghostTotalPaidOut;
    uint256 public ghostTotalBurned;
    uint256 public ghostReportsPlaced;
    uint256 public ghostResolvesPerformed;
    uint256 public ghostClaimsPerformed;
    uint256 public ghostNow;
    mapping(uint256 queryId => uint256) public ghostQueryCreateTime;
    mapping(uint256 queryId => uint256) public ghostQueryFee;
    mapping(uint256 queryId => uint256) public ghostStakeCount;
    mapping(uint256 queryId => uint256) public ghostQueryStaked;
    mapping(uint256 queryId => uint8) public ghostLastOutcome;
    // Per-stake records, written at report time (storage amounts zero on settlement, so the
    // original amount, owner, and outcome must survive here).
    mapping(uint256 queryId => mapping(uint256 stakeIndex => uint256)) public ghostStakeAmount;
    mapping(uint256 queryId => mapping(uint256 stakeIndex => address)) public ghostStakeReporter;
    mapping(uint256 queryId => mapping(uint256 stakeIndex => uint8)) public ghostStakeOutcome;
    mapping(uint256 queryId => bool) public ghostResolved;
    mapping(uint256 queryId => uint8) public ghostResolvedOutcome;
    mapping(uint256 queryId => mapping(uint256 stakeIndex => bool)) public ghostClaimed;
    mapping(address actor => uint256) public ghostActorStaked;
    mapping(address actor => uint256) public ghostActorReceived;

    constructor(
        Multiverse multiverse_,
        MockQueryFeeController feeCtl_,
        ILituusRep rep_,
        uint248 genesisUid_,
        address[] memory actors_
    ) {
        MULTIVERSE = multiverse_;
        FEE_CTL = feeCtl_;
        REP = rep_;
        GENESIS_UID = genesisUid_;
        actors = actors_;
        ghostNow = block.timestamp;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    /// @notice Create a query with a valid, bounded outcome count and fee.
    function createQuery(uint256 outcomeSeed, uint256 feeSeed) external {
        uint8 outcomes = uint8(bound(outcomeSeed, MULTIVERSE.MIN_OUTCOMES(), MULTIVERSE.MAX_OUTCOMES()));
        uint256 fee = bound(feeSeed, MIN_FEE, MAX_FEE);

        FEE_CTL.setFee(fee);
        uint256 balanceBefore = REP.balanceOf(address(this));
        MULTIVERSE.createQuery(GENESIS_UID, "q", outcomes);
        uint256 chargedFee = balanceBefore - REP.balanceOf(address(this));

        ghostQueryCreateTime[ghostQueriesCreated] = ghostNow;
        ghostQueryFee[ghostQueriesCreated] = chargedFee;
        ++ghostQueriesCreated;
        ghostTotalFees += chargedFee;
    }

    /// @notice Report on an existing query as a random actor, with a valid outcome that differs
    ///         from the previous one. No-ops when no report can land (nothing created yet, the
    ///         query already resolved, the reporting/appeal window expired, the next stake would
    ///         be a fork trigger, or the actor cannot afford the stake).
    function report(uint256 querySeed, uint256 outcomeSeed, uint256 actorSeed) external {
        if (ghostQueriesCreated == 0) return;
        uint256 queryId = bound(querySeed, 0, ghostQueriesCreated - 1);
        if (ghostResolved[queryId]) return;

        // A stake clamped up to the fork threshold would make report() revert ForkingNotImplemented.
        (uint256 requiredStake, uint256 forkThreshold) = MULTIVERSE.getNextRequiredStake(GENESIS_UID, queryId);
        if (requiredStake == 0 || requiredStake >= forkThreshold) return;

        // Respect the reporting window for the first report and the appeal window for escalations.
        uint256 stakeCount = ghostStakeCount[queryId];
        if (stakeCount == 0) {
            if (ghostNow > ghostQueryCreateTime[queryId] + MULTIVERSE.THREE_DAYS()) return;
        } else {
            Multiverse.Stake[] memory stakes = MULTIVERSE.getStakes(GENESIS_UID, queryId);
            if (ghostNow > uint256(stakes[stakes.length - 1].time) + MULTIVERSE.ONE_DAY()) return;
        }

        // Pick from the valid outcome set {1..numberOfOutcomes, INVALID}; when escalating, shift
        // once to the next candidate if the pick repeats the previous outcome (the set has at
        // least 3 members, so one shift always suffices).
        (uint8 numberOfOutcomes,,,) = MULTIVERSE.queries(queryId);
        uint256 pick = bound(outcomeSeed, 1, uint256(numberOfOutcomes) + 1);
        uint8 outcome = pick == uint256(numberOfOutcomes) + 1 ? MULTIVERSE.INVALID() : uint8(pick);
        if (stakeCount != 0 && outcome == ghostLastOutcome[queryId]) {
            pick = pick % (uint256(numberOfOutcomes) + 1) + 1;
            outcome = pick == uint256(numberOfOutcomes) + 1 ? MULTIVERSE.INVALID() : uint8(pick);
        }

        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        // Affordability guard: a pathological sequence of deep ladders could outrun an actor's
        // balance; with fail_on_revert on, that must be a no-op, not a transfer revert.
        if (REP.balanceOf(actor) < requiredStake) return;

        vm.prank(actor);
        MULTIVERSE.report(GENESIS_UID, queryId, outcome);

        ++ghostReportsPlaced;
        ghostStakeAmount[queryId][stakeCount] = requiredStake;
        ghostStakeReporter[queryId][stakeCount] = actor;
        ghostStakeOutcome[queryId][stakeCount] = outcome;
        ++ghostStakeCount[queryId];
        ghostLastOutcome[queryId] = outcome;
        ghostQueryStaked[queryId] += requiredStake;
        ghostActorStaked[actor] += requiredStake;
        ghostTotalStaked += requiredStake;
    }

    /// @notice Resolve an existing query as a random actor. No-ops when nothing is resolvable
    ///         (nothing created yet, already resolved, or the relevant window — reporting for an
    ///         unreported query, appeal for a reported one — has not passed yet).
    /// @dev    Payout amounts are observed, not recomputed, but they are checked against
    ///         formula-independent bounds: resolve burns the whole profit (the loser burn plus
    ///         the unpaid fee remainder), so the supply drop plus the transfer outflow must equal
    ///         exactly the fee, plus the losing stakes / BURN_DIVIDER, plus the auto-settled
    ///         bond — whatever the reward ramp paid. Only the expected recipient — the first
    ///         reporter of the winning outcome on the stakes path, the pranked resolver on the
    ///         INVALID path — may gain REP.
    function resolveQuery(uint256 querySeed, uint256 actorSeed) external {
        if (ghostQueriesCreated == 0) return;
        uint256 queryId = bound(querySeed, 0, ghostQueriesCreated - 1);
        if (ghostResolved[queryId]) return;

        // resolve() requires the window end to be strictly in the past.
        uint256 stakeCount = ghostStakeCount[queryId];
        if (stakeCount == 0) {
            if (ghostNow <= ghostQueryCreateTime[queryId] + MULTIVERSE.THREE_DAYS()) return;
        } else {
            Multiverse.Stake[] memory stakes = MULTIVERSE.getStakes(GENESIS_UID, queryId);
            if (ghostNow <= uint256(stakes[stakes.length - 1].time) + MULTIVERSE.ONE_DAY()) return;
        }

        uint8 winnerOutcome = stakeCount == 0 ? MULTIVERSE.INVALID() : ghostLastOutcome[queryId];
        // The expected reward recipient: the protocol pays the fee reward to whoever FIRST
        // reported the eventually-winning outcome; an unreported query pays the resolver instead.
        address resolver = actors[bound(actorSeed, 0, actors.length - 1)];
        address expectedRecipient = resolver;
        if (stakeCount > 0) {
            for (uint256 i = 0; i < stakeCount; ++i) {
                if (ghostStakeOutcome[queryId][i] == winnerOutcome) {
                    expectedRecipient = ghostStakeReporter[queryId][i];
                    break;
                }
            }
        }

        uint256 multiverseBalanceBefore = REP.balanceOf(address(MULTIVERSE));
        uint256 supplyBefore = REP.totalSupply();
        uint256[] memory actorBalancesBefore = _actorBalances();

        vm.prank(resolver);
        MULTIVERSE.resolve(GENESIS_UID, queryId);

        // resolve() burns the whole profit from the multiverse balance, so the balance drop
        // splits into destroyed shares (the supply drop) and transfers to recipients. The reward
        // ramp only moves value between the two streams: whatever the fee did not pay out was
        // burned, so their sum is pinned exactly, independently of the ramp.
        uint256 burned = supplyBefore - REP.totalSupply();
        uint256 expectedLosers;
        for (uint256 i = 0; i < stakeCount; ++i) {
            if (ghostStakeOutcome[queryId][i] != winnerOutcome) {
                expectedLosers += ghostStakeAmount[queryId][i];
            }
        }
        ghostTotalBurned += burned;

        uint256 paidOut = multiverseBalanceBefore - REP.balanceOf(address(MULTIVERSE)) - burned;
        uint256 autoSettledBond = stakeCount == 1 ? ghostStakeAmount[queryId][0] : 0;
        require(
            burned + paidOut
                == ghostQueryFee[queryId] + expectedLosers / MULTIVERSE.BURN_DIVIDER() + autoSettledBond,
            "resolveQuery: burn + outflow mismatch"
        );

        // Only the expected recipient may gain REP; everyone else's balance must be untouched.
        for (uint256 i = 0; i < actors.length; ++i) {
            uint256 balanceAfter = REP.balanceOf(actors[i]);
            if (actors[i] == expectedRecipient) {
                require(balanceAfter == actorBalancesBefore[i] + paidOut, "resolveQuery: recipient mismatch");
                ghostActorReceived[actors[i]] += paidOut;
            } else {
                require(balanceAfter == actorBalancesBefore[i], "resolveQuery: unexpected inflow");
            }
        }
        ghostTotalPaidOut += paidOut;

        ++ghostResolvesPerformed;
        ghostResolved[queryId] = true;
        ghostResolvedOutcome[queryId] = winnerOutcome;

        // Observe settlement through the contract's own settled flag (amount == 0) instead of
        // mirroring resolve()'s internals. ONLY a single-stake
        // query is auto-settled.
        uint256 settledCount;
        if (stakeCount > 0) {
            Multiverse.Stake[] memory stakesAfter = MULTIVERSE.getStakes(GENESIS_UID, queryId);
            for (uint256 i = 0; i < stakeCount; ++i) {
                if (stakesAfter[i].amount == 0) {
                    ghostClaimed[queryId][i] = true;
                    ++ghostClaimsPerformed;
                    ++settledCount;
                }
            }
        }
        require(settledCount == (stakeCount == 1 ? 1 : 0), "resolveQuery: unexpected auto-settlement");
    }

    /// @notice Claim a winning, still-unclaimed stake on a resolved query, pranked as the stake's
    ///         own reporter. No-ops when the query is unresolved or nothing is claimable on it.
    /// @dev    The payout amount is observed, but bounded independently of the payout formula:
    ///         a winner gets at least their stake back and never more than the query's whole
    ///         ladder, so a zero/under/over-payment regression reverts here.
    function claimStake(uint256 querySeed, uint256 stakeSeed) external {
        if (ghostQueriesCreated == 0) return;
        uint256 queryId = bound(querySeed, 0, ghostQueriesCreated - 1);
        if (!ghostResolved[queryId]) return;

        uint256 stakeCount = ghostStakeCount[queryId];
        if (stakeCount == 0) return;

        // Scan the per-stake ghosts for a winning, unclaimed stake, starting from a random
        // offset for coverage.
        uint8 winnerOutcome = ghostResolvedOutcome[queryId];
        uint256 offset = bound(stakeSeed, 0, stakeCount - 1);
        for (uint256 i = 0; i < stakeCount; ++i) {
            uint256 stakeIndex = (offset + i) % stakeCount;
            if (ghostClaimed[queryId][stakeIndex]) continue;
            if (ghostStakeOutcome[queryId][stakeIndex] != winnerOutcome) continue;

            address owner = ghostStakeReporter[queryId][stakeIndex];
            uint256 ownerBalanceBefore = REP.balanceOf(owner);
            vm.prank(owner);
            MULTIVERSE.claim(GENESIS_UID, queryId, stakeIndex);

            uint256 payout = REP.balanceOf(owner) - ownerBalanceBefore;
            require(payout >= ghostStakeAmount[queryId][stakeIndex], "claimStake: winner paid less than the stake");
            require(payout <= ghostQueryStaked[queryId], "claimStake: payout exceeds the query's ladder");
            ghostTotalPaidOut += payout;
            ghostActorReceived[owner] += payout;
            ghostClaimed[queryId][stakeIndex] = true;
            ++ghostClaimsPerformed;
            return;
        }
    }

    /// @notice Advance time by a bounded amount, so windows open and expire during a run.
    function advanceTime(uint256 deltaSeed) external {
        uint256 delta = bound(deltaSeed, 1, MAX_TIME_ADVANCE);
        ghostNow += delta;
        vm.warp(ghostNow);
    }

    /// @dev Snapshot of every actor's REP balance, index-aligned with `actors`.
    function _actorBalances() internal view returns (uint256[] memory balances) {
        balances = new uint256[](actors.length);
        for (uint256 i = 0; i < actors.length; ++i) {
            balances[i] = REP.balanceOf(actors[i]);
        }
    }
}
