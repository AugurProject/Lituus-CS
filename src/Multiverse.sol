// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IZoltar } from "./interfaces/IZoltar.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { LituusRep } from "./LituusRep.sol";
import { IReputationToken } from "./interfaces/IReputationToken.sol";
import { IQueryFeeController } from "./interfaces/IQueryFeeController.sol";

contract Multiverse {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILituusRep;

/* ============================================== CONSTANTS/IMMUTABLES ============================================== */
    uint8 public constant MAX_OUTCOMES = 253; //number of outcomes for a query
    uint8 public constant MAX_FORK_OUTCOMES = 2; //number of outcomes for a forking query
    uint8 public constant UNRESOLVED = 255; // Not reported in time.
    uint8 public constant INVALID = 254; // an invalid outcome value used for reporting an invalid fork outcome during
    // fork resolution. It is outside the valid outcome range [0, MAX_OUTCOMES-1]
    uint8 public constant NO_REPORT = 0; // the starting value for outcome is NO_REPORT.

    uint256 public constant THREE_DAYS = 3 days;
    // This is the divider for the burn depending on losingStakes on a query.
    // If burn ratio is 20% (1/5), then BURN_DIVIDER is 5.
    uint256 public constant BURN_DIVIDER = 5;

    uint256 public immutable GENESIS_TIMESTAMP;
    IZoltar public immutable ZOLTAR;
    IQueryFeeController public immutable QUERY_FEE_CONTROLLER;

/* ====================================================== ENUMS ===================================================== */
    enum ForkState {
        NotForking, // 0 - default; universe is operating normally
        AwaitingChildren, // 1 - system frozen, waiting for forkUniverse() to be called
        InitialMigration, // 2 - forking in progress; REP holders migrate to child universes
        SupplyRestoration1, // 3 - SR attempt 1
        SupplyRestoration2, // 4 - SR attempt 2
        SupplyRestoration3, // 5 - SR attempt 3
        PostFork, // 6 - fork finalized
        Forming // 7 - child universe still being formed
    }

/* ===================================================== STRUCTS ==================================================== */
    struct Stake {
        address reporter;
        uint48 time;
        uint8 reportedOutcome;
        uint256 amount;
    }

    struct Query {
        uint48 createTime;
        uint8 numberOfOutcomes;
        uint248 originUniverse;
        uint256 fee;
        string question;
        uint248[] resolvedUniverses;
    }

    struct QueryResolution {
        // flag which if true the query is resolved in the universe, otherwise it's not.
        bool isResolved;
        // The stakes for this query.
        Stake[] stakes;
    }

    struct Universe {
        ILituusRep repToken;
        ForkState forkState;
        uint248 parent;
        uint248 favoriteChild;
        uint248 heir;
        bytes32 history;
        uint256 forkQuery;
        uint256 supplyBeforeFork;
        address queryTokenizer;
    }

    struct UniverseRevenues {
        // The three day revenue for each three days that passed since GENESIS_TIMESTAMP.
        mapping(uint256 threeDayId => uint256) threeDayRevenue;
        // The three day profit for each three days that passed since GENESIS_TIMESTAMP.
        mapping(uint256 threeDayId => uint256) threeDayProfit;
        // The total revenue for this universe.
        uint256 totalRevenue;
        // The total profit for this universe.
        uint256 totalProfit;
    }

/* ==================================================== VARIABLES =================================================== */
    mapping(uint248 universeId => Universe) public universes;
    mapping(uint248 universeId => UniverseRevenues) public universeRevenues;
    mapping(uint256 queryId => Query) public queries;
    mapping(uint248 universeId => mapping(uint256 queryId => QueryResolution)) public queryResolutions;

    uint256 public queryCount;

/* ===================================================== EVENTS ===================================================== */
    event QueryCreated(uint256 indexed queryId, uint248 indexed universeId, string question, uint8 numberOfOutcomes);

/* ===================================================== ERRORS ===================================================== */
    error ZeroAddress();
    error InvalidUniverse();
    error UniverseForking();
    error InvalidNumberOfOutcomes();

/* =================================================== CONSTRUCTOR ================================================== */
    constructor(IZoltar _zoltar, uint248 _initialZoltarUniverseId, IQueryFeeController _queryFeeController) {
        ZOLTAR = _zoltar;
        if (address(ZOLTAR) == address(0)) revert ZeroAddress();
        QUERY_FEE_CONTROLLER = _queryFeeController;
        if (address(QUERY_FEE_CONTROLLER) == address(0)) revert ZeroAddress();

        // get the rep token address from the initial universe in Zoltar
        IReputationToken initialZoltarRepToken = ZOLTAR.getRepToken(_initialZoltarUniverseId);
        // deploy a Lituus REP token that wraps the Zoltar REP token
        // token symbol will use universe.history as a suffix. Genesis universe will have symbol "REP0"
        // TODO: Discuss the format of the suffix if the forks are for binary queries.
        ILituusRep repToken =
            new LituusRep(address(this), address(initialZoltarRepToken), "Lituus Reputation Token", "REP0");

        Universe storage genesisUniverse = universes[0];
        genesisUniverse.favoriteChild = 0;
        genesisUniverse.parent = 0;
        genesisUniverse.repToken = repToken;
        genesisUniverse.forkState = ForkState.NotForking;
        genesisUniverse.heir = 0;
        genesisUniverse.history = 0;
        genesisUniverse.forkQuery = 0;
        genesisUniverse.supplyBeforeFork = repToken.totalSupply(); // TODO: what should it be?
        genesisUniverse.queryTokenizer = address(0);

        GENESIS_TIMESTAMP = block.timestamp;
    }

/* ================================================= WRAP FUNCTIONS ================================================= */
    function wrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.wrap(msg.sender, amount);
    }

    function unwrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.unwrap(msg.sender, amount);
    }

    // Main functions

/* ================================================= QUERY FUNCTIONS ================================================ */
    function createQuery(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external {
        Universe storage universe = universes[universeId];
        ILituusRep repToken = universe.repToken;
        if (address(repToken) == address(0)) revert InvalidUniverse();
        // Forward the transaction to the heir
        uint248 heirId = universe.heir;
        if (heirId != universeId) {
            universe = universes[heirId];
            repToken = universe.repToken;
            if (address(repToken) == address(0)) revert InvalidUniverse();
        }
        // TODO: double check the allowed states
        // Query creation is allowed during a fork in child universes
        // but not in the parent universe that is forking.
        ForkState forkState = universe.forkState;
        if (
            forkState == ForkState.InitialMigration || forkState == ForkState.SupplyRestoration1
                || forkState == ForkState.SupplyRestoration2 || forkState == ForkState.SupplyRestoration3
                || forkState == ForkState.PostFork
        ) {
            revert UniverseForking();
        }
        // Validate the question and number of outcomes
        if (numberOfOutcomes <= 2) revert InvalidNumberOfOutcomes();
        if (numberOfOutcomes > MAX_OUTCOMES) revert InvalidNumberOfOutcomes();

        // TODO: Here we need to actually check if question contains the same numberOfOutcomes needed.

        // Get the fee amount from the query fee controller
        uint256 fee = QUERY_FEE_CONTROLLER.getQueryFee(universeId);
        // Transfer the query fee amount of REP token
        // TODO: permit? permit2?
        repToken.safeTransferFrom(msg.sender, address(this), fee);
        // Create a global query record

        Query storage query = queries[queryCount];
        query.createTime = uint48(block.timestamp);
        query.numberOfOutcomes = numberOfOutcomes;
        query.originUniverse = universeId;
        query.fee = fee;
        query.question = question;

        // A universe-specific outcome record will start with NO_REPORT
        // The record will be populated when the first report comes in

        // Emit an event
        emit QueryCreated(queryCount, universeId, question, numberOfOutcomes);

        queryCount++;
    }

/* ================================================ OUTCOME FUNCTIONS =============================================== */
    function getOutcome(uint248 universeId, uint256 queryId) external view returns (uint8) {
        Stake[] storage stakes = queryResolutions[universeId][queryId].stakes;
        return stakes[stakes.length - 1].reportedOutcome;
    }

/* ============================================== ESCALATION FUNCTIONS ============================================== */
    /**
     * @notice Resolves the escalation game for a reported query: pays the query fee reward to the
     *         first correct reporter, computes the protocol profit, records the universe's revenue
     *         and profit, and returns the winning outcome.
     * @dev Delegates total/winner extraction to `_extractWinnerOutcomeAndTotals`, which reverts if
     *      the query has no stakes; callers MUST guarantee the query is reported before calling.
     *
     *      `reporterPay` accrues linearly over the reporting window as
     *      `fee * (reportingTimestamp - createTime) / THREE_DAYS`, capped at the full `fee`: the
     *      winning report can land after escalation has begun and thus past the 3-day window, so
     *      the cap prevents paying out more than the fee.
     *
     *      `profit` is the REP removed from circulation: 20% of the losing stakes
     *      (`totalLoserStakes / BURN_DIVIDER`) plus the unpaid fee remainder (`fee - reporterPay`).
     *      The reporter reward is pushed here via `safeTransfer`; burning `profit` is still pending
     *      the Lituus wrap/unwrap path (TODO).
     *
     *      Winner stake refunds and their proportional share of the remaining 80% of losing stakes
     *      are NOT settled here — those are claimed separately at withdrawal time.
     * @param universeId The id of the universe the query is being resolved in.
     * @param queryId The id of the query being resolved.
     * @return winnerOutcome The winning outcome of the resolved query.
     */
    function _calculateAndSetEscalationPayoffs(uint248 universeId, uint256 queryId) internal returns (uint8) {
        (
            uint256 totalStaked,
            uint256 winnerOutcomeStaked,
            uint8 winnerOutcome,
            address reporter,
            uint48 reportingTimestamp
        ) = _extractWinnerOutcomeAndTotals(universeId, queryId);

        uint256 reporterFee = queries[queryId].fee;

        uint256 totalLoserStakes = totalStaked - winnerOutcomeStaked;
        uint256 reporterPay = reporterFee * uint256(reportingTimestamp - queries[queryId].createTime) / THREE_DAYS;
        // Here because the report for the winner query can come after escalation starts, sometimes it might extend over
        // 3 days, so we should make it equal to reporterFee in that case
        if (reporterPay > reporterFee) reporterPay = reporterFee;

        uint256 profit = totalLoserStakes / BURN_DIVIDER + (reporterFee - reporterPay);

        ILituusRep repToken = universes[universeId].repToken;
        // TODO-Check if makes sense to also calculate reporterStake and losing side.
        repToken.safeTransfer(reporter, reporterPay);
        // TODO-CHECK IF LITUUS HERE OR UNWRAP AND BURN REP.
        //        repToken.burn(profit);

        _applyRevenuesAndProfits(universeId, reporterFee, profit);

        return winnerOutcome;
    }
/* ========================================== RESOLUTION INTERNAL FUNCTIONS ========================================= */
    /**
     * @notice Records a resolved query's revenue and profit into the universe's current 3-day
     *         bucket and its running totals.
     * @dev The bucket is keyed by the 3-day window index derived from the global genesis anchor
     *      (`(block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS`). The sparse mapping avoids any
     *      age-dependent array padding and lets a fork copy a fixed window of buckets regardless of
     *      universe age. Both the windowed bucket and the running total are updated for revenue and
     *      profit.
     * @param universeId The id of the universe to credit.
     * @param revenueAmount The revenue realized by the resolved query (its fee).
     * @param profit The profit realized by the resolved query (the REP to be burned).
     */
    function _applyRevenuesAndProfits(uint248 universeId, uint256 revenueAmount, uint256 profit) internal {
        uint256 current3DayWindow = (block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS;

        UniverseRevenues storage universeRevenue = universeRevenues[universeId];

        // Store revenues.
        universeRevenue.threeDayRevenue[current3DayWindow] += revenueAmount;
        universeRevenue.totalRevenue += revenueAmount;

        // Store profits.
        universeRevenue.threeDayProfit[current3DayWindow] += profit;
        universeRevenue.totalProfit += profit;
    }

    /**
     * @notice Computes the staking totals and the winning outcome for a reported query, and
     *         identifies the reporter entitled to the query fee reward.
     * @dev MUST be called only for a reported query (`stakes.length > 0`); otherwise the
     *      `stakes[length - 1]` access underflows and reverts. The no-report / invalid path
     *      must be handled before calling this.
     *
     *      The winning outcome is always the last reported outcome (the last stake in the
     *      escalation chain), so the last stake is read before the loop to establish it; the
     *      loop then runs only when there is more than one stake.
     *
     *      `reporter` and `reportingTimestamp` correspond to the FIRST stake placed on the
     *      winning outcome (the earliest in the chain), since the query fee reward is paid to
     *      whoever first reported the eventually-winning outcome. Computed in a single pass.
     * @param universeId The id of the universe the query is being resolved in.
     * @param queryId The id of the query being resolved.
     * @return totalStaked The total staked amount for the whole query.
     * @return winnerOutcomeStaked The total staked amount on the winner outcome.
     * @return winnerOutcome The winner outcome.
     * @return reporter The reporter acquiring the query fee reward.
     * @return reportingTimestamp The timestamp when the stake acquiring the query fee reward occurred.
     */
    function _extractWinnerOutcomeAndTotals(uint248 universeId, uint256 queryId)
    internal
    view
    returns (
        uint256 totalStaked,
        uint256 winnerOutcomeStaked,
        uint8 winnerOutcome,
        address reporter,
        uint48 reportingTimestamp
    )
    {
        Stake[] storage stakes = queryResolutions[universeId][queryId].stakes;
        uint256 length = stakes.length;

        // The winner outcome comes always from the last stake in resolution, so extracting last stake before for loop
        // helps us identify it and then for loop only if array's length is greater than 1.
        Stake storage stake = stakes[length - 1];
        totalStaked += stake.amount;
        winnerOutcomeStaked += stake.amount;
        winnerOutcome = stake.reportedOutcome;
        // Those two are set temporarily, in case last stake was the only one reported the winnerOutcome.
        reporter = stake.reporter;
        reportingTimestamp = stake.time;

        if (length > 1) {
            // Extracted here, so as not to spend gas everytime for subtracting operation.
            length = length - 1;

            // Used to identify the first reporter for winnerOutcome. If true, first already exists, so skipping.
            bool isReporterSet;
            for (uint256 i = 0; i < length;) {
                stake = stakes[i];

                totalStaked += stake.amount;

                if (stake.reportedOutcome == winnerOutcome) {
                    winnerOutcomeStaked += stake.amount;

                    if (!isReporterSet) {
                        reporter = stake.reporter;
                        reportingTimestamp = stake.time;
                        isReporterSet = true;
                    }
                }

                unchecked {
                    i += 1;
                }
            }
        }
    }
}
