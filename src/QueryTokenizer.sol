// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IMultiverse } from "./interfaces/IMultiverse.sol";
import { IQueryToken } from "./interfaces/IQueryToken.sol";
import { IQueryTokenizer } from "./interfaces/IQueryTokenizer.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
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
 *      only path to a child. Inside the migration window a holder picks a child: the parent tokens burn,
 *      their share of the pool migrates through the Multiverse as a counted vote for that child, and the
 *      same number of the child's tokens is minted to the holder. Tokens not migrated stay in the parent
 *      with their share of the pool, worthless.
 */
contract QueryTokenizer is ReentrancyGuard, IQueryTokenizer {
    using SafeERC20 for ILituusRep;

    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    // 1e18 QueryToken wei = the right to create one query (18 decimals).
    uint256 public constant ONE_QUERY = 1e18;
    // Fixed 10% mint premium, applied as ×11/10 (equals the fee controller's max monthly step).
    uint256 public constant PREMIUM_NUMERATOR = 11;
    uint256 public constant PREMIUM_DENOMINATOR = 10;

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
    error CannotSet();

    /* ================================================= EVENTS ================================================== */
    event QueryTokenDeployed(uint248 indexed universeId, address token);
    event Minted(address indexed minter, uint248 indexed universeId, uint256 amount, uint256 cost);
    event Redeemed(address indexed redeemer, uint248 indexed universeId, uint256 price);
    event QueryTokensMigrated(
        address indexed holder,
        uint248 indexed parentUniverseId,
        uint248 indexed childUniverseId,
        uint256 amount,
        uint256 migratedRep
    );

    /* =========================================== CONSTRUCTOR/SETTER ============================================ */
    constructor() {
        DEPLOYER = msg.sender;
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
        (uint256 price,) = _mintPrice(multiverse, universeId);
        return price;
    }

    /// @dev `mintPrice` body taking the Multiverse as a parameter to reduce storage reads. Also returns
    ///      the universe's Lituus REP so `mint` prices and pays with a single Multiverse call.
    function _mintPrice(IMultiverse multiverse_, uint248 universeId) internal view returns (uint256, ILituusRep) {
        (uint256 uncappedFee, uint256 cap, ILituusRep repToken) = multiverse_.getMintPricing(universeId);
        uint256 price = uncappedFee * PREMIUM_NUMERATOR / PREMIUM_DENOMINATOR;
        return (price > cap ? cap : price, repToken);
    }

    /* ============================================= CORE ACTIONS =============================================== */
    /// @inheritdoc IQueryTokenizer
    function mint(uint248 universeId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IMultiverse multiverse_ = multiverse;

        // Price first: _mintPrice reverts for a nonexistent or non-current universe, so no QueryToken
        // is ever deployed for an invalid universe. A zero cost is rejected — free tokens would dilute
        // the pool average for every existing holder.
        (uint256 price, ILituusRep repToken) = _mintPrice(multiverse_, universeId);
        uint256 cost = price * amount;
        if (cost == 0) revert ZeroCost();
        repToken.safeTransferFrom(msg.sender, address(this), cost);
        pooledRep[universeId] += cost;

        IQueryToken queryToken = _getOrDeployToken(universeId);
        queryToken.mint(msg.sender, amount * ONE_QUERY);
        emit Minted(msg.sender, universeId, amount, cost);
    }

    /// @inheritdoc IQueryTokenizer
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
    /// @inheritdoc IQueryTokenizer
    function migrate(uint248 parentUniverseId, uint256 childOutcome, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IQueryToken parentToken = token[parentUniverseId];
        if (address(parentToken) == address(0)) revert QueryTokenNotExisting();
        uint256 wholeTokensTotalSupply = parentToken.totalSupply() / ONE_QUERY;
        if (wholeTokensTotalSupply == 0) revert NoWholeTokens();

        // The tokens take their share of the pool, rounded down: the holders who stay never lose, and the
        // last tokens out take the whole pool with them (nothing sweeps a forked universe's pool later).
        uint256 pooledRepTokens = pooledRep[parentUniverseId];
        uint256 migratedRep = pooledRepTokens * amount / wholeTokensTotalSupply;

        // Reverts with ERC20InsufficientBalance if the caller holds fewer whole tokens than `amount`.
        parentToken.burn(msg.sender, amount * ONE_QUERY);
        pooledRep[parentUniverseId] = pooledRepTokens - migratedRep;

        // The Multiverse burns this contract's parent wREP (owner lane, no approval), routes it through
        // Zoltar and hands back child wREP, which backs the child tokens from here on. The parent's state,
        // its window and the child's existence are its checks.
        (uint248 childUniverseId, uint256 childShares) = multiverse.migrate(parentUniverseId, childOutcome, migratedRep);
        pooledRep[childUniverseId] += childShares;

        IQueryToken childToken = _getOrDeployToken(childUniverseId);
        childToken.mint(msg.sender, amount * ONE_QUERY);
        emit QueryTokensMigrated(msg.sender, parentUniverseId, childUniverseId, amount, migratedRep);
    }

    /* ================================================ INTERNALS ================================================ */
    function _getOrDeployToken(uint248 universeId) internal returns (IQueryToken queryToken) {
        queryToken = token[universeId];
        if (address(queryToken) == address(0)) {
            // TODO: token naming (same pattern as Lituus REP)
            queryToken = IQueryToken(address(new QueryToken(address(this), "Lituus Query Token", "QT")));
            token[universeId] = queryToken;
            emit QueryTokenDeployed(universeId, address(queryToken));
        }
    }
}
