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
        address owner;
        uint48 time;
        uint8 claim;
        uint256 amount;
        uint256 queryId;
    }

    struct Query {
        uint48 createTime;
        uint8 numberOfOutcomes;
        uint248 originUniverse;
        uint256 fee;
        string question;
        uint248[] resolvedUniverses;
    }

    // firstReporter and firstReportTime are always stored together and they are packed.
    struct Outcome {
        // total stake for this specific outcome.
        uint256 totalOutcomeStake;
        // the first ever reporter that reported this outcome.
        address firstReporter;
        // the time where the first reporter for this outcome of the query actually reported it.
        uint48 firstReportTime;
    }

    // winningQuery and lastStakeId are always stored together, so convenient to pack em and make stakeIds uint248.
    struct QueryResolution {
        // Winning outcome while query not resolved yet, if query is fully resolved this is actually the winner outcome.
        uint8 winningOutcome;
        // The id of the last stake for this query.
        uint248 lastStakeId;
        // The total stake for the whole query.
        uint256 totalStake;
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
        // The counter for the stakes of this universe. Chose uint248 to be able to pack with winningOutcome.
        uint248 stakeCount;
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
    mapping(uint248 universeId => mapping(uint256 queryId => mapping(uint8 outcome => Outcome))) public outcomes;
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
        return queryResolutions[universeId][queryId].winningOutcome;
    }

    function getOutcomeData(uint248 universeId, uint256 queryId, uint8 outcome) external view returns (Outcome memory) {
        return outcomes[universeId][queryId][outcome];
    }

/* ============================================== ESCALATION FUNCTIONS ============================================== */
    function _calculateAndSetEscalationPayoffs(uint248 universeId, uint256 queryId) internal {
        Query memory query = queries[queryId];
        QueryResolution memory queryResolution = queryResolutions[universeId][queryId];
        // At this point we know the winnerOutcome, otherwise applyProfits should not be called.
        Outcome memory winnerOutcome = outcomes[universeId][queryId][queryResolution.winningOutcome];

        uint256 reporterFee = IQueryFeeController(QUERY_FEE_CONTROLLER).getQueryFee(universeId);

        uint256 totalLoserStakes = queryResolution.totalStake - winnerOutcome.totalOutcomeStake;
        uint256 reporterPay = reporterFee * uint256(winnerOutcome.firstReportTime - query.createTime) / THREE_DAYS;
        // Here because the report for the winner query can come after escalation starts, sometimes it might extend over
        // 3 days, so we should make it equal to reporterFee in that case
        if (reporterPay > reporterFee) reporterPay = reporterFee;

        uint256 burnAmount = totalLoserStakes / BURN_DIVIDER;
        uint256 profit = burnAmount + (reporterPay - reporterFee);

        ILituusRep repToken = universes[universeId].repToken;

        repToken.safeTransfer(winnerOutcome.firstReporter, reporterPay);
        // TODO-CHECK IF LITUUS HERE OR UNWRAP AND BURN REP.
        //        repToken.burn(burnAmount);

        _applyProfits(universeId, profit);
    }
/* ============================================ REVENUE/PROFIT FUNCTIONS ============================================ */
    function _applyRevenues(uint248 universeId, uint256 revenueAmount) internal {
        uint256 current3DayWindow = (block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS;

        UniverseRevenues storage universeRevenue = universeRevenues[universeId];

        universeRevenue.threeDayRevenue[current3DayWindow] += revenueAmount;
        universeRevenue.totalRevenue += revenueAmount;
    }

    function _applyProfits(uint248 universeId, uint256 profit) internal {
        uint256 current3DayWindow = (block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS;

        UniverseRevenues storage universeRevenue = universeRevenues[universeId];

        universeRevenue.threeDayProfit[current3DayWindow] += profit;
        universeRevenue.totalProfit += profit;
    }
}
