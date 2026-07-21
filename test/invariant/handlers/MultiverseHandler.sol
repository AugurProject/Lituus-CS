// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

/// @notice Handler for stateful fuzzing of createQuery and report. Wraps calls with bounded inputs.
/// @dev    The invariant runner picks random functions from this contract. The handler holds
///         REP and is the query creator; reports come from a bounded set of funded actors.
///         Infeasible actions (no queries yet, window expired, fork-level stake) return early
///         instead of reverting, so ghost variables only move on successful calls.
///         Time is tracked in `ghostNow` and only moved via `vm.warp`: with via-ir the optimizer
///         may cache `block.timestamp`, so it is never re-read after a warp.
contract MultiverseHandler is CommonBase, StdCheats, StdUtils {
    // Per-call fee ceiling, small relative to the handler's REP balance so cumulative fees
    // over an entire run never exhaust it.
    uint256 internal constant MAX_FEE = 1e24;
    // Per-call time-advance ceiling: two appeal windows, so runs explore both live and
    // expired reporting/appeal windows without instantly killing every query.
    uint256 internal constant MAX_TIME_ADVANCE = 2 days;

    Multiverse public immutable MULTIVERSE;
    MockQueryFeeController public immutable FEE_CTL;
    ILituusRep public immutable REP;
    uint248 public immutable GENESIS_UID;

    // Reporters the handler pranks as; funded and approved by the invariant test.
    address[] internal actors;

    // Ghost variables, observable from invariants.
    uint256 public ghostQueriesCreated;
    uint256 public ghostTotalFees;
    uint256 public ghostTotalStaked;
    uint256 public ghostReportsPlaced;
    uint256 public ghostNow;
    mapping(uint256 queryId => uint256) public ghostQueryCreateTime;
    mapping(uint256 queryId => uint256) public ghostStakeCount;
    mapping(uint256 queryId => uint256) public ghostQueryStaked;
    mapping(uint256 queryId => uint8) public ghostLastOutcome;
    mapping(address actor => uint256) public ghostActorStaked;

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
        uint256 fee = bound(feeSeed, 0, MAX_FEE);

        FEE_CTL.setFee(fee);
        uint256 balanceBefore = REP.balanceOf(address(this));
        MULTIVERSE.createQuery(GENESIS_UID, "q", outcomes);

        ghostQueryCreateTime[ghostQueriesCreated] = ghostNow;
        ++ghostQueriesCreated;
        ghostTotalFees += balanceBefore - REP.balanceOf(address(this));
    }

    /// @notice Report on an existing query as a random actor, with a valid outcome that differs
    ///         from the previous one. No-ops when no report can land (nothing created yet, the
    ///         reporting/appeal window expired, or the next stake would be a fork trigger).
    function report(uint256 querySeed, uint256 outcomeSeed, uint256 actorSeed) external {
        if (ghostQueriesCreated == 0) return;
        uint256 queryId = bound(querySeed, 0, ghostQueriesCreated - 1);

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
        vm.prank(actor);
        MULTIVERSE.report(GENESIS_UID, queryId, outcome);

        ++ghostReportsPlaced;
        ++ghostStakeCount[queryId];
        ghostLastOutcome[queryId] = outcome;
        ghostQueryStaked[queryId] += requiredStake;
        ghostActorStaked[actor] += requiredStake;
        ghostTotalStaked += requiredStake;
    }

    /// @notice Advance time by a bounded amount, so windows open and expire during a run.
    function advanceTime(uint256 deltaSeed) external {
        uint256 delta = bound(deltaSeed, 1, MAX_TIME_ADVANCE);
        ghostNow += delta;
        vm.warp(ghostNow);
    }
}
