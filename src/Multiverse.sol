// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IZoltar } from "./interfaces/IZoltar.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { LituusRep } from "./LituusRep.sol";
import { IReputationToken } from "./interfaces/IReputationToken.sol";
import { IQueryFeeController } from "./interfaces/IQueryFeeController.sol";
import { LibHistory } from "./libraries/LibHistory.sol";

// TODO: check zoltar forks

contract Multiverse is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILituusRep;

    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    uint8 public constant MAX_OUTCOMES = 253; //number of outcomes for a query
    uint8 public constant MAX_FORK_OUTCOMES = 2; //number of outcomes for a forking query
    uint8 public constant UNRESOLVED = 0; // the query is not resolved yet
    uint8 public constant INVALID = 254; // an invalid outcome value used for reporting an invalid fork outcome during
    // fork resolution. It is outside the valid outcome range [1, MAX_OUTCOMES]

    uint256 public constant THREE_DAYS = 3 days;
    uint256 public constant ONE_DAY = 1 days;
    // This is the divider for the burn depending on losingStakes on a query.
    // If burn ratio is 20% (1/5), then BURN_DIVIDER is 5.
    uint256 public constant BURN_DIVIDER = 5;

    uint256 public immutable GENESIS_TIMESTAMP;
    IZoltar public immutable ZOLTAR;
    IQueryFeeController public immutable QUERY_FEE_CONTROLLER;

    /* ================================================== ENUMS ================================================== */
    enum ForkState {
        NotForking, // 0 - default; universe is operating normally, not forking
        AwaitingChildren, // 1 - system frozen, waiting for forkUniverse() to be called
        Migration, // 2 - forking in progress; REP holders migrate to child universes
        SupplyRestoration1, // 3 - SR attempt 1
        SupplyRestoration2, // 4 - SR attempt 2
        SupplyRestoration3, // 5 - SR attempt 3
        PostFork, // 6 - fork finalized
        Forming // 7 - child universe still being formed
    }

    /* ================================================= STRUCTS ================================================= */
    struct Stake {
        address reporter;
        uint48 time;
        uint8 reportedOutcome;
        uint256 amount;
    }

    struct Query {
        uint8 numberOfOutcomes;
        uint248 originUniverse;
        uint256 fee;
        string question;
        uint248[] resolvedUniverses;
    }

    struct QueryResolution {
        // The time the query first became reportable in this universe.
        // Set on createQuery in the origin universe and lazily on the first report() in heir universes
        // (to that universe's forkTime).
        uint48 queryCreateTime;
        // if this is 0, then UNRESOLVED, otherwise it is RESOLVED.
        uint8 outcome;
        // The stakes for this query.
        Stake[] stakes;
    }

    struct Universe {
        ILituusRep repToken;
        ForkState forkState;
        // TODO: populate the forkTime
        uint48 forkTime;
        // The depth of the universe in the fork tree
        // Genesis universe has depth 0, its children have depth 1, etc. Max 256.
        uint16 forkDepth;
        // Whether this universe lies on the canonical timeline (the genesis -> favoriteChild -> ... chain).
        // Genesis is canonical; on a fork, only the designated favoriteChild inherits the parent's flag.
        bool isCanonical;
        uint248 parent;
        uint248 favoriteChild;
        uint248 heir;
        // TODO: populate the history
        // History format:
        // Genesis universe has history 0, depth 0.
        // First children have history 0b00 and 0b01, depth 1,
        // second children of the second child 0b010 and 0b011, depth 2, etc.
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

    /* ================================================ VARIABLES ================================================ */
    mapping(uint248 universeId => Universe) public universes;
    mapping(uint248 universeId => UniverseRevenues) public universeRevenues;
    mapping(uint256 queryId => Query) public queries;
    mapping(uint248 universeId => mapping(uint256 queryId => QueryResolution)) public queryResolutions;

    uint256 public queryCount;

    /* ================================================= EVENTS ================================================== */
    event QueryCreated(
        address indexed creator,
        uint256 indexed queryId,
        uint248 indexed universeId,
        string question,
        uint8 numberOfOutcomes
    );
    event QueryReported(
        address indexed reporter,
        uint248 indexed universeId,
        uint256 indexed queryId,
        uint8 outcome,
        uint256 stakeAmount
    );
    event QueryResolved(address indexed resolver, uint248 indexed universeId, uint256 indexed queryId, uint8 outcome);

    /* ================================================= ERRORS ================================================== */
    error ZeroAddress();
    error InvalidUniverse();
    error InvalidNumberOfOutcomes();
    error InvalidQuery();
    error InvalidOutcome();
    error OutcomeSameAsPrevious();
    error QueryAlreadyResolved();
    error QueryNotReadyToResolve();
    error QueryExpired();
    error AppealPeriodOver();
    error InvalidUniverseState();

    /* =============================================== CONSTRUCTOR =============================================== */
    constructor(IZoltar _zoltar, uint248 _initialZoltarUniverseId, IQueryFeeController _queryFeeController) {
        ZOLTAR = _zoltar;
        if (address(ZOLTAR) == address(0)) revert ZeroAddress();
        QUERY_FEE_CONTROLLER = _queryFeeController;
        if (address(QUERY_FEE_CONTROLLER) == address(0)) revert ZeroAddress();

        // get the REP token address from the initial universe in Zoltar
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
        genesisUniverse.forkTime = uint48(block.timestamp);
        genesisUniverse.heir = 0;
        // Genesis is the root of the fork tree: an empty inheritance path, and the root of the canonical timeline.
        genesisUniverse.history = 0;
        genesisUniverse.forkDepth = 0;
        genesisUniverse.isCanonical = true;
        genesisUniverse.forkQuery = 0;
        // TODO: fill in the correct supply
        genesisUniverse.supplyBeforeFork = ZOLTAR.getUniverseTheoreticalSupply(_initialZoltarUniverseId);
        genesisUniverse.queryTokenizer = address(0);

        GENESIS_TIMESTAMP = block.timestamp;
    }

    /* ============================================= WRAP FUNCTIONS ============================================== */
    function wrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        // TODO: maybe check if some fork is upcoming (some escalation game is close to fork threshold)
        universes[universeId].repToken.wrap(msg.sender, amount);
    }

    function unwrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.unwrap(msg.sender, amount);
    }

    /* ============================================= QUERY FUNCTIONS ============================================= */
    function createQuery(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external nonReentrant {
        (uint248 activeUniverseId,, ILituusRep repToken) = _getActiveUniverseAndRepToken(universeId);

        // Validate the question and number of outcomes
        if (numberOfOutcomes <= 2) revert InvalidNumberOfOutcomes();
        if (numberOfOutcomes > MAX_OUTCOMES) revert InvalidNumberOfOutcomes();

        // TODO: Here we need to actually check if question contains the same numberOfOutcomes needed.

        // Get the fee amount from the query fee controller
        uint256 fee = QUERY_FEE_CONTROLLER.getQueryFee(activeUniverseId);
        // Transfer the query fee amount of REP token
        // TODO: permit? permit2?
        repToken.safeTransferFrom(msg.sender, address(this), fee);
        // Create a global query record

        Query storage query = queries[queryCount];
        query.numberOfOutcomes = numberOfOutcomes;
        query.originUniverse = activeUniverseId;
        query.fee = fee;
        query.question = question;

        // A universe-specific resolution record starts with outcome == UNRESOLVED.
        // Set the queryCreateTime so the reporting window can be enforced in this universe.
        QueryResolution storage resolution = queryResolutions[activeUniverseId][queryCount];
        resolution.queryCreateTime = uint48(block.timestamp);

        // Emit an event
        emit QueryCreated(msg.sender, queryCount, activeUniverseId, question, numberOfOutcomes);

        queryCount++;
    }

    function report(uint248 universeId, uint256 queryId, uint8 outcome) external nonReentrant {
        // Check all conditions (universe exists, query exists, outcome is valid, report is within time, etc.)
        (uint248 activeUniverseId,, ILituusRep repToken) = _getActiveUniverseAndRepToken(universeId);

        Query storage query = queries[queryId];
        if (query.numberOfOutcomes == 0) revert InvalidQuery();

        QueryResolution storage resolution = queryResolutions[activeUniverseId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();
        // A query resolved in an ancestor universe is inherited by this lineage (via getOutcome), so it
        // cannot be reported on again here. The ancestor set is fixed per lineage, so this only needs to
        // be checked on the first report; later stakes in the same escalation are already covered.
        if (resolution.stakes.length == 0 && _findAncestorResolution(activeUniverseId, queryId) != UNRESOLVED) {
            revert QueryAlreadyResolved();
        }

        // Outcome should be between 1 and numberOfOutcomes unless the query should be reported as INVALID
        if (outcome == UNRESOLVED) revert InvalidOutcome();
        if ((outcome > query.numberOfOutcomes) && (outcome != INVALID)) revert InvalidOutcome();

        uint48 queryCreateTime = _getAndUpdateQueryCreateTime(activeUniverseId, queryId);

        // Check that the reporting window for the query is not over yet
        if (resolution.stakes.length == 0 && queryCreateTime + THREE_DAYS < block.timestamp) revert QueryExpired();

        uint256 numberOfStakes = resolution.stakes.length;
        // Check that the last outcome is not the same as the current outcome, and the appeal period hasn't expired.
        if (numberOfStakes > 0) {
            Stake storage lastStake = resolution.stakes[numberOfStakes - 1];
            if (lastStake.reportedOutcome == outcome) revert OutcomeSameAsPrevious();
            if (lastStake.time + ONE_DAY < block.timestamp) revert AppealPeriodOver();
        }

        uint256 requiredStakeAmount = _requiredStakeAmount(activeUniverseId, queryId);

        // Transfer the stake
        repToken.safeTransferFrom(msg.sender, address(this), requiredStakeAmount);

        uint256 forkThreshold = ZOLTAR.getForkThreshold(activeUniverseId); // TODO: actual Lituus threshold will differ
        if (requiredStakeAmount >= forkThreshold) {
            // TODO: fork logic in a separate call
            // If the universe cannot fork then revert
        }

        // Update the resolution record for the universe
        Stake[] storage stakes = resolution.stakes;
        uint256 index = stakes.length;
        stakes.push();

        Stake storage newStake = stakes[index];
        newStake.reporter = msg.sender;
        newStake.time = uint48(block.timestamp);
        newStake.reportedOutcome = outcome;
        newStake.amount = requiredStakeAmount;

        // Emit an event
        emit QueryReported(msg.sender, activeUniverseId, queryId, outcome, requiredStakeAmount);
    }

    function resolve(uint248 universeId, uint256 queryId) external nonReentrant {
        (uint248 activeUniverseId, Universe storage activeUniverse,) = _getActiveUniverseAndRepToken(universeId);

        Query storage query = queries[queryId];
        if (query.numberOfOutcomes == 0) revert InvalidQuery();

        QueryResolution storage resolution = queryResolutions[activeUniverseId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();

        uint48 queryCreateTime = _getAndUpdateQueryCreateTime(activeUniverseId, queryId);

        if (resolution.stakes.length == 0 && queryCreateTime + THREE_DAYS < block.timestamp) {
            // No report ever landed here, so the ancestor check was never run by report(): a query
            // resolved in an ancestor is inherited by this lineage (via getOutcome) and must not be
            // resolved again. The stakes branch below is already covered by report()'s first-stake check.
            if (_findAncestorResolution(activeUniverseId, queryId) != UNRESOLVED) revert QueryAlreadyResolved();
            // If the report period has passed and the query was not reported on then resolve the query as INVALID
            resolution.outcome = INVALID;
            _recordResolvedUniverse(queryId, activeUniverseId, activeUniverse.isCanonical);
            emit QueryResolved(msg.sender, activeUniverseId, queryId, INVALID);
            // TODO: Payout to the resolver, another clock auction
        } else if (resolution.stakes.length > 0) {
            if (resolution.stakes[resolution.stakes.length - 1].time + ONE_DAY < block.timestamp) {
                // If there are stakes and the appeal period has passed then resolve the query with the last outcome
                // TODO: Unless the query is 1 step from fork threshold, then we should wait for the fork to finish
                uint8 outcome = _calculateOutcomeAndEscalationPayoffs(activeUniverseId, queryId);
                resolution.outcome = outcome;
                _recordResolvedUniverse(queryId, activeUniverseId, activeUniverse.isCanonical);
                emit QueryResolved(msg.sender, activeUniverseId, queryId, outcome);
                // TODO: Payouts
            } else {
                // Appeal period is not over yet, cannot resolve
                revert QueryNotReadyToResolve();
            }
        } else {
            // Otherwise, the query cannot be resolved yet
            revert QueryNotReadyToResolve();
        }

        // TODO: check Zoltar forking state
    }

    /* ========================================== ESCALATION FUNCTIONS =========================================== */
    /**
     * @notice Resolves the escalation game for a reported query: pays the query fee reward to the
     *         first correct reporter, computes the protocol profit, records the universe's revenue
     *         and profit, and returns the winning outcome.
     * @dev Delegates total/winner extraction to `_extractWinnerOutcomeAndTotals`, which reverts if
     *      the query has no stakes; callers MUST guarantee the query is reported before calling.
     *
     *      `reporterPay` accrues linearly over the reporting window as
     *      `fee * (reportingTimestamp - queryCreateTime) / THREE_DAYS`, capped at the full `fee`: the
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
    function _calculateOutcomeAndEscalationPayoffs(uint248 universeId, uint256 queryId) internal returns (uint8) {
        (
            uint256 totalStaked,
            uint256 winnerOutcomeStaked,
            uint8 winnerOutcome,
            address reporter,
            uint48 reportingTimestamp
        ) = _extractWinnerOutcomeAndTotals(universeId, queryId);

        uint256 queryFee = queries[queryId].fee;
        // Per-universe queryCreateTime: createQuery sets it for the origin universe and report()
        // lazily sets it to universe.forkTime for heir universes on first report.
        uint48 queryCreateTime = queryResolutions[universeId][queryId].queryCreateTime;

        uint256 totalLoserStakes = totalStaked - winnerOutcomeStaked;
        uint256 reporterPay = queryFee * uint256(reportingTimestamp - queryCreateTime) / THREE_DAYS;
        // Here because the report for the winner query can come after escalation starts, sometimes it might extend over
        // 3 days, so we should make it equal to queryFee in that case
        if (reporterPay > queryFee) reporterPay = queryFee;

        uint256 profit = totalLoserStakes / BURN_DIVIDER + (queryFee - reporterPay);

        ILituusRep repToken = universes[universeId].repToken;
        // TODO-Check if makes sense to also calculate reporterStake and losing side.
        repToken.safeTransfer(reporter, reporterPay);
        // TODO-CHECK IF LITUUS HERE OR UNWRAP AND BURN REP.
        //        repToken.burn(profit);

        _applyRevenuesAndProfits(universeId, queryFee, profit);

        return winnerOutcome;
    }

    /* ====================================== RESOLUTION INTERNAL FUNCTIONS ====================================== */
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

    /* ========================================= PUBLIC VIEW FUNCTIONS =========================================== */
    /**
     * @notice Returns the outcome of a query as seen from a given universe.
     * @dev If the query is resolved in this universe, that outcome is returned directly. Otherwise the
     *      query's resolutions are scanned for one recorded in an ancestor of this universe (a prefix
     *      match on the inheritance path). A query is resolved at most once along any single lineage,
     *      so the first ancestor match is the applicable resolution. Returns UNRESOLVED if neither this
     *      universe nor any ancestor has resolved the query.
     * @param universeId The universe to read the outcome from.
     * @param queryId The query to read.
     * @return The resolved outcome, or UNRESOLVED if none applies to this universe.
     */
    function getOutcome(uint248 universeId, uint256 queryId) external view returns (uint8) {
        // Fast path: resolved in this universe.
        uint8 localOutcome = queryResolutions[universeId][queryId].outcome;
        if (localOutcome != UNRESOLVED) return localOutcome;

        // Forward to the heir if this universe has forked, so we read from the active universe where
        // report()/resolve() record resolutions. Reverts only if the universe does not exist; outcomes
        // remain readable while the universe is forking (no fork-state check, unlike report/resolve).
        (uint248 activeUniverseId,) = _getActiveUniverse(universeId);
        if (activeUniverseId != universeId) {
            uint8 heirOutcome = queryResolutions[activeUniverseId][queryId].outcome;
            if (heirOutcome != UNRESOLVED) return heirOutcome;
        }

        // Otherwise inherit the resolution from an ancestor universe, if any.
        return _findAncestorResolution(activeUniverseId, queryId);
    }

    /**
     * @notice Returns the outcome of the first ancestor of `universeId` that has resolved `queryId`.
     * @dev Scans the query's recorded resolution universes and prefix-matches their inheritance path
     *      against `universeId`'s path. A query is resolved at most once along any single
     *      lineage, so the first ancestor match is authoritative. Returns UNRESOLVED if no ancestor
     *      has resolved the query.
     */
    function _findAncestorResolution(uint248 universeId, uint256 queryId) internal view returns (uint8) {
        Universe storage universe = universes[universeId];
        bytes32 history = universe.history;
        uint16 forkDepth = universe.forkDepth;

        uint248[] storage resolvedUniverses = queries[queryId].resolvedUniverses;
        uint256 length = resolvedUniverses.length;
        for (uint256 i = 0; i < length; i++) {
            uint248 resolvedUniverseId = resolvedUniverses[i];
            Universe storage candidate = universes[resolvedUniverseId];
            if (LibHistory.isAncestor(candidate.history, candidate.forkDepth, history, forkDepth)) {
                return queryResolutions[resolvedUniverseId][queryId].outcome;
            }
        }
        return UNRESOLVED;
    }

    /**
     * @notice Records `universeId` as a universe where `queryId` is resolved.
     * @dev Keeps a canonical universe's entry at index 0 so `_findAncestorResolution` finds the canonical
     *      resolution first (the common-case read). Safe because the canonical chain is a single linear
     *      path, so at most one canonical universe ever resolves a given query. Saves gas during lookups.
     */
    function _recordResolvedUniverse(uint256 queryId, uint248 universeId, bool isCanonical) internal {
        uint248[] storage resolvedUniverses = queries[queryId].resolvedUniverses;
        if (isCanonical && resolvedUniverses.length > 0) {
            resolvedUniverses.push(resolvedUniverses[0]); // move current head to the tail
            resolvedUniverses[0] = universeId; // canonical entry takes index 0
        } else {
            resolvedUniverses.push(universeId);
        }
    }

    function _requiredStakeAmount(uint248 universeId, uint256 queryId) public view returns (uint256) {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        uint256 numberOfStakes = resolution.stakes.length;
        if (numberOfStakes == 0) {
            return QUERY_FEE_CONTROLLER.getQueryFee(universeId);
        } else {
            uint256 lastStakeAmount = resolution.stakes[numberOfStakes - 1].amount;
            uint256 requiredStakeAmount = lastStakeAmount * 2;
            uint256 forkThreshold = ZOLTAR.getForkThreshold(universeId);
            if (requiredStakeAmount >= forkThreshold / 2) {
                return forkThreshold;
            } else {
                return requiredStakeAmount;
            }
        }
    }

    /* ==================================== TOKEN SUPPLY MANAGEMENT FUNCTIONS ==================================== */
    /**
     * @notice Migration, auction, and other token supply management functions.
     */

    /* ============================================ FORKING FUNCTIONS ============================================ */
    function forkUniverse(uint248 universeId, uint256 queryId) internal {
        // TODO
        // Check if the universe can fork (state of the universe)
        // Check if ZOLTAR is not forking, revert if it's forking
        // Handle if the query should fork but the universe cannot fork
        // Create a ZOLTAR binary fork query
        // Approve REP for ZOLTAR
        // Create a fork in ZOLTAR
        // TODO: Update the universe's fork state to Awaiting children and set the forkQuery
        // Spawn child universes
        // Set outcomes in child universes and update their states to Forming
    }

    /* =========================================== INTERNAL HELPERS ============================================== */
    /**
     * @notice Resolves a universe id to the active universe, forwarding to the heir if it has forked.
     * @dev Reverts with InvalidUniverse only if the universe (or its heir) does not exist (repToken == 0).
     *      Does NOT check the fork state, so callers that must operate only on an active/forming universe
     *      (report/resolve) layer that check on top; read-only callers (getOutcome) can use this directly
     *      to stay readable while a universe is forking.
     */
    function _getActiveUniverse(uint248 universeId)
        internal
        view
        returns (uint248 activeUniverseId, Universe storage universe)
    {
        universe = universes[universeId];
        if (address(universe.repToken) == address(0)) revert InvalidUniverse();
        // Forward to the heir if this universe has forked.
        // If heir is not 0 and not itself, then the universe has forked.
        uint248 heirId = universe.heir;
        if (heirId != universeId && heirId != 0) {
            universe = universes[heirId];
            if (address(universe.repToken) == address(0)) revert InvalidUniverse();
            activeUniverseId = heirId;
        } else {
            activeUniverseId = universeId;
        }
    }

    function _getActiveUniverseAndRepToken(uint248 universeId)
        internal
        view
        returns (uint248 activeUniverseId, Universe storage universe, ILituusRep repToken)
    {
        (activeUniverseId, universe) = _getActiveUniverse(universeId);
        // Sanity check: if the universe is not active or forming,
        // then the reporting should have been forwarded to the heir.
        ForkState forkState = universe.forkState;
        if ((forkState != ForkState.NotForking) && (forkState != ForkState.Forming)) {
            revert InvalidUniverseState();
        }
        repToken = universe.repToken;
    }

    function _getAndUpdateQueryCreateTime(uint248 universeId, uint256 queryId)
        internal
        returns (uint48 queryCreateTime)
    {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.queryCreateTime != 0) {
            return resolution.queryCreateTime;
        } else {
            // TODO: check query flow after forks
            // If the queryCreateTime is not set, it means the query was not created in this universe but was reported
            // on in this universe. In this case, we should use the forkTime of the universe as the queryCreateTime,
            // since the query becomes reportable in this universe after the fork.
            Universe storage universe = universes[universeId];
            queryCreateTime = universe.forkTime;
            resolution.queryCreateTime = uint48(queryCreateTime);
            return queryCreateTime;
        }
    }
}
