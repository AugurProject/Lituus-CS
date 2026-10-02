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

contract Multiverse is ReentrancyGuard, IMultiverse {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILituusRep;

    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    // Query outcomes live in one uint256 domain, shared with Zoltar's answer space:
    // 0 - UNRESOLVED
    // 1..numberOfOutcomes - valid categorical outcomes (a query has 2..254 of them)
    // type(uint256).max - INVALID
    uint8 public constant MAX_OUTCOMES = 254; // number of outcomes for a query (not including UNRESOLVED and INVALID)
    uint8 public constant MIN_OUTCOMES = 2; // minimum number of valid outcomes for a query
    uint256 public constant UNRESOLVED = 0; // the query is not resolved yet
    // The invalid outcome: reportable on any query, and the outcome of an expired one.
    // TODO: map to Zoltar's INVALID
    uint256 public constant INVALID = type(uint256).max;
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
    // The genesis universe's id (mirrors its Zoltar id, which is not necessarily 0).
    uint248 public immutable GENESIS_UNIVERSE_ID;
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
        PostFork // 6 - fork finalized
    }

    /* ================================================= STRUCTS ================================================= */
    /// @dev How a query with no record yet in a universe relates to its lineage's frozen history
    ///      (see _classifyInheritedQuery). Determines what report() and resolve() may do with it.
    enum InheritedQueryKind {
        // Resolved in an ancestor: the outcome is inherited (via getOutcome).
        AncestorResolved,
        // Reporting (re)starts here with a full window; the clock is the parent's forkTime.
        Fresh,
        // The reporting window lapsed unreported before some ancestor's fork:
        // dead everywhere below — resolvable INVALID, never revived.
        ExpiredAtFork,
        // The escalation ladder concluded (appeal lapsed) before its universe's fork but was never
        // resolved: the frozen last outcome applies everywhere below.
        SettledLadder
    }

    struct Query {
        // Number of reportable outcomes, numbered 1..numberOfOutcomes. UNRESOLVED and INVALID are not counted.
        uint8 numberOfOutcomes;
        // The universe the query was created in. It is reportable there and in that universe's descendants.
        uint248 originUniverse;
        // The query fee in wREP, fixed at creation. Funds the reporter reward; the unpaid remainder is burned.
        uint256 fee;
        // The question text together with its possible answers.
        string question;
        // The query's Zoltar question, if it has one (non-zero): the fork question a Lituus fork submitted, or the
        // native Zoltar fork question a mirrored fork imported. With numberOfOutcomes == 0 the outcome set is
        // Zoltar's own — ZoltarQuestionData decides answer validity.
        uint256 zoltarQuestionId;
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

    /// @dev Escalation state of a query in one universe. The first five fields share a storage slot: every
    ///      report touches it (`noOfOutcomesAtCap` only when an outcome reaches the cap). `cap` takes the next
    ///      slot and is written at the first report only. Outcomes are full words — categorical outcomes and
    ///      Zoltar's packed scalar answers share one uint256 domain — so `outcome` and `lastReportedOutcome`
    ///      take a slot each; a report writes `lastReportedOutcome` and the shared slot. wREP amounts are
    ///      bounded by the REP max supply (100M * 1e18), comfortably within uint96.
    struct QueryResolution {
        // The time the query first became reportable in this universe.
        // Set on createQuery in the origin universe and lazily on the first report() in heir universes
        // (to the parent's forkTime — the fork moment that created the universe).
        uint48 queryCreateTime;
        // When the latest stake was placed. Each stake reopens the appeal window from this time.
        uint48 lastStakeTime;
        // Number of stakes placed so far.
        uint16 stakeCount;
        // Total wREP staked across all outcomes.
        uint96 totalStaked;
        // Number of outcomes whose total has reached `cap`. The second one triggers the fork.
        uint8 noOfOutcomesAtCap;
        // Per-outcome stake ceiling: 1% of the universe's REP supply, converted to wREP shares and frozen at
        // the first report so the whole ladder is measured against one grid.
        uint96 cap;
        // The resolved outcome. 0 means UNRESOLVED.
        uint256 outcome;
        // The outcome of the latest stake. Wins the query if the appeal window lapses unchallenged.
        uint256 lastReportedOutcome;
        // Stake totals and first reporter per outcome.
        mapping(uint256 outcome => OutcomeStakes) outcomes;
        // Each staker's total per outcome; zeroed when claimed or settled.
        mapping(address staker => mapping(uint256 outcome => uint96)) userStakes;
    }

    struct Universe {
        ILituusRep repToken;
        UniverseState universeState;
        // The universe's fork time (the moment of the fork that split it).
        uint48 forkTime;
        // Whether this universe lies on the canonical timeline (the genesis -> favoriteChild -> ... chain).
        // Genesis is canonical; on a fork, only the designated favoriteChild inherits the parent's flag.
        bool isCanonical;
        uint248 parent;
        // The child with max tokens migrated. During the fork it's the child with running max of migration counts.
        uint248 favoriteChild;
        bool isLituusFork; // If it's not Lituus fork then no payouts are necessary
        // Migrated REP INTO this universe from its parent, in underlying assets (not shares: assets
        // are what flows through the Zoltar migration logic, and share counts are polluted by
        // rate moves from child-side burns during query resolutions).
        uint128 totalMigratedIn;
        // Max migrated REP OUT of this universe into a single child (underlying assets). The running
        // winner's universe id is stored in favoriteChild. 2/3-supermajority numerator.
        uint128 maxMigratedOut;
        // Packed together into one slot. forkQuery is a query id; totalMigratedOut is a REP amount
        // (<= 100M * 1e18), both comfortably within uint128.
        uint128 forkQuery;
        // Total REP migrated OUT of this universe into all its children (underlying assets), via
        // the counted Lituus lanes only. A live counter, never a trigger-time snapshot: supply can
        // keep entering the electorate after the fork (wrap from the Zoltar level, then migrate,
        // or migrate from a parent that is still forming), so no balance at the fork moment is
        // complete. Read at the end of migration it is the
        // 2/3-supermajority denominator and the max supply for SupplyRestoration.
        uint128 totalMigratedOut;
        // Packed together into one slot; both are REP amounts within uint128.
        // Unconsumed query fees held for this universe, in nominal wREP shares: += at createQuery,
        // -= when a resolution consumes the fee (reporter/resolver share + burn). At a fork the
        // aggregate (minus the forking query's own fee) is split into EVERY child at its spawn,
        // funding inherited queries' resolutions there; the counter carries recursively.
        uint128 totalQueryFees;
        // The supply for migration at fork, in underlying assets: the contract's entire wREP balance (fees,
        // forking-query stakes, other stakes/winnings), moved into the Zoltar migration balance in
        // the fork tx. Written once. Supply committed to the child level but not yet realized as
        // counted migration — SR max supply = totalMigratedOut + unmigratedSupply. Future
        // stake-claims move value across (parked -> counted); fee splits move neither (per-world
        // duplicated copies). Kept locally: Zoltar's balance would include foreign flows.
        uint128 unmigratedSupply;
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

    // The current universe at the end of the canonical timeline (genesis -> favoriteChild -> ...).
    // Starts at the genesis and is repointed on fork finalization. Outcome lookups on any canonical
    // universe read through it (see _findResolution); nothing else forwards to it.
    uint248 public canonicalHeir;

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
        uint256 outcome,
        uint256 stakeAmount
    );
    event QueryResolved(address indexed resolver, uint248 indexed universeId, uint256 indexed queryId, uint256 outcome);
    /// @notice A universe entered Migration: a Lituus escalation fork, or a mirrored native Zoltar fork.
    event UniverseForked(
        uint248 indexed universeId, uint256 indexed forkQuery, uint256 indexed zoltarQuestionId, bool isLituusFork
    );
    /// @notice A child universe was spawned for one outcome of a forking universe.
    event ChildUniverseSpawned(uint248 indexed parentUniverseId, uint248 indexed childUniverseId, uint256 outcome);
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
    // The query's ladder concluded before a fork froze it: its outcome is predetermined and it can
    // only be resolved by calling resolve(), never reported on again.
    error QueryAlreadySettled();
    error QueryNotReadyToResolve();
    error QueryExpired();
    error AppealPeriodOver();
    error InvalidUniverseState();
    error ZoltarQueryCreationFailed();
    error ZoltarUniverseIsNotForking();
    error ZoltarUniverseAlreadyForking();
    error QueryTooLong();
    error ZeroFee();
    error ExactlyOneAmountRequired();
    error QueryNotInherited();
    error SpawnWindowClosed();
    error MigrationWindowClosed();
    error MigrationWindowNotClosed();
    error ParentForkNotResolved();
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
        // token symbol will use a per-universe suffix. Genesis universe will have symbol "REP0"
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
        // forkTime stays 0 until the genesis itself forks (deploy time lives in GENESIS_TIMESTAMP).
        genesisUniverse.forkTime = 0;
        // Genesis is the root of the fork tree and of the canonical timeline. Its parent stays 0 as
        // an empty sentinel, but genesis checks always compare ids against GENESIS_UNIVERSE_ID —
        // the genesis id itself is Zoltar's and may be any value, including 0.
        genesisUniverse.isCanonical = true;
        // The canonical timeline starts (and currently ends) at the genesis.
        canonicalHeir = _initialZoltarUniverseId;
        genesisUniverse.forkQuery = 0;
        // totalMigratedOut stays 0 until the universe forks and migration begins.
        genesisUniverse.totalMigratedOut = 0;

        GENESIS_UNIVERSE_ID = _initialZoltarUniverseId;
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
     *      Active, which also blocks minting during a fork window.
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
        if (universeState != UniverseState.Active) {
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
     * @param universeId The universe to create the query in (must be Active).
     * @param question The question text alongside the possible answers (to be checked).
     * @param numberOfOutcomes The number of reportable outcomes (UNRESOLVED and INVALID are always available
     * separately).
     */
    function createQuery(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external nonReentrant {
        // Queries can only be created in an existing, Active universe.
        Universe storage universe = _checkUniverseState(universeId);

        // Validate the question and number of outcomes
        // Only meaningful outcomes should be included. UNRESOLVED and INVALID are accounted for separately
        if (numberOfOutcomes < MIN_OUTCOMES) revert InvalidNumberOfOutcomes();
        if (numberOfOutcomes > MAX_OUTCOMES) revert InvalidNumberOfOutcomes();
        if (bytes(question).length > MAX_QUERY_LENGTH) revert QueryTooLong();

        // TODO: Here we need to actually check if question contains the same numberOfOutcomes needed.

        // get the base fee amount from the query fee controller
        uint256 baseFee = QUERY_FEE_CONTROLLER.getQueryFee(universeId);
        // Create a global query record

        // calculate the fee depending on previous volume and update the volume
        uint256 fee = _calculateFeeAndApplyVolume(universeId, baseFee);
        if (fee == 0) revert ZeroFee();
        // The first report's stake is derived from the query fee, bounded to a fraction of the per-outcome cap
        // by _requiredStake.
        uint256 queryFeeCap = _queryFeeCap(universe.repToken, universeId);
        if (fee >= queryFeeCap) fee = queryFeeCap;
        // transfer the query fee amount of REP token
        // TODO: permit? permit2?
        universe.repToken.safeTransferFrom(msg.sender, address(this), fee);

        _recordQuery(msg.sender, universeId, question, numberOfOutcomes, fee);
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
     * @param universeId The universe to create the query in (must be Active itself; never forwarded).
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
        _checkUniverseState(universeId);

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

        // The fee joins the universe's unconsumed-fee aggregate, migrated to children at a fork.
        // Fees are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        universes[currentUniverseId].totalQueryFees += uint128(fee);

        // A universe-specific resolution record starts with outcome == UNRESOLVED.
        // Set the queryCreateTime so the reporting window can be enforced in this universe.
        QueryResolution storage resolution = queryResolutions[currentUniverseId][queryCount];
        resolution.queryCreateTime = uint48(block.timestamp);

        emit QueryCreated(creator, queryCount, currentUniverseId, question, numberOfOutcomes);

        queryCount++;
    }

    /**
     * @notice Reports an outcome on a query, posting the required escalation stake.
     * @dev Acts on the universe as given — no heir forwarding; the universe must exist and be Active.
     *      Rejects reports on queries already resolved
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
    function report(uint248 universeId, uint256 queryId, uint256 outcome) external nonReentrant {
        // Check all conditions (universe exists, query exists, outcome is valid, report is within time, etc.)
        // Reports can only be placed in an existing and active universe.
        Universe storage universe = _checkUniverseState(universeId);

        Query storage query = queries[queryId];
        if (queryId >= queryCount) revert InvalidQuery();

        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();
        uint16 stakeCount = resolution.stakeCount;

        // Outcome should be between 1 and numberOfOutcomes unless the query should be reported as INVALID
        if (outcome == UNRESOLVED) revert InvalidOutcome();
        if ((outcome > query.numberOfOutcomes) && (outcome != INVALID)) revert InvalidOutcome();

        uint48 queryCreateTime = resolution.queryCreateTime;
        if (queryCreateTime == 0) {
            // First touch of an inherited query here: classify it against the lineage's frozen history.
            // Ancestor records are immutable once this universe exists (resolve is gated to Active), so
            // one classification at record materialization covers the query for good.
            (InheritedQueryKind kind, uint48 anchorCreateTime,,) = _classifyInheritedQuery(universeId, queryId);
            if (kind == InheritedQueryKind.AncestorResolved) revert QueryAlreadyResolved();
            if (kind == InheritedQueryKind.SettledLadder) revert QueryAlreadySettled();
            // Fresh or ExpiredAtFork: the anchor becomes the local clock; the window check below
            // rejects the expired case.
            resolution.queryCreateTime = anchorCreateTime;
            queryCreateTime = anchorCreateTime;
        }

        // check that the reporting window for the query is not over yet
        if (stakeCount == 0 && queryCreateTime + THREE_DAYS < block.timestamp) revert QueryExpired();

        if (stakeCount == 0) {
            // Freeze the per-outcome cap: the whole ladder is measured against this one value.
            // a fraction of the REP supply, bounded by max supply (100M * 1e18), within uint96
            // forge-lint: disable-next-line(unsafe-typecast)
            resolution.cap = uint96(_capShares(universe.repToken, universeId));
        } else if (resolution.lastStakeTime + ONE_DAY < block.timestamp) {
            revert AppealPeriodOver();
        }

        uint256 stake = _requiredStake(resolution, query.fee, outcome);
        universe.repToken.safeTransferFrom(msg.sender, address(this), stake);

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

        emit QueryReported(msg.sender, universeId, queryId, outcome, stake);

        if (totalOutcomeStaked == resolution.cap) {
            uint8 outcomesAtCap = resolution.noOfOutcomesAtCap + 1;
            resolution.noOfOutcomesAtCap = outcomesAtCap;
            // The second outcome at the cap means two sides each hold 1% of the supply: the query forks.
            if (outcomesAtCap == 2) {
                _forkLituusUniverse(universeId, queryId);
            }
        }
    }

    /**
     * @notice Resolves a query whose reporting or appeal window has elapsed, recording its outcome.
     * @dev Acts on the universe as given — no heir forwarding; the universe must exist and be Active.
     *      Three cases:
     *      (1) no report ever landed and the THREE_DAYS reporting window passed ->
     *      resolves INVALID (including a query already expired when a fork carried it in);
     *      (2) an inherited query whose ladder concluded before an ancestor's fork ->
     *      resolves immediately to the frozen last outcome (no window applies);
     *      (3) stakes exist and the last one's ONE_DAY appeal window passed
     *      -> resolves to the escalation outcome and settles payoffs; otherwise reverts as not-ready.
     *      In case 1 the RESOLVER earns the time-ramped fee share; in case 2 the frozen winning
     *      outcome's FIRST REPORTER earns it (on the ramp a live resolution would have paid), and
     *      the resolver earns nothing — the reporting work was done pre-fork.
     *
     *      After resolving, if the Zoltar counterpart has started forking, the fork is mirrored here.
     * @param universeId The universe to resolve in.
     * @param queryId The query to resolve.
     */
    function resolve(uint248 universeId, uint256 queryId) external nonReentrant {
        // Queries can only be resolved in an existing, operating or still-forming universe.
        Universe storage universe = _checkUniverseState(universeId);

        if (queryId >= queryCount) revert InvalidQuery();

        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();

        uint48 queryCreateTime = resolution.queryCreateTime;
        // Stays Fresh for a record that already exists here: the live window rules below apply as-is.
        InheritedQueryKind kind = InheritedQueryKind.Fresh;
        uint256 frozenOutcome;
        uint248 recordUniverseId;
        if (queryCreateTime == 0) {
            // First touch of an inherited query here: classify it against the lineage's frozen history
            // (see report() — ancestor records are immutable once this universe exists).
            uint48 anchorCreateTime;
            (kind, anchorCreateTime, frozenOutcome, recordUniverseId) = _classifyInheritedQuery(universeId, queryId);
            if (kind == InheritedQueryKind.AncestorResolved) revert QueryAlreadyResolved();
            // The anchor becomes the local clock: the fork-time restart for Fresh, the long-lapsed
            // window for ExpiredAtFork (the INVALID branch below fires immediately); for SettledLadder
            // it only marks the record materialized.
            resolution.queryCreateTime = anchorCreateTime;
            queryCreateTime = anchorCreateTime;
        }

        if (kind == InheritedQueryKind.SettledLadder) {
            // The frozen ladder concluded before the fork: materialize its predetermined outcome
            // in THIS universe's record (each world settles independently, consuming its own
            // spawn-funded fee copy; the frozen stakes pay out through the claims lane against the
            // ancestor's record — no stake transfers here). Resolvable immediately: no window applies.
            resolution.outcome = frozenOutcome;
            // The reporting work was done pre-fork: the frozen WINNING outcome's first reporter
            // earns the fee share, on the same ramp a live resolution would pay them.
            QueryResolution storage frozenRecord = queryResolutions[recordUniverseId][queryId];
            OutcomeStakes storage frozenWinner = frozenRecord.outcomes[frozenOutcome];
            uint256 queryFee = queries[queryId].fee;
            uint256 reporterPay =
                _timeBasedFeeShare(queryFee, frozenWinner.firstReportTime - frozenRecord.queryCreateTime);
            uint256 profit = queryFee - reporterPay;
            _consumeQueryFee(universe, queryFee);
            emit ReporterRewardPaid(frozenWinner.firstReporter, universeId, queryId, reporterPay);
            // TODO: make the reporter reward claimable instead of pushing it
            universe.repToken.safeTransfer(frozenWinner.firstReporter, reporterPay);
            // The unpaid fee remainder is the query's profit: recorded for the fee controller and
            // burned as wREP, the same as on the stakes path.
            // TODO: burn if the query is inherited?
            if (profit > 0) {
                universe.repToken.burnShares(profit);
            }
            _applyProfit(universeId, profit);
            // TODO: implement reward calculation for claiming

            emit QueryResolved(msg.sender, universeId, queryId, frozenOutcome);
        } else if (resolution.stakeCount == 0 && queryCreateTime + THREE_DAYS < block.timestamp) {
            // if the report period has passed and the query was not reported on then resolve the query as INVALID
            // This works for a query that was created in this universe and never reported on, or for an inherited
            // query that was already expired when the fork carried it in.
            resolution.outcome = INVALID;

            // The resolver setting this query to INVALID earns a share of the fee
            // that ramps from 0 at the reporting deadline to the full fee three days later, then stays
            // whole with no deadline.
            uint256 queryFee = queries[queryId].fee;
            uint256 resolverPay = _timeBasedFeeShare(queryFee, block.timestamp - (queryCreateTime + THREE_DAYS));
            uint256 profit = queryFee - resolverPay;
            _consumeQueryFee(universe, queryFee);
            emit ResolverRewardPaid(msg.sender, universeId, queryId, resolverPay);
            universe.repToken.safeTransfer(msg.sender, resolverPay);
            // The unpaid fee remainder is the query's profit: recorded for the fee controller and
            // burned as wREP, the same as on the stakes path.
            if (profit > 0) {
                universe.repToken.burnShares(profit);
            }
            _applyProfit(universeId, profit);

            emit QueryResolved(msg.sender, universeId, queryId, INVALID);
        } else if (resolution.stakeCount > 0) {
            if (resolution.lastStakeTime + ONE_DAY < block.timestamp) {
                // If there are stakes and the appeal period has passed then resolve the query with the last outcome
                uint256 outcome = _calculateOutcomeAndEscalationPayoffs(universeId, queryId);
                resolution.outcome = outcome;
                emit QueryResolved(msg.sender, universeId, queryId, outcome);
            } else {
                // appeal period is not over yet, cannot resolve
                revert QueryNotReadyToResolve();
            }
        } else {
            // otherwise, the query cannot be resolved yet
            revert QueryNotReadyToResolve();
        }

        // The universe is Active here (_checkUniverseState above). If its Zoltar counterpart has forked
        // natively in the meantime, mirror that fork now, in this same tx, right after the resolution.
        if (ZOLTAR.getForkTime(universeId) != 0) _mirrorZoltarFork(universeId);
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
        // Only while the universe is Active: once it forks, the whole pot is parked in the Zoltar
        // migration balance and claims become claim-and-migrate into a child.
        Universe storage universe = _checkUniverseState(universeId);
        uint256 payout = _claim(universeId, queryId);

        universe.repToken.safeTransfer(msg.sender, payout);

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

        _checkUniverseState(universeId);

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
        uint256 outcome = resolution.outcome;
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
    function _calculateOutcomeAndEscalationPayoffs(uint248 universeId, uint256 queryId) internal returns (uint256) {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        uint256 winnerOutcome = resolution.lastReportedOutcome;
        OutcomeStakes storage winnerStakes = resolution.outcomes[winnerOutcome];
        uint256 totalStaked = resolution.totalStaked;
        uint256 winnerOutcomeStaked = winnerStakes.totalOutcomeStaked;
        address reporter = winnerStakes.firstReporter;
        uint48 reportingTimestamp = winnerStakes.firstReportTime;

        uint256 queryFee = queries[queryId].fee;
        // Per-universe queryCreateTime: createQuery sets it for the origin universe and report()
        // lazily sets it to the parent's forkTime for heir universes on first report.
        uint48 queryCreateTime = resolution.queryCreateTime;

        uint256 totalLoserStakes = totalStaked - winnerOutcomeStaked;
        // Ramps to the full fee over the reporting window; a first correct report after day 3 earns it whole.
        uint256 reporterPay = _timeBasedFeeShare(queryFee, reportingTimestamp - queryCreateTime);

        uint256 loserBurn = totalLoserStakes / BURN_DIVIDER;
        uint256 profit = loserBurn + (queryFee - reporterPay);

        _consumeQueryFee(universes[universeId], queryFee);

        ILituusRep repToken = universes[universeId].repToken;

        emit ReporterRewardPaid(reporter, universeId, queryId, reporterPay);
        // Consecutive reports must differ, so no-losers <=> exactly one stake: settle the sole winner
        // here in one transfer (bond refund + reporter reward) instead of requiring a claim() call.
        // The two events stay separate so StakeClaimed payouts don't include a fee reward.
        // TODO: maybe claim the first reporter reward instead of pushing it
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
     * @dev If the query is resolved in this universe, that outcome is returned directly.
     *      Otherwise the universe's lineage is searched for a recorded resolution — for a canonical
     *      universe the walk starts at the canonicalHeir, so resolutions recorded in canonical
     *      descendants after this universe forked are visible too; a non-canonical universe first
     *      walks forward along its favoriteChild line and then up the parent chain to the query's
     *      origin universe. A query is resolved at most once along any single lineage, so the first
     *      match is the applicable resolution.
     *      Returns UNRESOLVED if no universe on the lineage has resolved the query. Reverts
     *      only if the universe does not exist; outcomes remain readable in any post-fork state.
     * @param universeId The universe to read the outcome from.
     * @param queryId The query to read.
     * @return The resolved outcome, or UNRESOLVED if none applies to this universe.
     */
    function getOutcome(uint248 universeId, uint256 queryId) external view returns (uint256) {
        if (universes[universeId].universeState == UniverseState.NotExisting) revert InvalidUniverse();
        // The walk checks this universe itself first, then inherits from an ancestor or a
        // favorite-child descendant, if any.
        if (queryId >= queryCount) revert InvalidQuery();
        return _findResolution(universeId, queryId);
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
    function getOutcomeStakes(uint248 universeId, uint256 queryId, uint256 outcome)
        external
        view
        returns (OutcomeStakes memory)
    {
        if (queryId >= queryCount) revert InvalidQuery();
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
    function getUserStake(uint248 universeId, uint256 queryId, address staker, uint256 outcome)
        external
        view
        returns (uint96)
    {
        if (queryId >= queryCount) revert InvalidQuery();
        return queryResolutions[universeId][queryId].userStakes[staker][outcome];
    }

    /**
     * @notice The stake the next report on `outcome` must place for `queryId` in `universeId`.
     * @dev Before the first report the cap is not frozen yet, so the estimate uses the live cap and can shift with
     *      the vault rate until the first stake lands. Applies report()'s gates — resolved here or in an
     *      ancestor, settled by a fork, expired — so a quote is only returned when report() would accept
     *      the stake (the appeal-window timing aside).
     * @param universeId The universe to report in.
     * @param queryId The query to report on.
     * @param outcome The outcome the next report would stake on.
     * @return requiredStake The stake the next reporter must post.
     */
    function getNextRequiredStake(uint248 universeId, uint256 queryId, uint256 outcome)
        external
        view
        returns (uint256 requiredStake)
    {
        if (queryId >= queryCount) revert InvalidQuery();
        Universe storage universe = _checkUniverseState(universeId);
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();

        // Mirror report()'s gates so the quote never contradicts it: classify an inherited query
        // with no local record yet, and never quote a price report() would reject.
        uint48 queryCreateTime = resolution.queryCreateTime;
        if (queryCreateTime == 0) {
            (InheritedQueryKind kind, uint48 anchorCreateTime,,) = _classifyInheritedQuery(universeId, queryId);
            if (kind == InheritedQueryKind.AncestorResolved) revert QueryAlreadyResolved();
            if (kind == InheritedQueryKind.SettledLadder) revert QueryAlreadySettled();
            queryCreateTime = anchorCreateTime;
        }

        uint256 fee = queries[queryId].fee;
        if (resolution.stakeCount == 0) {
            if (queryCreateTime + THREE_DAYS < block.timestamp) revert QueryExpired();
            uint256 cap = _capShares(universe.repToken, universeId);
            uint256 firstStakeCap = cap / FIRST_STAKE_CAP_DIVISOR;
            return _roundToPowerOfTwoStep(fee > firstStakeCap ? firstStakeCap : fee, cap);
        }
        return _requiredStake(resolution, fee, outcome);
    }

    /* ========================================= ANCESTRY FUNCTIONS =========================================== */

    /**
     * @notice Returns the outcome of `queryId` as recorded along `universeId`'s lineage.
     * @dev Checks `universeId` itself first. A canonical universe then reads through the canonical
     *      timeline: the walk starts at the canonicalHeir — whose parent chain covers every canonical
     *      universe — so a resolution recorded in a canonical descendant (after this universe forked)
     *      is found as well as one in an ancestor. A non-canonical universe has no settled tip
     *      pointer, so its favoriteChild line is walked forward first (descendants — where a
     *      resolution newer than the caller's, likely stale, universe id would live), crossing only
     *      settled forks: a still-migrating universe's favoriteChild is a running max and is not
     *      followed. Then the parent chain is walked up from the universe's parent, stopping at the
     *      query's origin universe: a query cannot be resolved above the universe it was created in.
     *      The two legs are disjoint, so every universe on the lineage is checked exactly once.
     *      A query is resolved at most once along any single lineage, so the first match is enough.
     *      Returns UNRESOLVED if no universe on the lineage has resolved the query.
     */
    function _findResolution(uint248 universeId, uint256 queryId) internal view returns (uint256 resolvedOutcome) {
        // Check the universe itself first.
        uint256 outcome = queryResolutions[universeId][queryId].outcome;
        if (outcome != UNRESOLVED) {
            return outcome;
        }
        uint248 originUniverseId = queries[queryId].originUniverse;
        Universe storage universe = universes[universeId];
        bool isCanonical = universe.isCanonical;
        // Walk forward for non-canonical universes
        if (!isCanonical) {
            Universe storage child = universe;
            // A hop is taken only out of a settled fork: during Migration favoriteChild is a
            // running max and should not be followed.
            while (child.universeState == UniverseState.PostFork) {
                uint248 childId = child.favoriteChild;
                if (childId == 0) {
                    break;
                }
                child = universes[childId];
                outcome = queryResolutions[childId][queryId].outcome;
                if (outcome != UNRESOLVED) {
                    return outcome;
                }
            }
            // A query cannot be resolved above its origin universe, so when this universe IS the
            // origin (itself and its descendants both checked above) the backward leg has nothing
            // left to check.
            if (originUniverseId == universeId) return UNRESOLVED;
        }
        // A canonical universe is always on the heir's parent chain, so starting the walk at the
        // canonicalHeir covers its canonical descendants as well as its ancestors. For non-canonical
        // universes the parent chain is walked from the universe's parent (the universe itself was
        // checked above) up to the query's origin universe or the genesis universe.
        uint248 currentId = isCanonical ? canonicalHeir : universe.parent;
        while (true) {
            outcome = queryResolutions[currentId][queryId].outcome;
            if (outcome != UNRESOLVED) {
                return outcome;
            }
            // The query cannot be resolved above its origin universe, so the walk stops there. The
            // genesis — checked above as a universe in its own right — roots every parent chain and
            // ends the walk too.
            if (currentId == originUniverseId || currentId == GENESIS_UNIVERSE_ID) {
                return UNRESOLVED;
            }
            currentId = universes[currentId].parent;
        }
    }

    /**
     * @notice Returns whether `ancestorId` is `universeId` itself or one of its ancestors in the fork tree.
     * @dev Walks the parent chain from `universeId` up to the root — the genesis, which is checked
     *      against `ancestorId` in its own right before ending the walk.
     */
    function _isSelfOrAncestor(uint248 ancestorId, uint248 universeId) internal view returns (bool isAncestor) {
        uint248 currentId = universeId;
        while (true) {
            if (currentId == ancestorId) {
                return true;
            }
            // Every parent chain terminates at the genesis.
            if (currentId == GENESIS_UNIVERSE_ID) {
                return false;
            }
            currentId = universes[currentId].parent;
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
    function _requiredStake(QueryResolution storage resolution, uint256 fee, uint256 outcome)
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
        // A zero stake is unreachable and doesn't need a check.
    }

    /* ==================================== TOKEN SUPPLY MANAGEMENT FUNCTIONS ==================================== */
    /**
     * @notice Migration, auction, and other token supply management functions.
     */

    /* ============================================ FORKING FUNCTIONS ============================================ */
    /// @notice Forks a universe on a query whose escalation reached the fork threshold.
    /// @dev Zero eager children: the fork question mirrors the query's own outcome set and every child
    ///      is spawned lazily via spawnChildUniverse. The Zoltar question submits the raw Lituus
    ///      question string with numbered outcome labels — real-Zoltar label ordering (hash-descending)
    ///      is a later phase; against the mock the labels are unchecked.
    function _forkLituusUniverse(uint248 universeId, uint256 queryId) internal {
        Universe storage universe = universes[universeId];

        // The Zoltar counterpart may have forked natively, in this case this call should revert
        // and Zoltar fork should be mirrored. The current query will be refunded as the rest of
        // the queries in this universe, and the reporting can start over in a child immediately.
        if (ZOLTAR.getForkTime(universeId) != 0) revert ZoltarUniverseAlreadyForking();

        IZoltarQuestionData.QuestionData memory questionData;
        questionData.title = _createForkQuestionString(queryId);
        questionData.description = "";
        questionData.startTime = block.timestamp - 1 days;
        // in Zoltar: require(block.timestamp >= endTime, 'Question has not ended');
        questionData.endTime = block.timestamp - 1 days;
        questionData.numTicks = 0;
        questionData.displayValueMin = 0;
        questionData.displayValueMax = 0;
        questionData.answerUnit = "";

        // Placeholder labels — the mock ignores them (it need not even match the outcome count).
        // TODO: The real label set (one per Lituus outcome plus INVALID, hash-ordered) is to
        // be implemented later.
        string[] memory outcomes = new string[](2);
        outcomes[0] = "1";
        outcomes[1] = "2";

        uint256 zoltarQueryId = ZOLTAR_QUESTION_DATA.createQuestion(questionData, outcomes);
        if (zoltarQueryId == 0) revert ZoltarQueryCreationFailed();

        // Fork in Zoltar. The threshold burn / pot escrow will be added later; the mock is a no-op.
        ZOLTAR.forkUniverse(universeId, zoltarQueryId);

        Query storage query = queries[queryId];
        // The Lituus query now has a Zoltar question: the fork question just submitted.
        query.zoltarQuestionId = zoltarQueryId;

        // queryId indexes queries by count, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.forkQuery = uint128(queryId);
        universe.isLituusFork = true;
        // The forking query's fee leaves the fee aggregate: every child resolves the query at spawn
        // by writing the outcome directly, so no payoff path ever consumes this fee in any child.
        _consumeQueryFee(universe, query.fee);
        _enterMigration(universeId, universe, queryId, zoltarQueryId);
    }

    /**
     * @notice The state transition shared by both fork kinds — a Lituus escalation fork and a mirrored
     *         native Zoltar fork: the universe enters Migration, its fork clock starts, its whole pot is
     *         parked in the Zoltar migration balance and its vault is unwrap-paused for good.
     * @dev forkQuery and isLituusFork are the caller's to set before this runs (they differ per kind).
     *      forkTime is Lituus time — the tx that forks or mirrors — never Zoltar's own fork time: a late
     *      mirror must still open a full migration window, or the permanent unwrap pause would strand
     *      every holder with the window already closed. (For a Lituus fork the two times coincide.)
     */
    function _enterMigration(uint248 universeId, Universe storage universe, uint256 queryId, uint256 zoltarQuestionId)
        internal
    {
        universe.universeState = UniverseState.Migration;
        universe.forkTime = uint48(block.timestamp);
        _addPotToMigrationBalance(universeId, universe);
        // Permanent: wrapped capital in a forked universe exits ONLY through the counted Lituus
        // migration lane (migrate(), and later the claim lanes) — never by unwrapping to the Zoltar
        // level. No code path ever unpauses a forked universe's vault.
        universe.repToken.setUnwrapPaused(true);
        emit UniverseForked(universeId, queryId, zoltarQuestionId, universe.isLituusFork);
    }

    /**
     * @notice Parks the contract's entire wREP holding of a forking universe in the Zoltar
     *         migration balance: query fees, the forking query's pot, and all other stakes and
     *         unclaimed winnings. Runs once, in the fork tx.
     * @dev From here every path to this value is a "second part" of a migration — minting into a
     *      child universe (fee splits at spawn now; per-stake claims/refunds in the claims phase).
     *      Nothing is ever withdrawable on the parent side again. The parked total is recorded in
     *      unmigratedSupply: SR max supply = totalMigratedOut + unmigratedSupply.
     */
    function _addPotToMigrationBalance(uint248 universeId, Universe storage universe) internal {
        uint256 potShares = universe.repToken.balanceOf(address(this));
        if (potShares > 0) {
            uint256 potAssets = universe.repToken.migrateOut(address(this), potShares);
            ZOLTAR.addRepToMigrationBalance(universeId, potAssets);
            // Asset amounts are REP amounts within uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            universe.unmigratedSupply = uint128(potAssets);
        }
    }

    /// @dev Marks a query's fee consumed in this universe's fee aggregate. Saturating: the
    ///      spawn-time fee split rounds down twice, so a child's carried aggregate can run short of
    ///      the nominal fee sum by dust.
    // TODO: rewrite the fee accounting so that it correctly handles dust and rounding issues.
    function _consumeQueryFee(Universe storage universe, uint256 fee) internal {
        uint128 totalQueryFees = universe.totalQueryFees;
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.totalQueryFees = fee >= totalQueryFees ? 0 : totalQueryFees - uint128(fee);
    }

    /**
     * @notice Spawns the child universe for one outcome of a forking universe. Permissionless.
     * @dev Lazy per-child deployment: only outcomes somebody pays to spawn get a universe, and only
     *      during the 60-day fork window (use-it-or-lose-it). The outcome must be a valid outcome of
     *      the forking query: 1..numberOfOutcomes or INVALID for a Lituus fork; for a mirrored Zoltar
     *      fork any answer Zoltar deems well-formed (categorical 0 = Invalid, 1..n; scalar encodings).
     * @param universeId The forking universe (must be in Migration).
     * @param outcome The forking query's outcome this child stands for (a Zoltar answer for a mirrored fork).
     */
    function spawnChildUniverse(uint248 universeId, uint256 outcome) external nonReentrant {
        Universe storage universe = universes[universeId];
        if (universe.universeState != UniverseState.Migration) revert InvalidUniverseState();
        // The spawn window is the migration window, self-enforced by clock.
        if (block.timestamp >= uint256(universe.forkTime) + SIXTY_DAYS) revert SpawnWindowClosed();

        uint256 forkQueryId = universe.forkQuery;
        // TODO: map outcomeId to Zoltar outcomes.
        Query storage forkQuery = queries[forkQueryId];
        uint8 numberOfOutcomes = forkQuery.numberOfOutcomes;
        if (numberOfOutcomes != 0) {
            // A Lituus-defined outcome set: 1..numberOfOutcomes or INVALID, keyed into Zoltar as-is.
            // TODO (labels/mapping phase): submit real labels and map INVALID to Zoltar's Invalid (0); then
            // Zoltar's rule below covers this branch too.
            if (outcome == UNRESOLVED || (outcome > numberOfOutcomes && outcome != INVALID)) revert InvalidOutcome();
        } else if (ZOLTAR_QUESTION_DATA.isMalformedAnswerOption(forkQuery.zoltarQuestionId, outcome)) {
            // A Zoltar-defined outcome set (mirrored fork): the outcome is a Zoltar answer and Zoltar's own
            // rule decides, categorical or scalar alike. Zoltar's deployChild re-checks it; this is only the
            // clean revert.
            revert InvalidOutcome();
        }

        _spawnChildUniverse(universeId, forkQueryId, outcome);
    }

    /**
     * @notice Creates one child universe for a forking branch and links it into the fork tree.
     * @dev Deploys the Zoltar-side child if needed, then the child's Lituus REP vault at the parent's
     *      rate (so accrued appreciation carries over), approves the vault to pull migrated underlying
     *      from this contract, seeds the child's fee state with the parent's base fee, and resolves the
     *      forking query to the CHILD'S OWN outcome — every child answers the forking query its own way.
     *      Children spawn Active (fully functional immediately) and non-canonical.
     * @param universeId The parent universe forking.
     * @param queryId The forking query.
     * @param outcome The Zoltar outcome index the child is keyed by. For a Lituus fork it is also the forking
     * query's Lituus outcome (identity keying until the labels/mapping phase); for a mirrored fork it is a
     * Zoltar answer, recorded as-is except Zoltar's Invalid (0), which is recorded as INVALID for now.
     */
    function _spawnChildUniverse(uint248 universeId, uint256 queryId, uint256 outcome) internal {
        uint248 childUniverseId = ZOLTAR.getChildUniverseId(universeId, outcome);
        if (childUniverseId == 0) revert InvalidUniverse();
        // Never overwrite an existing universe.
        if (universes[childUniverseId].universeState != UniverseState.NotExisting) revert InvalidUniverse();

        Universe storage parentUniverse = universes[universeId];

        // Deploy the Zoltar-side child only if it does not exist yet (a zero rep token means
        // undeployed): Zoltar's deployChild reverts on an already-deployed universe, and anyone may
        // have deployed it directly at the Zoltar level.
        IReputationToken childUniverseZoltarRepToken = ZOLTAR.getRepToken(childUniverseId);
        if (address(childUniverseZoltarRepToken) == address(0)) {
            ZOLTAR.deployChild(universeId, outcome);
            childUniverseZoltarRepToken = ZOLTAR.getRepToken(childUniverseId);
        }
        // An undeployed/broken Zoltar child reads threshold 0.
        if (ZOLTAR.getForkThreshold(childUniverseId) == 0) revert InvalidUniverse();

        // Deploy a Lituus REP token that wraps the child's Zoltar REP token
        // TODO: have the same REP token symbol format as in Zoltar
        // The child vault starts at the parent's current rate.
        ILituusRep childUniverseRepToken = new LituusRep(
            address(this),
            address(childUniverseZoltarRepToken),
            "Lituus Reputation Token",
            "REP0.0", // TODO
            parentUniverse.repToken.rate()
        );
        // migrate() wraps migrated underlying into the child vault, which pulls from this contract.
        IERC20(address(childUniverseZoltarRepToken)).forceApprove(address(childUniverseRepToken), type(uint256).max);
        // The child vault spawns with unwrap OPEN: unwrapping child wREP harms nothing — fork
        // accounting is counter-based, and only migrate()/claim lanes write totalMigratedIn. The
        // pause is only ever set on a universe that forks, permanently, in its own fork tx.

        Universe storage childUniverse = universes[childUniverseId];
        childUniverse.repToken = childUniverseRepToken;
        // Children spawn ACTIVE: fully query-functional immediately.
        childUniverse.universeState = UniverseState.Active;
        // forkTime stays 0: the child has not forked (it is set if/when the child's own fork triggers).
        childUniverse.forkTime = 0;
        childUniverse.parent = universeId;

        // Inherit the parent's base fee so the child can charge nonzero query fees from birth
        QUERY_FEE_CONTROLLER.initializeFeeState(childUniverseId, QUERY_FEE_CONTROLLER.getQueryFee(universeId));

        // Fund the child with the parent's whole fee aggregate: split from the parked migration
        // balance (a full copy per child — Zoltar's per-child escrow makes the duplication legal)
        // and wrap into the child vault. This backs the resolutions of EVERY query the child
        // inherits; the carried counter re-parks if the child itself forks later. Deliberately NOT
        // counted in totalMigratedIn/totalMigratedOut/max: fees duplicate per child and are not
        // single-spend voting capital — totalQueryFees is their ledger.
        uint256 feeAssets = parentUniverse.repToken.convertToAssets(parentUniverse.totalQueryFees);
        if (feeAssets > 0) {
            ZOLTAR.splitMigrationRep(universeId, feeAssets, outcome);
            uint256 feeShares = childUniverseRepToken.wrap(address(this), feeAssets);
            // Share amounts are REP amounts within uint128.
            // forge-lint: disable-next-line(unsafe-typecast)
            childUniverse.totalQueryFees = uint128(feeShares);
        }

        // Every child resolves the forking query to its own outcome; descendants inherit it via the
        // ancestor walk
        QueryResolution storage resolution = queryResolutions[childUniverseId][queryId];
        resolution.queryCreateTime = uint48(block.timestamp);
        // Only a Zoltar-defined outcome set lets 0 (Zoltar's Invalid) through the spawn validation.
        // TODO: rework in the labels/mapping phase — temporary Zoltar Invalid (0) -> Lituus INVALID translation.
        resolution.outcome = outcome == 0 ? INVALID : outcome;
        emit QueryResolved(msg.sender, childUniverseId, queryId, resolution.outcome);
        emit ChildUniverseSpawned(universeId, childUniverseId, outcome);

        if (parentUniverse.isLituusFork) {
            // TODO: fork payouts
        }
    }

    /**
     * @notice Migrates the caller's wREP from a forking universe into one of its children.
     *         Counted voting: the running migration max designates the fork's winner.
     * @dev Only during the 60-day window, self-enforced by clock. The target child must already be
     *      spawned (spawnChildUniverse is permissionless). The caller's parent wREP is burned via the
     *      migrateOut lane; the underlying routes through Zoltar migration into the
     *      child's REP, is wrapped into the child vault, and the child wREP is credited to the
     *      caller. Migration is burn-based and irreversible.
     * @param universeId The forking universe to migrate out of.
     * @param outcome The forking query's outcome whose child to migrate into, as passed to spawnChildUniverse.
     * @param shares The amount of the caller's parent wREP shares to migrate.
     */
    function migrate(uint248 universeId, uint256 outcome, uint256 shares) external nonReentrant {
        Universe storage universe = universes[universeId];
        if (universe.universeState != UniverseState.Migration) revert InvalidUniverseState();

        // The forking window is closed if the migration stage is over (60 days passed)
        // and the parent fork is resolved (PostFork). The parent migration phase must end first,
        // and then the nested fork can finish migration.
        // TODO: make a getter for universe state
        Universe storage parentUniverse = universes[universe.parent];
        bool isParentForkResolved =
            universeId == GENESIS_UNIVERSE_ID || parentUniverse.universeState == UniverseState.PostFork;
        if ((block.timestamp >= uint256(universe.forkTime) + SIXTY_DAYS) && isParentForkResolved) {
            revert MigrationWindowClosed();
        }

        // The child is keyed by the outcome exactly as spawnChildUniverse keyed it.
        uint248 childUniverseId = ZOLTAR.getChildUniverseId(universeId, outcome);
        Universe storage childUniverse = universes[childUniverseId];
        // The target child must exist: spawn it first (permissionless) if this outcome has none yet.
        // TODO: maybe spawn the child universe here if needed
        if (childUniverse.universeState == UniverseState.NotExisting) revert InvalidUniverse();

        // Burn the caller's parent wREP and take the underlying (pause-exempt, rate-preserving
        // owner lane — the forked vault is permanently unwrap-paused).
        uint256 assets = universe.repToken.migrateOut(msg.sender, shares);
        // Route the underlying through Zoltar migration into the child's REP
        ZOLTAR.addRepToMigrationBalance(universeId, assets);
        ZOLTAR.splitMigrationRep(universeId, assets, outcome);
        // Wrap it into the child vault (pulls via the spawn-time approval) and credit the caller.
        uint256 childShares = childUniverse.repToken.wrap(address(this), assets);
        childUniverse.repToken.safeTransfer(msg.sender, childShares);

        // Count the vote in underlying assets (what actually flowed through Lituus). The parent's
        // outflow total is the live electorate measure: the 2/3 denominator and the SR max supply.
        // Asset amounts are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.totalMigratedOut += uint128(assets);
        // forge-lint: disable-next-line(unsafe-typecast)
        childUniverse.totalMigratedIn += uint128(assets);
        if (childUniverse.totalMigratedIn > universe.maxMigratedOut) {
            universe.maxMigratedOut = childUniverse.totalMigratedIn;
            universe.favoriteChild = childUniverseId;
        }
    }

    /**
     * @notice Advances a forking universe out of Migration after the migration window closes.
     *         Permissionless.
     * @dev For now it always resolves the fork: designates the winner and moves the universe to
     *      PostFork. Later it will check the max amount migrated (2/3 of totalMigratedOut, both
     *      read live here at the end of migration) and either resolve the fork or start the supply
     *      restoration and the auction.
     *      Root-first ordering: a nested fork cannot resolve before its parent's fork has resolved.
     * @param universeId The forking universe to advance.
     */
    function advanceForkState(uint248 universeId) external nonReentrant {
        Universe storage universe = universes[universeId];
        if (universe.universeState != UniverseState.Migration) revert InvalidUniverseState();
        // Root-first: the parent's fork must be resolved before this universe's fork can advance
        // (the genesis, having no parent, is exempt).
        bool isParentForkResolved =
            universeId == GENESIS_UNIVERSE_ID || universes[universe.parent].universeState == UniverseState.PostFork;
        if (!isParentForkResolved) revert ParentForkNotResolved();

        if (block.timestamp < uint256(universe.forkTime) + SIXTY_DAYS) revert MigrationWindowNotClosed();

        // The winner is the running max, already in favoriteChild. Only a canonical universe's
        // resolution moves the canonical timeline.
        uint248 winner = universe.favoriteChild;
        if (winner != 0 && universe.isCanonical) {
            universes[winner].isCanonical = true;
            canonicalHeir = winner;
        }

        universe.universeState = UniverseState.PostFork;
        // The vault stays paused forever: unmigrated wREP's recourse is the Lituus claim/migration
        // lanes, not a Zoltar-level exit.
    }

    /**
     * @notice Mirrors a native Zoltar fork of a universe into this Multiverse. Permissionless.
     * @dev Reentrancy-guarded wrapper over _mirrorZoltarFork; resolve() takes the same path implicitly.
     *      Reverts unless this universe is Active and its Zoltar counterpart has forked.
     * @param universeId The universe whose Zoltar fork to mirror.
     */
    function mirrorZoltarFork(uint248 universeId) external nonReentrant {
        _mirrorZoltarFork(universeId);
    }

    /**
     * @notice Imports a native Zoltar fork by id: the mirrored fork is a Lituus fork minus the forking-query
     *         payouts. A Lituus query is created for the Zoltar fork question so getOutcome(child, forkQuery)
     *         tells which branch any descendant universe stands on, exactly as for a Lituus fork.
     * @dev The query is Zoltar-defined: numberOfOutcomes stays 0 and zoltarQuestionId is Zoltar's forkQuestionId;
     *      its title, labels and answer validity live in ZoltarQuestionData and are never copied here. Nothing
     *      is read from the question at mirror time, so no Zoltar fork — categorical or scalar — can fail to
     *      mirror. Children spawn lazily through spawnChildUniverse, keyed by Zoltar answer, and each resolves
     *      the mirrored query to its own answer at spawn. No fee: there is nothing to pay out for this query.
     */
    function _mirrorZoltarFork(uint248 universeId) internal {
        Universe storage universe = _checkUniverseState(universeId);
        if (ZOLTAR.getForkTime(universeId) == 0) revert ZoltarUniverseIsNotForking();

        uint256 zoltarQuestionId = ZOLTAR.universes(universeId).forkQuestionId;

        uint256 queryId = queryCount;
        Query storage query = queries[queryId];
        // numberOfOutcomes stays 0 (the outcome set is Zoltar's), question stays empty (the title is Zoltar's),
        // fee stays 0 (nothing is ever paid out for this query).
        query.originUniverse = universeId;
        query.zoltarQuestionId = zoltarQuestionId;
        // The origin's record exists from creation, as for every query. Its outcome stays UNRESOLVED: the
        // forking universe never resolves its own fork question; its children do, each its own way.
        queryResolutions[universeId][queryId].queryCreateTime = uint48(block.timestamp);
        emit QueryCreated(msg.sender, queryId, universeId, "", 0);
        queryCount++;

        // queryId indexes queries by count, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.forkQuery = uint128(queryId);
        // Explicit for clarity: a mirrored fork pays nothing out for its forking query.
        universe.isLituusFork = false;
        _enterMigration(universeId, universe, queryId, zoltarQuestionId);
    }

    /* =========================================== INTERNAL HELPERS ============================================== */
    /**
     * @notice Checks that a universe can be operated on directly — it must exist and be Active — and
     *         returns it.
     * @dev Reverts with InvalidUniverse if the universe does not exist
     *      and InvalidUniverseState if it is in any forking state.
     */
    function _checkUniverseState(uint248 universeId) internal view returns (Universe storage universe) {
        universe = universes[universeId];
        UniverseState universeState = universe.universeState;
        if (universeState == UniverseState.NotExisting) revert InvalidUniverse();
        if (universeState != UniverseState.Active) {
            revert InvalidUniverseState();
        }
    }

    /**
     * @notice Classifies an inherited query with no local record yet against its lineage's frozen history,
     *         in one pass over the ancestor chain.
     * @dev Walks the parent chain to the NEAREST materialized record R (the origin always has one, so a
     *      genuinely inherited query always terminates there; reaching the genesis without finding any
     *      record means the query does not belong to this lineage). Records only materialize while a
     *      universe is Active, so R's record was frozen as-is by R's own fork at forkTime F:
     *      - resolved in R (or any ancestor on the way) -> AncestorResolved;
     *      - stakes with the appeal window lapsed before F -> SettledLadder: the last outcome is
     *        predetermined for every descendant;
     *      - no stakes and the reporting window lapsed before F -> ExpiredAtFork, anchored at R's
     *        createTime;
     *      - otherwise the game is voided and reporting restarts (Fresh) — UNLESS some untouched
     *        generation between R and here held the query for more than the reporting window between
     *        its carry-in fork and its own fork: then it silently expired there (ExpiredAtFork,
     *        anchored at that generation's carry-in time).
     *      The Fresh clock is the parent's forkTime — the fork, not this universe's spawn, so a child
     *      spawned more than the reporting window after the fork receives the query already expired.
     * @param universeId The universe the query is being acted on in (must have no local record).
     * @param queryId The query in question.
     * @return kind The classification.
     * @return anchorCreateTime The local reportable-from clock to store: the parent's forkTime for
     *         Fresh (and SettledLadder, where it only marks the record materialized), or the expired
     *         generation's carry-in time for ExpiredAtFork. Zero for AncestorResolved.
     * @return frozenOutcome The predetermined outcome (SettledLadder), or the inherited one
     *         (AncestorResolved). Zero otherwise.
     * @return recordUniverseId SettledLadder only: the ancestor holding the frozen ladder's record —
     *         the winning first reporter and the reward ramp are read from it, and the future claims
     *         lane settles its stakes.
     */
    function _classifyInheritedQuery(uint248 universeId, uint256 queryId)
        internal
        view
        returns (InheritedQueryKind kind, uint48 anchorCreateTime, uint256 frozenOutcome, uint248 recordUniverseId)
    {
        // The genesis inherits from nowhere.
        if (universeId == GENESIS_UNIVERSE_ID) revert QueryNotInherited();

        uint248 currentParentId = universes[universeId].parent;
        // Every ancestor of an existing universe has forked, so its forkTime is nonzero.
        uint48 freshAnchor = universes[currentParentId].forkTime;
        // The carry-in time of the untouched generation closest to R whose window lapsed, if any.
        uint48 expiredAnchor = 0;
        while (true) {
            QueryResolution storage record = queryResolutions[currentParentId][queryId];
            if (record.outcome != UNRESOLVED) {
                return (InheritedQueryKind.AncestorResolved, 0, record.outcome, 0);
            }
            uint48 recordCreateTime = record.queryCreateTime;
            if (recordCreateTime != 0) {
                // The nearest materialized record R, frozen by R's own fork.
                uint48 forkTime = universes[currentParentId].forkTime;
                if (record.stakeCount > 0) {
                    if (record.lastStakeTime + ONE_DAY < forkTime) {
                        return
                            (InheritedQueryKind.SettledLadder, freshAnchor, record.lastReportedOutcome, currentParentId);
                    }
                    // The appeal window was still open at F: the ladder is voided (stakes refundable
                    // through the claims lane) and reporting restarts below.
                } else if (recordCreateTime + THREE_DAYS < forkTime) {
                    return (InheritedQueryKind.ExpiredAtFork, recordCreateTime, 0, 0);
                }
                if (expiredAnchor != 0) {
                    return (InheritedQueryKind.ExpiredAtFork, expiredAnchor, 0, 0);
                }
                return (InheritedQueryKind.Fresh, freshAnchor, 0, 0);
            }
            // Records exist only in the origin's descendants, and the origin's record always exists:
            // exhausting the chain without finding one means this universe does not descend from the
            // query's origin.
            if (currentParentId == GENESIS_UNIVERSE_ID) revert QueryNotInherited();
            // An untouched generation: it held the query from its carry-in fork to its own fork. If a
            // full reporting window fit in that time, the query expired there. Later (higher) finds
            // overwrite earlier ones, so the anchor ends at the generation closest to R — where the
            // window truly lapsed first. Finding the first expiration window is used for determining
            // the reporter pay based on the time ramp.
            uint248 parentId = universes[currentParentId].parent;
            uint48 carryInTime = universes[parentId].forkTime;
            if (carryInTime + THREE_DAYS < universes[currentParentId].forkTime) {
                expiredAnchor = carryInTime;
            }
            currentParentId = parentId;
        }
    }

    /**
     * @notice Builds the question text for creating a fork in Zoltar.
     * @dev Placeholder — returns the original question unchanged; Zoltar formatting is TODO.
     * @param queryId The query being forked on.
     * @return The question string for the Zoltar query.
     */
    function _createForkQuestionString(uint256 queryId) internal view returns (string memory) {
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
