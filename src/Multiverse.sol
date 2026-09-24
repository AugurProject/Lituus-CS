// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IZoltar, IZoltarQuestionData } from "./interfaces/IZoltar.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { LituusRep } from "./LituusRep.sol";
import { IReputationToken } from "./interfaces/IReputationToken.sol";
import { IQueryFeeController } from "./interfaces/IQueryFeeController.sol";
import { IMultiverse } from "./interfaces/IMultiverse.sol";
import { LibHistory } from "./libraries/LibHistory.sol";

// TODO: check zoltar forks

contract Multiverse is ReentrancyGuard, IMultiverse {
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
    /// @notice Divisor of the universe's REP supply that sets the per-outcome stake cap (1%).
    uint256 public constant CAP_DIVISOR = 100;
    /// @notice Divisor of the cap that bounds the first stake, so no ladder starts closer than two rounds to it.
    uint256 public constant FIRST_STAKE_CAP_DIVISOR = 4;

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
    // The QueryTokenizer allowed to create queries at a tokenizer-supplied price.
    // One immutable contract serves every universe.
    address public immutable QUERY_TOKENIZER;

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
    struct Query {
        // Number of reportable outcomes, numbered 1..numberOfOutcomes. UNRESOLVED and INVALID are not counted.
        uint8 numberOfOutcomes;
        // The universe the query was created in. It is reportable there and in that universe's descendants.
        uint248 originUniverse;
        // The query fee in wREP, fixed at creation. Funds the reporter reward; the unpaid remainder is burned.
        uint256 fee;
        // The question text together with its possible answers.
        string question;
        // Universes in which the query has been resolved. A canonical universe's entry is kept at index 0.
        uint248[] resolvedUniverses;
    }

    /// @dev One outcome's side of an escalation ladder. `totalOutcomeStaked` is written on every stake placed
    ///      on the outcome; the reporter fields are written once, at the outcome's first stake.
    struct OutcomeStakes {
        // Total wREP staked on this outcome.
        uint96 totalOutcomeStaked;
        // The first account to stake on this outcome. Earns the time-based fee share if the outcome wins.
        address firstReporter;
        // When the outcome was first staked on. Drives the fee ramp paid to `firstReporter`.
        uint48 firstReportTime;
    }

    /// @dev Escalation state of a query in one universe. The first six fields share a storage slot and are
    ///      all touched by every report; `cap` and `noOfOutcomesAtCap` share the next slot and are written at
    ///      the first report and when an outcome reaches the cap only. wREP amounts are bounded by the REP
    ///      max supply (100M * 1e18), comfortably within uint96.
    struct QueryResolution {
        // The time the query first became reportable in this universe.
        // Set on createQuery in the origin universe and lazily on the first report() in heir universes
        // (to that universe's forkTime).
        uint48 queryCreateTime;
        // The resolved outcome. 0 means UNRESOLVED.
        uint8 outcome;
        // When the latest stake was placed. Each stake reopens the appeal window from this time.
        uint48 lastStakeTime;
        // The outcome of the latest stake. Wins the query if the appeal window lapses unchallenged.
        uint8 lastReportedOutcome;
        // Number of stakes placed so far.
        uint16 stakeCount;
        // Total wREP staked across all outcomes.
        uint96 totalStaked;
        // Per-outcome stake ceiling: 1% of the universe's REP supply, converted to wREP shares and frozen at
        // the first report so the whole ladder is measured against one grid.
        uint96 cap;
        // Number of outcomes whose total has reached `cap`. The second one triggers the fork.
        uint8 noOfOutcomesAtCap;
        // Stake totals and first reporter per outcome.
        mapping(uint8 outcome => OutcomeStakes) outcomes;
        // Each staker's total per outcome; zeroed when claimed or settled.
        mapping(address staker => mapping(uint8 outcome => uint96)) userStakes;
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
    event StakeClaimed(address indexed reporter, uint248 indexed universeId, uint256 indexed queryId, uint256 payout);
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
    error CannotStakeOnOutcome();
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
    error ExactlyOneAmountRequired();
    error QueryNotInherited();
    error QueryNotResolved();
    error NothingToClaim();
    error InvalidClaimBatch();
    error OnlyQueryTokenizer();

    /* =============================================== CONSTRUCTOR =============================================== */
    /**
     * @notice Wires the Zoltar address, seeds the genesis universe, and sets the fee controller.
     * @param _zoltar The Zoltar address.
     * @param _initialZoltarUniverseId The Zoltar universe id treated as the Lituus genesis. It is also
     * the genesis universe's id here: Lituus universe ids mirror Zoltar universe ids.
     * @param _queryFeeController The controller owning each universe's monthly base fee.
     * @param _queryTokenizer The QueryTokenizer allowed to create queries at a tokenizer-supplied price
     * (one immutable contract for all universes).
     */
    constructor(
        IZoltar _zoltar,
        uint248 _initialZoltarUniverseId,
        IQueryFeeController _queryFeeController,
        address _queryTokenizer
    ) {
        QUERY_TOKENIZER = _queryTokenizer;
        if (QUERY_TOKENIZER == address(0)) revert ZeroAddress();
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

        GENESIS_TIMESTAMP = block.timestamp;
        BOOT_PROFIT = 2 * QUERY_FEE_CONTROLLER.INITIAL_BASE_FEE();
    }

    /* ======================================= QUERY TOKENIZER FUNCTIONS ========================================= */
    /**
     * @notice The Lituus REP token for a universe (the ERC20 the QueryTokenizer pools and pays fees in).
     * @param universeId The universe to read.
     */
    function repTokenOf(uint248 universeId) external view returns (ILituusRep) {
        UniverseState universeState = universes[universeId].universeState;
        if (universeState == UniverseState.NotExisting) revert InvalidUniverse();
        return universes[universeId].repToken;
    }

    /**
     * @notice Everything the QueryTokenizer needs to price and pay for a mint, in one call: the
     *         uncapped query fee, the fee cap, and the universe's wREP token.
     * @dev The fee is `createQuery`'s pricing formula (base fee * demand modifier) computed read-only:
     *      it does NOT record volume and is NOT capped — the tokenizer's mintPrice applies the
     *      returned cap itself. Does NOT forward to the heir: query tokens are universe-specific, so
     *      once a universe forks, minting (like redeeming) freezes on it and migration is the only
     *      path to a child. Reverts for a nonexistent universe or one that is no longer
     *      Active/Forming, which also blocks minting during a fork window.
     * @param universeId The universe to price.
     * @return uncappedFee The current query fee (base fee * demand modifier, uncapped) in wREP.
     * @return queryFeeCap The cap on query fees (half the fork threshold) in wREP.
     * @return repToken The universe's Lituus REP (wREP) token.
     */
    function getMintPricing(uint248 universeId)
        external
        view
        returns (uint256 uncappedFee, uint256 queryFeeCap, ILituusRep repToken)
    {
        UniverseState universeState = universes[universeId].universeState;
        if (universeState == UniverseState.NotExisting) revert InvalidUniverse();
        if ((universeState != UniverseState.Active) && (universeState != UniverseState.Forming)) {
            revert InvalidUniverseState();
        }
        uncappedFee = _previewFee(universeId, QUERY_FEE_CONTROLLER.getQueryFee(universeId));
        repToken = universes[universeId].repToken;
        queryFeeCap = _queryFeeCap(repToken, universeId);
    }

    /**
     * @dev The cap on query fees in a universe, in wREP: half its fork threshold. The first report's
     *      stake equals the query fee, so the cap keeps an opening report below fork level. Applied
     *      by `createQuery` and (via `getMintPricing`) by the QueryTokenizer's mintPrice. Takes an
     *      already-loaded repToken to avoid a duplicate storage read.
     */
    function _queryFeeCap(ILituusRep repToken, uint248 universeId) internal view returns (uint256) {
        return _forkThreshold(repToken, universeId) / 2;
    }

    /**
     * @dev The fork threshold for a universe in wREP shares: converts the raw Zoltar fork threshold
     *      (denominated in underlying REP) into wREP shares using the universe's REP vault rate.
     *      Takes an already-loaded repToken to avoid a duplicate storage read.
     */
    function _forkThreshold(ILituusRep repToken, uint248 universeId) internal view returns (uint256) {
        return repToken.convertToShares(ZOLTAR.getForkThreshold(universeId));
    }

    /// @dev The per-outcome stake cap in wREP shares: 1% of the universe's REP supply at the vault's current rate.
    ///      Read once, at a query's first report, and frozen in `QueryResolution.cap`.
    function _capShares(ILituusRep repToken, uint248 universeId) internal view returns (uint256) {
        return repToken.convertToShares(ZOLTAR.getUniverseTheoreticalSupply(universeId) / CAP_DIVISOR);
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
        if ((assetsToProvide == 0 && sharesToReceive == 0) || (assetsToProvide != 0 && sharesToReceive != 0)) {
            revert ExactlyOneAmountRequired();
        }

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
        if ((sharesToProvide == 0 && assetsToReceive == 0) || (sharesToProvide != 0 && assetsToReceive != 0)) {
            revert ExactlyOneAmountRequired();
        }

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
     *      The fee must be nonzero and is capped at half the universe's fork threshold. The fee only
     *      derives the first report's stake: report() bounds it to a quarter of the per-outcome stake cap
     *      and rounds it to a step of that cap, so even a fee at its own cap needs two more escalations
     *      before an outcome can reach that cap.
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
        // The first report's stake is derived from the query fee, bounded to a fraction of the per-outcome cap
        // by _requiredStake.
        uint256 queryFeeCap = _queryFeeCap(currentUniverse.repToken, currentUniverseId);
        if (fee >= queryFeeCap) fee = queryFeeCap;
        // transfer the query fee amount of REP token
        // TODO: permit? permit2?
        currentUniverse.repToken.safeTransferFrom(msg.sender, address(this), fee);

        _recordQuery(msg.sender, currentUniverseId, question, numberOfOutcomes, fee);
    }

    /**
     * @notice Creates a query on behalf of the Query Tokenizer protocol, paying a tokenizer-supplied price
     *         instead of the live dynamic fee.
     * @dev Enables Query Tokenizer: the authorized, immutable
     *      QueryTokenizer may pay a *different* price (the pool's per-token average) than `createQuery`
     *      would charge. The QueryTokenizer transfers `fee` of the universe's REP to this contract
     *      immediately before this call (push model — no allowance needed), so no `safeTransferFrom`
     *      happens here. From the oracle's viewpoint the query is otherwise identical to a direct
     *      submission: it still counts as demand volume (the redemption is a real query) and
     *      its fee is distributed/burned normally at resolution. The `queryFeeCap` is NOT applied, so
     *      the full pool price reaches the oracle.
     *
     *      Does NOT forward to the heir: the QueryTokenizer's pool and the pushed
     *      fee are denominated in the current universe's REP, so forwarding would mix up the REP tokens,
     *      bypassing migration. Once the universe forks, redemption freezes here and
     *      migration is the only path to a child.
     * @param universeId The universe to create the query in (must be Active/Forming itself; never forwarded).
     * @param question The question text alongside the possible answers.
     * @param numberOfOutcomes The number of reportable outcomes.
     * @param fee The price the QueryTokenizer pays (the redeemed token's pooled average), already sent here.
     * @param creator The redeemer the query is created on behalf of.
     */
    function createQueryFromTokenizer(
        uint248 universeId,
        string calldata question,
        uint8 numberOfOutcomes,
        uint256 fee,
        address creator
    ) external nonReentrant {
        if (msg.sender != QUERY_TOKENIZER) revert OnlyQueryTokenizer();
        UniverseState universeState = universes[universeId].universeState;
        if (universeState == UniverseState.NotExisting) revert InvalidUniverse();
        if ((universeState != UniverseState.Active) && (universeState != UniverseState.Forming)) {
            revert InvalidUniverseState();
        }

        if (numberOfOutcomes < MIN_OUTCOMES) revert InvalidNumberOfOutcomes();
        if (numberOfOutcomes > MAX_OUTCOMES) revert InvalidNumberOfOutcomes();
        if (bytes(question).length > MAX_QUERY_LENGTH) revert QueryTooLong();
        if (fee == 0) revert ZeroFee();

        // Count the redemption as demand volume like a direct query. The charged fee is the
        // tokenizer-supplied `fee`, so only the volume increment is needed.
        _applyVolume(universeId);

        // The QueryTokenizer already transferred `fee` of this universe's REP to this contract.
        _recordQuery(creator, universeId, question, numberOfOutcomes, fee);
    }

    /**
     * @notice Writes the global query record and per-universe resolution, emits QueryCreated, bumps the
     *         query counter. Shared by `createQuery` and `createQueryFromTokenizer`.
     * @dev `creator` is emitted as QueryCreated's creator: the caller for direct queries, the redeemer
     *      for tokenizer queries — the tokenizer contract itself is never the attributed creator.
     */
    function _recordQuery(
        address creator,
        uint248 currentUniverseId,
        string calldata question,
        uint8 numberOfOutcomes,
        uint256 fee
    ) internal {
        Query storage query = queries[queryCount];
        query.numberOfOutcomes = numberOfOutcomes;
        query.originUniverse = currentUniverseId;
        query.fee = fee;
        query.question = question;

        // A universe-specific resolution record starts with outcome == UNRESOLVED.
        // Set the queryCreateTime so the reporting window can be enforced in this universe.
        QueryResolution storage resolution = queryResolutions[currentUniverseId][queryCount];
        resolution.queryCreateTime = uint48(block.timestamp);

        emit QueryCreated(creator, queryCount, currentUniverseId, question, numberOfOutcomes);

        queryCount++;
    }

    /**
     * @notice Reports an outcome on a query, posting the required escalation stake.
     * @dev Forwards to the heir if the universe has forked. Rejects reports on queries already resolved
     *      here or in an ancestor lineage. A query created in another universe is reportable here only
     *      if it was inherited through a fork, i.e. this universe descends from the query's origin.
     *      The first report must fall within THREE_DAYS of the query becoming reportable and freezes the
     *      per-outcome cap (1% of the REP supply, in wREP shares). Each later report must land within the
     *      ONE_DAY appeal window and contest the latest outcome; its stake brings the outcome to twice the
     *      total of every other outcome, bounded by the cap. When two outcomes reach the cap the query forks.
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
        uint16 stakeCount = resolution.stakeCount;
        // A query resolved in an ancestor universe is inherited by this lineage (via getOutcome), so it
        // cannot be reported on again here. The ancestor set is fixed per lineage, so this only needs to
        // be checked on the first report; later stakes in the same escalation are already covered.
        if (stakeCount == 0 && _findAncestorResolution(currentUniverseId, queryId) != UNRESOLVED) {
            revert QueryAlreadyResolved();
        }

        // Outcome should be between 1 and numberOfOutcomes unless the query should be reported as INVALID
        if (outcome == UNRESOLVED) revert InvalidOutcome();
        if ((outcome > query.numberOfOutcomes) && (outcome != INVALID)) revert InvalidOutcome();

        uint48 queryCreateTime = _getAndUpdateQueryCreateTime(currentUniverseId, queryId);

        // check that the reporting window for the query is not over yet
        if (stakeCount == 0 && queryCreateTime + THREE_DAYS < block.timestamp) revert QueryExpired();

        if (stakeCount == 0) {
            // Freeze the per-outcome cap: the whole ladder is measured against this one value.
            // a fraction of the REP supply, bounded by max supply (100M * 1e18), within uint96
            // forge-lint: disable-next-line(unsafe-typecast)
            resolution.cap = uint96(_capShares(currentUniverse.repToken, currentUniverseId));
        } else if (resolution.lastStakeTime + ONE_DAY < block.timestamp) {
            revert AppealPeriodOver();
        }

        uint256 stake = _requiredStake(resolution, query.fee, outcome);
        currentUniverse.repToken.safeTransferFrom(msg.sender, address(this), stake);

        // bounded by the cap, itself a uint96
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 stakeAmount = uint96(stake);
        OutcomeStakes storage outcomeStakes = resolution.outcomes[outcome];
        uint96 totalOutcomeStaked = outcomeStakes.totalOutcomeStaked;
        if (totalOutcomeStaked == 0) {
            outcomeStakes.firstReporter = msg.sender;
            outcomeStakes.firstReportTime = uint48(block.timestamp);
        }
        totalOutcomeStaked += stakeAmount;
        outcomeStakes.totalOutcomeStaked = totalOutcomeStaked;
        resolution.userStakes[msg.sender][outcome] += stakeAmount;

        resolution.totalStaked += stakeAmount;
        resolution.lastStakeTime = uint48(block.timestamp);
        resolution.lastReportedOutcome = outcome;
        resolution.stakeCount = stakeCount + 1;

        emit QueryReported(msg.sender, currentUniverseId, queryId, outcome, stake);

        if (totalOutcomeStaked == resolution.cap) {
            resolution.noOfOutcomesAtCap++;
            // The second outcome at the cap means two sides each hold 1% of the supply: the query forks.
            if (resolution.noOfOutcomesAtCap == 2) {
                // TODO: Implement Forking here.
            }
        }
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

        if (resolution.stakeCount == 0 && queryCreateTime + THREE_DAYS < block.timestamp) {
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
            uint256 profit = queryFee - resolverPay;
            emit ResolverRewardPaid(msg.sender, currentUniverseId, queryId, resolverPay);
            currentUniverse.repToken.safeTransfer(msg.sender, resolverPay);
            // The unpaid fee remainder is the query's profit: recorded for the fee controller and
            // burned as wREP, the same as on the stakes path.
            if (profit > 0) {
                currentUniverse.repToken.burnShares(profit);
            }
            _applyProfit(currentUniverseId, profit);

            emit QueryResolved(msg.sender, currentUniverseId, queryId, INVALID);
        } else if (resolution.stakeCount > 0) {
            if (resolution.lastStakeTime + ONE_DAY < block.timestamp) {
                // If there are stakes and the appeal period has passed then resolve the query with the last outcome
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
     * @notice Claims the caller's payout from a resolved query: the caller's stake on the winning outcome
     *         back, plus its pro-rata share of the losing stakes after the burn cut.
     * @dev Payouts are computed from the resolution's per-outcome totals, never by looping stakes. The
     *      caller's stake on the winning outcome is zeroed on settlement, so a second claim finds nothing.
     * @param universeId The universe the query was resolved in.
     * @param queryId The resolved query.
     */
    function claim(uint248 universeId, uint256 queryId) external nonReentrant {
        uint256 payout = _claim(universeId, queryId);

        universes[universeId].repToken.safeTransfer(msg.sender, payout);

        emit StakeClaimed(msg.sender, universeId, queryId, payout);
    }

    /**
     * @notice Claims the caller's payouts across several resolved queries of one universe, in a single
     *         transfer.
     * @dev Same guards per query as claim(). A repeated queryId reverts on its second occurrence (the stake
     *      is already zeroed), failing the whole batch.
     * @param universeId The universe the queries were resolved in.
     * @param queryIds The resolved queries being claimed from.
     */
    function claimMultiple(uint248 universeId, uint256[] calldata queryIds) external nonReentrant {
        uint256 length = queryIds.length;
        if (length == 0) revert InvalidClaimBatch();

        uint256 totalPayout;
        for (uint256 i = 0; i < length;) {
            uint256 payout = _claim(universeId, queryIds[i]);
            totalPayout += payout;

            emit StakeClaimed(msg.sender, universeId, queryIds[i], payout);

            unchecked {
                i += 1;
            }
        }

        universes[universeId].repToken.safeTransfer(msg.sender, totalPayout);
    }

    /**
     * @notice Settles the caller's stake on a resolved query's winning outcome, returning its payout.
     * @dev Only the caller's own stake on the winning outcome can be claimed. Zeroes it (the settled flag)
     *      before any transfer happens in the callers.
     * @param universeId The universe the query was resolved in.
     * @param queryId The resolved query.
     * @return payout The stake amount plus its pro-rata share of the distributable losing stakes.
     */
    function _claim(uint248 universeId, uint256 queryId) internal returns (uint256 payout) {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        uint8 outcome = resolution.outcome;
        if (outcome == UNRESOLVED) revert QueryNotResolved();

        uint256 amount = resolution.userStakes[msg.sender][outcome];
        if (amount == 0) revert NothingToClaim();
        // Zeroed is the settled flag, set before any transfer happens in the callers.
        resolution.userStakes[msg.sender][outcome] = 0;

        uint256 winnerStaked = resolution.outcomes[outcome].totalOutcomeStaked;
        uint256 totalLoserStakes = resolution.totalStaked - winnerStaked;
        uint256 totalDistributable = totalLoserStakes - totalLoserStakes / BURN_DIVIDER;
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

        // Advance the incremental 60-day cache to the current window before reading it below.
        _rollVolumeWindow(stats, currentThreeDayWindow);

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

        // count this query in the current demand-volume bucket for future fees; the cache is already
        // rolled above, so increment directly rather than re-rolling via _applyVolume. Nothing has
        // written the bucket since `currentVolume` was read, so reuse it instead of re-reading.
        // forge-lint: disable-next-line(unsafe-typecast)
        stats.threeDayInfo[currentThreeDayWindow].threeDayVolume = uint128(currentVolume + 1);
    }

    /**
     * @notice Rolls the 60-day cache forward, then records one query in the current 3-day demand-volume
     *         bucket, without computing any fee.
     * @dev The lightweight half of `_calculateFeeAndApplyVolume`. `createQueryFromTokenizer` uses it to
     *      count a redemption as demand. Rolls the cache first (like the organic `createQuery` path) so a
     *      token-only stretch — redemptions recording volume with no organic query in between — never lets
     *      the cache go stale.
     * @param universeId The universe whose current volume bucket to increment.
     */
    function _applyVolume(uint248 universeId) internal {
        UniverseStatistics storage stats = universeStatistics[universeId];
        uint256 currentThreeDayWindow = _getCurrentThreeDayWindow();
        _rollVolumeWindow(stats, currentThreeDayWindow);
        // a per-window query count, far below the uint128 max
        // forge-lint: disable-next-line(unsafe-typecast)
        stats.threeDayInfo[currentThreeDayWindow].threeDayVolume =
            uint128(stats.threeDayInfo[currentThreeDayWindow].threeDayVolume + 1);
    }

    /**
     * @notice Advances the incremental 60-day volume cache (`sixtyDayVolume` + `lastWindowId`) to the
     *         current window, persisting the result.
     * @dev The single writer of the cache, shared by every query-recording path (organic and tokenizer),
     *      so the cache stays fresh no matter which path last recorded volume. A no-op when the current
     *      window already equals `lastWindowId` — at most one real roll happens per universe per window.
     * @param stats The universe's statistics storage.
     * @param currentThreeDayWindow The current 3-day window index.
     */
    function _rollVolumeWindow(UniverseStatistics storage stats, uint256 currentThreeDayWindow) internal {
        uint256 lastWindow = stats.lastWindowId;
        if (currentThreeDayWindow <= lastWindow) return;

        uint256 sixtyDayVolume = _rolledSixtyDayVolume(stats, currentThreeDayWindow, lastWindow, stats.sixtyDayVolume);
        // running query count over the window range, far below the uint128 max
        // forge-lint: disable-next-line(unsafe-typecast)
        stats.sixtyDayVolume = uint128(sixtyDayVolume);
        // 3-day window index since genesis, far below the uint128 max
        // forge-lint: disable-next-line(unsafe-typecast)
        stats.lastWindowId = uint128(currentThreeDayWindow);
    }

    /**
     * @notice Rolls a cached 60-day volume from `lastWindow` up to `currentThreeDayWindow`, read-only.
     * @dev Storage holds REAL volume only — bootstrap is never stored, so nothing bootstrap-related is
     *      added or subtracted here. Shared by the mutating `_rollVolumeWindow` (which persists the result)
     *      and the `view` `_previewFee` (which cannot persist), keeping the window math in exactly one place.
     * @param stats The universe's statistics storage.
     * @param currentThreeDayWindow The window to roll the cache up to.
     * @param lastWindow The window the cache is currently anchored at.
     * @param cachedSixtyDayVolume The cached sum as of `lastWindow`.
     * @return sixtyDayVolume The 60-day running sum as of `currentThreeDayWindow`.
     */
    function _rolledSixtyDayVolume(
        UniverseStatistics storage stats,
        uint256 currentThreeDayWindow,
        uint256 lastWindow,
        uint256 cachedSixtyDayVolume
    ) internal view returns (uint256 sixtyDayVolume) {
        sixtyDayVolume = cachedSixtyDayVolume;
        if (currentThreeDayWindow <= lastWindow) return sixtyDayVolume;

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
    }

    /**
     * @notice Read-only twin of `_calculateFeeAndApplyVolume`'s fee computation: `baseFee × demandModifier`,
     *         WITHOUT rolling the volume cache forward or recording the query.
     * @dev A `view` cannot persist the incremental `sixtyDayVolume` cache, so it advances a copy in memory
     *      via the shared `_rolledSixtyDayVolume`. When the cache is fresh — which every recorded query,
     *      redemptions included, keeps it (see `_applyVolume`) — this is a single cached read with no loop;
     *      only a genuinely idle span (no query at all since `lastWindowId`) pays the catch-up, exactly as
     *      the mutating path would. Returns the UNCAPPED fee: `getMintPricing` exposes it as-is
     *      and the QueryTokenizer's mintPrice applies the `queryFeeCap`.
     */
    function _previewFee(uint248 universeId, uint256 baseFee) internal view returns (uint256) {
        UniverseStatistics storage stats = universeStatistics[universeId];
        uint256 currentThreeDayWindow = _getCurrentThreeDayWindow();

        // Advance the maintained 60-day cache in memory (a view cannot persist it). Fresh cache - no loop.
        uint256 sixtyDayVolume =
            _rolledSixtyDayVolume(stats, currentThreeDayWindow, stats.lastWindowId, stats.sixtyDayVolume);

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
        uint256 lastSixtyDayVolume = currentVolume + sixtyDayVolume;
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

        return baseFee * _calculateCurveModifier(lastSixtyDayVolume, lastThreeDayVolume) / SCALE;
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
     *      TODO: the below-average branch bottoms out near ~1% of the base fee; since the fee is also
     *      TODO: the first report's bond, a floor may be needed (needs testing).
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
     * @dev Reads the winner (the latest reported outcome) and its totals from the resolution record;
     *      callers MUST guarantee the query is reported before calling.
     *
     *      `reporterPay` accrues linearly over the reporting window as
     *      `fee * (reportingTimestamp - queryCreateTime) / THREE_DAYS`, capped at the full `fee`: the
     *      winning report can land after escalation has begun and thus past the 3-day window, so
     *      the cap prevents paying out more than the fee.
     *
     *      `profit` is the wREP removed from circulation: 20% of the losing stakes
     *      (`totalLoserStakes / BURN_DIVIDER`) plus the unpaid fee remainder (`fee - reporterPay`).
     *      The reporter reward is pushed here via `safeTransfer`.
     *
     *      Winner stake refunds and their proportional share of the remaining 80% of losing stakes
     *      are NOT settled here — those are claimed separately through claim() (except the case of
     *      a single stake, which is settled here in one transfer).
     * @param universeId The id of the universe the query is being resolved in.
     * @param queryId The id of the query being resolved.
     * @return winnerOutcome The winning outcome of the resolved query.
     */
    function _calculateOutcomeAndEscalationPayoffs(uint248 universeId, uint256 queryId) internal returns (uint8) {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        uint8 winnerOutcome = resolution.lastReportedOutcome;
        OutcomeStakes storage winnerStakes = resolution.outcomes[winnerOutcome];
        uint256 totalStaked = resolution.totalStaked;
        uint256 winnerOutcomeStaked = winnerStakes.totalOutcomeStaked;
        address reporter = winnerStakes.firstReporter;
        uint48 reportingTimestamp = winnerStakes.firstReportTime;

        uint256 queryFee = queries[queryId].fee;
        // Per-universe queryCreateTime: createQuery sets it for the origin universe and report()
        // lazily sets it to universe.forkTime for heir universes on first report.
        uint48 queryCreateTime = resolution.queryCreateTime;

        uint256 totalLoserStakes = totalStaked - winnerOutcomeStaked;
        // Ramps to the full fee over the reporting window; a first correct report after day 3 earns it whole.
        uint256 reporterPay = _timeBasedFeeShare(queryFee, reportingTimestamp - queryCreateTime);

        uint256 loserBurn = totalLoserStakes / BURN_DIVIDER;
        uint256 profit = loserBurn + (queryFee - reporterPay);

        ILituusRep repToken = universes[universeId].repToken;

        emit ReporterRewardPaid(reporter, universeId, queryId, reporterPay);
        // Consecutive reports must differ, so no-losers <=> exactly one stake: settle the sole winner
        // here in one transfer (bond refund + reporter reward) instead of requiring a claim() call.
        // The two events stay separate so StakeClaimed payouts don't include a fee reward.
        if (resolution.stakeCount == 1) {
            resolution.userStakes[reporter][winnerOutcome] = 0; // zeroed marks the stake settled
            emit StakeClaimed(reporter, universeId, queryId, totalStaked);
            repToken.safeTransfer(reporter, reporterPay + totalStaked);
        }
        // with more than one stake, even the rewarded reporter must claim their bond separately
        else {
            repToken.safeTransfer(reporter, reporterPay);
        }
        // Burn the recorded profit as wREP: the burned fifth of the losing stakes plus the unpaid
        // fee remainder. Destroying shares while the asset ledger is untouched raises the
        // assets-per-share rate, so the value accrues to wREP holders; the underlying Zoltar REP
        // is never burned here. _applyProfit records the same amount for the fee controller.
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
     *      universe age. Only the windowed profit bucket is updated; `_getProfits` reconstructs the
     *      rolling monthly totals from the buckets on demand.
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
     * @notice Returns one outcome's side of a query's escalation in a given universe: its stake total and
     *         first reporter.
     * @dev Reads the record of the given universe as-is, without forwarding to the universe's heir. Pass
     *      the universe the stakes were placed in.
     * @param universeId The universe whose resolution record to read.
     * @param queryId The query whose stakes to read.
     * @param outcome The outcome whose side to read.
     * @return The outcome's stake total, first reporter and first report time.
     */
    function getOutcomeStakes(uint248 universeId, uint256 queryId, uint8 outcome)
        external
        view
        returns (OutcomeStakes memory)
    {
        if (queries[queryId].numberOfOutcomes == 0) revert InvalidQuery();
        return queryResolutions[universeId][queryId].outcomes[outcome];
    }

    /**
     * @notice Returns a staker's total stake on one outcome of a query in a given universe. Zero once
     *         claimed or settled.
     * @dev Reads the record of the given universe as-is, without forwarding to the universe's heir.
     * @param universeId The universe whose resolution record to read.
     * @param queryId The query whose stakes to read.
     * @param staker The staker whose stake to read.
     * @param outcome The outcome the stake was placed on.
     * @return The staker's stake on the outcome.
     */
    function getUserStake(uint248 universeId, uint256 queryId, address staker, uint8 outcome)
        external
        view
        returns (uint96)
    {
        if (queries[queryId].numberOfOutcomes == 0) revert InvalidQuery();
        return queryResolutions[universeId][queryId].userStakes[staker][outcome];
    }

    /**
     * @notice The stake the next report on `outcome` must place for `queryId` in `universeId`.
     * @dev Before the first report the cap is not frozen yet, so the estimate uses the live cap and can shift with
     *      the vault rate until the first stake lands. Forwards to the universe's heir like report().
     * @param universeId The universe to report in (forwarded to the heir if it has forked).
     * @param queryId The query to report on.
     * @param outcome The outcome the next report would stake on.
     * @return requiredStake The stake the next reporter must post.
     */
    function getNextRequiredStake(uint248 universeId, uint256 queryId, uint8 outcome)
        external
        view
        returns (uint256 requiredStake)
    {
        if (queries[queryId].numberOfOutcomes == 0) revert InvalidQuery();
        (uint248 currentUniverseId,) = _getCurrentUniverse(universeId);
        QueryResolution storage resolution = queryResolutions[currentUniverseId][queryId];
        uint256 fee = queries[queryId].fee;
        if (resolution.stakeCount == 0) {
            uint256 cap = _capShares(universes[currentUniverseId].repToken, currentUniverseId);
            uint256 firstStakeCap = cap / FIRST_STAKE_CAP_DIVISOR;
            return _roundToPowerOfTwoStep(fee > firstStakeCap ? firstStakeCap : fee, cap);
        }
        return _requiredStake(resolution, fee, outcome);
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

    /// @dev Rounds `amount` to the nearest step of the halving sequence cap, cap/2, cap/4, ... in log space:
    ///      the chosen step is never more than a factor of sqrt(2) away from `amount`. A first stake on a step keeps
    ///      every later stake on a step, so the leading outcomes land exactly on the cap. Requires `amount <= cap`.
    function _roundToPowerOfTwoStep(uint256 amount, uint256 cap) internal pure returns (uint256 step) {
        step = cap >> Math.log2(cap / amount);
        if (step > amount) step >>= 1; // log2 floors, so the step can land one halving above `amount`
        // Move up when `amount` is above the geometric mean of the two steps, i.e. amount > step * sqrt(2).
        if (amount * amount > 2 * step * step) step <<= 1;
    }

    /// @dev The exact stake the next report on `outcome` must place.
    ///      First stake: the query fee, bounded to `cap / FIRST_STAKE_CAP_DIVISOR` and rounded to a step.
    ///      Later stakes: the amount that brings the outcome to exactly twice the total of every other outcome,
    ///      bounded by the cap. An outcome that already holds that share cannot be staked on: it is the
    ///      outcome the last report backed.
    function _requiredStake(QueryResolution storage resolution, uint256 fee, uint8 outcome)
        internal
        view
        returns (uint256 stake)
    {
        uint256 cap = resolution.cap;
        if (resolution.stakeCount == 0) {
            uint256 firstStakeCap = cap / FIRST_STAKE_CAP_DIVISOR;
            return _roundToPowerOfTwoStep(fee > firstStakeCap ? firstStakeCap : fee, cap);
        }
        uint256 totalStaked = resolution.totalStaked;
        uint256 totalOutcomeStaked = resolution.outcomes[outcome].totalOutcomeStaked;
        // An appeal contests the latest report, so restating its outcome is not one. The second condition keeps
        // the subtraction below safe; it never holds for an outcome other than the latest.
        if (outcome == resolution.lastReportedOutcome || 3 * totalOutcomeStaked >= 2 * totalStaked) {
            revert CannotStakeOnOutcome();
        }
        uint256 amountToReachDoubleTheRest = 2 * totalStaked - 3 * totalOutcomeStaked;
        uint256 amountToReachCap = cap - totalOutcomeStaked;
        stake = amountToReachDoubleTheRest < amountToReachCap ? amountToReachDoubleTheRest : amountToReachCap;
        // TODO-Remove the following line when forks are implemented.
        if (stake == 0) revert CannotStakeOnOutcome();
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
