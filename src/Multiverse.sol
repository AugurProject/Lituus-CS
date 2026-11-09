// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IZoltar, IZoltarQuestionData } from "./interfaces/IZoltar.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { ITokenDeployer } from "./interfaces/ITokenDeployer.sol";
import { IReputationToken } from "./interfaces/IReputationToken.sol";
import { IQueryFeeController } from "./interfaces/IQueryFeeController.sol";
import { IMultiverse } from "./interfaces/IMultiverse.sol";
import { IPermit2 } from "./interfaces/IPermit2.sol";
import { PermitSupport } from "./PermitSupport.sol";
import { ForkLib } from "./libraries/ForkLib.sol";
import { MultiverseHelpers } from "./libraries/MultiverseHelpers.sol";

contract Multiverse is ReentrancyGuard, PermitSupport, IMultiverse {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILituusRep;

    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    // UNRESOLVED, INVALID and BURN_DIVIDER, and the outcome domain they belong to, are defined and documented in
    // MultiverseHelpers, which ForkLib shares (a library cannot read a contract's constants).
    uint8 public constant MAX_OUTCOMES = 254; // number of outcomes for a query (not including UNRESOLVED and INVALID)
    uint8 public constant MIN_OUTCOMES = 2; // minimum number of valid outcomes for a query
    uint256 public constant UNRESOLVED = MultiverseHelpers.UNRESOLVED;
    uint256 public constant INVALID = MultiverseHelpers.INVALID;
    // TODO: determine the max query length based on gas costs
    uint16 public constant MAX_QUERY_LENGTH = 2058; // maximum length of a query string

    uint256 public constant BURN_DIVIDER = MultiverseHelpers.BURN_DIVIDER;
    /// @notice Divisor of the universe's REP supply that sets the per-outcome stake cap (1%).
    uint256 public constant CAP_DIVISOR = 100;
    /// @notice Divisor of the cap that bounds the first stake, so no ladder starts closer than two rounds to it.
    uint256 public constant FIRST_STAKE_CAP_DIVISOR = 4;

    uint256 public constant SCALE = 1 ether;

    // The genesis universe's id (mirrors its Zoltar id, which is not necessarily 0).
    uint248 public immutable GENESIS_UNIVERSE_ID;
    IZoltar public immutable ZOLTAR;
    // The ZoltarQuestionData contract is immutable in Zoltar so it can be cached here.
    IZoltarQuestionData public immutable ZOLTAR_QUESTION_DATA;
    IQueryFeeController public immutable QUERY_FEE_CONTROLLER;
    // The QueryTokenizer allowed to create queries at a tokenizer-supplied price.
    // One immutable contract serves every universe.
    address public immutable QUERY_TOKENIZER;
    // Deploy factory for Lituus wREP tokens and for query tokens.
    ITokenDeployer public immutable TOKEN_DEPLOYER;

    // Time periods
    uint256 public immutable MIGRATION_DURATION;
    uint256 public immutable REPORTING_PERIOD;
    uint256 public immutable APPEAL_PERIOD;

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
    ///      report touches it (`noOfOutcomesAtCap` only when an outcome reaches the cap). `cap` and `forkBurn`
    ///      share the next slot: the cap is written at the first report only, the burn once, in the fork tx, and
    ///      the fork payouts read both together. Outcomes are full words — categorical outcomes and Zoltar's
    ///      packed scalar answers share one uint256 domain — so `outcome` and `lastReportedOutcome` take a slot
    ///      each; a report writes `lastReportedOutcome` and the shared slot. wREP amounts are bounded by the REP
    ///      max supply (100M * 1e18), comfortably within uint96.
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
        // Per-outcome stake ceiling: 1% of the universe's REP supply, converted to wREP shares (rounded up, see
        // _capShares) and frozen at the first report so the whole ladder is measured against one grid.
        uint96 cap;
        // Forking query only: what Zoltar kept of the fork bond, in wREP shares at the parent's rate. It comes
        // off the losing side before the stakes are paid out in the children (see ForkLib._forkPayout). Set in
        // the fork tx, zero on every other query.
        uint96 forkBurn;
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
        // forking-query stakes, other stakes/winnings) as it stood before the fork, moved into the Zoltar
        // migration balance in the fork tx less what Zoltar kept of the fork bond (recorded on the forking
        // query's record as forkBurn). Written once. Supply committed to the child level but not yet
        // realized as counted migration — SR max supply = totalMigratedOut + unmigratedSupply, less that
        // burn. Future stake-claims move value across (parked -> counted) at face value, which is why the
        // burned part stays in here; fee splits move neither (per-world duplicated copies). Kept locally:
        // Zoltar's balance would include foreign flows.
        uint128 unmigratedSupply;
    }

    /* ================================================ VARIABLES ================================================ */
    mapping(uint248 universeId => Universe) public universes;
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
    // Wallet wREP migrated out of a forking universe into one of its children, counted as a vote in `assets`.
    event Migrated(address indexed holder, uint248 indexed universeId, uint248 indexed childUniverseId, uint256 assets);
    // A stake claimed out of a forked universe into one of its children, paid in the child's wREP.
    event StakeMigrated(
        address indexed staker,
        uint248 indexed universeId,
        uint248 indexed childUniverseId,
        uint256 queryId,
        uint256 assets
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
    error ZoltarUniverseAlreadyForking();
    error QueryTooLong();
    error ZeroFee();
    error ExactlyOneAmountRequired();
    error QueryNotInherited();
    error MigrationWindowClosed();
    error MigrationWindowNotClosed();
    error ParentForkNotResolved();
    error QueryNotResolved();
    error NothingToClaim();
    error NotAWinningOutcome();
    error InvalidClaimBatch();
    error OnlyQueryTokenizer();

    /* =============================================== CONSTRUCTOR =============================================== */
    /**
     * @notice Wires the Zoltar address, seeds the genesis universe, and sets the fee controller.
     * @param _zoltar The Zoltar address.
     * @param _initialZoltarUniverseId The Zoltar universe id treated as the Lituus genesis. It is also
     * the genesis universe's id here: Lituus universe ids mirror Zoltar universe ids.
     * @param _queryFeeController The controller pricing queries: base fee, demand modifier and profit history.
     * @param _queryTokenizer The QueryTokenizer allowed to create queries at a tokenizer-supplied price
     * (one immutable contract for all universes).
     * @param _tokenDeployer The deployer of the wREP vaults and of the query tokens.
     * @param _permit2 Uniswap's Permit2, for approving and paying in one transaction (see PermitSupport).
     */
    constructor(
        IZoltar _zoltar,
        uint248 _initialZoltarUniverseId,
        IQueryFeeController _queryFeeController,
        address _queryTokenizer,
        ITokenDeployer _tokenDeployer,
        IPermit2 _permit2,
        uint256 _migrationDuration,
        uint256 _reportingPeriod,
        uint256 _appealPeriod
    ) PermitSupport(_permit2) {
        MIGRATION_DURATION = _migrationDuration;
        REPORTING_PERIOD = _reportingPeriod;
        APPEAL_PERIOD = _appealPeriod;
        QUERY_TOKENIZER = _queryTokenizer;
        if (QUERY_TOKENIZER == address(0)) revert ZeroAddress();
        TOKEN_DEPLOYER = _tokenDeployer;
        if (address(TOKEN_DEPLOYER) == address(0)) revert ZeroAddress();
        ZOLTAR = _zoltar;
        if (address(ZOLTAR) == address(0)) revert ZeroAddress();
        ZOLTAR_QUESTION_DATA = ZOLTAR.zoltarQuestionData();
        if (address(ZOLTAR_QUESTION_DATA) == address(0)) revert ZeroAddress();
        QUERY_FEE_CONTROLLER = _queryFeeController;
        if (address(QUERY_FEE_CONTROLLER) == address(0)) revert ZeroAddress();

        // get the REP token address from the initial universe in Zoltar
        IReputationToken initialZoltarRepToken = ZOLTAR.getRepToken(_initialZoltarUniverseId);
        // deploy a Lituus REP token that wraps the Zoltar REP token (named after it by the deployer)
        ILituusRep repToken = TOKEN_DEPLOYER.deployLituusRep(address(initialZoltarRepToken), SCALE);
        // wrap() through Permit2 brings the underlying here first and wraps it from this contract.
        IERC20(address(initialZoltarRepToken)).forceApprove(address(repToken), type(uint256).max);

        // Lituus universe ids mirror Zoltar universe ids (children already use Zoltar's child ids via
        // getChildUniverseId), so the genesis must be keyed by its Zoltar id.
        Universe storage genesisUniverse = universes[_initialZoltarUniverseId];
        genesisUniverse.favoriteChild = 0;
        genesisUniverse.parent = 0;
        genesisUniverse.repToken = repToken;
        genesisUniverse.universeState = UniverseState.Active;
        // forkTime stays 0 until the genesis itself forks.
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
        uncappedFee = QUERY_FEE_CONTROLLER.previewFee(universeId);
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
    ///      Read once, at a query's first report, and frozen in `QueryResolution.cap`. Rounded up: two outcomes
    ///      at the cap are the fork bond Zoltar takes (2% of the supply), and the bond is converted to shares
    ///      rounded up as well. Rounding the cap down would leave the two caps a wei or two short of the bond
    ///      whenever the rate is not exactly 1, and the fork could never fire. The cap is a ceiling, not an
    ///      amount anyone is owed, so the extra wei costs nobody anything. The rate only ever rises, so the bond
    ///      in shares at fork time is never above what it was when the cap was frozen.
    function _capShares(ILituusRep repToken, uint248 universeId) internal view returns (uint256) {
        return repToken.convertToSharesUp(ZOLTAR.getUniverseTheoreticalSupply(universeId) / CAP_DIVISOR);
    }

    /* ============================================ PERMIT FUNCTIONS ============================================= */
    /**
     * @notice Applies the caller's ERC-2612 permit on a universe's wREP in favor of this contract, so a fee or
     *         a stake can be approved and paid in one multicall: [permitRep, createQuery] or [permitRep, report].
     * @dev A permit somebody else already submitted goes through as long as the allowance it set is in place;
     *      anything that leaves the allowance short of `value` reverts with PermitNotEffective.
     * @param universeId The universe whose wREP the permit is for.
     * @param value The allowance the permit grants.
     * @param deadline The permit's deadline.
     * @param v The signature's v.
     * @param r The signature's r.
     * @param s The signature's s.
     */
    function permitRep(uint248 universeId, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        ILituusRep repToken = universes[universeId].repToken;
        if (address(repToken) == address(0)) revert InvalidUniverse();
        _permit(repToken, value, deadline, v, r, s);
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
     *      The underlying is pulled on the caller's allowance to the vault when it covers the amount, through
     *      the caller's Permit2 allowance otherwise (the underlying then passes through this contract, which
     *      wraps it and hands the shares over).
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
        bool exactAssets = assetsToProvide > 0;
        assets = exactAssets ? assetsToProvide : repToken.convertToAssetsUp(sharesToReceive);

        address payer = msg.sender;
        IERC20 underlying = repToken.UNDERLYING_TOKEN();
        if (underlying.allowance(msg.sender, address(repToken)) < assets) {
            // REP amounts stay far below uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            PERMIT2.transferFrom(msg.sender, address(this), uint160(assets), address(underlying));
            payer = address(this);
        }
        if (exactAssets) {
            shares = repToken.wrap(payer, assets);
        } else {
            shares = sharesToReceive;
            // Pulls exactly `assets`: the same rounded-up conversion at the same rate.
            repToken.wrapShares(payer, shares);
        }
        if (payer == address(this)) repToken.safeTransfer(msg.sender, shares);
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
     * @dev Fee = controller base fee times the short-term demand modifier (see QueryFeeController.chargeQuery).
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

        // The controller prices the query on the universe's base fee and recent demand, and counts it.
        uint256 fee = QUERY_FEE_CONTROLLER.chargeQuery(universeId);
        if (fee == 0) revert ZeroFee();
        // The first report's stake is derived from the query fee, bounded to a fraction of the per-outcome cap
        // by _requiredStake.
        uint256 queryFeeCap = _queryFeeCap(universe.repToken, universeId);
        if (fee >= queryFeeCap) fee = queryFeeCap;
        // Take the fee: plain allowance, or the caller's Permit2 allowance (see PermitSupport).
        _pull(universe.repToken, fee);

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
        QUERY_FEE_CONTROLLER.recordQuery(universeId);

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
     *      The first report must fall within REPORTING_PERIOD of the query becoming reportable and freezes the
     *      per-outcome cap (1% of the REP supply, in wREP shares). Each later report must land within the
     *      APPEAL_PERIOD appeal window and contest the latest outcome; its stake brings the outcome to twice the
     *      total of every other outcome, bounded by the cap. When two outcomes reach the cap the query forks.
     * @param universeId The universe to report in.
     * @param queryId The query being reported on.
     * @param outcome The reported outcome (1..numberOfOutcomes, or INVALID).
     */
    function report(uint248 universeId, uint256 queryId, uint256 outcome) external nonReentrant {
        (Universe storage universe, QueryResolution storage resolution, uint48 queryCreateTime) =
            _checkReportable(universeId, queryId, outcome);
        uint16 stakeCount = resolution.stakeCount;

        uint256 cap = resolution.cap;
        if (stakeCount == 0) {
            // Only a query without a stake can lack a local record: the first touch of an inherited query stores
            // the clock it inherited (for any other query this rewrites the same value).
            resolution.queryCreateTime = queryCreateTime;
            // Freeze the per-outcome cap: the whole ladder is measured against this one value.
            // a fraction of the REP supply, bounded by max supply (100M * 1e18), within uint96
            cap = _capShares(universe.repToken, universeId);
            // forge-lint: disable-next-line(unsafe-typecast)
            resolution.cap = uint96(cap);
        }

        uint256 stake = _requiredStake(resolution, queries[queryId].fee, outcome, cap);
        _pull(universe.repToken, stake);

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
                ForkLib.forkLituusUniverse(
                    universes, queries, queryResolutions, ZOLTAR, ZOLTAR_QUESTION_DATA, universeId, queryId
                );
            }
        }
    }

    /**
     * @notice Resolves a query whose reporting or appeal window has elapsed, recording its outcome.
     * @dev The universe must exist and be Active.
     *      Two cases:
     *      (1) no report ever landed and the REPORTING_PERIOD reporting window passed ->
     *      resolves INVALID; the RESOLVER earns the time-ramped fee share;
     *      (2) stakes exist and the last one's APPEAL_PERIOD appeal window passed
     *      -> resolves to the escalation outcome and settles payoffs; otherwise reverts as not-ready.
     *      An inherited query (no local record yet) restarts its window at the parent's forkTime,
     *      whatever state its ancestor record was frozen in; only a query resolved in an ancestor
     *      is rejected.
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

        // A query resolved in an ancestor is inherited by this lineage (via getOutcome) and must not be
        // resolved again. Only the first touch of an inherited query (no local record yet) needs the walk.
        if (resolution.queryCreateTime == 0 && _findResolution(universeId, queryId) != UNRESOLVED) {
            revert QueryAlreadyResolved();
        }

        uint48 queryCreateTime = _getAndUpdateQueryCreateTime(universeId, queryId);

        if (resolution.stakeCount == 0 && queryCreateTime + REPORTING_PERIOD < block.timestamp) {
            // if the report period has passed and the query was not reported on then resolve the query as INVALID
            // This works for a query that was created in this universe and never reported on, or for an inherited
            // query that was not reported on within the window restarted at the fork.
            resolution.outcome = INVALID;

            // The resolver setting this query to INVALID earns a share of the fee
            // that ramps from 0 at the reporting deadline to the full fee three days later, then stays
            // whole with no deadline.
            uint256 queryFee = queries[queryId].fee;
            uint256 resolverPay = _timeBasedFeeShare(queryFee, block.timestamp - (queryCreateTime + REPORTING_PERIOD));
            uint256 profit = queryFee - resolverPay;
            MultiverseHelpers._consumeQueryFee(universe, queryFee);
            emit ResolverRewardPaid(msg.sender, universeId, queryId, resolverPay);
            universe.repToken.safeTransfer(msg.sender, resolverPay);
            // The unpaid fee remainder is the query's profit: burned as wREP and recorded for the fee
            // controller, the same as on the stakes path.
            if (profit > 0) {
                universe.repToken.burnShares(profit);
                QUERY_FEE_CONTROLLER.recordProfit(universeId, profit);
            }

            emit QueryResolved(msg.sender, universeId, queryId, INVALID);
        } else if (resolution.stakeCount > 0) {
            if (resolution.lastStakeTime + APPEAL_PERIOD < block.timestamp) {
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
        if (ZOLTAR.getForkTime(universeId) != 0) {
            // queryCount++ passes the current count as the new query's id, then advances it before the library runs.
            ForkLib.mirrorZoltarFork(universes, queries, queryResolutions, ZOLTAR, universeId, queryCount++);
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
        // Only while the universe is Active: once it forks, the whole pot is parked in the Zoltar
        // migration balance and stakes are claimed into a child through migrateStake.
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

        payout = MultiverseHelpers._winningPayout(resolution, outcome, amount);
    }

    /* ========================================== QUERY FEE EXTERNALS ============================================ */
    /**
     * @notice Runs the fee controller's monthly base-fee hill-climb for a universe.
     * @dev Standalone for now; it will be called from the createQuery path once incentives are wired.
     *      Only while the universe is Active — the forking window must not move the fee. The controller
     *      enforces the once-a-month cadence itself.
     * @param universeId The universe whose base fee to update.
     */
    function updateBaseFee(uint248 universeId) external {
        if (universes[universeId].universeState != UniverseState.Active) revert InvalidUniverseState();

        QUERY_FEE_CONTROLLER.updateBaseFee(universeId);
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
     *      `fee * (reportingTimestamp - queryCreateTime) / REPORTING_PERIOD`, capped at the full `fee`: the
     *      winning report can land after escalation has begun and thus past the reporting window, so
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

        MultiverseHelpers._consumeQueryFee(universes[universeId], queryFee);

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
        // is never burned here. The fee controller records the same amount for its hill-climb.
        if (profit > 0) {
            repToken.burnShares(profit);
            QUERY_FEE_CONTROLLER.recordProfit(universeId, profit);
        }

        return winnerOutcome;
    }

    /* ====================================== RESOLUTION INTERNAL FUNCTIONS ====================================== */
    /**
     * @notice Time-proportional share of a query fee: ramps linearly over REPORTING_PERIOD, then caps at the
     *         full fee with no deadline.
     * @dev Works both for the query fee after reporting and when no reporting exists (INVALID on resolve).
     * @param fee The query fee the share is drawn from.
     * @param elapsed Seconds since the ramp's origin.
     * @return The earned share.
     */
    function _timeBasedFeeShare(uint256 fee, uint256 elapsed) internal view returns (uint256) {
        return MultiverseHelpers._timeBasedFeeShare(fee, elapsed, REPORTING_PERIOD);
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
     *      the vault rate until the first stake lands. Runs report()'s gates (see _checkReportable), so a quote
     *      is returned exactly when report() would accept the stake, and reverts with report()'s error otherwise.
     *      It's still possible that the report will be rejected because someone else reports first or
     *      the report/appeal timer expires between quoting and actual reporting, but the returned stake is
     *      guaranteed to be enough if the report is accepted.
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
        (Universe storage universe, QueryResolution storage resolution,) =
            _checkReportable(universeId, queryId, outcome);

        // Before the first report the cap is not frozen yet: quote against the one report() would freeze now.
        uint256 cap = resolution.stakeCount == 0 ? _capShares(universe.repToken, universeId) : resolution.cap;
        return _requiredStake(resolution, queries[queryId].fee, outcome, cap);
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

    /// @dev The gates a report on `outcome` must pass, shared by report() and getNextRequiredStake() so the quote
    ///      never contradicts the report: the universe is Active, the query exists and is unresolved here and
    ///      along the lineage, the outcome is valid, this universe inherited the query, and the report lands in
    ///      the reporting window (first report) or the appeal window (later ones). The stake-specific gate
    ///      (CannotStakeOnOutcome) lives in _requiredStake, which both also share. Returns the query's clock in
    ///      this universe, inherited from the lineage when there is no local record yet; storing it is the
    ///      caller's.
    function _checkReportable(uint248 universeId, uint256 queryId, uint256 outcome)
        internal
        view
        returns (Universe storage universe, QueryResolution storage resolution, uint48 queryCreateTime)
    {
        // Reports can only be placed in an existing and active universe.
        universe = _checkUniverseState(universeId);
        if (queryId >= queryCount) revert InvalidQuery();

        resolution = queryResolutions[universeId][queryId];
        if (resolution.outcome != UNRESOLVED) revert QueryAlreadyResolved();

        // Outcome should be between 1 and numberOfOutcomes unless the query should be reported as INVALID
        if (outcome == UNRESOLVED) revert InvalidOutcome();
        if ((outcome > queries[queryId].numberOfOutcomes) && (outcome != INVALID)) revert InvalidOutcome();

        // A query resolved in an ancestor universe is inherited by this lineage (via getOutcome), so it
        // cannot be reported on again here. The ancestor set is fixed per lineage, so this only needs to
        // be checked on the first touch of an inherited query (no local record yet).
        if (resolution.queryCreateTime == 0 && _findResolution(universeId, queryId) != UNRESOLVED) {
            revert QueryAlreadyResolved();
        }

        queryCreateTime = _inheritedQueryCreateTime(universeId, queryId);

        if (resolution.stakeCount == 0) {
            // check that the reporting window for the query is not over yet
            if (queryCreateTime + REPORTING_PERIOD < block.timestamp) revert QueryExpired();
        } else if (resolution.lastStakeTime + APPEAL_PERIOD < block.timestamp) {
            revert AppealPeriodOver();
        }
    }

    /// @dev The exact stake the next report on `outcome` must place.
    ///      First stake: the query fee, bounded to `cap / FIRST_STAKE_CAP_DIVISOR` and rounded to a step.
    ///      Later stakes: the amount that brings the outcome to exactly twice the total of every other outcome,
    ///      bounded by the cap. An outcome that already holds that share cannot be staked on: it is the
    ///      outcome the last report backed. `cap` is the ladder's frozen cap, or before the first report the
    ///      one the first report freezes.
    function _requiredStake(QueryResolution storage resolution, uint256 fee, uint256 outcome, uint256 cap)
        internal
        view
        returns (uint256 stake)
    {
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

    /**
     * @notice Spawns the child universe for one outcome of a forking universe. Permissionless.
     * @dev Callable at any time after the fork: the spawn window never closes, but a child spawned after the
     *      migration window closes can never receive counted migrations, so it can never become the favorite child
     *      or canonical. Reverts with InvalidUniverse if `universeId` does not exist or the child already does,
     *      InvalidUniverseState if `universeId` has not forked, and InvalidOutcome unless `outcome` is a valid
     *      outcome of the forking query: 1..numberOfOutcomes or INVALID for a Lituus fork, any answer Zoltar deems
     *      well-formed for a mirrored Zoltar fork.
     *      Runs in ForkLib.spawnChildUniverse, then has the fee controller seed the child from the parent: the
     *      base fee and the demand/profit history (see QueryFeeController.seedChild). Beyond the vault deployment,
     *      the spawner pays for that seeding: one storage write per non-empty window of the 21 copied.
     * @param universeId The forked universe (any state past Active: Migration or later).
     * @param outcome The forking query's outcome this child stands for (a Zoltar answer for a mirrored fork).
     */
    function spawnChildUniverse(uint248 universeId, uint256 outcome) external nonReentrant {
        uint248 childUniverseId = ForkLib.spawnChildUniverse(
            universes,
            queries,
            queryResolutions,
            ZOLTAR,
            ZOLTAR_QUESTION_DATA,
            TOKEN_DEPLOYER,
            REPORTING_PERIOD,
            universeId,
            outcome
        );

        // Inherit the parent's base fee and its demand/profit history, so the child charges nonzero fees from
        // birth and the fee ramp and the hill-climb continue across the fork.
        QUERY_FEE_CONTROLLER.seedChild(universeId, childUniverseId, universes[universeId].forkTime);
    }

    /**
     * @notice Migrates the caller's wREP from a forking universe into one of its children.
     *         Counted voting: the running migration max designates the fork's winner.
     * @dev Only while `universeId` is in Migration and its window is open: MIGRATION_DURATION after the fork, and
     *      for a nested fork not before the parent's fork is resolved. The child for `outcome` must already be
     *      spawned (spawnChildUniverse is permissionless). Burn-based and irreversible. Reverts with
     *      InvalidUniverseState, MigrationWindowClosed or InvalidUniverse (child not spawned). Runs in ForkLib.migrate.
     * @param universeId The forking universe to migrate out of.
     * @param outcome The forking query's outcome whose child to migrate into, as passed to spawnChildUniverse.
     * @param shares The amount of the caller's parent wREP shares to migrate.
     * @return childUniverseId The child the wREP landed in.
     * @return childShares The child wREP credited to the caller.
     */
    function migrate(uint248 universeId, uint256 outcome, uint256 shares)
        external
        nonReentrant
        returns (uint248 childUniverseId, uint256 childShares)
    {
        return ForkLib.migrate(universes, ZOLTAR, GENESIS_UNIVERSE_ID, MIGRATION_DURATION, universeId, outcome, shares);
    }

    /**
     * @notice Claims the caller's stake on a query out of a forked universe, into one of its children. What
     *         comes back depends on the query's record in the parent:
     *         - the forking query: in the child for outcome X the query is resolved to X, so a stake on X is a
     *           winning stake there and comes back with the return every child pays (see ForkLib._forkPayout). The
     *           child is the one of the stake's outcome.
     *         - a query resolved before the fork: a stake on the winning outcome comes back with the payout
     *           claim() would have made in the parent, into the child of the caller's choice.
     *         - any other query: the game restarts in the children, so the stake comes back as it was, into
     *           the child of the caller's choice.
     * @dev Open for as long as migrate() is, into an already spawned child (same reverts). Claimable once: the
     *      stake is zeroed. Reverts with NothingToClaim if the caller has no stake on `outcome`, and with
     *      NotAWinningOutcome if the stake cannot win in that child. Runs in ForkLib.migrateStake.
     * @param universeId The forked universe the stake was placed in.
     * @param queryId The query the stake was placed on.
     * @param outcome The outcome the caller staked on.
     * @param childOutcome The outcome whose child receives the payout. Must equal `outcome` for the forking
     *        query, since no other outcome wins in that child.
     */
    function migrateStake(uint248 universeId, uint256 queryId, uint256 outcome, uint256 childOutcome)
        external
        nonReentrant
    {
        ForkLib.migrateStake(
            universes,
            queryResolutions,
            ZOLTAR,
            GENESIS_UNIVERSE_ID,
            MIGRATION_DURATION,
            universeId,
            queryId,
            outcome,
            childOutcome
        );
    }

    /**
     * @notice Claims the caller's stakes on several queries of a forked universe into one child, in a single
     *         transfer. Same rules per stake as migrateStake.
     * @dev A repeated (query, outcome) pair reverts on its second occurrence (the stake is already zeroed),
     *      failing the whole batch; so do empty or mismatched arrays (InvalidClaimBatch). The forking query can be
     *      part of the batch only when `childOutcome` is the outcome staked on. Runs in ForkLib.migrateStakes.
     * @param universeId The forked universe the stakes were placed in.
     * @param queryIds The queries the stakes were placed on.
     * @param outcomes The outcome staked on per query, parallel to `queryIds`.
     * @param childOutcome The outcome whose child receives all the payouts.
     */
    function migrateStakes(
        uint248 universeId,
        uint256[] calldata queryIds,
        uint256[] calldata outcomes,
        uint256 childOutcome
    ) external nonReentrant {
        ForkLib.migrateStakes(
            universes,
            queryResolutions,
            ZOLTAR,
            GENESIS_UNIVERSE_ID,
            MIGRATION_DURATION,
            universeId,
            queryIds,
            outcomes,
            childOutcome
        );
    }

    /**
     * @notice Advances a forking universe out of Migration after the migration window closes.
     *         Permissionless.
     * @dev For now it always resolves the fork: the favorite child (the running migration max) wins and the
     *      universe moves to PostFork; a canonical universe's winner becomes the canonicalHeir. Reverts with
     *      InvalidUniverseState unless the universe is in Migration. Root-first: reverts with
     *      ParentForkNotResolved until the parent's fork is resolved, and with MigrationWindowNotClosed until
     *      MIGRATION_DURATION has passed since the fork. Runs in ForkLib.advanceForkState; moves the canonical
     *      timeline here when the library says so.
     * @param universeId The forking universe to advance.
     */
    function advanceForkState(uint248 universeId) external nonReentrant {
        uint248 newCanonicalHeir =
            ForkLib.advanceForkState(universes, GENESIS_UNIVERSE_ID, MIGRATION_DURATION, universeId);
        if (newCanonicalHeir != 0) canonicalHeir = newCanonicalHeir;
    }

    /**
     * @notice Mirrors a native Zoltar fork of a universe into this Multiverse. Permissionless.
     * @dev Reentrancy-guarded wrapper over ForkLib.mirrorZoltarFork; resolve() takes the same path implicitly.
     *      Reverts unless this universe is Active and its Zoltar counterpart has forked.
     * @param universeId The universe whose Zoltar fork to mirror.
     */
    function mirrorZoltarFork(uint248 universeId) external nonReentrant {
        // queryCount++ passes the current count as the new query's id, then advances it before the library runs.
        ForkLib.mirrorZoltarFork(universes, queries, queryResolutions, ZOLTAR, universeId, queryCount++);
    }

    /* =========================================== INTERNAL HELPERS ============================================== */
    /**
     * @notice Checks that a universe can be operated on directly — it must exist and be Active — and
     *         returns it.
     * @dev Reverts with InvalidUniverse if the universe does not exist
     *      and InvalidUniverseState if it is in any forking state.
     */
    function _checkUniverseState(uint248 universeId) internal view returns (Universe storage universe) {
        return MultiverseHelpers._checkUniverseState(universes, universeId);
    }

    /**
     * @notice Returns when a query became reportable in a universe, without storing anything.
     * @dev If the local record already has a create time, returns it. Otherwise the query can only be
     *      acted on here if it was inherited through a fork, i.e. its origin universe is an ancestor of
     *      this one — enforced by walking the parent chain. Its reportable time is then the parent's
     *      forkTime: the moment of the fork that carried the query in. Every unresolved query restarts
     *      here with a full window at the fork, whatever state its ancestor record was frozen in — those
     *      stakes stay in the ancestor record, refundable through migrateStake.
     * @param universeId The universe the query is being acted on in.
     * @param queryId The query in question.
     * @return queryCreateTime The timestamp the query became reportable in this universe.
     */
    function _inheritedQueryCreateTime(uint248 universeId, uint256 queryId)
        internal
        view
        returns (uint48 queryCreateTime)
    {
        queryCreateTime = queryResolutions[universeId][queryId].queryCreateTime;
        if (queryCreateTime != 0) return queryCreateTime;
        // The query was not created in this universe, so it is only available here if this universe
        // descends from the query's origin universe. New queries cannot be created in a forked (ancestor)
        // universe, so an origin-is-ancestor match guarantees the query was genuinely inherited.
        if (!_isSelfOrAncestor(queries[queryId].originUniverse, universeId)) {
            revert QueryNotInherited();
        }
        // The query becomes reportable in this universe at the moment of the fork that carried it in:
        // the parent's forkTime (this universe's own forkTime is 0 until it forks itself). The genesis
        // has no parent and never reaches here: a query it lacks a record for is not inherited.
        queryCreateTime = universes[universes[universeId].parent].forkTime;
    }

    /**
     * @notice Returns when a query became reportable in a universe, setting it lazily on first access.
     * @dev See _inheritedQueryCreateTime for the rule; this stores the inherited clock in the local
     *      record so the query's window is anchored for good in this universe.
     * @param universeId The universe the query is being acted on in.
     * @param queryId The query in question.
     * @return queryCreateTime The timestamp the query became reportable in this universe.
     */
    function _getAndUpdateQueryCreateTime(uint248 universeId, uint256 queryId)
        internal
        returns (uint48 queryCreateTime)
    {
        QueryResolution storage resolution = queryResolutions[universeId][queryId];
        if (resolution.queryCreateTime != 0) return resolution.queryCreateTime;
        queryCreateTime = _inheritedQueryCreateTime(universeId, queryId);
        resolution.queryCreateTime = queryCreateTime;
    }
}
