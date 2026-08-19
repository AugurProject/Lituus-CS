// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IZoltar, IZoltarQuestionData } from "./interfaces/IZoltar.sol";
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
    // Query outcomes:
    // 0 - UNRESOLVED
    // 1..numberOfOutcomes - valid outcomes (a query has 2..254 of them; 1 is YES and 2 is NO for a binary query)
    // 255 - INVALID
    uint8 public constant MAX_OUTCOMES = 254; // number of outcomes for a query (not including UNRESOLVED and INVALID)
    uint8 public constant MIN_OUTCOMES = 2; // minimum number of valid outcomes for a query
    uint8 public constant MAX_FORK_OUTCOMES = 2; // number of outcomes for a forking query
    uint8 public constant UNRESOLVED = 0; // the query is not resolved yet
    uint8 public constant INVALID = 255; // an invalid outcome value used for reporting an invalid fork outcome during
    // fork resolution. It is outside the valid outcome range [1, MAX_OUTCOMES]
    // TODO: determine the max query length based on gas costs
    uint16 public constant MAX_QUERY_LENGTH = 2058; // maximum length of a query string

    uint256 public constant THREE_DAYS = 3 days;
    uint256 public constant SIXTY_DAYS = 60 days;
    uint256 public constant ONE_DAY = 1 days;
    // This is the divider for the burn depending on losingStakes on a query.
    // If burn ratio is 20% (1/5), then BURN_DIVIDER is 5.
    uint256 public constant BURN_DIVIDER = 5;

    uint256 public constant SCALE = 1 ether;
    // The volume for a three day window that needs to get booted in (when we need to calculate pre genesis).
    uint256 public constant BOOT_VOLUME = 3;

    // The profit for a three day window that needs to get booted in (when we need to calculate pre genesis).
    // Calculated in constructor as 2 * INITIAL_BASE_FEE of Controller.
    uint256 public immutable BOOT_PROFIT;
    uint256 public immutable GENESIS_TIMESTAMP;
    IZoltar public immutable ZOLTAR;
    // The ZoltarQuestionData contract is immutable in Zoltar so it can be cached here.
    IZoltarQuestionData public immutable ZOLTAR_QUESTION_DATA;
    IQueryFeeController public immutable QUERY_FEE_CONTROLLER;

    /* ================================================== ENUMS ================================================== */
    enum UniverseState {
        NotExisting, // 0 - universe does not exist yet
        Active, // 1 - default; universe is operating normally, not forking
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
        // Escalation settlement totals, frozen at resolution, so claim() computes each payout in O(1).
        // totalDistributable is the losers' pool minus the burn cut, computed once at resolution.
        // REP amounts are bounded by max supply (100M * 1e18), comfortably within uint96.
        uint96 totalDistributable;
        uint96 winnerStaked;
        // The stakes for this query.
        Stake[] stakes;
    }

    struct Universe {
        ILituusRep repToken;
        UniverseState universeState;
        uint48 forkTime;
        // The depth of the universe in the fork tree
        // Genesis universe has depth 0, its children have depth 1, etc. Max 256.
        uint16 forkDepth;
        // Whether this universe lies on the canonical timeline (the genesis -> favoriteChild -> ... chain).
        // Genesis is canonical; on a fork, only the designated favoriteChild inherits the parent's flag.
        bool isCanonical;
        uint248 parent;
        // The child on the canonical timeline. On a fork, one child is designated the favoriteChild and
        // inherits the parent's canonical flag; the other branches stay non-canonical.
        uint248 favoriteChild;
        // The current universe for this lineage. On fork finalization every ancestor's heir is
        // repointed to the final current universe (not just the immediate child), so resolving the current
        // universe is always a single hop with no chain walk.
        uint248 heir;
        // History format:
        // Genesis universe has history 0, depth 0.
        // First children have history 0b00 and 0b01, depth 1,
        // second children of the second child 0b010 and 0b011, depth 2, etc.
        bytes32 history;
        // Packed together into one slot. forkQuery is a query id; supplyBeforeFork is a REP amount
        // (<= 100M * 1e18), both comfortably within uint128.
        uint128 forkQuery;
        uint128 supplyBeforeFork;
        address queryTokenizer;
        uint8 forkOutcome;
        bool isLituusFork; // If it's not Lituus fork then no payouts are necessary
    }

    struct UniverseStatistics {
        // All the 3-day info needed for every universe for the dynamic query fee calculation.
        mapping(uint256 threeDayId => ThreeDayInfo) threeDayInfo;
        // A 60-day volume kept for gas reasons. It is updated per query, instead of doing 20 SLOADS.
        uint128 sixtyDayVolume;
        // The id of the 3-day-window that last query was created into.
        uint128 lastWindowId;
    }

    struct ThreeDayInfo {
        // The 3-day profit of the universe for this specific 3-day info.
        uint128 threeDayProfit;
        // The 3-day volume aka number of the queries created of the universe for this specific 3-day info.
        uint128 threeDayVolume;
    }

    /* ================================================ VARIABLES ================================================ */
    mapping(uint248 universeId => Universe) public universes;
    mapping(uint248 universeId => UniverseStatistics) public universeStatistics;
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
    event StakeClaimed(
        address indexed reporter,
        uint248 indexed universeId,
        uint256 indexed queryId,
        uint256 stakeIndex,
        uint256 payout
    );
    // The first correct reporter's share of the query fee, paid when the escalation game resolves.
    event ReporterRewardPaid(
        address indexed reporter, uint248 indexed universeId, uint256 indexed queryId, uint256 amount
    );
    // The resolver's share of the query fee for resolving an unreported query INVALID after expiry.
    event ResolverRewardPaid(
        address indexed resolver, uint248 indexed universeId, uint256 indexed queryId, uint256 amount
    );

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
    error ZoltarQueryCreationFailed();
    error ZoltarUniverseIsNotForking();
    error InvalidZoltarQuestion();
    error QueryTooLong();
    error ZeroFee();
    error ZeroStakeAmount();
    error AmbiguousAmount();
    error QueryNotInherited();
    error ForkingNotImplemented();
    error QueryNotResolved();
    error StakeAlreadyClaimed();
    error NotAWinningStake();
    error NotStakeOwner();
    error InvalidClaimBatch();
    error InvalidStakeIndex();

    /* =============================================== CONSTRUCTOR =============================================== */
    /**
     * @notice Wires the Zoltar address, seeds the genesis universe, and sets the fee controller.
     * @param _zoltar The Zoltar address.
     * @param _initialZoltarUniverseId The Zoltar universe id treated as the Lituus genesis. It is also
     * the genesis universe's id here: Lituus universe ids mirror Zoltar universe ids.
     * @param _queryFeeController The controller owning each universe's monthly base fee.
     */
    constructor(IZoltar _zoltar, uint248 _initialZoltarUniverseId, IQueryFeeController _queryFeeController) {
        ZOLTAR = _zoltar;
        if (address(ZOLTAR) == address(0)) revert ZeroAddress();
        ZOLTAR_QUESTION_DATA = ZOLTAR.zoltarQuestionData();
        if (address(ZOLTAR_QUESTION_DATA) == address(0)) revert ZeroAddress();
        QUERY_FEE_CONTROLLER = _queryFeeController;
        if (address(QUERY_FEE_CONTROLLER) == address(0)) revert ZeroAddress();

        // get the REP token address from the initial universe in Zoltar
        IReputationToken initialZoltarRepToken = ZOLTAR.getRepToken(_initialZoltarUniverseId);
        // deploy a Lituus REP token that wraps the Zoltar REP token
        // token symbol will use universe.history as a suffix. Genesis universe will have symbol "REP0"
        // TODO: Discuss the format of the suffix if the forks are for binary queries.
        ILituusRep repToken =
            new LituusRep(address(this), address(initialZoltarRepToken), "Lituus Reputation Token", "REP0", SCALE);

        // Lituus universe ids mirror Zoltar universe ids (children already use Zoltar's child ids via
        // getChildUniverseId), so the genesis must be keyed by its Zoltar id.
        Universe storage genesisUniverse = universes[_initialZoltarUniverseId];
        genesisUniverse.favoriteChild = 0;
        genesisUniverse.parent = 0;
        genesisUniverse.repToken = repToken;
        genesisUniverse.universeState = UniverseState.Active;
        genesisUniverse.forkTime = uint48(block.timestamp);
        genesisUniverse.heir = 0;
        // Genesis is the root of the fork tree: an empty inheritance path, and the root of the canonical timeline.
        genesisUniverse.history = 0;
        genesisUniverse.forkDepth = 0;
        genesisUniverse.isCanonical = true;
        genesisUniverse.forkQuery = 0;
        // TODO: fill in the correct supply
        genesisUniverse.supplyBeforeFork = uint128(ZOLTAR.getUniverseTheoreticalSupply(_initialZoltarUniverseId));
        genesisUniverse.queryTokenizer = address(0);

        GENESIS_TIMESTAMP = block.timestamp;
        BOOT_PROFIT = 2 * QUERY_FEE_CONTROLLER.INITIAL_BASE_FEE();
    }

    /* ============================================= WRAP FUNCTIONS ============================================== */
    /**
     * @notice Wraps a universe's underlying Zoltar REP into its Lituus REP (wREP) for the caller.
     * @dev wREP is a share token over the universe's REP vault (1:1 at genesis; the rate only
     *      rises as losing stakes are burned - see ILituusRep for the accounting model). Exactly
     *      one of the two amounts must be nonzero: with `assetsToProvide` the caller fixes the
     *      underlying spent and the shares received round down, with `sharesToReceive` the caller
     *      fixes the shares received and the underlying pulled rounds up. Both roundings favor
     *      the vault.
     * @param universeId The universe whose REP token to wrap into.
     * @param assetsToProvide The exact amount of underlying REP to spend (0 to fix shares instead).
     * @param sharesToReceive The exact amount of wREP shares to receive (0 to fix assets instead).
     * @return assets The amount of underlying REP pulled from the caller.
     * @return shares The amount of wREP shares minted to the caller.
     */
    function wrap(uint248 universeId, uint256 assetsToProvide, uint256 sharesToReceive)
        external
        returns (uint256 assets, uint256 shares)
    {
        if ((assetsToProvide == 0) == (sharesToReceive == 0)) revert AmbiguousAmount();

        // TODO: check universe status
        // TODO: maybe check if some fork is upcoming (some escalation game is close to fork threshold)
        ILituusRep repToken = universes[universeId].repToken;
        if (assetsToProvide > 0) {
            assets = assetsToProvide;
            shares = repToken.wrap(msg.sender, assetsToProvide);
        } else {
            shares = sharesToReceive;
            assets = repToken.wrapShares(msg.sender, sharesToReceive);
        }
    }

    /**
     * @notice Unwraps a universe's Lituus REP (wREP) back into the underlying Zoltar REP for the caller.
     * @dev The underlying is valued at the vault's stored assets-per-share rate, so it carries the
     *      appreciation accrued from burned stakes. Exactly one of the two amounts must be
     *      nonzero: with `sharesToProvide` the caller fixes the shares burned and the underlying
     *      received rounds down, with `assetsToReceive` the caller fixes the underlying received
     *      and the shares burned round up. Both roundings favor the vault. Reverts while
     *      unwrapping is paused on the vault.
     * @param universeId The universe whose REP token to unwrap from.
     * @param sharesToProvide The exact amount of wREP shares to unwrap (0 to fix assets instead).
     * @param assetsToReceive The exact amount of underlying REP to receive (0 to fix shares instead).
     * @return shares The amount of wREP shares burned from the caller.
     * @return assets The amount of underlying Zoltar REP released to the caller.
     */
    function unwrap(uint248 universeId, uint256 sharesToProvide, uint256 assetsToReceive)
        external
        returns (uint256 shares, uint256 assets)
    {
        if ((sharesToProvide == 0) == (assetsToReceive == 0)) revert AmbiguousAmount();

        // TODO: check universe status
        ILituusRep repToken = universes[universeId].repToken;
        if (sharesToProvide > 0) {
            shares = sharesToProvide;
            assets = repToken.unwrap(msg.sender, sharesToProvide);
        } else {
            assets = assetsToReceive;
            shares = repToken.unwrapAssets(msg.sender, assetsToReceive);
        }
    }

    /* ============================================= QUERY FUNCTIONS ============================================= */
    /**
     * @notice Creates a query in a universe, charging the dynamic fee and recording it as demand volume.
     * @dev Fee = controller base fee times the short-term demand modifier (see _calculateFeeAndApplyVolume).
     *      The query is counted in the current 3-day volume bucket only after its own fee is computed.
     *      The fee must be nonzero and is capped at half the universe's fork threshold — the fee doubles
     *      as the first report's stake, and any stake exceeding half the threshold is clamped up to the
     *      full threshold (a fork-level stake), so an uncapped fee above half would make the very first
     *      report the fork trigger. At the cap, the first report is an ordinary stake and the fork level
     *      can only be reached by escalating (the second report).
     * @param universeId The universe to create the query in (forwarded to the heir if it has forked).
     * @param question The question text alongside the possible answers (to be checked).
     * @param numberOfOutcomes The number of reportable outcomes (UNRESOLVED and INVALID are always available
     * separately).
     */
    function createQuery(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external nonReentrant {
        (uint248 currentUniverseId, Universe storage currentUniverse) = _getCurrentUniverse(universeId);
        // Queries can only be created in an operating or still-forming universe; any later state
        // should already have been forwarded to the heir.
        UniverseState universeState = currentUniverse.universeState;
        if ((universeState != UniverseState.Active) && (universeState != UniverseState.Forming)) {
            revert InvalidUniverseState();
        }

        // Validate the question and number of outcomes
        // Only meaningful outcomes should be included. UNRESOLVED and INVALID are accounted for separately
        if (numberOfOutcomes < MIN_OUTCOMES) revert InvalidNumberOfOutcomes();
        if (numberOfOutcomes > MAX_OUTCOMES) revert InvalidNumberOfOutcomes();
        if (bytes(question).length > MAX_QUERY_LENGTH) revert QueryTooLong();

        // TODO: Here we need to actually check if question contains the same numberOfOutcomes needed.

        // get the base fee amount from the query fee controller
        uint256 baseFee = QUERY_FEE_CONTROLLER.getQueryFee(currentUniverseId);
        // Create a global query record

        // calculate the fee depending on previous volume and update the volume
        uint256 fee = _calculateFeeAndApplyVolume(currentUniverseId, baseFee);
        if (fee == 0) revert ZeroFee();
        // The first report's stake equals the query fee, and any stake that exceeds half the fork
        // threshold is clamped up to the full threshold (a fork-level stake) — the same rule
        // _requiredStakeAmountAndForkThreshold applies. Capping the fee at exactly half keeps the
        // first report an ordinary stake; the fork level can then only be reached by escalating.
        uint256 forkThreshold = ZOLTAR.getForkThreshold(currentUniverseId) / 2;
        if (fee >= forkThreshold) fee = forkThreshold;
        // transfer the query fee amount of REP token
        // TODO: permit? permit2?
        currentUniverse.repToken.safeTransferFrom(msg.sender, address(this), fee);

        Query storage query = queries[queryCount];
        query.numberOfOutcomes = numberOfOutcomes;
        query.originUniverse = currentUniverseId;
        query.fee = fee;
        query.question = question;

        // A universe-specific resolution record starts with outcome == UNRESOLVED.
        // Set the queryCreateTime so the reporting window can be enforced in this universe.
        QueryResolution storage resolution = queryResolutions[currentUniverseId][queryCount];
        resolution.queryCreateTime = uint48(block.timestamp);

        emit QueryCreated(msg.sender, queryCount, currentUniverseId, question, numberOfOutcomes);

        queryCount++;
    }

    /**
     * @notice Reports an outcome on a query, posting the required escalation stake.
     * @dev Forwards to the heir if the universe has forked. Rejects reports on queries already resolved
     *      here or in an ancestor lineage. A query created in another universe is reportable here only
     *      if it was inherited through a fork, i.e. this universe descends from the query's origin.
     *      The first report must fall within THREE_DAYS of the query
     *      becoming reportable; each subsequent report must differ from the previous outcome and land
     *      within the ONE_DAY appeal window. The required stake doubles each escalation; reaching the
     *      fork threshold is meant to trigger a fork.
     * @param universeId The universe to report in.
     * @param queryId The query being reported on.
     * @param outcome The reported outcome (1..numberOfOutcomes, or INVALID).
     */
    function report(uint248 universeId, uint256 queryId, uint8 outcome) external nonReentrant {
        // Check all conditions (universe exists, query exists, outcome is valid, report is within time, etc.)
        (uint248 currentUniverseId, Universe storage currentUniverse) = _getCurrentUniverse(universeId);
        // Reports can only be placed in an operating or still-forming universe; any later state
        // should already have been forwarded to the heir.
        UniverseState universeState = currentUniverse.universeState;
        if ((universeState != UniverseState.Active) && (universeState != UniverseState.Forming)) {
            revert InvalidUniverseState();
        }

        Query storage query = queries[queryId];
        if (query.numberOfOutcomes == 0) revert InvalidQuery();

        QueryResolution storage resolution = queryResolutions[currentUniverseId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();
        uint256 numberOfStakes = resolution.stakes.length;
        // A query resolved in an ancestor universe is inherited by this lineage (via getOutcome), so it
        // cannot be reported on again here. The ancestor set is fixed per lineage, so this only needs to
        // be checked on the first report; later stakes in the same escalation are already covered.
        if (numberOfStakes == 0 && _findAncestorResolution(currentUniverseId, queryId) != UNRESOLVED) {
            revert QueryAlreadyResolved();
        }

        // Outcome should be between 1 and numberOfOutcomes unless the query should be reported as INVALID
        if (outcome == UNRESOLVED) revert InvalidOutcome();
        if ((outcome > query.numberOfOutcomes) && (outcome != INVALID)) revert InvalidOutcome();

        uint48 queryCreateTime = _getAndUpdateQueryCreateTime(currentUniverseId, queryId);

        // check that the reporting window for the query is not over yet
        if (numberOfStakes == 0 && queryCreateTime + THREE_DAYS < block.timestamp) revert QueryExpired();

        // Check that the last outcome is not the same as the current outcome, and the appeal period hasn't expired.
        if (numberOfStakes > 0) {
            Stake storage lastStake = resolution.stakes[numberOfStakes - 1];
            if (lastStake.reportedOutcome == outcome) revert OutcomeSameAsPrevious();
            if (lastStake.time + ONE_DAY < block.timestamp) revert AppealPeriodOver();
        }

        (uint256 requiredStakeAmount, uint256 forkThreshold) =
            _requiredStakeAmountAndForkThreshold(currentUniverseId, queryId);
        // a zero stake would allow free reports and an escalation ladder stuck at 0.
        if (requiredStakeAmount == 0) revert ZeroStakeAmount();
        // TODO: If the bond before a fork bond is placed so that the next appeal would cause a fork,
        // and its not possible to fork because the parent has still not resolved their fork,
        // then the bond placing is reverted and the query is frozen until the parent universe resolves the fork.

        // transfer the stake
        currentUniverse.repToken.safeTransferFrom(msg.sender, address(this), requiredStakeAmount);

        if (requiredStakeAmount >= forkThreshold) {
            // TODO: fork logic in a separate call
            // If the universe cannot fork then:
            // revert or keep the stake and freeze the query (TBD)
            // Check conditions:
            // 1. Current state of the universe
            // 2. Zoltar universe is not forking

            // Fork the universe here and in Zoltar and create child universes
            // If Zoltar doesn't allow forking (maybe due to rate limiting)
            // then accept the stake and freeze the query
            revert ForkingNotImplemented();
        }

        // Update the resolution record for the universe
        Stake[] storage stakes = resolution.stakes;
        stakes.push();

        Stake storage newStake = stakes[numberOfStakes];
        newStake.reporter = msg.sender;
        newStake.time = uint48(block.timestamp);
        newStake.reportedOutcome = outcome;
        newStake.amount = requiredStakeAmount;

        emit QueryReported(msg.sender, currentUniverseId, queryId, outcome, requiredStakeAmount);
    }

    /**
     * @notice Resolves a query whose reporting or appeal window has elapsed, recording its outcome.
     * @dev Forwards to the heir if the universe has forked. Two cases:
     *      (1) no report ever landed and the THREE_DAYS reporting window passed ->
     *      resolves INVALID (after the ancestor-inheritance check report() never ran).
     *      (2) stakes exist and the last one's ONE_DAY appeal window passed
     *      -> resolves to the escalation outcome and settles payoffs; otherwise reverts as not-ready.
     *
     *      After resolving, if the Zoltar counterpart has started forking, the fork is mirrored here.
     * @param universeId The universe to resolve in.
     * @param queryId The query to resolve.
     */
    function resolve(uint248 universeId, uint256 queryId) external nonReentrant {
        (uint248 currentUniverseId, Universe storage currentUniverse) = _getCurrentUniverse(universeId);
        // Queries can only be resolved in an operating or still-forming universe; any later state
        // should already have been forwarded to the heir.
        UniverseState universeState = currentUniverse.universeState;
        if ((universeState != UniverseState.Active) && (universeState != UniverseState.Forming)) {
            revert InvalidUniverseState();
        }

        Query storage query = queries[queryId];
        if (query.numberOfOutcomes == 0) revert InvalidQuery();

        QueryResolution storage resolution = queryResolutions[currentUniverseId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();

        uint48 queryCreateTime = _getAndUpdateQueryCreateTime(currentUniverseId, queryId);

        if (resolution.stakes.length == 0 && queryCreateTime + THREE_DAYS < block.timestamp) {
            // No report ever landed here, so the ancestor check was never run by report(): a query
            // resolved in an ancestor is inherited by this lineage (via getOutcome) and must not be
            // resolved again. The stakes branch below is already covered by report()'s first-stake check.
            if (_findAncestorResolution(currentUniverseId, queryId) != UNRESOLVED) revert QueryAlreadyResolved();
            // if the report period has passed and the query was not reported on then resolve the query as INVALID
            resolution.outcome = INVALID;
            _recordResolvedUniverse(queryId, currentUniverseId, currentUniverse.isCanonical);

            // The resolver setting this query to INVALID earns a share of the fee
            // that ramps from 0 at the reporting deadline to the full fee three days later, then stays
            // whole with no deadline.
            uint256 queryFee = queries[queryId].fee;
            uint256 resolverPay = _timeBasedFeeShare(queryFee, block.timestamp - (queryCreateTime + THREE_DAYS));
            emit ResolverRewardPaid(msg.sender, currentUniverseId, queryId, resolverPay);
            currentUniverse.repToken.safeTransfer(msg.sender, resolverPay);
            // The unpaid fee remainder is the query's profit: recorded for the fee controller and
            // burned as wREP, the same as on the stakes path.
            if (queryFee - resolverPay > 0) {
                currentUniverse.repToken.burnShares(queryFee - resolverPay);
            }
            _applyProfit(currentUniverseId, queryFee - resolverPay);

            emit QueryResolved(msg.sender, currentUniverseId, queryId, INVALID);
        } else if (resolution.stakes.length > 0) {
            if (resolution.stakes[resolution.stakes.length - 1].time + ONE_DAY < block.timestamp) {
                // If there are stakes and the appeal period has passed then resolve the query with the last outcome
                // TODO: Unless the query is 1 step from fork threshold, then we should wait for the fork to finish
                uint8 outcome = _calculateOutcomeAndEscalationPayoffs(currentUniverseId, queryId);
                resolution.outcome = outcome;
                _recordResolvedUniverse(queryId, currentUniverseId, currentUniverse.isCanonical);
                emit QueryResolved(msg.sender, currentUniverseId, queryId, outcome);
            } else {
                // appeal period is not over yet, cannot resolve
                revert QueryNotReadyToResolve();
            }
        } else {
            // otherwise, the query cannot be resolved yet
            revert QueryNotReadyToResolve();
        }

        if (currentUniverse.universeState == UniverseState.Active) {
            // check if Zoltar universe is forking
            if (ZOLTAR.universes(currentUniverseId).forkTime != 0) {
                // if Zoltar is forking, then we should mirror the fork in this universe
                _mirrorZoltarFork(currentUniverseId);
            }
        }
    }

    /**
     * @notice Claims a winning stake's payout from a resolved query: the stake back plus its pro-rata
     *         share of the losing stakes (after the burn cut).
     * @dev Payouts are computed from the totals frozen at resolution, never by looping stakes. A stake's
     *      amount is zeroed on settlement, so amount == 0 also applies as the claimed flag.
     * @param universeId The universe the query was resolved in.
     * @param queryId The resolved query.
     * @param stakeIndex The index of the stake being claimed.
     */
    function claim(uint248 universeId, uint256 queryId, uint256 stakeIndex) external nonReentrant {
        uint256 payout = _claim(universeId, queryId, stakeIndex);

        universes[universeId].repToken.safeTransfer(msg.sender, payout);

        emit StakeClaimed(msg.sender, universeId, queryId, stakeIndex, payout);
    }

    /**
     * @notice Claims multiple winning stakes of the caller across queries of one universe, in a single
     *         transfer.
     * @dev Entry i claims stakeIndices[i] on queryIds[i]; the two arrays must align and be non-empty.
     *      Same guards per stake as claim(). A repeated (queryId, stakeIndex) pair reverts on its second
     *      occurrence (amount == 0), failing the whole batch.
     * @param universeId The universe the queries were resolved in.
     * @param queryIds The resolved queries being claimed from.
     * @param stakeIndices The indices of the caller's stakes in the matching queries.
     */
    function claimMultiple(uint248 universeId, uint256[] calldata queryIds, uint256[] calldata stakeIndices)
        external
        nonReentrant
    {
        uint256 length = queryIds.length;
        if (length == 0 || length != stakeIndices.length) revert InvalidClaimBatch();

        uint256 totalPayout;
        for (uint256 i = 0; i < length;) {
            uint256 payout = _claim(universeId, queryIds[i], stakeIndices[i]);
            totalPayout += payout;

            emit StakeClaimed(msg.sender, universeId, queryIds[i], stakeIndices[i], payout);

            unchecked {
                i += 1;
            }
        }

        universes[universeId].repToken.safeTransfer(msg.sender, totalPayout);
    }

    /**
     * @notice Validates and settles a single stake for the caller, returning its payout.
     * @dev Only the stake's reporter can claim it. Zeroes the amount (the settled flag) before any
     *      transfer happens in the callers.
     * @param universeId The universe the query was resolved in.
     * @param queryId The resolved query the stake belongs to.
     * @param stakeIndex The index of the stake being claimed.
     * @return payout The stake amount plus its pro-rata share of the distributable losing stakes.
     */
    function _claim(uint248 universeId, uint256 queryId, uint256 stakeIndex) internal returns (uint256 payout) {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.outcome == UNRESOLVED) revert QueryNotResolved();

        if (stakeIndex >= resolution.stakes.length) revert InvalidStakeIndex();
        Stake storage stake = resolution.stakes[stakeIndex];
        if (stake.reporter != msg.sender) revert NotStakeOwner();

        uint256 amount = stake.amount;
        if (amount == 0) revert StakeAlreadyClaimed();
        if (stake.reportedOutcome != resolution.outcome) revert NotAWinningStake();

        // amount == 0 is the settled flag, which should be set before the transfer.
        stake.amount = 0;

        uint256 winnerStaked = uint256(resolution.winnerStaked);
        uint256 totalDistributable = uint256(resolution.totalDistributable);
        payout = amount + amount * totalDistributable / winnerStaked;
    }

    /* ========================================== QUERY FEE EXTERNALS ============================================ */
    /**
     * @notice Pushes a universe's recent realized profits to the fee controller to run its monthly
     *         base-fee hill-climb.
     * @dev Standalone for now; it will be called from the createQuery path once incentives are wired.
     *      Only pushes while the universe is not forking — the forking window must not move the fee.
     *      The controller enforces the once-a-month cadence itself.
     * @param universeId The universe whose base fee to update.
     */
    function updateBaseFee(uint248 universeId) external {
        if (universes[universeId].universeState != UniverseState.Active) revert InvalidUniverseState();

        (uint256 currentProfit, uint256 lastProfit) = _getProfits(universeId);
        QUERY_FEE_CONTROLLER.changeBaseFee(universeId, currentProfit, lastProfit);
    }

    /* ========================================== QUERY FEE INTERNALS ============================================ */
    /**
     * @notice Multiplies the monthly base fee by a short-term demand modifier and records this query
     *         in the current 3-day volume bucket.
     * @dev Demand is a live rolling 3-day window rebuilt from discrete buckets, so the fee neither ramps
     *      within a window nor goes stale. `w` is the current window, `vol[x]` a real stored bucket, and
     *      `f` the fraction of `w` elapsed. Bootstrap volume for pre-genesis windows is NEVER stored; it
     *      is added only to the local values below, so storage always holds real volume only.
     *
     *        lastThreeDayVolume = vol[w] + (1 - f) * prevWindowVolume
     *        lastSixtyDayVolume = vol[w] + sixtyDayVolume - f * oldestWindowVolume        (w >= 20)
     *                           = vol[w] + sixtyDayVolume + (20 - w) * BOOT_VOLUME         (w  < 20)
     *
     *      where `prevWindowVolume` / `oldestWindowVolume` fall back to BOOT_VOLUME when window `w-1` /
     *      `w-20` predates genesis. `sixtyDayVolume` is the running sum of the real windows `vol[w-1..w-20]`,
     *      rolled forward once per new window (completed real window in, real window now older than 60 days
     *      out; a gap >= 20 recomputes it from real storage). The query is counted only AFTER its fee is
     *      computed, so it never prices itself.
     * @param universeId The current universe the query is created in.
     * @param baseFee The monthly base fee from the controller, before the demand modifier.
     * @return fee The final query fee.
     */
    function _calculateFeeAndApplyVolume(uint248 universeId, uint256 baseFee) internal returns (uint256 fee) {
        UniverseStatistics storage stats = universeStatistics[universeId];
        uint256 currentThreeDayWindow = _getCurrentThreeDayWindow();
        uint256 lastWindow = stats.lastWindowId;

        // Roll the running sum forward. Storage holds REAL volume only — bootstrap is never stored,
        // so nothing bootstrap-related is added or subtracted here.
        if (currentThreeDayWindow > lastWindow) {
            uint256 sixtyDayVolume = stats.sixtyDayVolume;
            if (currentThreeDayWindow - lastWindow >= 20) {
                // Idle >= 60 days: every real window in range rolled out; recompute from real storage only.
                uint256 sum;
                for (uint256 i = 1; i <= 20;) {
                    // real window only; a window c-i predating genesis contributes 0 (bootstrap is not stored)
                    if (currentThreeDayWindow >= i) {
                        sum += stats.threeDayInfo[currentThreeDayWindow - i].threeDayVolume;
                    }
                    unchecked {
                        i += 1;
                    }
                }
                sixtyDayVolume = sum;
            } else {
                for (uint256 i = lastWindow; i < currentThreeDayWindow;) {
                    // сompleted window enters
                    sixtyDayVolume += stats.threeDayInfo[i].threeDayVolume; // completed real window enters
                    if (i >= 20) {
                        // Real window leaves; bootstrap never subtracted (no accounting for bootstrap).
                        sixtyDayVolume -= stats.threeDayInfo[i - 20].threeDayVolume;
                    }
                    unchecked {
                        i += 1;
                    }
                }
            }
            // running query count over the window range, far below the uint128 max
            // forge-lint: disable-next-line(unsafe-typecast)
            stats.sixtyDayVolume = uint128(sixtyDayVolume);
            // 3-day window index since genesis, far below the uint128 max
            // forge-lint: disable-next-line(unsafe-typecast)
            stats.lastWindowId = uint128(currentThreeDayWindow);
        }

        // fraction of the current window elapsed, in [0, SCALE)
        uint256 proportionOfCurrentWindow = ((block.timestamp - GENESIS_TIMESTAMP) % THREE_DAYS) * SCALE / THREE_DAYS;

        uint256 currentVolume = stats.threeDayInfo[currentThreeDayWindow].threeDayVolume;

        // previous window (w-1): real volume, or bootstrap if it predates genesis. Check done here, before the read
        uint256 previousVolume =
            currentThreeDayWindow >= 1 ? stats.threeDayInfo[currentThreeDayWindow - 1].threeDayVolume : BOOT_VOLUME;

        // recent 3-day (local): current partial + tail of the previous window
        uint256 lastThreeDayVolume = currentVolume + (SCALE - proportionOfCurrentWindow) * previousVolume / SCALE;

        // 60-day (local): current + real running sum, then trim the oldest window's rolled-out tail.
        // Bootstrap stays local only. In both branches the oldest window (real for w >= 20, bootstrap for
        // w < 20) contributes only its (1 - f) tail, since f of it has already slid out of the 60-day span.
        uint256 lastSixtyDayVolume = currentVolume + stats.sixtyDayVolume;
        if (currentThreeDayWindow >= 20) {
            // oldest window (w-20) is real: subtract the f-tail that rolled out
            uint256 oldestVolume = stats.threeDayInfo[currentThreeDayWindow - 20].threeDayVolume;
            lastSixtyDayVolume -= proportionOfCurrentWindow * oldestVolume / SCALE;
        } else {
            // missing pre-genesis windows are bootstrap. The (20 - w - 1) newer ones enter whole; the single
            // oldest (w-20) enters only its (1 - f) tail — same trimming the real branch applies
            lastSixtyDayVolume += (20 - currentThreeDayWindow - 1) * BOOT_VOLUME + (SCALE - proportionOfCurrentWindow)
                * BOOT_VOLUME / SCALE;
        }

        fee = baseFee * _calculateCurveModifier(lastSixtyDayVolume, lastThreeDayVolume) / SCALE;

        // count this query for future fees
        // a per-window query count, far below the uint128 max
        // forge-lint: disable-next-line(unsafe-typecast)
        stats.threeDayInfo[currentThreeDayWindow].threeDayVolume = uint128(currentVolume + 1);
    }

    /**
     * @notice Turns the demand ratio (recent 3-day volume vs the 60-day average) into the multiplier
     *         applied to the base fee.
     * @dev Ratio is SCALE-scaled: SCALE (1.0) means the recent rate equals the 60-day average. An empty
     *      60-day window (only possible with zero history) yields a neutral 1.0, so a brand-new or idle
     *      universe is not pushed to the bottom of the curve.
     *
     *      Above average (ratio >= SCALE): a gentle linear rise, 0.8 + 0.2 * ratio, so double the demand
     *      is only +20%. Since recent3 <= sixty always, ratio is bounded by 20 and this branch by 4.8x.
     *
     *      Below average (ratio < SCALE): a steep drop, 1 / (1 + 100 * (1 - ratio)^6). The 6th power is
     *      built iteratively (each step re-divided by SCALE) because (1 - ratio)^6 in SCALE fixed-point
     *      would overflow a direct exponentiation.
     *
     *      TODO: the below-average branch bottoms out near ~1% of the base fee; since the fee doubles as
     *      TODO: the reporting bond, a floor may be needed (needs testing).
     * @param lastSixtyDayVolume The reconstructed 60-day rolling volume (denominator).
     * @param lastThreeDayVolume The reconstructed 3-day rolling volume (numerator).
     * @return modifier_ The SCALE-scaled multiplier to apply to the base fee.
     */
    function _calculateCurveModifier(uint256 lastSixtyDayVolume, uint256 lastThreeDayVolume)
        internal
        pure
        returns (uint256 modifier_)
    {
        uint256 ratio = lastSixtyDayVolume == 0 ? SCALE : 20 * lastThreeDayVolume * SCALE / lastSixtyDayVolume;

        if (ratio >= SCALE) {
            // above average: gentle linear rise, slope 0.2
            modifier_ = (4 * SCALE) / 5 + ratio / 5;
        } else {
            // Below average: steep drop.
            uint256 shortage = SCALE - ratio;
            uint256 powered = SCALE;
            for (uint256 i = 0; i < 6;) {
                powered = powered * shortage / SCALE;
                unchecked {
                    i += 1;
                }
            }
            modifier_ = SCALE * SCALE / (SCALE + 100 * powered);
        }
    }

    /**
     * @notice Realized profit of the current and previous ~30-day periods for a universe, as live rolling
     *         windows, for the controller's monthly base-fee hill-climb.
     * @dev Same interpolation as the volume path. With `c` the current window and `f` the fraction of it
     *      elapsed, `currentProfit` is the 30 days ending now and `lastProfit` the 30 days before that:
     *        currentProfit = profit[c] + sum(profit[c-1..c-9]) + (1 - f) * profit[c-10]
     *        lastProfit    = f * profit[c-10] + sum(profit[c-11..c-19]) + (1 - f) * profit[c-20]
     *      The boundary window c-10 is split between the two periods; the oldest window c-20 contributes
     *      only its (1 - f) tail. Windows predating genesis fall back to BOOT_PROFIT (checked before each
     *      read). Profit only — no division here, so a zero period is harmless to the controller.
     * @param universeId The universe to read.
     * @return currentProfit Rolling realized profit over the last 30 days.
     * @return lastProfit Rolling realized profit over the 30 days before those.
     */
    function _getProfits(uint248 universeId) internal view returns (uint256 currentProfit, uint256 lastProfit) {
        UniverseStatistics storage stats = universeStatistics[universeId];
        uint256 currentThreeDayWindow = _getCurrentThreeDayWindow();
        // fraction of the current window elapsed, in [0, SCALE)
        uint256 proportionOfCurrentWindow = ((block.timestamp - GENESIS_TIMESTAMP) % THREE_DAYS) * SCALE / THREE_DAYS;

        // Current month: current window's partial profit + the 9 completed windows behind it.
        currentProfit = stats.threeDayInfo[currentThreeDayWindow].threeDayProfit;
        for (uint256 i = 1; i <= 9;) {
            currentProfit += currentThreeDayWindow >= i
                ? stats.threeDayInfo[currentThreeDayWindow - i].threeDayProfit
                : BOOT_PROFIT;
            unchecked {
                i += 1;
            }
        }

        // Boundary window c-10 is split: (1 - f) tail to the current month, f to the previous month.
        uint256 boundaryProfit =
            currentThreeDayWindow >= 10 ? stats.threeDayInfo[currentThreeDayWindow - 10].threeDayProfit : BOOT_PROFIT;
        currentProfit += (SCALE - proportionOfCurrentWindow) * boundaryProfit / SCALE;
        lastProfit += proportionOfCurrentWindow * boundaryProfit / SCALE;

        // Previous month: the 9 completed windows behind the boundary.
        for (uint256 i = 11; i <= 19;) {
            lastProfit += currentThreeDayWindow >= i
                ? stats.threeDayInfo[currentThreeDayWindow - i].threeDayProfit
                : BOOT_PROFIT;
            unchecked {
                i += 1;
            }
        }

        // oldest window c-20 contributes only its (1 - f) tail; the rest has rolled out of the 60-day span
        uint256 oldestProfit =
            currentThreeDayWindow >= 20 ? stats.threeDayInfo[currentThreeDayWindow - 20].threeDayProfit : BOOT_PROFIT;
        lastProfit += (SCALE - proportionOfCurrentWindow) * oldestProfit / SCALE;
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
     *      are NOT settled here — those are claimed separately through claim() (except the case of
     *      a single stake, which is settled here in one transfer).
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
        // Ramps to the full fee over the reporting window; a first correct report after day 3 earns it whole.
        uint256 reporterPay = _timeBasedFeeShare(queryFee, reportingTimestamp - queryCreateTime);

        uint256 loserBurn = totalLoserStakes / BURN_DIVIDER;
        uint256 profit = loserBurn + (queryFee - reporterPay);

        ILituusRep repToken = universes[universeId].repToken;

        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        // Store the escalation totals so claim() can compute each winner's payout without looping again.
        // Both are REP amounts bounded by max supply (100M * 1e18), within uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        resolution.totalDistributable = uint96(totalLoserStakes - loserBurn);
        // forge-lint: disable-next-line(unsafe-typecast)
        resolution.winnerStaked = uint96(winnerOutcomeStaked);

        emit ReporterRewardPaid(reporter, universeId, queryId, reporterPay);
        // Consecutive reports must differ, so no-losers <=> exactly one stake: settle the sole winner
        // here in one transfer (bond refund + reporter reward) instead of requiring a claim() call.
        // The two events stay separate so StakeClaimed payouts don't include a fee reward.
        if (resolution.stakes.length == 1) {
            resolution.stakes[0].amount = 0; // amount == 0 marks the stake settled
            emit StakeClaimed(reporter, universeId, queryId, 0, totalStaked);
            repToken.safeTransfer(reporter, reporterPay + totalStaked);
        }
        // with more than one stake, even the rewarded reporter must claim their bond separately
        else {
            repToken.safeTransfer(reporter, reporterPay);
        }
        // Burn the whole recorded profit as wREP - the losers' share of the pot plus the unpaid
        // fee remainder: destroying shares while the vault's asset ledger is untouched raises the
        // assets-per-share rate, so the burn accrues to every wREP holder ("value to wREP without
        // value to REP"). The underlying Zoltar REP is never burned here. _applyProfit records the
        // same amount for the fee controller; recording is accounting, the tokens themselves are
        // destroyed.
        if (profit > 0) {
            repToken.burnShares(profit);
        }

        _applyProfit(universeId, profit);

        return winnerOutcome;
    }

    /* ====================================== RESOLUTION INTERNAL FUNCTIONS ====================================== */
    /**
     * @notice Records a resolved query's profit into the universe's current 3-day
     *         bucket.
     * @dev The bucket is keyed by the 3-day window index derived from the global genesis anchor
     *      (`(block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS`). The sparse mapping avoids any
     *      age-dependent array padding and lets a fork copy a fixed window of buckets regardless of
     *      universe age. Both the windowed bucket and the running total are updated for revenue and
     *      profit.
     * @param universeId The id of the universe to credit.
     * @param profit The profit realized by the resolved query (the REP to be burned).
     */
    function _applyProfit(uint248 universeId, uint256 profit) internal {
        uint256 current3DayWindow = _getCurrentThreeDayWindow();
        ThreeDayInfo storage threeDayInfo = universeStatistics[universeId].threeDayInfo[current3DayWindow];

        // profit is a REP amount bounded by max supply (100M * 1e18), within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        threeDayInfo.threeDayProfit += uint128(profit);
    }

    /**
     * @notice Time-proportional share of a query fee: ramps linearly over THREE_DAYS, then caps at the
     *         full fee with no deadline.
     * @dev Works both for the query fee after reporting and when no reporting exists (INVALID on resolve).
     * @param fee The query fee the share is drawn from.
     * @param elapsed Seconds since the ramp's origin.
     * @return The earned share.
     */
    function _timeBasedFeeShare(uint256 fee, uint256 elapsed) internal pure returns (uint256) {
        return elapsed >= THREE_DAYS ? fee : fee * elapsed / THREE_DAYS;
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

    /* ========================================== PUBLIC VIEW FUNCTIONS ========================================== */
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

        // Forward to the heir if this universe has forked, so we read from the current universe where
        // report()/resolve() record resolutions. Reverts only if the universe does not exist; outcomes
        // remain readable while the universe is forking (no fork-state check, unlike report/resolve).
        (uint248 currentUniverseId,) = _getCurrentUniverse(universeId);
        if (currentUniverseId != universeId) {
            uint8 heirOutcome = queryResolutions[currentUniverseId][queryId].outcome;
            if (heirOutcome != UNRESOLVED) return heirOutcome;
        }

        // Otherwise inherit the resolution from an ancestor universe, if any.
        return _findAncestorResolution(currentUniverseId, queryId);
    }

    /**
     * @notice Returns the stakes placed on a query in a universe.
     * @dev Rejects a nonexistent query; an existing query with no stakes in the given universe
     *      returns an empty array. Reads the raw per-universe record and does NOT forward to the
     *      heir — pass the universe the stakes were placed in. The escalation chain is short
     *      (stakes double towards the fork threshold), so returning the full array is safe.
     * @param universeId The universe whose resolution record to read.
     * @param queryId The query whose stakes to read.
     * @return The stakes placed on the query in that universe, in reporting order.
     */
    function getStakes(uint248 universeId, uint256 queryId) external view returns (Stake[] memory) {
        if (queries[queryId].numberOfOutcomes == 0) revert InvalidQuery();
        return queryResolutions[universeId][queryId].stakes;
    }

    /**
     * @notice Returns the stake the next report on a query must post, and the universe's fork threshold.
     * @dev Rejects a nonexistent query or universe. Forwards to the heir exactly like report()
     *      does, so `requiredStakeAmount` is the amount report() would pull from the caller. A
     *      required stake at or above `forkThreshold` means the next report triggers the fork path.
     * @param universeId The universe to report in (forwarded to the heir if it has forked).
     * @param queryId The query to report on.
     * @return requiredStakeAmount The stake the next reporter must post.
     * @return forkThreshold The stake level at which posting triggers a fork.
     */
    function getNextRequiredStake(uint248 universeId, uint256 queryId)
        external
        view
        returns (uint256 requiredStakeAmount, uint256 forkThreshold)
    {
        if (queries[queryId].numberOfOutcomes == 0) revert InvalidQuery();
        (uint248 currentUniverseId,) = _getCurrentUniverse(universeId);
        return _requiredStakeAmountAndForkThreshold(currentUniverseId, queryId);
    }

    /* ========================================= HISTORY FUNCTIONS =========================================== */

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

    /**
     * @notice Computes the stake required for the report on a query and the universe's fork threshold.
     * @dev The next stake is the query fee for the first report and double the previous stake for each
     *      subsequent report. Either way, once it exceeds half the fork threshold it is clamped up to the
     *      full fork threshold (a fork-level stake); a stake of exactly half is left untouched — its own
     *      doubling lands exactly on the threshold.
     * @param universeId The (current) universe the query lives in.
     * @param queryId The query being reported on.
     * @return requiredStakeAmount The stake the reporter must post.
     * @return forkThreshold The stake level at which posting triggers a fork.
     */
    function _requiredStakeAmountAndForkThreshold(uint248 universeId, uint256 queryId)
        internal
        view
        returns (uint256 requiredStakeAmount, uint256 forkThreshold)
    {
        forkThreshold = ZOLTAR.getForkThreshold(universeId);

        Stake[] storage stakes = queryResolutions[universeId][queryId].stakes;
        uint256 numberOfStakes = stakes.length;

        // The first report's stake is the query fee; each escalation doubles the previous stake.
        uint256 nextStakeAmount;
        if (numberOfStakes == 0) {
            nextStakeAmount = queries[queryId].fee;
        } else {
            uint256 lastStakeAmount = stakes[numberOfStakes - 1].amount;
            nextStakeAmount = lastStakeAmount * 2;
        }

        // Once the next stake exceeds half the fork threshold, clamp it to the full threshold so the
        // escalation ends exactly at the fork level instead of overshooting it on the next doubling.
        bool reachesForkLevel = nextStakeAmount > forkThreshold / 2;
        requiredStakeAmount = reachesForkLevel ? forkThreshold : nextStakeAmount;
    }

    /* ==================================== TOKEN SUPPLY MANAGEMENT FUNCTIONS ==================================== */
    /**
     * @notice Migration, auction, and other token supply management functions.
     */

    /* ============================================ FORKING FUNCTIONS ============================================ */
    /// @notice Internal function for forking the universe
    /// @dev All preconditions should be checked before calling this function.
    function _forkLituusUniverse(uint248 universeId, uint256 queryId, uint8 outcomeId) internal {
        Universe storage universe = universes[universeId];
        // Create a question in ZOLTAR
        // Form a string for the question.
        // The question will be:
        // "Is Green the valid outcome to the question "Color of the sky: Red/Blue/Green"?"
        // Outcomes are YES and NO.
        string memory question = _createForkQuestionString(queryId, outcomeId);

        IZoltarQuestionData.QuestionData memory questionData;
        questionData.title = question;
        questionData.description = "";
        questionData.startTime = block.timestamp - 1 days;
        // in Zoltar: require(block.timestamp >= endTime, 'Question has not ended');
        questionData.endTime = block.timestamp - 1 days;
        questionData.numTicks = 0;
        questionData.displayValueMin = 0;
        questionData.displayValueMax = 0;
        questionData.answerUnit = "";

        string[] memory outcomes = new string[](2);
        outcomes[0] = "NO";
        outcomes[1] = "YES";

        // Create a ZOLTAR binary fork query
        uint256 zoltarQueryId = ZOLTAR_QUESTION_DATA.createQuestion(questionData, outcomes);
        if (zoltarQueryId == 0) revert ZoltarQueryCreationFailed();

        // REP token will get burned by Zoltar without approval
        // Create a fork in ZOLTAR
        // TODO: possibly wrap in try-catch to avoid wasting gas if the decision is to keep the fork stake
        ZOLTAR.forkUniverse(universeId, zoltarQueryId);
        // Deploy child universes in Zoltar
        // NO-universe
        ZOLTAR.deployChild(universeId, 0);
        // YES-universe
        ZOLTAR.deployChild(universeId, 1);
        _spawnChildUniverse(universeId, queryId, outcomeId, 0);
        _spawnChildUniverse(universeId, queryId, outcomeId, 1);
        // TODO: Split the REP token supply in the child universes via Zoltar
        universe.universeState = UniverseState.Migration;
        // queryId indexes queries by count, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.forkQuery = uint128(queryId);
        universe.isLituusFork = true;
        universe.forkOutcome = outcomeId;
    }

    /**
     * @notice Creates one child universe for a forking branch and links it into the fork tree.
     * @dev Deploys the child's Lituus REP wrapping the child's Zoltar REP, sets parent/history/depth via
     *      LibHistory.appendHistory, marks it Forming, and snapshots its pre-fork theoretical supply. On the
     *      YES branch (zoltarOutcomeId == 1) it resolves the forking query to forkingOutcomeId and records
     *      the resolution so descendants inherit it via the ancestor scan; the NO branch leaves it unresolved.
     *      Children are non-canonical at spawn — the favoriteChild is designated at fork finalization.
     * @param universeId The parent universe forking.
     * @param queryId The query that caused the fork.
     * @param forkingOutcomeId The outcome the forking query resolves to in the YES child.
     * @param zoltarOutcomeId The Zoltar branch id (0 = NO, 1 = YES).
     */
    function _spawnChildUniverse(uint248 universeId, uint256 queryId, uint8 forkingOutcomeId, uint8 zoltarOutcomeId)
        internal
    {
        uint248 childUniverseId = ZOLTAR.getChildUniverseId(universeId, zoltarOutcomeId);
        if (childUniverseId == 0) revert InvalidUniverse();
        // Never overwrite an existing universe.
        if (universes[childUniverseId].universeState != UniverseState.NotExisting) revert InvalidUniverse();

        Universe storage parentUniverse = universes[universeId];

        IReputationToken childUniverseZoltarRepToken = ZOLTAR.getRepToken(childUniverseId);
        // Deploy a Lituus REP token that wraps the Zoltar REP token
        // TODO: Discuss the format of the suffix if the forks are for binary queries.
        // The child vault starts at the parent's current rate so the appreciation accrued from
        // burns carries into the child universe instead of resetting to 1:1.
        ILituusRep childUniverseRepToken = new LituusRep(
            address(this),
            address(childUniverseZoltarRepToken),
            "Lituus Reputation Token",
            "REP0.0",
            parentUniverse.repToken.rate()
        );
        Universe storage childUniverse = universes[childUniverseId];
        childUniverse.repToken = childUniverseRepToken;
        childUniverse.universeState = UniverseState.Forming;
        childUniverse.forkTime = uint48(block.timestamp);
        childUniverse.parent = universeId;
        childUniverse.favoriteChild = 0;
        childUniverse.heir = 0;

        // TODO: inherit the parent's base fee

        // The child extends the parent's inheritance path by the branch it was spawned on.
        (childUniverse.history, childUniverse.forkDepth) =
            LibHistory.appendHistory(parentUniverse.history, parentUniverse.forkDepth, zoltarOutcomeId);
        // isCanonical stays false at spawn time: only the favoriteChild inherits the canonical flag,
        // and it is designated at fork finalization.
        childUniverse.forkQuery = 0;
        childUniverse.supplyBeforeFork = uint128(ZOLTAR.getUniverseTheoreticalSupply(childUniverseId));

        // Set outcomes in forking queries in child universes
        QueryResolution storage resolution = queryResolutions[childUniverseId][queryId];
        resolution.queryCreateTime = uint48(block.timestamp);
        if (zoltarOutcomeId == 1) {
            // The query is resolved in the Yes-universe
            resolution.outcome = forkingOutcomeId;
            // Record the resolution so descendants of the Yes-universe inherit it via the ancestor scan.
            // Children are never canonical at spawn time (the favoriteChild is designated at fork finalization).
            _recordResolvedUniverse(queryId, childUniverseId, false);
        }
    }

    /**
     * @notice Mirrors an in-progress Zoltar fork into this Multiverse, spawning the matching child universes.
     * @dev Reentrancy-guarded external wrapper over _mirrorZoltarFork. Reverts unless this universe is
     *      Active and its Zoltar counterpart is actually forking.
     * @param universeId The universe whose Zoltar fork to mirror.
     */
    function mirrorZoltarFork(uint248 universeId) external nonReentrant {
        _mirrorZoltarFork(universeId);
    }

    /// @dev Guard-free internal variant
    function _mirrorZoltarFork(uint248 universeId) internal {
        // TODO
        // Check if the universe can fork (state of the universe)
        Universe storage universe = universes[universeId];
        if (universe.universeState != UniverseState.Active) revert InvalidUniverseState();
        // Check if ZOLTAR universe is forking, revert if it's not forking
        IZoltar.Universe memory zoltarUniverse = ZOLTAR.universes(universeId);
        if (zoltarUniverse.forkTime == 0) revert ZoltarUniverseIsNotForking();

        // Import a ZOLTAR binary fork query
        uint256 forkQuestionId = zoltarUniverse.forkQuestionId;
        IZoltarQuestionData.QuestionData memory questionData = ZOLTAR_QUESTION_DATA.questions(forkQuestionId);
        if (questionData.endTime == 0) revert InvalidZoltarQuestion();

        uint256 queryId = queryCount;

        Query storage query = queries[queryId];
        query.numberOfOutcomes = 2; // 1 is NO, 2 is YES (0 stays UNRESOLVED)
        query.originUniverse = universeId;
        query.fee = 0;
        query.question = questionData.title;

        emit QueryCreated(msg.sender, queryId, universeId, questionData.title, 2);

        queryCount++;

        // Spawn child universes. The mirrored query resolves as YES (outcome 2) in the YES-child only;
        // in the NO-child it stays unresolved.
        // TODO: what if the Zoltar query has more than 2 outcomes?
        _spawnChildUniverse(universeId, queryId, 2, 0);
        _spawnChildUniverse(universeId, queryId, 2, 1);
        // Set outcomes in child universes and update their states to Forming
        universe.universeState = UniverseState.Migration;
        // queryId indexes queries by count, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.forkQuery = uint128(queryId);
        universe.forkOutcome = 2;
    }

    /* =========================================== INTERNAL HELPERS ============================================== */
    /**
     * @notice Resolves a universe id to the current universe, forwarding to the heir if it has forked.
     * @dev Reverts with InvalidUniverse only if the universe (or its heir) does not exist
     *      (universeState == NotExisting). Does NOT check the fork progress, so callers that must operate
     *      only on an active/forming universe (report/resolve) layer that check on top.
     */
    function _getCurrentUniverse(uint248 universeId)
        internal
        view
        returns (uint248 currentUniverseId, Universe storage currentUniverse)
    {
        currentUniverse = universes[universeId];
        if (currentUniverse.universeState == UniverseState.NotExisting) revert InvalidUniverse();
        // Forward to the heir if this universe has forked.
        // If heir is not 0 and not itself, then the universe has forked.
        uint248 heirId = currentUniverse.heir;
        if (heirId != universeId && heirId != 0) {
            currentUniverse = universes[heirId];
            if (currentUniverse.universeState == UniverseState.NotExisting) revert InvalidUniverse();
            currentUniverseId = heirId;
        } else {
            currentUniverseId = universeId;
        }
    }

    /**
     * @notice Returns when a query became reportable in a universe, setting it lazily on first access.
     * @dev If already set, returns it. Otherwise the query can only be reported on if it was inherited
     *      through a fork, i.e. its origin universe is an ancestor of this one — enforced via the history
     *      prefix check. Its reportable time is then the universe's forkTime, which is stored and returned.
     * @param universeId The universe the query is being acted on in.
     * @param queryId The query in question.
     * @return queryCreateTime The timestamp the query became reportable in this universe.
     */
    function _getAndUpdateQueryCreateTime(uint248 universeId, uint256 queryId)
        internal
        returns (uint48 queryCreateTime)
    {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.queryCreateTime != 0) {
            return resolution.queryCreateTime;
        } else {
            // TODO: check query flow after forks
            // If the queryCreateTime is not set, the query was not created in this universe, so it is only
            // available here if this universe descends from the query's origin universe. New queries cannot
            // be created in a forked (ancestor) universe, so an origin-is-ancestor match guarantees the
            // query was genuinely inherited.
            Universe storage universe = universes[universeId];
            Universe storage originUniverse = universes[queries[queryId].originUniverse];
            if (!LibHistory.isAncestor(
                    originUniverse.history, originUniverse.forkDepth, universe.history, universe.forkDepth
                )) {
                revert QueryNotInherited();
            }
            // The query becomes reportable in this universe at the moment of the fork.
            queryCreateTime = universe.forkTime;
            resolution.queryCreateTime = uint48(queryCreateTime);
            return queryCreateTime;
        }
    }

    /**
     * @notice Builds the question text for creating a fork in Zoltar.
     * @dev Placeholder — returns the original question unchanged; Zoltar formatting is TODO.
     * @param queryId The query being forked on.
     * @return The question string for the Zoltar query.
     */
    // outcomeId is reserved: the Zoltar fork question will name the winning branch once formatting is done.
    function _createForkQuestionString(
        uint256 queryId,
        uint8 /* outcomeId */
    )
        internal
        view
        returns (string memory)
    {
        // TODO: Placeholder for now
        Query storage query = queries[queryId];
        return query.question;
    }

    /**
     * @notice This function returns the current 3-day window id for all universes since GENESIS.
     * @return currentThreeDayWindow The current 3-day window id.
     */
    function _getCurrentThreeDayWindow() internal view returns (uint256 currentThreeDayWindow) {
        currentThreeDayWindow = (block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS;
    }
}
