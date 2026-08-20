// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IMultiverse } from "./interfaces/IMultiverse.sol";
import { IQueryToken } from "./interfaces/IQueryToken.sol";
import { IQueryTokenizer } from "./interfaces/IQueryTokenizer.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { IZoltar } from "./interfaces/IZoltar.sol";
import { QueryToken } from "./QueryToken.sol";

/**
 * @title QueryTokenizer
 * @notice The Query Token protocol: a single immutable, trustless, governance-free contract that lets
 *         users prepay for Queries. Minting deposits `currentQueryFee × 1.10` (capped at half the fork
 *         threshold) in Lituus REP into a per-universe pool and issues a per-universe `QueryToken` ERC20;
 *         redeeming destroys one token and creates a normal Query in the oracle, paying the pool's
 *         per-token average.
 * @dev One contract serves the whole fork tree (mirroring the single-contract `Multiverse`); only the
 *      `QueryToken` ERC20 instances deploy per universe. Amounts are in WHOLE QUERIES;
 *      internally scaled by `ONE_QUERY` (1e18) since one whole token = one query.
 *
 *      The pooled-average design has one key property: redeeming pays `pooledRep / wholeTokensTotalSupply`,
 *      and removing exactly the average leaves the average unchanged — so only mints (at new fees) move
 *      the price. The redemption fee is recorded whole, uncapped: the pool average can exceed half the
 *      fork threshold (the average never decays while the threshold can decline), and the oracle handles
 *      that separately.
 *
 *      Query tokens are universe-specific and are NEVER forwarded to the heir: once a universe forks,
 *      minting and redeeming freeze there (the oracle rejects non-current universes) and migration is the
 *      only path to a child.
 *
 *      Fork migration is NOT implemented yet (`migrate` reverts). Intended semantics: during the fork
 *      window a holder picks a child universe; the matching pool share of Lituus REP migrates via the
 *      Multiverse, which custodies the sibling-universe REP, and the migrated amount counts as a vote for
 *      the chosen universe. Unmigrated tokens become useless along with their share of the pool.
 */
contract QueryTokenizer is ReentrancyGuard, IQueryTokenizer {
    using SafeERC20 for ILituusRep;

    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    // 1e18 QueryToken wei = the right to create one query (18 decimals).
    uint256 public constant ONE_QUERY = 1e18;
    // Fixed 10% mint premium, applied as ×11/10 (equals the fee controller's max monthly step).
    uint256 public constant PREMIUM_NUMERATOR = 11;
    uint256 public constant PREMIUM_DENOMINATOR = 10;

    // The underlying Zoltar oracle (source of the fork threshold for the mint price cap).
    IZoltar public immutable ZOLTAR;
    // The deployer, allowed to set the Multiverse address once after it is deployed.
    address private immutable DEPLOYER;

    // The Multiverse this tokenizer creates queries in. Set once by the deployer after the Multiverse is
    // deployed.
    IMultiverse public multiverse;

    /* ================================================ VARIABLES ================================================ */
    // The per-universe QueryToken ERC20, deployed lazily on first mint into a universe.
    mapping(uint248 universeId => IQueryToken) public token;
    // Per-universe pooled Lituus REP backing its outstanding query tokens.
    mapping(uint248 universeId => uint256) public pooledRep;

    /* ================================================= ERRORS ================================================== */
    error ZeroAmount();
    error ZeroCost();
    error QueryTokenNotExisting();
    error NoWholeTokens();
    error MigrationNotImplemented();
    error CannotSet();

    /* ================================================= EVENTS ================================================== */
    event QueryTokenDeployed(uint248 indexed universeId, address token);
    event Minted(address indexed minter, uint248 indexed universeId, uint256 amount, uint256 cost);
    event Redeemed(address indexed redeemer, uint248 indexed universeId, uint256 price);

    /* =========================================== CONSTRUCTOR/SETTER ============================================ */
    /// @param zoltar The underlying Zoltar oracle (used for the fork-threshold cap on the mint price).
    constructor(IZoltar zoltar) {
        DEPLOYER = msg.sender;
        ZOLTAR = zoltar;
    }

    /**
     * @notice Sets the Multiverse. Callable once, by the deployer, after the Multiverse is deployed.
     * @dev Deploy order: this tokenizer first, then the Multiverse with this address, then call this.
     * @param multiverse_ The Multiverse contract.
     */
    function setMultiverse(IMultiverse multiverse_) external {
        if (msg.sender != DEPLOYER || address(multiverse) != address(0)) revert CannotSet();
        multiverse = multiverse_;
    }

    /* ============================================== PRICE (VIEW) =============================================== */
    /**
     * @notice The Lituus REP cost to mint one Query Token in a universe: the full demand-inclusive query
     *         fee plus the fixed 10% premium, capped at half the fork threshold.
     * @dev The cap keeps every deposit at or under the fee cap the oracle enforces on queries.
     * @param universeId The universe to price.
     * @return The mint price per whole query, in Lituus REP.
     */
    function mintPrice(uint248 universeId) public view returns (uint256) {
        return _mintPrice(multiverse, universeId);
    }

    /// @dev `mintPrice` body taking the Multiverse as a parameter to reduce storage reads.
    function _mintPrice(IMultiverse multiverse_, uint248 universeId) internal view returns (uint256) {
        uint256 price = multiverse_.previewQueryFeeUncapped(universeId) * PREMIUM_NUMERATOR / PREMIUM_DENOMINATOR;
        // TODO: the fork threshold will be converted to Lituus REP later
        uint256 cap = ZOLTAR.getForkThreshold(universeId) / 2;
        return price > cap ? cap : price;
    }

    /* ============================================= CORE ACTIONS =============================================== */
    /**
     * @notice Mints `amount` whole Query Tokens for the caller, depositing `mintPrice × amount` REP.
     * @dev Caller must approve this contract for the universe's Lituus REP.
     * @param universeId The universe to mint tokens for.
     * @param amount Number of whole query rights to mint.
     */
    function mint(uint248 universeId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IMultiverse multiverse_ = multiverse;

        // Price first: _mintPrice reverts for a nonexistent or non-current universe, so no QueryToken
        // is ever deployed for an invalid universe. A zero cost is rejected — free tokens would dilute
        // the pool average for every existing holder.
        uint256 cost = _mintPrice(multiverse_, universeId) * amount;
        if (cost == 0) revert ZeroCost();
        multiverse_.repTokenOf(universeId).safeTransferFrom(msg.sender, address(this), cost);
        pooledRep[universeId] += cost;

        IQueryToken queryToken = _getOrDeployToken(universeId);
        queryToken.mint(msg.sender, amount * ONE_QUERY);
        emit Minted(msg.sender, universeId, amount, cost);
    }

    /**
     * @notice Redeems one whole Query Token: destroys it and creates a normal Query in the oracle on the
     *         caller's behalf, paying the pool's per-token average as the fee.
     * @dev Removing exactly the average leaves the average unchanged for remaining holders. The fee is
     *      recorded whole, uncapped — if it exceeds half the fork threshold, the oracle clamps the first
     *      report's stake instead of the fee.
     * @param universeId The universe to redeem in.
     * @param question The question text for the created query.
     * @param numberOfOutcomes The number of reportable outcomes.
     */
    function redeem(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external nonReentrant {
        IQueryToken queryToken = token[universeId];
        if (address(queryToken) == address(0)) revert QueryTokenNotExisting();
        uint256 wholeTokensTotalSupply = queryToken.totalSupply() / ONE_QUERY;
        if (wholeTokensTotalSupply == 0) revert NoWholeTokens();

        // Price of this exact token = the pool average per query.
        uint256 pooledRepTokens = pooledRep[universeId];
        uint256 price = pooledRepTokens / wholeTokensTotalSupply;

        // Reverts with ERC20InsufficientBalance if the caller holds less than one whole token,
        // so no separate balance pre-check is needed.
        queryToken.burn(msg.sender, ONE_QUERY);
        pooledRep[universeId] = pooledRepTokens - price;

        // Push the REP to the oracle, then create the query at exactly `price`, attributed to the redeemer.
        IMultiverse multiverse_ = multiverse;
        multiverse_.repTokenOf(universeId).safeTransfer(address(multiverse_), price);
        multiverse_.createQueryFromTokenizer(universeId, question, numberOfOutcomes, price, msg.sender);

        emit Redeemed(msg.sender, universeId, price);
    }

    /* ============================================ FORK MIGRATION =============================================== */
    /**
     * @notice Migrates `amount` whole Query Tokens from a forking parent universe to a chosen child.
     *         NOT IMPLEMENTED YET — reverts.
     * @dev Intended semantics (pending the core fork workstream): during the fork window the holder picks
     *      a child universe; the parent tokens burn, the matching pool share of Lituus REP migrates via
     *      the Multiverse (which custodies the sibling-universe REP), the migrated amount counts as a vote
     *      for the chosen universe, and equivalent child Query Tokens are minted to the holder. Unmigrated
     *      tokens are destroyed along with their share of the pool once the window closes.
     * @param parentUniverseId The forking (parent) universe.
     * @param childUniverseId The child universe to migrate into.
     * @param amount Number of whole query rights to migrate.
     */
    function migrate(uint248 parentUniverseId, uint248 childUniverseId, uint256 amount) external nonReentrant {
        // Statement-expressions silence the unused-parameter warnings; the named parameters document
        // the intended future interface.
        parentUniverseId;
        childUniverseId;
        amount;
        revert MigrationNotImplemented();
    }

    /* ================================================ INTERNALS ================================================ */
    function _getOrDeployToken(uint248 universeId) internal returns (IQueryToken queryToken) {
        queryToken = token[universeId];
        if (address(queryToken) == address(0)) {
            queryToken = IQueryToken(address(new QueryToken(address(this), "Lituus Query Token", "QT")));
            token[universeId] = queryToken;
            emit QueryTokenDeployed(universeId, address(queryToken));
        }
    }
}
